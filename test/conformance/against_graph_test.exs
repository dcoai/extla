defmodule TLA.ConformanceAgainstGraphTest do
  @moduledoc """
  Layer 2 and Layer 3 checked against each other (#49/#60).

  Every test asserts **which class**, not merely that something was found. The classes are
  the deliverable: a containment check that reported "diverged" would add nothing over
  what Layer 3 already says, and the one class that is new — `:checker`, the search having
  missed a step the spec permits — is the only finding here that no other gate in the
  project can produce.
  """

  use ExUnit.Case, async: true

  alias TLA.Conformance.Counter.{Impl, Spec}
  alias TLA.{Conformance, ModelChecker, Simulation, StateGraph}

  @constants %{max_val: 5}

  setup_all do
    {result, graph} =
      ModelChecker.explore(Spec, %{
        constants: @constants,
        liveness_graph: true,
        invariants: [],
        action_properties: []
      })

    %{graph: graph, status: result.status}
  end

  describe "an implementation that conforms" do
    test "produces only in-graph traces", ctx do
      for seed <- [1, 7, 42] do
        {result, behaviour} =
          Simulation.run_trace(Impl.Conforming, %{max_steps: 12, seed: seed})

        assert result.status == :ok

        assert Conformance.against_graph(ctx.graph, behaviour, status: ctx.status) == :ok,
               "seed #{seed} left the graph"
      end
    end

    test "and the trace really did move, so this is not vacuous", ctx do
      {_result, behaviour} = Simulation.run_trace(Impl.Conforming, %{max_steps: 12, seed: 7})

      assert length(behaviour) > 3
      assert Enum.uniq(behaviour) != [hd(behaviour)]
      assert Conformance.against_graph(ctx.graph, behaviour, status: ctx.status) == :ok
    end
  end

  describe "a graph the search did not finish building" do
    # The finding this whole module exists for: the spec permits the step, and the graph
    # does not have it. A running server found a path the traversal missed.
    test "classifies an otherwise-fine trace as a CHECKER finding", ctx do
      {_result, behaviour} = Simulation.run_trace(Impl.Conforming, %{max_steps: 12, seed: 7})

      # Remove one edge the trace uses. Both states stay in the graph, so this is not an
      # absent state — it is a step the search should have recorded and did not.
      [pre, post | _] = behaviour
      id_pre = StateGraph.id_of(ctx.graph, pre)
      id_post = StateGraph.id_of(ctx.graph, post)

      thinned =
        Map.update!(ctx.graph.edges, id_pre, fn edges ->
          Enum.reject(edges, fn {_a, _b, to} -> to == id_post end)
        end)

      assert {:checker, detail} =
               Conformance.against_graph(%{ctx.graph | edges: thinned}, behaviour,
                 status: ctx.status
               )

      assert detail.from == pre
      assert detail.to == post

      assert Conformance.explain({:checker, detail}) =~
               "defect in the search rather than in the code"
    end

    test "and a state missing entirely is ABSENT rather than a missing edge", ctx do
      {_result, behaviour} = Simulation.run_trace(Impl.Conforming, %{max_steps: 12, seed: 7})

      [_pre, post | _] = behaviour
      id_post = StateGraph.id_of(ctx.graph, post)

      fingerprints = :ets.tab2list(ctx.graph.fingerprints)
      {fingerprint, ^id_post} = Enum.find(fingerprints, fn {_f, id} -> id == id_post end)
      :ets.delete(ctx.graph.fingerprints, fingerprint)

      assert {:absent_state, detail} =
               Conformance.against_graph(ctx.graph, behaviour, status: ctx.status)

      assert detail.state == post
      :ets.insert(ctx.graph.fingerprints, {fingerprint, id_post})
    end
  end

  describe "a step the spec does not permit" do
    test "is classified as the pair it is, without a confident split", ctx do
      # A behaviour the spec forbids: `count` jumps by two, which no action of
      # `Specs.Counter` does. Both states are legal states; the STEP between them is not.
      fabricated = [
        %{count: 0, status: :ready},
        %{count: 2, status: :incrementing}
      ]

      assert {:not_a_step_of_the_spec, detail} =
               Conformance.against_graph(ctx.graph, fabricated, status: ctx.status)

      explanation = Conformance.explain({:not_a_step_of_the_spec, detail})

      assert explanation =~ "forbids, or the refinement mapping"
      assert explanation =~ "NOT decidable from one step"
    end
  end

  # #168. `Enum.zip(behaviour, tl(behaviour))` is `[]` for a one-state behaviour, so the fold
  # returned its `:ok` seed and `explain/1` said "every observed state is in the graph" about
  # a state that was not in it.
  #
  # Reachable in practice: a simulation trace whose first generated message times out or is
  # refused yields exactly one state. And this is the module that already refuses a BOUNDED
  # graph outright rather than report absence from it — the same discipline, missed at the
  # other end of the input.
  describe "a behaviour with no steps" do
    test "a single state absent from the graph is a finding, not a pass", ctx do
      bogus = %{count: 999, status: :nowhere}

      assert StateGraph.id_of(ctx.graph, bogus) == nil,
             "the fixture state must genuinely be absent or this test asserts nothing"

      assert {:absent_state, detail} =
               Conformance.against_graph(ctx.graph, [bogus], status: ctx.status)

      assert detail.state == bogus
      assert detail.position == :only

      explanation = Conformance.explain({:absent_state, detail})
      assert explanation =~ "the behaviour's only state"
      refute explanation =~ "step 0"
    end

    test "a single state that IS in the graph is :ok", ctx do
      {_result, behaviour} = Simulation.run_trace(Impl.Conforming, %{max_steps: 12, seed: 7})
      first = hd(behaviour)

      refute StateGraph.id_of(ctx.graph, first) == nil

      assert Conformance.against_graph(ctx.graph, [first], status: ctx.status) == :ok
    end

    # Not `:ok`. Nothing was observed, so nothing contradicts the graph — but answering
    # success about an empty observation is the shape that made the case above lie.
    test "an empty behaviour is its own outcome, and says so", ctx do
      assert Conformance.against_graph(ctx.graph, [], status: ctx.status) == :nothing_observed

      assert Conformance.explain(:nothing_observed) =~ "not a pass"
    end
  end

  describe "a truncated graph" do
    test "is refused rather than answered from", ctx do
      {_result, behaviour} = Simulation.run_trace(Impl.Conforming, %{max_steps: 4, seed: 7})

      for bounded <- [:max_states_reached, :constrained] do
        assert_raise ArgumentError, ~r/does not describe the whole state space/, fn ->
          Conformance.against_graph(ctx.graph, behaviour, status: bounded)
        end
      end
    end

    test "and the status is required, not defaulted", ctx do
      {_result, behaviour} = Simulation.run_trace(Impl.Conforming, %{max_steps: 4, seed: 7})

      assert_raise KeyError, fn -> Conformance.against_graph(ctx.graph, behaviour, []) end
    end
  end
end
