defmodule ExTLA.StateGraph.Export do
  @moduledoc """
  DOT and JSON renderings of a state graph — the bodies of
  `ExTLA.StateGraph.to_dot/2` and `ExTLA.StateGraph.to_json/1`, which
  `04-layer2-model-checker.md` §State Graph specifies.

  A separate module because the graph itself is about *building* and querying the search
  structure, and rendering it needs the spec, the constants and `ExTLA.Trace` — the replay
  machinery — none of which the graph's own operations touch.

  ## Three things the graph's memory model forces

  **1. The edges come from the edge table, and there is no substitute.** `add_state/5`
  records one parent pointer per state, which is a spanning *tree*: every state appears
  once with one in-edge, and no cycle of the real graph is visible in it. That is the
  structure `successors/2` refuses to answer from, and drawing it while calling it the
  state graph would be a picture that is wrong in exactly the way the tool exists to
  prevent. So both exports require a graph built with `check_liveness: true` or
  `liveness_graph: true`, and raise otherwise rather than under-draw.

  **2. Node labels are replayed, not stored.** "The state itself is not retained" — a
  label costs a `path_to/2` walk and one action application per step (D-5). That is
  affordable for a graph a person reads and absurd for 58,359 states, which is why
  `to_dot/2` refuses past a cap rather than working for a very long time.

  **3. The refusal names the true count.** Over the cap, the caller is told how many
  states there are, in the spirit of `:max_states_reached`: a tool that quietly rendered
  the first 500 of 58,359 would hand back a picture that looks complete.
  """

  alias ExTLA.{StateGraph, Trace}

  # Large enough for the graphs people actually read, small enough that Graphviz produces
  # something a person can look at. Past a few hundred nodes a layout engine gives back a
  # hairball, so a higher cap would be offering to produce a picture nobody can use.
  @default_max_states 500

  @doc """
  DOT for Graphviz. See `ExTLA.StateGraph.to_dot/2`.
  """
  def to_dot(graph, opts \\ []) do
    require_edges!(graph, "to_dot/2")
    max_states = Keyword.get(opts, :max_states, @default_max_states)
    refuse_if_large!(graph, max_states, "--max-states")

    highlighted = highlighted_ids(graph, Keyword.get(opts, :highlight))
    ids = ids(graph)
    labels = Map.new(ids, &{&1, label(graph, &1)})

    [
      "digraph #{quoted(inspect(graph.spec.module))} {\n",
      "  rankdir=LR;\n",
      "  node [shape=box, fontname=\"monospace\", fontsize=10];\n",
      "  edge [fontname=\"monospace\", fontsize=9];\n\n",
      Enum.map(ids, &node_line(graph, &1, labels[&1], highlighted)),
      "\n",
      Enum.map(ids, &edge_lines(graph, &1, highlighted)),
      "}\n"
    ]
    |> IO.iodata_to_binary()
  end

  @doc """
  JSON for tooling. See `ExTLA.StateGraph.to_json/1`.
  """
  def to_json(graph) do
    require_edges!(graph, "to_json/1")
    ids = ids(graph)

    payload = %{
      "spec" => inspect(graph.spec.module),
      "constants" => ExTLA.State.Json.encode(graph.constants),
      "distinct_states" => graph.state_count,
      "transitions" => graph.transition_count,
      "diameter" => graph.diameter,
      "states" => Enum.map(ids, &json_state(graph, &1)),
      "edges" => Enum.flat_map(ids, &json_edges(graph, &1))
    }

    Jason.encode!(payload, pretty: true)
  end

  # ── Shared ──────────────────────────────────────────────────────────────────

  # Read from the table rather than assumed to be `0..state_count - 1`: ids have gaps under
  # `workers:`, because the loser of an `insert_new/2` race has already taken one (D-27).
  defp ids(graph), do: graph.nodes |> :ets.tab2list() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  defp require_edges!(graph, function) do
    unless StateGraph.liveness?(graph) do
      raise ArgumentError,
            "#{function} needs the edge table, and this graph was built without it. Parent " <>
              "pointers are a spanning tree — one in-edge per state, no cycles — so a " <>
              "rendering from them would show a different graph and say nothing about the " <>
              "difference. Re-run with `liveness_graph: true` (or `check_liveness: true`, " <>
              "which implies it). Note that liveness is refused together with `workers:` " <>
              "(D-27), so a graph for export is a single-process run."
    end
  end

  @doc false
  # The size rule, as a message rather than as a raise, so that `mix extla.visualize` can
  # present it as a `Mix.Error` beside its other refusals instead of letting an
  # `ArgumentError` out with a stack trace. One threshold and one wording, two surfaces —
  # the alternative is the task re-implementing the comparison and the two drifting.
  #
  # Returns `nil` when the graph is small enough.
  def refusal(graph, max_states, flag \\ ":max_states") do
    if graph.state_count > max_states do
      "this graph has #{graph.state_count} states and the limit is #{max_states}. " <>
        "Rendering it would produce a file no layout engine turns into a picture " <>
        "anyone can read, and every node's label costs a replay from `init` " <>
        "(states are not retained). Raise `#{flag}` if you meant it, or reduce the " <>
        "model — smaller constants, or a `state_constraint`."
    end
  end

  defp refuse_if_large!(graph, max_states, flag) do
    case refusal(graph, max_states, flag) do
      nil -> :ok
      message -> raise ArgumentError, message
    end
  end

  # The states named by a trace, as ids. A trace carries states rather than ids — it is a
  # behaviour, and a behaviour is meaningful without a graph — so each is fingerprinted
  # back to the id the graph knows it by.
  defp highlighted_ids(_graph, nil), do: %{states: MapSet.new(), edges: MapSet.new()}

  defp highlighted_ids(graph, %Trace{} = trace) do
    ids = Enum.map(trace.states, &StateGraph.id_of(graph, &1))

    %{
      states: ids |> Enum.reject(&is_nil/1) |> MapSet.new(),
      edges:
        ids
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.reject(fn [from, to] -> is_nil(from) or is_nil(to) end)
        |> MapSet.new(fn [from, to] -> {from, to} end)
    }
  end

  defp label(graph, id) do
    graph
    |> StateGraph.state_at(id)
    |> Enum.sort_by(fn {var, _} -> var end)
    |> Enum.map_join("\\n", fn {var, value} -> "#{var} = #{inspect(value, limit: 5)}" end)
  end

  # ── DOT ─────────────────────────────────────────────────────────────────────

  defp node_line(graph, id, label, highlighted) do
    record = StateGraph.node_record(graph, id)

    attrs =
      [
        "label=#{quoted("#{id}\\n#{label}")}",
        if(record.parent == nil, do: "peripheries=2"),
        if(MapSet.member?(graph.deadlocked, id), do: "style=filled, fillcolor=\"#ffdddd\""),
        if(MapSet.member?(graph.terminal, id), do: "shape=doubleoctagon"),
        if(MapSet.member?(highlighted.states, id), do: "color=\"#cc0000\", penwidth=2")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    "  #{id} [#{attrs}];\n"
  end

  defp edge_lines(graph, id, highlighted) do
    for {action, params, to} <- StateGraph.successors(graph, id) do
      attrs =
        [
          "label=#{quoted(edge_label(action, params))}",
          if(MapSet.member?(highlighted.edges, {id, to}), do: "color=\"#cc0000\", penwidth=2")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(", ")

      "  #{id} -> #{to} [#{attrs}];\n"
    end
  end

  defp edge_label(action, params) when params in [nil, %{}], do: to_string(action)

  defp edge_label(action, params) do
    bound = Enum.map_join(params, ", ", fn {k, v} -> "#{k}=#{inspect(v, limit: 3)}" end)
    "#{action}(#{bound})"
  end

  # DOT strings take C-style escapes, and `\\n` inside a label is a line break rather than
  # a character to escape — so backslashes are left alone and only quotes are escaped.
  defp quoted(string), do: "\"" <> String.replace(string, "\"", "\\\"") <> "\""

  # ── JSON ────────────────────────────────────────────────────────────────────

  defp json_state(graph, id) do
    record = StateGraph.node_record(graph, id)
    state = StateGraph.state_at(graph, id)

    %{
      "id" => id,
      "depth" => record.depth,
      "initial" => record.parent == nil,
      "deadlocked" => MapSet.member?(graph.deadlocked, id),
      "terminal" => MapSet.member?(graph.terminal, id),
      "state" => ExTLA.State.Json.encode(state)
    }
  end

  defp json_edges(graph, id) do
    for {action, params, to} <- StateGraph.successors(graph, id) do
      %{
        "from" => id,
        "to" => to,
        "action" => Atom.to_string(action),
        "params" => ExTLA.State.Json.encode(params || %{})
      }
    end
  end

  @doc false
  def default_max_states, do: @default_max_states
end
