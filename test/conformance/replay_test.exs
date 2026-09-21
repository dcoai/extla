defmodule TLA.ConformanceReplayTest do
  use ExUnit.Case, async: true

  alias TLA.Conformance.Counter.{BuggySpec, Impl}
  alias TLA.{ModelChecker, Replay, Trace}

  describe "a model-checker counterexample, replayed against the code" do
    # The loop that makes the three layers one tool: `BuggySpec` contradicts itself,
    # `mix tla.check` finds it before any code exists, and this runs that exact trace
    # against a server that refines the spec faithfully.
    setup do
      result = ModelChecker.run(BuggySpec, %{constants: %{max_val: 5}, check_liveness: false})

      assert result.status == :violation
      assert %Trace{} = result.violation

      %{trace: result.violation}
    end

    test "reproduces the design bug in the running server", %{trace: trace} do
      report = Replay.counterexample(Impl.FaithfulToABuggySpec, trace)

      assert report.status == :violation
      assert report.violation.kind == :invariant
      assert report.violation.detail =~ "invariant :at_most_two"

      # The trace reaches count == 3, so the server takes every step before the last one.
      assert report.steps_checked == report.violation.step - 1
      assert report.violation.step == length(trace.actions)
    end

    test "and the trace it replays is the one the checker produced", %{trace: trace} do
      assert List.last(trace.states).count == 3
      assert :increment in trace.actions
    end

    # #207. `Driver.call/3` matched the `:DOWN` on `^server`; a monitor on a registered name
    # delivers `{name, node}` there, so neither clause matched and the call waited out its
    # timeout. The same violation reported in 23 ms for a pid came back `:not_followed`
    # after 5 seconds for a name — a real finding discarded, with delivery blamed.
    test "reports the same violation for a registered name as for a pid", %{trace: trace} do
      name = :"replay_named_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(Impl.FaithfulToABuggySpec, [], name: name)
      Process.unlink(pid)

      # Well inside the timeout, so a fall-through to it is what fails this, not a slow run.
      named = Replay.counterexample(Impl.FaithfulToABuggySpec, trace, server: name, timeout: 500)

      assert named.status == :violation
      assert named.violation.kind == :invariant
      assert named.violation.step == length(trace.actions)
    end
  end

  describe "TLA.GenServer.Driver.call/3" do
    alias TLA.GenServer.Driver

    test "a pid and a registered name give the same outcome for a violation" do
      name = :"driver_named_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(Impl.FaithfulToABuggySpec, [], name: name)
      Process.unlink(pid)

      # The checker's own counterexample: increments must alternate with `done`, and the
      # third increment reaches count == 3, which `at_most_two` refuses.
      steps = [:increment, :done, :increment, :done]
      for step <- steps, do: assert({:ok, :ok} = Driver.call(name, step, 500))

      assert {:violation, %TLA.GenServer.Violation{kind: :invariant}} =
               Driver.call(name, :increment, 500)

      {:ok, pid} = GenServer.start_link(Impl.FaithfulToABuggySpec, [])
      Process.unlink(pid)
      for step <- steps, do: assert({:ok, :ok} = Driver.call(pid, step, 500))

      assert {:violation, %TLA.GenServer.Violation{kind: :invariant}} =
               Driver.call(pid, :increment, 500)
    end

    # #254. The first version of this test raced: it killed the server from a spawned process
    # after a sleep, and on a 2-core runner the kill landed before the send every time —
    # `send/2` to a name whose process is gone raises `invalid destination`, where a dead pid
    # is a no-op answered by `:noproc`. Two orderings, made deterministic: the kill waits until
    # the `$gen_call` is in the suspended server's mailbox, so it always follows the send.
    test "a server that stops for another reason reports :stopped under a name too" do
      name = :"driver_stops_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(Impl.Conforming, [], name: name)
      Process.unlink(pid)
      :sys.suspend(pid)

      killer =
        spawn(fn ->
          receive do
            :go -> :ok
          end

          until_queued(pid)
          Process.exit(pid, :shutdown)
        end)

      send(killer, :go)
      assert {:stopped, :shutdown} = Driver.call(name, :get, 5_000)
    end

    # A server that is already gone is the same outcome under every shape — nothing is sent,
    # nothing raises. Before #254 a dead name raised from `send/2`.
    test "a dead server reports :noproc for a pid and for a name alike" do
      name = :"driver_dead_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(Impl.Conforming, [], name: name)
      Process.unlink(pid)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert {:stopped, :noproc} = Driver.call(pid, :get, 500)
      assert {:stopped, :noproc} = Driver.call(name, :get, 500)
      assert {:stopped, :noproc} = Driver.call({name, node()}, :get, 500)
    end

    # Every `GenServer.server()` shape is the pid path by construction, and this is what holds
    # it there: a shape-dependent branch cannot come back on one shape only.
    test "every server shape gives the identical outcome" do
      for shape <- [:pid, :name, :name_and_node] do
        name = :"driver_shape_#{System.unique_integer([:positive])}"
        {:ok, pid} = GenServer.start_link(Impl.FaithfulToABuggySpec, [], name: name)
        Process.unlink(pid)

        server =
          case shape do
            :pid -> pid
            :name -> name
            :name_and_node -> {name, node()}
          end

        for step <- [:increment, :done, :increment, :done] do
          assert {:ok, :ok} = Driver.call(server, step, 500), "#{shape}: #{step}"
        end

        assert {:violation, %TLA.GenServer.Violation{kind: :invariant}} =
                 Driver.call(server, :increment, 500),
               "#{shape}: the third increment"

        assert {:stopped, :noproc} = Driver.call(server, :get, 500), "#{shape}: after the crash"
      end
    end
  end

  describe "a counterexample the implementation cannot follow" do
    test "is reported as :not_followed, with why that is itself a finding" do
      report = Replay.counterexample(Impl.RefusesDone, two_step_trace())

      assert report.status == :not_followed
      assert report.steps_checked == 1
      assert report.detail =~ "step 2 (done) could not be delivered"
      assert report.detail =~ "permits a behaviour the implementation does not take"
    end

    test "a legal step that lands somewhere else is not a conformance violation" do
      # Every step here is one the spec permits; the trace simply claims a different
      # post-state. The implementation took a step the spec allows — just not this one.
      wrong = %Trace{
        type: :safety,
        actions: [:increment],
        bindings: [%{}],
        states: [%{count: 0, status: :ready}, %{count: 2, status: :incrementing}],
        length: 1
      }

      report = Replay.counterexample(Impl.Conforming, wrong)

      assert report.status == :not_followed
      assert report.violation == nil
      assert report.detail =~ "was legal, but left the implementation in a different"
      assert report.detail =~ "expected: %{count: 2"
      assert report.detail =~ ~r/actual:\s+%\{count: 1/
    end

    test "a refinement with no concrete_message/2 says so by name" do
      report = Replay.counterexample(Impl.Undrivable, two_step_trace())

      assert report.status == :not_followed
      assert report.steps_checked == 0
      assert report.detail =~ "does not define concrete_message/2"
      assert report.detail =~ "can be checked as it runs and cannot be replayed"
    end
  end

  describe "a captured trace, checked offline" do
    # Nothing is running: this is a pure function over recorded data, so it works in CI
    # against a fixture or against a captured incident.
    test "a capture the spec permits passes" do
      captured = [
        {:init, %{value: 0, status: :ready}},
        {:increment, %{value: 1, status: :incrementing}},
        {:done, %{value: 1, status: :ready}},
        {:reset, %{value: 0, status: :ready}}
      ]

      assert %{status: :ok, steps_checked: 3, violation: nil} =
               Replay.trace(Impl.Conforming, captured)
    end

    test "a capture with Example 4's bug in it is caught at the step that has it" do
      captured = [
        {:init, %{value: 0, status: :ready}},
        {:increment, %{value: 1, status: :incrementing}},
        {:done, %{value: 1, status: :ready}},
        # The bug: an increment that also does `done`'s work.
        {:increment, %{value: 2, status: :ready}}
      ]

      report = Replay.trace(Impl.Conforming, captured)

      assert report.status == :violation
      assert report.violation.step == 3
      assert report.violation.kind == :diverged
      assert report.violation.action == :increment
      assert report.violation.message == :increment
      assert report.violation.detail =~ "status:"
    end

    test "a capture whose unmapped message moved the state is caught as such" do
      captured = [
        {:init, %{value: 0, status: :ready}},
        {:get, %{value: 1, status: :ready}}
      ]

      report = Replay.trace(Impl.Conforming, captured)

      assert report.violation.step == 1
      assert report.violation.kind == :unmapped_but_moved
    end

    test "a capture whose first state already breaks an invariant is caught at step 0" do
      report = Replay.trace(Impl.FaithfulToABuggySpec, [{:init, %{value: 3, status: :ready}}])

      assert report.violation.step == 0
      assert report.violation.kind == :invariant
    end

    test "an empty capture is a pass over nothing, and says so" do
      assert %{status: :ok, steps_checked: 0} = Replay.trace(Impl.Conforming, [])
    end

    test "a capture of one state checks its invariants and no step" do
      assert %{status: :ok, steps_checked: 0} =
               Replay.trace(Impl.Conforming, [{:init, %{value: 1, status: :ready}}])
    end
  end

  describe "a lasso" do
    test "is replayed as its prefix followed by one pass of its cycle" do
      lasso = %{
        prefix: %Trace{
          type: :liveness,
          actions: [:increment],
          bindings: [%{}],
          states: [%{count: 0, status: :ready}, %{count: 1, status: :incrementing}],
          length: 1
        },
        cycle: %Trace{
          type: :liveness,
          actions: [:done],
          bindings: [%{}],
          states: [%{count: 1, status: :ready}],
          length: 1
        }
      }

      assert %{status: :ok, steps_checked: 2} = Replay.counterexample(Impl.Conforming, lasso)
    end
  end

  defp until_queued(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} when n > 0 -> :ok
      {:message_queue_len, 0} -> until_queued(pid)
      nil -> :ok
    end
  end

  defp two_step_trace do
    %Trace{
      type: :safety,
      actions: [:increment, :done],
      bindings: [%{}, %{}],
      states: [
        %{count: 0, status: :ready},
        %{count: 1, status: :incrementing},
        %{count: 1, status: :ready}
      ],
      length: 2
    }
  end
end
