defmodule TLA.InvariantModesTest do
  # Compiles modules under different `config :extla, mode:` values, which is application
  # state, so these cannot run beside anything else.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @source """
  defmodule <NAME> do
    use GenServer
    use TLA.Invariant

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
    TLA.TestCall.call(pid, {:withdraw, amount})
  end

  # The layer's headline claim, and the reason `TLA.Config.mode/0` is a `compile_env`
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
      use TLA.Invariant

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
        use TLA.Invariant

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
        use TLA.Invariant

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
end
