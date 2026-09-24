defmodule TLA.ConformanceStepTest do
  use ExUnit.Case, async: true

  alias TLA.Conformance.Counter.Impl
  alias TLA.Conformance.Counter.{Refinement, Spec}
  alias TLA.GenServer.Runtime
  alias TLA.GenServer.Violation

  # A conformance failure raises inside the server, which reaches the caller as an exit.
  # The call is made from a monitored process so the failure arrives as a message rather
  # than being caught.
  defp call(pid, message) do
    ref = Process.monitor(pid)
    send(pid, {:"$gen_call", {self(), ref}, message})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        {:ok, reply}

      {:DOWN, ^ref, :process, ^pid, {%Violation{} = violation, _stack}} ->
        {:violation, violation}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:exit, reason}
    after
      5_000 -> {:error, :timeout}
    end
  end

  defp start(module) do
    {:ok, pid} = module.start_link()
    Process.unlink(pid)
    pid
  end

  describe "the implementation that conforms" do
    setup do: %{server: start(Impl.Conforming)}

    test "takes every spec action without a finding", %{server: server} do
      assert {:ok, :ok} = call(server, :increment)
      assert {:ok, :ok} = call(server, :done)
      assert {:ok, :ok} = call(server, :reset)
      assert {:ok, 0} = call(server, :get)
    end

    test "records the abstract behaviour, starting at the initial state", %{server: server} do
      {:ok, :ok} = call(server, :increment)
      {:ok, :ok} = call(server, :done)

      # `%{states:, dropped:}` since #278: a bare list cannot say whether it still holds
      # the behaviour's beginning, and the bare-predicate verdict depends on that.
      #
      # Four states until #168, because the initial one was recorded twice — this test
      # asserted the duplicate and so agreed with the defect. Two `:increment`/`:done`
      # calls are two steps, and two steps have three states. The opening self-step was a
      # transition that never happened, which `TLA.Conformance.against_graph/3` classifies
      # as FORBIDDEN unless the spec carries a self-loop at its initial state — see the
      # `against_graph/3` test below, which is the case that could not pass before.
      assert Runtime.get_trace(server) == %{
               states: [
                 %{count: 0, status: :ready},
                 %{count: 1, status: :incrementing},
                 %{count: 1, status: :ready}
               ],
               dropped: 0
             }
    end

    # A real trace has no lasso, so a property that needs one is `:inconclusive` by
    # construction rather than by accident — the same honesty as `max_states_reached`.
    test "and its trace answers the spec's temporal properties", %{server: server} do
      {:ok, :ok} = call(server, :increment)
      {:ok, :ok} = call(server, :done)

      verdicts = Runtime.check_temporal_properties(Spec, Runtime.get_trace(server))

      assert Map.keys(verdicts) == [:always_returns_to_ready]
      assert verdicts.always_returns_to_ready in [:holds, :inconclusive]
    end
  end

  # The entry that justifies the layer. Every invariant of the spec holds in the
  # post-state: `in_bounds` is satisfied by `count: 1`. A Layer 3 that checked only
  # invariants and action properties would report conformance here.
  describe "CollapsesTwoSteps — Example 4's own bug" do
    test "is caught as :diverged, and names the variable" do
      server = start(Impl.CollapsesTwoSteps)

      assert {:violation, violation} = call(server, :increment)
      assert violation.kind == :diverged
      assert violation.action == :increment

      assert [{:status, :incrementing, :ready}] = violation.diff

      message = Exception.message(violation)
      assert message =~ "CONFORMANCE: DIVERGED"
      assert message =~ "status:"
      assert message =~ "spec:           :incrementing"
      assert message =~ "implementation: :ready"
    end

    test "and the spec's own invariants would not have caught it" do
      # The post-state the implementation produced, checked the way a Layer 3 without a
      # step check would have checked it.
      assert Runtime.check_spec_invariants!(Spec, %{count: 1, status: :ready}) == :ok
    end
  end

  describe "MovesWhileUnmapped" do
    test "is caught as :unmapped_but_moved, and names what changed" do
      server = start(Impl.MovesWhileUnmapped)

      assert {:violation, violation} = call(server, :get)
      assert violation.kind == :unmapped_but_moved
      assert [{:count, 0, 1}] = violation.diff

      message = Exception.message(violation)
      assert message =~ "CONFORMANCE: UNMAPPED BUT MOVED"
      assert message =~ "count: 0 -> 1"
      assert message =~ "positive claim"
    end
  end

  describe "IgnoresTheGuard" do
    test "is caught as :not_enabled, and says the guard was false" do
      server = start(Impl.IgnoresTheGuard)

      assert {:violation, violation} = call(server, :increment)
      assert violation.kind == :not_enabled
      assert violation.action == :increment
      assert violation.pre == %{count: 0, status: :incrementing}

      message = Exception.message(violation)
      assert message =~ "CONFORMANCE: NOT ENABLED"
      assert message =~ "guard is false in this state"
    end
  end

  describe "check_step!/5 directly" do
    test "accepts a step the spec permits" do
      assert Runtime.check_step!(Spec, :increment, %{}, %{count: 0, status: :ready}, %{
               count: 1,
               status: :incrementing
             }) == :ok
    end

    test "refuses an action the spec does not declare, as a mapping fault" do
      error =
        assert_raise ArgumentError, fn ->
          Runtime.check_step!(Spec, :teleport, %{}, %{count: 0, status: :ready}, %{
            count: 0,
            status: :ready
          })
        end

      assert Exception.message(error) =~ "which TLA.Conformance.Counter.Spec does not declare"
      assert Exception.message(error) =~ ":increment"
    end

    # A param the action does not take is a fault in the mapping, not in the
    # implementation, and reporting it as `:not_enabled` would blame the wrong one.
    test "refuses params the action does not take, as a mapping fault" do
      error =
        assert_raise ArgumentError, fn ->
          Runtime.check_step!(Spec, :increment, %{by: 2}, %{count: 0, status: :ready}, %{
            count: 1,
            status: :incrementing
          })
        end

      assert Exception.message(error) =~ "bound [:by]"
    end
  end

  describe "the mapping is validated when the module compiles" do
    test "a mapping that does not name every action fails the build" do
      source = """
      defmodule TLA.ConformanceStepTest.Unbuildable do
        use GenServer
        use TLA.GenServer,
          spec: TLA.Conformance.Counter.Spec,
          refinement: TLA.Conformance.Counter.Mutants.ActionNeverNamed

        def init(_), do: {:ok, %{value: 0, status: :ready}}
        def handle_call(:increment, _from, state), do: {:reply, :ok, state}
      end
      """

      error = assert_raise TLA.Refinement.Error, fn -> Code.compile_string(source) end
      assert Exception.message(error) =~ "names no message for"
    end
  end

  describe "validate!/3's deferred rules are checked on every mapping instead" do
    test "a mapping that returns the wrong variables fails at the transition" do
      assert_raise TLA.Refinement.Error, fn ->
        Runtime.abstract!(Spec, TLA.Conformance.Counter.Mutants.MissingVariable, %{
          value: 1,
          status: :ready
        })
      end
    end
  end

  # `describe "the trace is bounded"` moved to `trace_buffer_test.exs` (#285). It set
  # `trace_buffer` — application config, read by `record_transition!/4` in whatever
  # process is recording — from this `async: true` file, so for its duration every
  # concurrently running test that recorded a transition saw a 3-state buffer. The test
  # is unchanged; only its neighbours are.

  describe "a server whose author wrote no init/1" do
    # #300 fixed this for Layer 1 and left Layer 3, where it is UNCONDITIONAL —
    # `init_wrapper/1` wraps `init/1` for every mapping rather than only where an invariant
    # applies. So `TLA.GenServer`'s own front-page example still did not compile after the
    # work item that was supposed to close it, and #301's moduledoc gate is what found that.
    #
    # Kept here as well as there because this is the behaviour; the gate is the reader's
    # copy of it.
    test "compiles under use TLA.GenServer" do
      assert [{_module, _binary} | _] =
               Code.compile_string("""
               defmodule NoInitLayerThree do
                 use GenServer

                 use TLA.GenServer,
                   spec: TLA.Conformance.Counter.Spec,
                   refinement: TLA.Conformance.Counter.Refinement

                 def handle_call(:increment, _from, s), do: {:reply, :ok, %{s | value: s.value + 1}}
               end
               """)
    end
  end

  describe "what use TLA.GenServer says about rules it could not decide" do
    # `validate!/3`'s moduledoc argues that "a validator that claims a check it cannot
    # perform is worse than one that states its limits", and the statement of limits was
    # thrown away at the only call site: `{:ok, _deferred} = …` (#169). A user whose mapping
    # has no `concrete_message/2` — so action coverage was never checked AT ALL — was never
    # told.
    @server """
    defmodule <NAME> do
      use GenServer

      use TLA.GenServer,
        spec: TLA.Conformance.Counter.Spec,
        refinement: <NAME>.Mapping

      defmodule Mapping do
        use TLA.Refinement

        def abstract(%{value: v, status: s}), do: %{count: v, status: s}
        def abstract_action(:increment), do: {:increment, %{}}
        def abstract_action(:done), do: {:done, %{}}
        def abstract_action(:reset), do: {:reset, %{}}
        def abstract_action(_other), do: :unmapped<CONCRETE>
      end

      def init(_), do: {:ok, %{value: 0, status: :ready}}
      def handle_call(:increment, _from, s), do: {:reply, :ok, %{s | value: s.value + 1}}
    end
    """

    defp compile_server(name, concrete) do
      @server
      |> String.replace("<NAME>", Atom.to_string(name))
      |> String.replace("<CONCRETE>", concrete)
      |> Code.compile_string()
    end

    test "it names the rule that went unchecked for this mapping" do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          compile_server(NoConcreteMessage, "")
        end)

      assert warning =~ "refinement rule(s) were not checked"
      assert warning =~ "no `concrete_message/2` to enumerate them with"
      assert warning =~ "limits of what a compile can decide, not findings"
    end

    # A compile-time message that fires on every module is one a reader learns to skip,
    # which would leave the ones that matter unread. The two rules that need a concrete
    # state are deferred for EVERY mapping — that is how validation works, not news.
    test "and says nothing when only the always-deferred rules are outstanding" do
      concrete =
        "\n\n    def concrete_message(:increment, _params), do: :increment" <>
          "\n    def concrete_message(:done, _params), do: :done" <>
          "\n    def concrete_message(:reset, _params), do: :reset"

      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          compile_server(WithConcreteMessage, concrete)
        end)

      refute warning =~ "were not checked"
    end
  end

  describe "Refinement.validate!/3 is not weakened by the layer above it" do
    test "the conforming mapping still validates against the spec" do
      assert {:ok, deferred} = TLA.Refinement.validate!(Refinement, Spec)
      assert length(deferred) == 2
    end
  end
end
