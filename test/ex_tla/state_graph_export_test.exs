defmodule ExTLA.StateGraphExportTest do
  @moduledoc """
  `to_dot/2` and `to_json/1`, which `04-layer2-model-checker.md` §State Graph specifies.

  The tests that matter here are the refusals. A visualization is a claim about a graph,
  and the two ways this one could lie — drawing a spanning tree as though it were the
  transition relation, and rendering a prefix of a large graph as though it were the whole
  — are both silent unless something stops them.
  """

  use ExUnit.Case, async: true

  @moduletag verifies:
               "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/State Graph"

  alias ExTLA.{ModelChecker, StateGraph, TestSpecs}

  # Both exports need the edge table, so every fixture here asks for it.
  defp graph(module, config) do
    ModelChecker.explore(module, Map.put(config, :liveness_graph, true))
  end

  describe "to_dot/2" do
    setup do
      {_result, graph} = graph(TestSpecs.Counter, %{constants: %{max: 2}})
      %{graph: graph, dot: StateGraph.to_dot(graph)}
    end

    test "declares one node per state and one edge per transition", %{graph: graph, dot: dot} do
      nodes = Regex.scan(~r/^  (\d+) \[/m, dot)
      edges = Regex.scan(~r/^  (\d+) -> (\d+) \[/m, dot)

      assert length(nodes) == graph.state_count

      recorded =
        graph
        |> all_ids()
        |> Enum.map(&length(StateGraph.successors(graph, &1)))
        |> Enum.sum()

      assert length(edges) == recorded
    end

    # Graphviz is not installed on this machine or in CI's image, and taking a dependency
    # on it to test a string would be the wrong trade. The structural checks are what
    # `dot -Tsvg` would catch: unbalanced braces, and an edge naming a node that was never
    # declared — which is what an id-numbering bug looks like from the outside.
    test "is structurally well formed", %{dot: dot} do
      assert String.starts_with?(dot, "digraph ")
      assert String.ends_with?(dot, "}\n")

      opens = dot |> String.graphemes() |> Enum.count(&(&1 == "{"))
      closes = dot |> String.graphemes() |> Enum.count(&(&1 == "}"))
      assert opens == closes

      declared = ~r/^  (\d+) \[/m |> Regex.scan(dot) |> MapSet.new(&Enum.at(&1, 1))

      for [_, from, to] <- Regex.scan(~r/^  (\d+) -> (\d+) \[/m, dot) do
        assert MapSet.member?(declared, from), "edge from undeclared node #{from}"
        assert MapSet.member?(declared, to), "edge to undeclared node #{to}"
      end
    end

    test "labels every node with its variables", %{dot: dot} do
      assert dot =~ "n = 0"
      assert dot =~ "done = false"
      assert dot =~ "done = true"
    end

    test "marks initial states", %{dot: dot} do
      assert dot =~ ~r/^  0 \[.*peripheries=2/m
    end

    test "labels edges with the action, and with its bindings where it has them" do
      {_result, graph} =
        graph(TestSpecs.Transfer, %{
          constants: %{accounts: MapSet.new([:alice, :bob]), max_balance: 2},
          state_constraint: fn state -> length(state.log) == 0 end,
          check_deadlock: false
        })

      dot = StateGraph.to_dot(graph)

      assert dot =~ ~r/label="\w+\(\w+=/, "an action with params should show its binding"
    end
  end

  describe "what to_dot/2 refuses" do
    # The failure this exists to prevent. Parent pointers give one in-edge per state, so a
    # DOT built from them is a tree — a picture that is wrong in a way nobody looking at it
    # could detect.
    test "a graph with no edge table, rather than drawing the spanning tree" do
      {_result, graph} = ModelChecker.explore(TestSpecs.Counter, %{constants: %{max: 2}})

      error = assert_raise ArgumentError, fn -> StateGraph.to_dot(graph) end
      message = Exception.message(error)

      assert message =~ "spanning tree"
      assert message =~ "liveness_graph: true"
    end

    test "a graph larger than the cap, naming the count it actually has" do
      {_result, graph} = graph(TestSpecs.Counter, %{constants: %{max: 20}})

      error = assert_raise ArgumentError, fn -> StateGraph.to_dot(graph, max_states: 5) end
      message = Exception.message(error)

      assert message =~ "#{graph.state_count} states"
      assert message =~ "the limit is 5"
      assert message =~ "--max-states"
    end

    test "and renders it when the cap allows" do
      {_result, graph} = graph(TestSpecs.Counter, %{constants: %{max: 20}})

      assert StateGraph.to_dot(graph, max_states: 1_000) =~ "digraph"
    end
  end

  describe "a counterexample on the graph it was found in" do
    setup do
      {result, graph} = graph(TestSpecs.Broken, %{})
      %{result: result, graph: graph}
    end

    test "the violation's states are drawn distinguishably", ctx do
      assert ctx.result.status == :violation

      plain = StateGraph.to_dot(ctx.graph)
      marked = StateGraph.to_dot(ctx.graph, highlight: ctx.result.violation)

      refute plain =~ "penwidth"
      assert marked =~ "penwidth"

      # Every state of the trace, and no more than those.
      highlighted = ~r/^  (\d+) \[.*penwidth/m |> Regex.scan(marked) |> length()
      assert highlighted == ctx.result.violation.length
    end

    test "a trace whose states this graph never registered highlights nothing", ctx do
      other = %{ctx.result.violation | states: [%{n: 9_999}]}

      assert StateGraph.to_dot(ctx.graph, highlight: other) == StateGraph.to_dot(ctx.graph)
    end
  end

  describe "to_json/1" do
    setup do
      {_result, graph} = graph(TestSpecs.Counter, %{constants: %{max: 2}})
      %{graph: graph, json: StateGraph.to_json(graph)}
    end

    test "round-trips through Jason", %{graph: graph, json: json} do
      decoded = Jason.decode!(json)

      assert decoded["spec"] == "ExTLA.TestSpecs.Counter"
      assert decoded["distinct_states"] == graph.state_count
      assert decoded["diameter"] == graph.diameter
      assert length(decoded["states"]) == graph.state_count
    end

    test "carries every state's variables, not just its id", %{json: json} do
      decoded = Jason.decode!(json)
      initial = Enum.find(decoded["states"], & &1["initial"])

      assert initial["depth"] == 1
      assert initial["state"] != nil
    end

    test "carries every edge with the action that produced it", %{graph: graph, json: json} do
      decoded = Jason.decode!(json)

      recorded =
        graph |> all_ids() |> Enum.map(&length(StateGraph.successors(graph, &1))) |> Enum.sum()

      assert length(decoded["edges"]) == recorded
      assert Enum.all?(decoded["edges"], &is_binary(&1["action"]))
    end

    test "refuses a graph with no edge table, for the reason to_dot/2 does" do
      {_result, graph} = ModelChecker.explore(TestSpecs.Counter, %{constants: %{max: 2}})

      assert_raise ArgumentError, ~r/spanning tree/, fn -> StateGraph.to_json(graph) end
    end
  end

  describe "id_of/2" do
    test "answers the id the graph knows a state by" do
      {_result, graph} = graph(TestSpecs.Counter, %{constants: %{max: 2}})

      assert StateGraph.id_of(graph, %{n: 0, done: false}) == 0
      assert is_integer(StateGraph.id_of(graph, %{n: 1, done: false}))
    end

    test "and nil for a state it never registered" do
      {_result, graph} = graph(TestSpecs.Counter, %{constants: %{max: 2}})

      assert StateGraph.id_of(graph, %{n: 99, done: false}) == nil
    end
  end

  defp all_ids(graph), do: graph.nodes |> :ets.tab2list() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
end
