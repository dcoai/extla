defmodule ExTLA.BehaviourInvariantTest do
  @moduledoc """
  One invariant for a behaviour trace, held by every producer (#303, for #168).

  ## What was wrong

  The invariant — *n states, n - 1 actions, one binding each, `length` == n* — was already
  written down, as a private `misaligned?/1` in `ExTLA.Trace`, and checked at three
  **consumers**: `from_json!/1`, `to_diffs/1` and `legal_steps/4`. Two producers broke it
  and neither said so:

  * `ExTLA.Simulation`'s restart path pushed a state with no action on a **successful**
    restart, while its own violation branch pushed all three. `to_diffs/1`'s comment
    records the cost — it was found when `Trace.Explore` and `format/1` disagreed about
    one trace, three modules from where it broke, after it had been rendered wrong.

  * `ExTLA.GenServer.Runtime.record_initial!/3` recorded a transition from the initial state
    to itself, and `record_transition!/4` seeds an empty buffer with its own `pre` — so
    the first state landed **twice** and every recorded behaviour opened with a step that
    never happened. Fed to `ExTLA.Conformance.against_graph/3` that self-step classifies as
    **forbidden**, unless the spec happens to carry a self-loop at its initial state. The
    layer's two behaviour sources disagreed with each other about the same server.

  So the predicate is public now (`ExTLA.Trace.well_formed/1`) and asserted where a trace is
  **built**, which is where the fix goes.

  ## Why the counter corpus could not have caught the second one

  `ExTLA.Conformance.Counter.Spec` has `reset`, which requires `status == :ready` and sets
  `count = 0` — from the initial `%{count: 0, status: :ready}` that is a **self-loop**. The
  duplicated state was therefore a legal step of that spec and `against_graph/3` passed it.
  `Ratchet` below has no self-loop anywhere, which is the whole reason it exists.
  """

  use ExUnit.Case, async: true

  alias ExTLA.{Conformance, ModelChecker, Simulation, Trace}
  alias ExTLA.Conformance.Counter.Impl
  alias ExTLA.GenServer.Runtime

  # ── A spec with no self-loop at its initial state ───────────────────────────

  defmodule Ratchet do
    @moduledoc """
    `n` counts up to two and nothing brings it back. Every step changes `n`, so no state
    has an edge to itself — which is what makes the duplicated initial state visible.
    """
    use ExTLA.Spec

    variable :n, type: 0..2

    init do
      n = 0
    end

    action :bump do
      require n < 2
      n = n + 1
    end
  end

  defmodule RatchetRefinement do
    use ExTLA.Refinement

    def abstract(%{count: c}), do: %{n: c}

    def abstract_action(:bump), do: {:bump, %{}}
    def abstract_action(_), do: :unmapped

    def concrete_message(:bump, _params), do: :bump
  end

  defmodule RatchetServer do
    use GenServer

    use ExTLA.GenServer,
      spec: ExTLA.BehaviourInvariantTest.Ratchet,
      refinement: ExTLA.BehaviourInvariantTest.RatchetRefinement

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts), do: {:ok, %{count: 0}}

    @impl true
    def handle_call(:bump, _from, state), do: {:reply, :ok, %{state | count: state.count + 1}}
  end

  # ── The predicate ───────────────────────────────────────────────────────────

  describe "the invariant, stated once" do
    test "holds of a trace the checker built" do
      {_result, graph} =
        ModelChecker.explore(Ratchet, %{check_deadlock: false, liveness_graph: true})

      trace = Trace.replay(graph, 0, [{:bump, %{}}, {:bump, %{}}])

      assert Trace.well_formed(trace) == :ok
      assert length(trace.states) == length(trace.actions) + 1
      assert trace.length == length(trace.states)
    end

    # Each clause on its own: a predicate whose three conditions are only ever tested
    # together is three conditions one of which may do nothing.
    test "and refuses one state too many" do
      trace = %Trace{states: [%{n: 0}, %{n: 1}, %{n: 2}], actions: [:bump], bindings: [%{}]}

      assert {:error, message} = Trace.well_formed(%{trace | length: 3})
      assert message =~ "3 states, 1 actions and 1 bindings"
      assert message =~ "cannot describe one behaviour"
    end

    test "and refuses a binding count that does not match the actions" do
      trace = %Trace{
        states: [%{n: 0}, %{n: 1}],
        actions: [:bump],
        bindings: [],
        length: 2
      }

      assert {:error, message} = Trace.well_formed(trace)
      assert message =~ "0 bindings"
    end

    # `length` counts STATES (#212). It is the field most easily left behind, because
    # nothing downstream reads it to iterate — so a trace can read as one shape and report
    # another with no other symptom.
    test "and refuses a length that disagrees with the states" do
      trace = %Trace{
        states: [%{n: 0}, %{n: 1}],
        actions: [:bump],
        bindings: [%{}],
        length: 7
      }

      assert {:error, message} = Trace.well_formed(trace)
      assert message =~ "says length 7 and carries 2 states"
    end

    test "and refuses a trace with no states at all" do
      assert {:error, message} = Trace.well_formed(%Trace{})
      assert message =~ "at least one state"
    end

    test "and reaches into a lasso's prefix and cycle" do
      good = %Trace{states: [%{n: 0}, %{n: 1}], actions: [:bump], bindings: [%{}], length: 2}
      bad = %{good | length: 9}

      assert Trace.well_formed(%{prefix: good, cycle: nil}) == :ok
      assert Trace.well_formed(%{prefix: good, cycle: good}) == :ok
      assert {:error, _} = Trace.well_formed(%{prefix: good, cycle: bad})
      assert {:error, _} = Trace.well_formed(%{prefix: bad, cycle: good})
    end
  end

  describe "the assertion at a producer" do
    # The point of raising rather than returning: the message has to send a reader to the
    # code that built it, not to the code that read it. That is the whole difference
    # between this and the three consumer-side checks it replaces.
    test "names the producer that broke it" do
      malformed = %Trace{states: [%{n: 0}, %{n: 1}], actions: [], bindings: [], length: 2}

      assert_raise ArgumentError, ~r/TLA\.Nonsense produced a malformed trace/, fn ->
        Trace.well_formed!(malformed, "ExTLA.Nonsense")
      end
    end

    test "and passes a well-formed one through unchanged" do
      trace = %Trace{states: [%{n: 0}, %{n: 1}], actions: [:bump], bindings: [%{}], length: 2}

      assert Trace.well_formed!(trace, "ExTLA.Nonsense") == trace
    end
  end

  # ── Producer: the simulation ────────────────────────────────────────────────

  describe "a simulation that restarts" do
    # `--inject-failures` fires at a fixed probability against a per-trace seed, so this is
    # deterministic given the seed rather than a race. The `restarts > 0` assertion is the
    # anti-vacuity guard: without it a change to the seeding would turn this into a test of
    # a run that never restarted, which is the case that already worked.
    test "produces a behaviour whose states and steps agree" do
      {result, behaviour} =
        Simulation.run_trace(Impl.Conforming, %{
          max_steps: 40,
          seed: 20_303,
          inject_failures: true
        })

      assert result.restarts > 0,
             "seed 20303 took no restart, so this asserts nothing about the restart path"

      # The invariant in the terms the public result exposes: one state per step, one per
      # restart, and the one the behaviour starts at. Before #303 the states matched and
      # the ACTIONS did not, which is why this is asserted alongside the trace below.
      assert length(behaviour) == result.total_steps + result.restarts + 1
    end

    # `trace_of/1` is the only public route to the accumulator's three lists, and it runs
    # only on a finding — so a violation *after* a restart is what exercises the branch that
    # was wrong. `run_trace/2` rather than `run/2`: `run/2` sums `restarts` over every trace
    # it ran, so `restarts > 0` there would not say that the trace which FAILED restarted.
    # One trace, one seed, both facts about the same run.
    test "and a counterexample found after one is well-formed" do
      {result, _behaviour} =
        Simulation.run_trace(Impl.CollapsesTwoSteps, %{
          max_steps: 60,
          seed: 2,
          inject_failures: true
        })

      assert result.status == :violation
      assert result.restarts > 0, "no restart occurred, so the repaired branch never ran"

      assert Trace.well_formed(result.violation) == :ok

      # The arithmetic spelled out, so a future change that keeps the lists aligned by
      # dropping the restart's state fails here rather than passing quietly.
      assert result.violation.length == result.total_steps + result.restarts + 1
    end
  end

  # ── Producer: the runtime's recorded behaviour ──────────────────────────────

  describe "the behaviour a conforming server records" do
    test "opens at the initial state, once" do
      server = start_ratchet()

      assert :ok = GenServer.call(server, :bump)
      assert :ok = GenServer.call(server, :bump)

      assert Runtime.get_trace(server) == %{
               states: [%{n: 0}, %{n: 1}, %{n: 2}],
               dropped: 0
             }
    end

    # The defect, in the form it actually mattered: a behaviour from `get_trace/1` fed to
    # the conformance check. `Ratchet` has no self-loop anywhere, so the duplicated state
    # was a step no action of the spec permits — a FORBIDDEN step reported about a server
    # that had done nothing wrong.
    test "and passes against_graph/3 for a spec with no self-loop at its initial state" do
      {result, graph} =
        ModelChecker.explore(Ratchet, %{check_deadlock: false, liveness_graph: true})

      server = start_ratchet()
      assert :ok = GenServer.call(server, :bump)
      assert :ok = GenServer.call(server, :bump)

      behaviour = Runtime.get_trace(server).states

      assert Conformance.against_graph(graph, behaviour, status: result.status) == :ok,
             Conformance.explain(
               Conformance.against_graph(graph, behaviour, status: result.status)
             )
    end

    # Anti-vacuity for the test above: it would also pass if `Ratchet` had a self-loop at
    # `%{n: 0}`, which is exactly how the counter corpus hid this for as long as it did.
    test "and Ratchet has no self-loop at its initial state" do
      {_result, graph} =
        ModelChecker.explore(Ratchet, %{check_deadlock: false, liveness_graph: true})

      initial = %{n: 0}
      id = ExTLA.StateGraph.id_of(graph, initial)

      assert id != nil

      refute Enum.any?(ExTLA.StateGraph.successors(graph, id), fn {_action, _binding, to} ->
               to == id
             end),
             "Ratchet has a self-loop at its initial state, so this file's central test " <>
               "would pass whether or not the initial state is recorded twice"
    end
  end

  defp start_ratchet do
    {:ok, pid} = RatchetServer.start_link()
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end
end
