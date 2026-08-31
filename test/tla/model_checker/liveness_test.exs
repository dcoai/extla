defmodule TLA.ModelChecker.LivenessTest do
  use ExUnit.Case, async: true

  alias TLA.ModelChecker
  alias TLA.ModelChecker.Liveness
  alias TLA.{Spec, StateGraph, Trace}

  alias TLA.TestSpecs.{
    Counter,
    Idling,
    IdlingUnfair,
    PerBinding,
    Stalls,
    Unbounded,
    WeaklyFair
  }

  @processes %{processes: MapSet.new([:p1, :p2])}

  defp check(module, constants, names) do
    ModelChecker.run(module, %{
      constants: constants,
      check_liveness: true,
      temporals: names
    })
  end

  describe "verdicts" do
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

    test "a spec with no temporal properties is unaffected by asking" do
      assert check(Unbounded, %{}, :all).status in [:ok, :max_states_reached]
    end
  end

  describe "fairness" do
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
    test "the cycle it prints is one the fairness constraints permit" do
      result = check(WeaklyFair, @processes, [:no_starvation])
      {_result, graph} = explore_live(WeaklyFair, @processes)

      cycle = result.violation.cycle
      assert cycle.actions != []

      # p1 waits for the whole cycle while p2 goes round; `acquire(p1)` is disabled
      # wherever p2 holds the lock, which is what makes weak fairness powerless here.
      assert Enum.all?(cycle.states, &(&1.pc.p1 == :waiting))
      assert Enum.any?(cycle.states, &(&1.owner == :p2))
      assert graph.fairness_index != []
    end
  end

  describe "terminal states" do
    # §5.3: a state with no successors stutters there forever, which is a legal
    # behaviour — and it refutes anything still waiting for something to happen.
    test "a spec that ends before its goal is refuted by the end state" do
      result = check(Stalls, %{}, [:eventually_done])

      assert result.status == :violation
      assert result.violation.cycle.actions == []
      assert List.last(result.violation.prefix.states) == %{phase: :stuck}
    end

    test "the formatted counterexample says the behaviour stutters rather than ending" do
      output = Trace.format(check(Stalls, %{}, [:eventually_done]).violation)

      assert output =~ "LIVENESS: eventually_done"
      assert output =~ "stutters there forever"
    end

    test "a real cycle is formatted as a loop back to where it started" do
      output = Trace.format(check(IdlingUnfair, %{}, [:eventually_two]).violation)

      assert output =~ "↺ back to state 1"
      assert output =~ "repeat forever"
    end
  end

  describe "what it refuses" do
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

    test "a nesting of operators it does not evaluate" do
      spec = Spec.Compiled.from_module(Counter)

      nested = %{
        name: :too_deep,
        opts: [],
        formula: fn _constants ->
          {:eventually, {:always, {:eventually, {:predicate, fn _state -> true end}}}}
        end
      }

      {_result, graph} =
        ModelChecker.explore(Counter, %{constants: %{max: 2}, liveness_graph: true})

      assert_raise ArgumentError, ~r/nests operators more deeply/, fn ->
        Liveness.check(%{spec | temporals: [nested]}, graph)
      end
    end
  end

  describe "the run" do
    test "asking for liveness builds the graph it needs" do
      {_result, graph} =
        ModelChecker.explore(Idling, %{constants: %{}, check_liveness: true})

      assert StateGraph.liveness?(graph)
    end

    test "a refuted property does not make the coverage report claim a bounded run" do
      result = check(IdlingUnfair, %{}, [:eventually_two])

      assert result.status == :violation
      assert result.coverage.bounded_by == :none
    end

    test "not asking still says the properties went unchecked" do
      result = ModelChecker.run(Idling, %{constants: %{}})

      assert result.status == :ok
      assert Enum.any?(result.warnings, &(&1 =~ "declared and not checked"))
    end

    test "asking stops the warning" do
      result = check(Idling, %{}, [:eventually_two])

      refute Enum.any?(result.warnings, &(&1 =~ "declared and not checked"))
    end
  end

  defp explore_live(module, constants),
    do: ModelChecker.explore(module, %{constants: constants, liveness_graph: true})
end
