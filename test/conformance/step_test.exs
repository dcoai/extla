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
      assert Runtime.get_trace(server) == %{
               states: [
                 %{count: 0, status: :ready},
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

  describe "the trace is bounded" do
    test "and drops oldest-first rather than growing without limit" do
      previous = Application.get_env(:extla, :trace_buffer)
      Application.put_env(:extla, :trace_buffer, 3)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:extla, :trace_buffer, previous),
          else: Application.delete_env(:extla, :trace_buffer)
      end)

      server = start(Impl.Conforming)

      for _ <- 1..4 do
        assert {:ok, :ok} = call(server, :increment)
        assert {:ok, :ok} = call(server, :done)
      end

      trace = Runtime.get_trace(server)
      assert length(trace.states) == 3
      assert List.last(trace.states) == %{count: 4, status: :ready}

      # And it says how many it dropped to stay at three, which is what makes a verdict
      # about the behaviour's first state refusable rather than wrong (#278). Ten states
      # were recorded — the initial one, then a pre and a post for the first transition and
      # a post for each of the seven after it — and three are kept.
      assert trace.dropped == 7
      assert length(trace.states) + trace.dropped == 10
    end
  end

  describe "Refinement.validate!/3 is not weakened by the layer above it" do
    test "the conforming mapping still validates against the spec" do
      assert {:ok, deferred} = TLA.Refinement.validate!(Refinement, Spec)
      assert length(deferred) == 2
    end
  end
end
