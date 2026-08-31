defmodule TLA.Trace do
  @moduledoc """
  Counterexample traces.

  When the model checker finds a violation it produces a trace: the shortest
  sequence of states from an initial state to the violating one. The search is
  breadth-first and an invariant is evaluated when a state is first discovered,
  so "the first violation found" and "the shortest counterexample" are the same
  thing.

  The states are not stored during the run (`TLA.StateGraph`), so a trace is
  *regenerated*: the path of `{action, params}` is walked back through parent
  pointers and replayed forward from the `init` block that produced the root.
  """

  alias TLA.{Spec, StateGraph}

  @type t :: %__MODULE__{
          type: :safety | :liveness | :deadlock,
          property: atom() | nil,
          message: String.t(),
          states: [TLA.State.t()],
          actions: [atom()],

          # The parameter binding of each action. `04-layer2-model-checker.md`
          # typed a trace as states plus action NAMES, but its own example output
          # prints `begin_transfer(from: alice, to: bob, amount: 3)` — and without
          # the binding a reader cannot tell which of |accounts|^2 transitions the
          # trace took, which is most of what a counterexample is for.
          bindings: [map()],
          length: non_neg_integer()
        }

  @typedoc """
  A liveness counterexample: a finite prefix, then a cycle repeated forever.

  `cycle` is `nil` where a single state refutes the property — `pred` and `always(pred)`
  are settled by one state, and printing an invented cycle after it would suggest the
  reason lay somewhere it does not. A `cycle` whose `actions` are empty is a state that
  stutters forever: a `terminal` (`02-dsl-semantics.md` §5.3), which is a legal end of a
  behaviour and refutes anything that was still waiting for something to happen.
  """
  @type lasso :: %{prefix: t(), cycle: t() | nil}

  defstruct type: :safety,
            property: nil,
            message: "",
            states: [],
            actions: [],
            bindings: [],
            length: 0

  @doc """
  Generate the shortest trace from an initial state to the target.
  """
  @spec generate(StateGraph.t(), StateGraph.state_id(), keyword()) :: t()
  def generate(graph, target, opts \\ []) do
    {init_index, steps} = StateGraph.path_to(graph, target)
    replay(graph, init_index, steps, opts)
  end

  @doc """
  A trace for an arbitrary path: the state `init_index` produces, then `steps` applied in
  order.

  `generate/3` is the shortest path to one state, which is what a safety violation needs.
  A liveness counterexample is not that shape — its prefix may be restricted to a subgraph
  and its cycle starts nowhere near an `init` — so the path is handed over rather than
  walked back from parent pointers.
  """
  @spec replay(StateGraph.t(), non_neg_integer(), [{atom(), map()}], keyword()) :: t()
  def replay(graph, init_index, steps, opts \\ []) do
    initial = graph.spec.init |> Enum.at(init_index) |> apply([graph.constants])
    from(graph, initial, steps, opts)
  end

  @doc """
  A trace beginning at a state already in hand, applying `steps` in order.
  """
  @spec from(StateGraph.t(), TLA.State.t(), [{atom(), map()}], keyword()) :: t()
  def from(graph, initial, steps, opts \\ []) do
    states =
      Enum.scan(steps, initial, fn {action, params}, state ->
        Spec.Compiled.action(graph.spec, action).transition.(graph.constants, state, params)
      end)

    %__MODULE__{
      type: Keyword.get(opts, :type, :safety),
      property: Keyword.get(opts, :property),
      message: Keyword.get(opts, :message, ""),
      states: [initial | states],
      actions: Enum.map(steps, fn {action, _} -> action end),
      bindings: Enum.map(steps, fn {_, params} -> params || %{} end),
      length: length(steps) + 1
    }
  end

  @doc """
  Export a trace as a sequence of state diffs, for programmatic consumption.
  """
  @spec to_diffs(t()) :: [%{action: atom(), params: map(), changed: map(), state: TLA.State.t()}]
  def to_diffs(%__MODULE__{states: [first | rest]} = trace) do
    steps = Enum.zip([trace.actions, trace.bindings, rest])

    [%{action: nil, params: %{}, changed: first, state: first}] ++
      Enum.map(Enum.zip(steps, [first | rest]), fn {{action, params, state}, previous} ->
        changed =
          {previous, state}
          |> TLA.State.changed_vars()
          |> Map.new(&{&1, Map.fetch!(state, &1)})

        %{action: action, params: params, changed: changed, state: state}
      end)
  end

  def to_diffs(%__MODULE__{states: []}), do: []

  @doc """
  Pretty-print a trace or a lasso, marking the variables each step changed.
  """
  @spec format(t() | lasso()) :: String.t()
  def format(%{prefix: prefix, cycle: nil}), do: format(prefix)

  def format(%{prefix: prefix, cycle: %__MODULE__{} = cycle}) do
    back_to = length(prefix.states)

    joined = %{
      prefix
      | states: prefix.states ++ tl(cycle.states),
        actions: prefix.actions ++ cycle.actions,
        bindings: prefix.bindings ++ cycle.bindings,
        length: prefix.length + cycle.length - 1
    }

    format(joined) <> loop_note(cycle, back_to)
  end

  def format(%__MODULE__{} = trace) do
    header = header(trace)
    diffs = to_diffs(trace)
    last = length(diffs)

    body =
      diffs
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {diff, index} ->
        step(diff, index, index == last, trace)
      end)

    header <> "\n\n" <> body <> "\n" <> String.duplicate("═", 68) <> "\n"
  end

  # The whole point of a lasso: what happens after the last state printed. Without this
  # line the trace reads as though it ended, and "ended" is the one thing it did not do.
  defp loop_note(%__MODULE__{actions: []}, back_to) do
    "\nState #{back_to} has no successors: the behaviour stutters there forever " <>
      "(02-dsl-semantics.md §5.3).\n"
  end

  defp loop_note(%__MODULE__{states: states}, back_to) do
    "\n↺ back to state #{back_to} — states #{back_to}-#{back_to + length(states) - 2} " <>
      "repeat forever.\n"
  end

  defp header(%{type: :deadlock}), do: banner("DEADLOCK")
  defp header(%{type: :safety, property: property}), do: banner("VIOLATION: #{property}")
  defp header(%{type: :liveness, property: property}), do: banner("LIVENESS: #{property}")

  defp banner(title) do
    line = String.duplicate("═", max(0, 68 - String.length(title) - 5))
    "═══ " <> title <> " " <> line
  end

  defp step(diff, index, last?, trace) do
    label =
      cond do
        index == 1 and last? -> "State 1 (Init) [VIOLATION]:"
        index == 1 -> "State 1 (Init):"
        last? -> "State #{index} [VIOLATION]:"
        true -> "State #{index}:"
      end

    transition =
      if index == 1 do
        ""
      else
        "── " <>
          call(Enum.at(trace.actions, index - 2), Enum.at(trace.bindings, index - 2)) <>
          " " <> String.duplicate("─", 20) <> "\n\n"
      end

    width =
      diff.state
      |> Map.keys()
      |> Enum.map(&String.length(Atom.to_string(&1)))
      |> Enum.max(&>=/2, fn -> 0 end)

    variables =
      diff.state
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map_join("\n", fn {name, value} ->
        marker = if Map.has_key?(diff.changed, name) and index > 1, do: "   ← changed", else: ""

        "  " <>
          String.pad_trailing(Atom.to_string(name), width) <> " = " <> inspect(value) <> marker
      end)

    transition <> label <> "\n" <> variables <> "\n"
  end

  defp call(action, params) when map_size(params) == 0, do: "#{action}"

  defp call(action, params) do
    arguments =
      params
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map_join(", ", fn {name, value} -> "#{name}: #{inspect(value)}" end)

    "#{action}(#{arguments})"
  end
end
