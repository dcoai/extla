defmodule ExTLA.InvariantModesTest do
  # Compiles modules under different `config :extla, mode:` values, which is application
  # state, so these cannot run beside anything else.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @source """
  defmodule <NAME> do
    use GenServer
    use ExTLA.Invariant

    invariant :never_negative, desc: "no negative balance" do
      state.balance >= 0
    end

    invariant :costly, enabled: false do
      raise "this must never be compiled in"
    end

    def init(balance), do: {:ok, %{balance: balance}}

    def handle_call({:withdraw, n}, _from, state) do
      {:reply, :ok, %{state | balance: state.balance - n}}
    end
  end
  """

  defp compile(name, mode) do
    previous = Application.get_env(:extla, :mode)
    Application.put_env(:extla, :mode, mode)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:extla, :mode, previous),
        else: Application.delete_env(:extla, :mode)
    end)

    [{module, _binary} | _] =
      Code.compile_string(String.replace(@source, "<NAME>", Atom.to_string(name)))

    module
  end

  defp withdraw(module, amount) do
    {:ok, pid} = GenServer.start_link(module, 100)
    Process.unlink(pid)
    ExTLA.TestCall.call(pid, {:withdraw, amount})
  end

  # The layer's headline claim, and the reason `ExTLA.Config.mode/0` is a `compile_env`
  # macro rather than a runtime lookup: not cheap emitted code, but none.
  test ":disabled emits no wrapper at all" do
    module = compile(DisabledCounter, :disabled)

    refute function_exported?(module, :__tla_invariant__, 2)
    refute function_exported?(module, :__tla_mode__, 0)

    # No wrapper, so the violating withdrawal simply happens.
    assert withdraw(module, 500) == {:ok, :ok}
  end

  test ":log_only reports and lets the process carry on" do
    module = compile(LoggingCounter, :log_only)

    log = capture_log(fn -> assert withdraw(module, 500) == {:ok, :ok} end)

    assert log =~ "INVARIANT VIOLATED: never_negative"
    assert log =~ "no negative balance"
  end

  test ":enabled raises, and the mode is baked into the module" do
    module = compile(RaisingCounter, :enabled)

    assert module.__tla_mode__() == :enabled
    assert {:violation, violation} = withdraw(module, 500)
    assert violation.name == :never_negative
  end

  # `enabled: false` is resolved at compile time. If it were not, this module would not
  # compile at all — the block raises.
  test "`enabled: false` emits nothing anywhere" do
    module = compile(FilteredCounter, :enabled)

    assert module.__tla_invariant__(:never_negative, %{balance: 1})
    assert_raise FunctionClauseError, fn -> module.__tla_invariant__(:costly, %{balance: 1}) end
  end

  # #149. The test above passed for the whole life of the option and proved nothing about the
  # idiom `spec/03:634` documents, because a literal `false` is the ONE input that worked.
  #
  # Options are stored with `Macro.escape/1`, so `enabled: Mix.env() == :test` was kept as a
  # `{:==, _, _}` tuple and `Enum.filter/2` keeps everything but `false` and `nil`. Every
  # expression was truthy, so "compile this out except in test" emitted the check everywhere —
  # including `:dev`, which is `:enabled` by default and is where the lever is most obviously
  # meant to help.
  #
  # These assert on what was EMITTED, not on what the checker later reports: the whole claim
  # is that no code exists, and a runtime assertion cannot tell "absent" from "present and
  # false".
  describe "`enabled:` is an expression, not a literal (#149)" do
    @expression_source """
    defmodule <NAME> do
      use GenServer
      use ExTLA.Invariant

      invariant :off_here, enabled: Mix.env() == :prod do
        raise "this must never be compiled in"
      end

      invariant :on_here, enabled: Mix.env() == :test do
        state.balance >= 0
      end

      def init(balance), do: {:ok, %{balance: balance}}
    end
    """

    defp compile_expression(name) do
      source = String.replace(@expression_source, "<NAME>", inspect(name))
      [{module, _}] = Code.compile_string(source)
      module
    end

    test "an expression that is false at compile time emits nothing" do
      module = compile_expression(EnabledFalseByExpression)

      assert_raise FunctionClauseError, fn ->
        module.__tla_invariant__(:off_here, %{balance: 1})
      end
    end

    test "an expression that is true at compile time emits the check" do
      module = compile_expression(EnabledTrueByExpression)

      assert module.__tla_invariant__(:on_here, %{balance: 1})
    end

    test "a non-boolean value is refused rather than treated as true" do
      source = """
      defmodule EnabledNonBoolean do
        use GenServer
        use ExTLA.Invariant

        invariant :bad, enabled: :yes do
          state.balance >= 0
        end

        def init(balance), do: {:ok, %{balance: balance}}
      end
      """

      error = assert_raise ArgumentError, fn -> Code.compile_string(source) end

      assert error.message =~ "invariant :bad"
      assert error.message =~ "must evaluate to a boolean at compile time"
      assert error.message =~ ":yes"
    end

    # The option is filtered for all four declaration kinds by `declared/2`, and before #149
    # three of them had no coverage of it at all.
    test "it applies to action properties, preconditions and postconditions too" do
      source = """
      defmodule EnabledEveryKind do
        use GenServer
        use ExTLA.Invariant

        action_property :ap_off, enabled: Mix.env() == :prod do
          raise "never compiled in"
        end

        precondition {:withdraw, _n}, enabled: Mix.env() == :prod do
          raise "never compiled in"
        end

        postcondition {:withdraw, _n}, enabled: Mix.env() == :prod do
          raise "never compiled in"
        end

        def init(balance), do: {:ok, %{balance: balance}}
      end
      """

      [{module, _}] = Code.compile_string(source)

      # Every declaration in the module was filtered, so the predicate function is not
      # merely clause-less — it is never defined. That is the strongest form of the claim
      # `:disabled emits nothing` makes, and the one a runtime check cannot make.
      refute function_exported?(module, :__tla_action_property__, 3)

      assert module.__tla_conditions__(:precondition) == []
      assert module.__tla_conditions__(:postcondition) == []
    end
  end

  # #149 item 2, and the same root cause as the option above: declaration options were stored
  # wholesale and consulted by name with `Keyword.get/3` defaults, so a key nobody reads and a
  # key nobody wrote were indistinguishable.
  describe "unknown declaration options are refused" do
    defp refuse_options(source) do
      assert_raise CompileError, fn -> Code.compile_string(source) end
    end

    test "a typo'd option names the key and what the declaration accepts" do
      error =
        refuse_options("""
        defmodule OptionTypo do
          use GenServer
          use ExTLA.Invariant

          invariant :i, callbaks: [:handle_cast] do
            state.n >= 0
          end

          def init(a), do: {:ok, a}
        end
        """)

      assert error.description =~ "invariant :i"
      assert error.description =~ "unknown option :callbaks"
      assert error.description =~ ":desc, :enabled, :callbacks"
    end

    # `callbacks:` is honoured only where `applicable/2` is reached, which is the wrapper —
    # so invariants and action properties. Preconditions and postconditions are emitted from
    # `__tla_conditions__/1` and never consult it, so it used to be accepted and ignored.
    # Accepted-and-ignored is the same defect as unknown, one step subtler.
    test "an option that exists but is not honoured here is refused too" do
      error =
        refuse_options("""
        defmodule OptionNotHonoured do
          use GenServer
          use ExTLA.Invariant

          precondition {:withdraw, _n}, callbacks: [:handle_cast] do
            true
          end

          def init(a), do: {:ok, a}
        end
        """)

      assert error.description =~ "precondition"
      assert error.description =~ "unknown option :callbacks"
      assert error.description =~ ":desc, :enabled"
    end

    test "every accepted option still compiles on every kind that takes it" do
      [{module, _}] =
        Code.compile_string("""
        defmodule OptionsAllAccepted do
          use GenServer
          use ExTLA.Invariant

          invariant :i, desc: "d", enabled: true, callbacks: [:handle_cast] do
            state.n >= 0
          end

          action_property :ap, desc: "d", enabled: true, callbacks: [:handle_cast] do
            new.n >= old.n
          end

          precondition {:withdraw, _n}, desc: "d", enabled: true do
            true
          end

          postcondition {:withdraw, _n}, desc: "d", enabled: true do
            true
          end

          def init(a), do: {:ok, a}
        end
        """)

      assert module.__tla_invariant__(:i, %{n: 1})
    end
  end

  # #166. A `callbacks:` VALUE naming a callback that does not exist silently deleted the
  # declaration: `applicable/2` keeps a name only where the callback matches, so a typo left
  # every wrapper with an empty name list. Verified before the fix — a withdrawal of 999
  # against a balance of 100 returned `:ok` and left `-899`, with the invariant declared.
  #
  # This is #158's defect one level down: there the option KEY was unchecked, here the VALUE.
  describe "`callbacks:` values are checked (#166)" do
    test "a callback that is not instrumented at all is a compile error" do
      error =
        assert_raise CompileError, fn ->
          Code.compile_string("""
          defmodule CallbacksTypo do
            use GenServer
            use ExTLA.Invariant

            invariant :never_negative, callbacks: [:handle_cal] do
              state.balance >= 0
            end

            def init(b), do: {:ok, %{balance: b}}
            def handle_call({:withdraw, n}, _f, s), do: {:reply, :ok, %{s | balance: s.balance - n}}
          end
          """)
        end

      assert error.description =~ "invariant :never_negative"
      assert error.description =~ ":handle_cal"
      assert error.description =~ "not an instrumented callback"
    end

    test "a real callback the module does not define warns rather than failing" do
      # Legitimate in one case — a callback added in a later edit — so this is a warning.
      # Silence is what it must not be.
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule CallbacksUndefined do
            use GenServer
            use ExTLA.Invariant

            invariant :never_negative, callbacks: [:handle_cast] do
              state.balance >= 0
            end

            def init(b), do: {:ok, %{balance: b}}
            def handle_call({:withdraw, n}, _f, s), do: {:reply, :ok, %{s | balance: s.balance - n}}
          end
          """)
        end)

      assert warning =~ ":never_negative"
      assert warning =~ ":handle_cast"
      assert warning =~ "will never be checked"
    end

    test "a correct callbacks: value still compiles silently" do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule CallbacksFine do
            use GenServer
            use ExTLA.Invariant

            invariant :never_negative, callbacks: [:handle_call] do
              state.balance >= 0
            end

            def init(b), do: {:ok, %{balance: b}}
            def handle_call({:withdraw, n}, _f, s), do: {:reply, :ok, %{s | balance: s.balance - n}}
          end
          """)
        end)

      refute warning =~ "never be checked"
    end
  end

  # #175. `invariant_test.exs`'s "one restricted to a callback is not checked in the others"
  # does not discriminate on `callbacks:` at all: making `applicable/2` ignore the option
  # entirely leaves it green. Its apparent discrimination comes from declaration ORDER —
  # `never_negative` is declared before `audited` and raises first, so `audited` never gets a
  # chance whether or not the restriction is honoured.
  #
  # Here the restricted invariant is declared FIRST, so honouring `callbacks:` and ignoring it
  # produce different reported violations. That is the assertion the other test's name makes.
  describe "`callbacks:` actually restricts (#175)" do
    @restricted_first """
    defmodule CallbacksRestrictedFirst do
      use GenServer
      use ExTLA.Invariant

      # Declared FIRST, and restricted to a callback this test does not use. If the
      # restriction were ignored this would fire, because :skim breaks it too.
      invariant :audited, callbacks: [:handle_call] do
        state.logged >= state.moved
      end

      invariant :never_negative do
        state.balance >= 0
      end

      def init(_), do: {:ok, %{balance: 100, logged: 0, moved: 0}}

      def handle_cast(:skim, s),
        do: {:noreply, %{s | balance: s.balance - 1_000, moved: s.moved + 1}}
    end
    """

    test "a restricted invariant does not fire in a callback it excludes" do
      [{module, _}] = Code.compile_string(@restricted_first)

      {:ok, pid} = GenServer.start_link(module, [])
      Process.unlink(pid)
      ref = Process.monitor(pid)

      GenServer.cast(pid, :skim)

      assert_receive {:DOWN, ^ref, :process, ^pid, {%ExTLA.Invariant.Violation{} = violation, _}}

      # Both invariants are broken by `:skim`. `audited` is declared first and would be
      # reported first if `callbacks:` were ignored, so the NAME is the whole assertion.
      assert violation.name == :never_negative,
             "callbacks: was ignored — the restricted invariant fired in a callback it excludes"
    end

    test "and the excluded invariant really would have fired otherwise" do
      # Without this the test above could pass because `audited` holds, which would make it
      # assert nothing about the restriction.
      unrestricted = String.replace(@restricted_first, ", callbacks: [:handle_call]", "")

      unrestricted =
        String.replace(unrestricted, "CallbacksRestrictedFirst", "CallbacksUnrestricted")

      [{module, _}] = Code.compile_string(unrestricted)

      {:ok, pid} = GenServer.start_link(module, [])
      Process.unlink(pid)
      ref = Process.monitor(pid)

      GenServer.cast(pid, :skim)

      assert_receive {:DOWN, ^ref, :process, ^pid, {%ExTLA.Invariant.Violation{} = violation, _}}

      assert violation.name == :audited
    end
  end

  describe "telemetry" do
    test "a violation is announced" do
      module = compile(TelemetryCounter, :log_only)
      handler = {__MODULE__, self()}

      :telemetry.attach(
        handler,
        [:extla, :invariant, :violated],
        fn event, _measure, metadata, pid -> send(pid, {event, metadata}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      capture_log(fn -> withdraw(module, 500) end)

      assert_received {[:extla, :invariant, :violated], metadata}
      assert metadata.name == :never_negative
      assert metadata.module == module
    end

    # Successes are the hot path: a transition can fire four of these, and
    # `:telemetry.execute/3` is about a microsecond even with nothing attached. So the
    # quiet wrapper does not call the arity that would emit them.
    test "a success is not announced unless the module asked for it" do
      module = compile(QuietCounter, :enabled)
      handler = {__MODULE__, :checked}

      :telemetry.attach(
        handler,
        [:extla, :invariant, :checked],
        fn event, _measure, metadata, pid -> send(pid, {event, metadata}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, pid} = GenServer.start_link(module, 100)
      assert GenServer.call(pid, {:withdraw, 1}) == :ok

      refute_received {[:extla, :invariant, :checked], _metadata}
      assert module.__tla_telemetry__() == :quiet
    end
  end

  describe "a GenServer whose author wrote no init/1" do
    # `** (ArgumentError) cannot make function init/1 overridable because it was not
    # defined` — from `Module.make_overridable/2`, naming neither this library nor the
    # cause (#171). Layer 1 hit it for any module with an invariant that applies to
    # `init`; Layer 3 hit it unconditionally. The example at the top of `ExTLA.Invariant`'s
    # own moduledoc produced it, which is the first thing a reader copies.
    #
    # `use GenServer` injects `init/1` from its `@before_compile`, AFTER the hook is
    # installed, so `@on_definition` sees it and `{:init, 1}` lands in the wrapped set for
    # a module that never wrote one.
    test "compiles under Layer 1" do
      [{module, _binary} | _] =
        Code.compile_string("""
        defmodule NoInitLayerOne do
          use GenServer
          use ExTLA.Invariant

          invariant :never_negative do
            state.balance >= 0
          end

          def handle_call(:balance, _from, state), do: {:reply, state.balance, state}
        end
        """)

      assert function_exported?(module, :handle_call, 3)
    end

    # The example as PRINTED, copied from the moduledoc. #301 gates every such example;
    # this one is the reason the bug mattered, so it keeps an assertion of its own.
    test "and so does the front-page example, exactly as printed" do
      assert [{_module, _binary} | _] =
               Code.compile_string("""
               defmodule FrontPageAccount do
                 use GenServer
                 use ExTLA.Invariant

                 invariant :never_negative, desc: "an account may not go below zero" do
                   state.balance >= 0
                 end

                 action_property :no_free_money do
                   new.balance <= old.balance or new.deposits > old.deposits
                 end

                 precondition {:withdraw, amount} do
                   amount > 0
                 end
               end
               """)
    end

    # An author-written `init/1` is still wrapped — the guard asks whether the callback is
    # in the definitions table, not whether it is called `init`, so it must not have
    # turned the wrapper off for everyone.
    test "while an author-written init/1 is still checked" do
      [{module, _binary} | _] =
        Code.compile_string("""
        defmodule AuthorWroteInit do
          use GenServer
          use ExTLA.Invariant

          invariant :never_negative do
            state.balance >= 0
          end

          def init(balance), do: {:ok, %{balance: balance}}
        end
        """)

      Process.flag(:trap_exit, true)

      assert {:error, {%ExTLA.Invariant.Violation{} = violation, _stack}} =
               GenServer.start(module, -1)

      assert violation.name == :never_negative
    end
  end
end
