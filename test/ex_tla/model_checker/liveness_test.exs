defmodule ExTLA.ModelChecker.LivenessTest do
  use ExUnit.Case, async: true

  alias ExTLA.ModelChecker
  alias ExTLA.ModelChecker.Liveness
  alias ExTLA.{Spec, StateGraph, Trace}

  alias ExTLA.TestSpecs.{
    Counter,
    Idling,
    IdlingUnfair,
    PerBinding,
    Stalls,
    Unbounded,
    WeaklyFair
  }

  @processes %{processes: MapSet.new([:p1, :p2])}

  defp check(module, constants, names, opts \\ %{}) do
    ModelChecker.run(
      module,
      Map.merge(
        %{constants: constants, check_liveness: true, temporals: names},
        opts
      )
    )
  end

  # The one shape that distinguishes SF from WF, and it was refuted by nothing (#174).
  #
  # `weak_break/3` breaks a cycle only when the action is enabled in EVERY state of it;
  # `strong_break/3` when it is enabled in ANY. So a cycle where `grab` is enabled
  # intermittently and never taken is fair to WF and unfair to SF — and every existing
  # strong-fairness fixture was only ever VERIFIED, which `[]` also achieves. Replacing the
  # strong branch with `[]` left the suite green.
  #
  # Two specs identical but for the word `:strong`, so the verdict difference can only come
  # from the branch under test.
  defmodule IntermittentWeak do
    @moduledoc false
    use ExTLA.Spec

    variable :n, type: 0..1
    variable :grabbed, type: [false, true]

    init do
      n = 0
      grabbed = false
    end

    action :up do
      require n == 0
      n = 1
    end

    action :down do
      require n == 1
      n = 0
    end

    # Enabled only at n == 0 — in SOME states of the up/down cycle, not all.
    action :grab do
      require n == 0
      require grabbed == false
      grabbed = true
    end

    temporal :eventually_grabbed do
      eventually(grabbed == true)
    end

    terminal :done do
      grabbed == true and n == 0
    end

    fairness(:weak, [:grab])
  end

  defmodule IntermittentStrong do
    @moduledoc false
    use ExTLA.Spec

    variable :n, type: 0..1
    variable :grabbed, type: [false, true]

    init do
      n = 0
      grabbed = false
    end

    action :up do
      require n == 0
      n = 1
    end

    action :down do
      require n == 1
      n = 0
    end

    action :grab do
      require n == 0
      require grabbed == false
      grabbed = true
    end

    temporal :eventually_grabbed do
      eventually(grabbed == true)
    end

    terminal :done do
      grabbed == true and n == 0
    end

    fairness(:strong, [:grab])
  end

  describe "strong fairness is not weak fairness" do
    @describetag verifies:
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Liveness`"
    test "an action enabled intermittently and never taken is fair to WF" do
      result = check(IntermittentWeak, %{}, [:eventually_grabbed])

      assert result.status == :violation,
             "the up/down cycle never grabs, and `grab` is disabled at n == 1, so weak " <>
               "fairness does not require it — the cycle is a legal behaviour"
    end

    test "and unfair to SF, which is the whole difference between them" do
      result = check(IntermittentStrong, %{}, [:eventually_grabbed])

      assert result.status == :ok,
             "`grab` is enabled infinitely often in that cycle, so strong fairness forbids " <>
               "it — and the property holds"
    end
  end

  describe "verdicts" do
    @describetag verifies:
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Liveness`"
    test "a property that holds leaves the run verified" do
      assert check(Idling, %{}, [:eventually_two]).status == :ok
      assert check(Counter, %{max: 2}, [:eventually_done]).status == :ok
      assert check(PerBinding, @processes, [:no_starvation]).status == :ok
    end

    # The failure mode this whole slice is measured against: a checker that answers
    # "holds" to everything passes every test above and none of these.
    test "a property that does not hold comes back refuted, with a lasso" do
      result = check(IdlingUnfair, %{}, [:eventually_two])

      assert result.status == :violation
      assert result.violation.prefix.property == :eventually_two
      assert result.violation.prefix.type == :liveness
      assert result.violation.cycle.actions != []
    end

    test "checks every property when none is selected" do
      # `never_two` is refuted where `eventually_two` holds, so a run over both has to
      # report the second rather than stop at the first verdict it likes.
      assert check(Idling, %{}, :all).status == :violation
      assert check(Idling, %{}, [:never_two]).status == :violation
      assert check(Idling, %{}, [:eventually_two]).status == :ok
    end

    # `max_states` is load-bearing, not tidiness. `Unbounded` is infinite (`tick: n = n + 1`),
    # so without a bound this inherits ExTLA.Config's default of 1,000,000 and builds a liveness
    # graph -- the edge table and ENABLED bits, which are per-struct maps -- over a million
    # states, in order to assert that a status is one of two atoms. Measured at 909 MB peak RSS
    # for this file, against 125-178 MB for every other test file in the suite, and it was
    # enough to get `mix test` OOM-killed in CI (#77, #78). The claim under test is that asking
    # for liveness changes nothing for a spec with no temporal properties; 100 states settle
    # that as well as a million. The test at line ~137 bounds itself the same way.
    test "a spec with no temporal properties is unaffected by asking" do
      assert check(Unbounded, %{}, :all, %{max_states: 100}).status in [:ok, :max_states_reached]
    end
  end

  describe "fairness" do
    @describetag verifies:
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Liveness`"
    # §5.2's whole point. `Idling` and `IdlingUnfair` are the same spec; one declares
    # WF(advance) and the other declares nothing, and the verdict differs.
    test "weak fairness rules out a cycle that sits beside a continuously enabled action" do
      assert check(Idling, %{}, [:eventually_two]).status == :ok
      assert check(IdlingUnfair, %{}, [:eventually_two]).status == :violation
    end

    # `PerBinding` and `WeaklyFair` are the same spec, and differ only in whether
    # acquiring is strongly or weakly fair. A competitor takes the lock and gives it
    # back, so `acquire(p1)` is enabled infinitely often and continuously enabled never:
    # weak fairness lets p1 wait forever, strong fairness does not.
    test "strong fairness is not weak fairness" do
      assert check(PerBinding, @processes, [:no_starvation]).status == :ok

      result = check(WeaklyFair, @processes, [:no_starvation])
      assert result.status == :violation
    end

    # A counterexample the spec's own assumptions forbid is not a counterexample. The
    # cycle it prints has to be one every fairness constraint permits, which means
    # visiting the states where each constraint is disabled.
    @tag verifies: [
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Liveness`",
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Liveness`/The counterexample"
         ]
    test "the cycle it prints is one the fairness constraints permit" do
      result = check(WeaklyFair, @processes, [:no_starvation])
      {_result, graph} = explore_live(WeaklyFair, @processes)

      cycle = result.violation.cycle
      assert cycle.actions != []

      # One process waits for the whole cycle while the other goes round; `acquire` for the
      # waiter is disabled wherever the other holds the lock, which is what makes weak
      # fairness powerless here. The property, not a process: `WeaklyFair` is symmetric in
      # p1/p2, so a lasso starving either is a valid counterexample, and this test once
      # named p1 — which is more than the checker promises. It has always come back p1 in
      # every run anyone has looked at (#243); if it ever does not, the message below is
      # what records it, and a lasso that differs run to run would be its own finding.
      processes = [:p1, :p2]

      starved =
        Enum.filter(processes, fn p -> Enum.all?(cycle.states, &(&1.pc[p] == :waiting)) end)

      assert [waiter] = starved,
             "expected exactly one process waiting through the whole cycle, got " <>
               "#{inspect(starved)}\nactions: #{inspect(cycle.actions)}\nstates:\n" <>
               Enum.map_join(cycle.states, "\n", &("  " <> inspect(&1)))

      [other] = processes -- [waiter]

      assert Enum.any?(cycle.states, &(&1.owner == other)),
             "#{inspect(other)} never held the lock in a cycle that starves #{inspect(waiter)}: " <>
               inspect(cycle.states)

      assert graph.fairness_index != []
    end
  end

  describe "terminal states" do
    # §5.3: a state with no successors stutters there forever, which is a legal
    # behaviour — and it refutes anything still waiting for something to happen.
    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Liveness`"
    test "a spec that ends before its goal is refuted by the end state" do
      result = check(Stalls, %{}, [:eventually_done])

      assert result.status == :violation
      assert result.violation.cycle.actions == []
      assert List.last(result.violation.prefix.states) == %{phase: :stuck}
    end

    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Trace`"
    test "the formatted counterexample says the behaviour stutters rather than ending" do
      output = Trace.format(check(Stalls, %{}, [:eventually_done]).violation)

      assert output =~ "LIVENESS: eventually_done"
      assert output =~ "stutters there forever"
    end

    # What a counterexample is FOR is telling someone what went wrong, and `desc:` is the
    # sentence its author wrote to say what the property means. The chain is four hops long —
    # the DSL stores the option, `compiled_temporals/1` emits it, `temporal_instances/2`
    # carries it onto the instance, `describe/2` prints it — and it was severed at the second
    # for a fortnight (#176). The assertion is on the RENDERING, not on the struct: the
    # message field it lands in was itself unrendered until this work item, so a test that
    # read `violation.prefix.message` would have passed over a counterexample that showed the
    # reader nothing. Every hop is load-bearing; cut any one and this goes red.
    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Trace`"
    test "a refuted property's counterexample carries the description its author wrote" do
      output = Trace.format(check(IdlingUnfair, %{}, [:eventually_two]).violation)

      assert output =~ "the counter reaches two and does not spin forever"
    end

    # `desc:` is optional and stored as `""` when it is absent (#160), so the line has to read
    # the same as it did before there was a description to add to it.
    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Trace`"
    test "and a property declared without one reads exactly as it did before" do
      output = Trace.format(check(Stalls, %{}, [:eventually_done]).violation)

      assert output =~ "temporal property :eventually_done is refuted by this behaviour\n"
      refute output =~ "behaviour —"
    end

    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Trace`"
    test "a real cycle is formatted as a loop back to where it started" do
      output = Trace.format(check(IdlingUnfair, %{}, [:eventually_two]).violation)

      assert output =~ "↺ back to state 1"
      assert output =~ "repeat forever"

      # #212. The closing duplicate is the cycle head again, and was labelled `[VIOLATION]`
      # like a safety trace's final state — the wrong thing to point a reader at.
      refute output =~ "[VIOLATION]"
      assert output =~ ~r/State \d+ \(= state 1, the cycle head\):/
    end

    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Trace`"
    test "a lasso's length counts states, sharing the cycle head once" do
      violation = check(IdlingUnfair, %{}, [:eventually_two]).violation
      {joined, _} = Trace.join(violation)

      assert joined.length == length(joined.states)
      assert joined.length == violation.prefix.length + violation.cycle.length - 1
    end
  end

  describe "what it refuses" do
    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Liveness`"
    test "a graph with no liveness structure" do
      {_result, graph} = ModelChecker.explore(Counter, %{constants: %{max: 2}})
      spec = Spec.Compiled.from_module(Counter)

      assert_raise ArgumentError, ~r/needs the liveness graph/, fn ->
        Liveness.check(spec, graph)
      end
    end

    # A verdict about every behaviour needs every behaviour. A bounded run explored part
    # of the state space, and an unexpanded state is indistinguishable from one that ends
    # the spec — which is exactly the shape that refutes a liveness property.
    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Liveness`"
    test "a graph whose search was bounded before it finished" do
      spec = Spec.Compiled.from_module(Unbounded)

      {_result, graph} =
        ModelChecker.explore(Unbounded, %{
          constants: %{},
          liveness_graph: true,
          check_deadlock: false,
          max_states: 20
        })

      assert map_size(graph.edges) < graph.state_count

      assert_raise ArgumentError, ~r/did not expand every state/, fn ->
        Liveness.check(spec, graph)
      end
    end

    # Since #277 this is an INTERNAL invariant rather than a diagnostic: the front end
    # refuses the nesting at compile time, so the only way to build the formula below is to
    # hand-assemble one, as this test does. It is kept — and its message rewritten to address
    # ExTLA rather than the author of a spec — because a shape reaching the checker unchecked
    # is a hole in the front end, and carrying on with a weaker shape is the one thing the
    # checker must not do.
    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Liveness`/The fragment, shape by shape"
    test "a nesting of operators it does not evaluate" do
      spec = Spec.Compiled.from_module(Counter)

      nested = %{
        name: :too_deep,
        description: "",
        opts: [],
        formula: fn _constants ->
          {:eventually, {:always, {:eventually, {:predicate, fn _state -> true end}}}}
        end
      }

      {_result, graph} =
        ModelChecker.explore(Counter, %{constants: %{max: 2}, liveness_graph: true})

      error =
        assert_raise ArgumentError, fn ->
          Liveness.check(%{spec | temporals: [nested]}, graph)
        end

      assert Exception.message(error) =~ "a shape it does not evaluate"
      assert Exception.message(error) =~ "eventually(always(eventually(pred)))"
      assert Exception.message(error) =~ "bug in ExTLA, not in the specification"
    end
  end

  describe "the run" do
    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API"
    test "asking for liveness builds the graph it needs" do
      {_result, graph} =
        ModelChecker.explore(Idling, %{constants: %{}, check_liveness: true})

      assert StateGraph.liveness?(graph)
    end

    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Coverage and Vacuity — `ExTLA.Coverage`"
    test "a refuted property does not make the coverage report claim a bounded run" do
      result = check(IdlingUnfair, %{}, [:eventually_two])

      assert result.status == :violation
      assert result.coverage.bounded_by == :none
    end

    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API/The CLI infers `check_liveness`; the API does not"
    test "not asking still says the properties went unchecked" do
      result = ModelChecker.run(Idling, %{constants: %{}})

      assert result.status == :ok
      assert Enum.any?(result.warnings, &(&1 =~ "declared and not checked"))
    end

    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API/The CLI infers `check_liveness`; the API does not"
    test "asking stops the warning" do
      result = check(Idling, %{}, [:eventually_two])

      refute Enum.any?(result.warnings, &(&1 =~ "declared and not checked"))
    end
  end

  describe "the counterexample as a behaviour" do
    @describetag verifies:
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Trace`"
    test "a plain trace is a prefix, with no cycle to return to" do
      trace = ModelChecker.run(ExTLA.TestSpecs.Broken, %{constants: %{}}).violation

      assert {states, nil} = Trace.to_behavior(trace)
      assert states == trace.states
    end

    # §5.3's stuttering end: the behaviour is the prefix, looping on its own last state.
    test "a stuttering lasso loops on the state the spec ended in" do
      lasso = check(Stalls, %{}, [:eventually_done]).violation

      assert {states, lasso_start} = Trace.to_behavior(lasso)
      assert states == lasso.prefix.states
      assert lasso_start == length(states) - 1
      assert Enum.at(states, lasso_start) == %{phase: :stuck}
    end

    # The cycle trace ends where it began, so the repeated state is dropped: the behaviour
    # lists each state once and `lasso_start` says where to loop back to.
    test "a real cycle is listed once, not once and a bit" do
      lasso = check(IdlingUnfair, %{}, [:eventually_two]).violation

      assert {states, lasso_start} = Trace.to_behavior(lasso)
      assert length(states) == length(lasso.prefix.states) + length(lasso.cycle.states) - 2
      assert Enum.at(states, lasso_start) == List.last(lasso.cycle.states)
    end
  end

  defp explore_live(module, constants),
    do: ModelChecker.explore(module, %{constants: constants, liveness_graph: true})
end
