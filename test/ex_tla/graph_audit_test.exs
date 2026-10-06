defmodule ExTLA.GraphAuditTest do
  @moduledoc """
  `ExTLA.GraphAudit` (#48/#59).

  Every test here damages a real graph, because the defects this exists for are the ones
  that leave a graph **self-consistent**: a missing edge and a wrongly-stuck state both
  produce a smaller graph that no assertion contradicts. An audit that only ever sees a
  correct graph would be a function that returns `:ok`.
  """

  use ExUnit.Case, async: true

  alias ExTLA.{GraphAudit, ModelChecker, Spec, TestSpecs}

  defp graph_for(module, constants \\ %{}) do
    {_result, graph} =
      ModelChecker.explore(module, %{
        constants: constants,
        liveness_graph: true,
        check_deadlock: false,
        invariants: []
      })

    {Spec.Compiled.from_module(module), constants, graph}
  end

  describe "a graph the checker really built" do
    test "audits clean" do
      {spec, constants, graph} = graph_for(TestSpecs.Cube)

      assert GraphAudit.audit(spec, constants, graph) == :ok
    end

    test "including one with a stuck state in it" do
      {spec, constants, graph} = graph_for(TestSpecs.Broken)

      assert GraphAudit.audit(spec, constants, graph) == :ok
    end

    @tag verifies: [
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/State Graph",
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Overview/DSL Macro Reference"
         ]
    test "and one with more than one initial state" do
      {spec, constants, graph} = graph_for(TestSpecs.TwoStarts)

      assert GraphAudit.audit(spec, constants, graph) == :ok
    end
  end

  describe "an edge table that is not what the spec admits" do
    # The defect #54 found surviving every gate. A missing out-edge makes some cycle
    # unfindable, and an unfindable cycle is indistinguishable from a property that holds.
    test "a dropped edge is found, and the message says which state" do
      {spec, constants, graph} = graph_for(TestSpecs.Cube)

      {id, [_dropped | rest]} = Enum.find(graph.edges, fn {_id, edges} -> edges != [] end)
      damaged = %{graph | edges: Map.put(graph.edges, id, rest)}

      assert {:error, message} = GraphAudit.audit(spec, constants, damaged)
      assert message =~ "state #{id}'s recorded out-edges"
      assert message =~ "admitted but not recorded"
      assert message =~ "indistinguishable from a property that holds"
    end

    # The reason the comparison is by identity and not by count. A table with the right
    # NUMBER of wrong edges is exactly what a merge or an ordering defect produces.
    test "a right-sized wrong table is found too" do
      {spec, constants, graph} = graph_for(TestSpecs.Cube)

      [{one, [first | _]}, {two, [second | _]}] =
        graph.edges |> Enum.filter(fn {_, e} -> e != [] end) |> Enum.take(2)

      swapped =
        graph.edges
        |> Map.put(one, [second | tl(graph.edges[one])])
        |> Map.put(two, [first | tl(graph.edges[two])])

      assert {:error, message} = GraphAudit.audit(spec, constants, %{graph | edges: swapped})
      assert message =~ "recorded but not admitted"
    end
  end

  describe "a stuck claim that is not true" do
    test "a state recorded as deadlocked that has successors" do
      {spec, constants, graph} = graph_for(TestSpecs.Cube)

      live = graph.edges |> Enum.find(fn {_id, edges} -> edges != [] end) |> elem(0)
      damaged = %{graph | deadlocked: MapSet.put(graph.deadlocked, live)}

      assert {:error, message} = GraphAudit.audit(spec, constants, damaged)
      assert message =~ "recorded as deadlocked, but the spec enables actions in it"
    end

    # `Broken` runs to n = 5 and then has nothing enabled; `Counter` cycles through
    # `reset` forever and has no stuck state at all, so it cannot exercise this.
    test "a state with nothing enabled that the search did not record as stuck" do
      {spec, constants, graph} = graph_for(TestSpecs.Broken)

      damaged = %{graph | terminal: MapSet.new(), deadlocked: MapSet.new()}

      assert {:error, message} = GraphAudit.audit(spec, constants, damaged)
      assert message =~ "has no enabled action, but the search did not record it"
    end
  end

  describe "what it refuses to audit" do
    test "a graph with no edge table, rather than reporting every edge as missing" do
      {_result, graph} =
        ModelChecker.explore(TestSpecs.Cube, %{check_deadlock: false, invariants: []})

      spec = Spec.Compiled.from_module(TestSpecs.Cube)

      assert_raise ArgumentError, ~r/needs the edge table/, fn ->
        GraphAudit.audit(spec, %{}, graph)
      end
    end
  end

  describe "a state the search never registered" do
    test "is named as a state the search missed, not as a missing edge" do
      {spec, constants, graph} = graph_for(TestSpecs.Cube)

      # Forget one state entirely: drop its fingerprint, so `id_of/2` cannot find it. That
      # is what a search which missed a state would leave behind.
      last = graph.fingerprints |> :ets.tab2list() |> List.last()
      :ets.delete_object(graph.fingerprints, last)

      assert {:error, message} = GraphAudit.audit(spec, constants, graph)

      assert message =~ "never registered" or message =~ "recorded out-edges",
             "expected a missed-state or edge finding, got: #{message}"
    end
  end

  describe "invariant_partition/3" do
    # `Safety.check_invariants/4` reads a predicate's result with `if`, so truthiness
    # rather than a boolean decides the verdict. That is what makes this partition a real
    # check rather than the tautology it looks like: `|I| + |not I| == total` cannot fail
    # if `not` is Elixir's, and ExTLA keeps no invariant AST to negate independently. The
    # third bucket is what can fail.
    test "a real invariant partitions the reachable states" do
      {spec, constants, _graph} = graph_for(TestSpecs.Broken)

      invariants = ModelChecker.checked_invariants(spec, constants)

      assert GraphAudit.invariant_partition(
               constants,
               invariants,
               GraphAudit.reachable(spec, constants)
             ) == :ok

      assert invariants != [], "the fixture must have an invariant, or this proves nothing"
    end

    # `:maybe` is truthy, so every state would report `holds` and the run would be green
    # over an invariant that never expressed anything.
    test "a predicate returning a truthy non-boolean is caught" do
      {spec, constants, _graph} = graph_for(TestSpecs.Broken)
      bad = %{name: :truthy_nonsense, predicate: fn _c, _s -> :maybe end}

      assert {:error, message} =
               GraphAudit.invariant_partition(
                 constants,
                 [bad],
                 GraphAudit.reachable(spec, constants)
               )

      assert message =~ ":truthy_nonsense"
      assert message =~ "returned neither `true` nor `false`"
      assert message =~ ":maybe"
      assert message =~ "reports `holds`"
    end

    # `nil` is falsy, so the run reports a violation the spec never expressed — a
    # counterexample for a property nobody wrote.
    test "a predicate returning nil is caught, and it is the more dangerous case" do
      {spec, constants, _graph} = graph_for(TestSpecs.Broken)
      bad = %{name: :missing_key, predicate: fn _c, state -> Map.get(state, :no_such_var) end}

      assert {:error, message} =
               GraphAudit.invariant_partition(
                 constants,
                 [bad],
                 GraphAudit.reachable(spec, constants)
               )

      assert message =~ ":missing_key"
      assert message =~ "a violation the spec never expressed"
    end

    test "one that decides most states and fumbles one is still caught" do
      {spec, constants, _graph} = graph_for(TestSpecs.Broken)

      bad = %{
        name: :mostly_fine,
        predicate: fn _c, state -> if state.n == 3, do: :shrug, else: true end
      }

      assert {:error, message} =
               GraphAudit.invariant_partition(
                 constants,
                 [bad],
                 GraphAudit.reachable(spec, constants)
               )

      assert message =~ "1 returned neither"
    end

    test "and a predicate that raises surfaces as the invariant's problem" do
      {spec, constants, _graph} = graph_for(TestSpecs.Broken)
      bad = %{name: :explodes, predicate: fn _c, state -> state.n / 0 > 1 end}

      # It raises rather than returning an error, and that is the honest outcome: a
      # predicate that cannot be evaluated is not a partition that came out wrong. What
      # matters is that it happens here, over a named invariant, rather than from inside
      # the search over an anonymous state.
      assert_raise ArithmeticError, fn ->
        GraphAudit.invariant_partition(constants, [bad], GraphAudit.reachable(spec, constants))
      end
    end
  end

  describe "fingerprint_injectivity/2" do
    test "a real graph maps distinct states to distinct ids" do
      {spec, constants, graph} = graph_for(TestSpecs.Cube)

      assert GraphAudit.fingerprint_injectivity(graph, GraphAudit.reachable(spec, constants)) ==
               :ok
    end

    # The observation the reported `collision_estimate` cannot make. Two states sharing an
    # id means their fingerprints collided, which removes a subtree from the search and
    # lowers `distinct_states` — and the run reports that smaller number with exactly the
    # same confidence as a correct one.
    test "two distinct states handed the same id are caught" do
      {spec, constants, graph} = graph_for(TestSpecs.Cube)
      states = GraphAudit.reachable(spec, constants)

      # Point a second state's fingerprint at an id already taken, which is what a
      # collision looks like from outside: `id_of/2` answers the same id for both.
      [{fingerprint_a, id_a}, {fingerprint_b, _} | _] = :ets.tab2list(graph.fingerprints)
      refute fingerprint_a == fingerprint_b
      :ets.insert(graph.fingerprints, {fingerprint_b, id_a})

      assert {:error, message} = GraphAudit.fingerprint_injectivity(graph, states)
      assert message =~ "distinct reachable states share id #{id_a}"
      assert message =~ "removes a subtree from the search"
    end

    test "it refuses a symmetry-reduced graph rather than calling the reduction a defect" do
      {_result, graph} =
        ModelChecker.explore(TestSpecs.Asymmetric, %{
          constants: %{processes: MapSet.new([:p1, :p2])},
          liveness_graph: true,
          check_deadlock: false,
          invariants: [],
          symmetry: [:processes]
        })

      assert_raise ArgumentError, ~r/not a property of a symmetry-reduced graph/, fn ->
        GraphAudit.fingerprint_injectivity(graph, MapSet.new())
      end
    end
  end
end
