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

  alias TLA.{ModelChecker, Spec, StateGraph}

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
  The trace as data `Jason.encode!/1` accepts, and `from_json!/1` reads back.

  Accepts a lasso too, which round-trips as `%{prefix:, cycle:}`. States and bindings go
  through `TLA.State.Json`, because `inspect/1` produces something a person can read and a
  machine cannot parse — and `05-layer3-conformance.md`'s pipeline runs
  `mix tla.check --format json` into `mix tla.replay --trace`, which needs the second.
  """
  def to_json(%__MODULE__{} = trace) do
    %{
      "type" => Atom.to_string(trace.type),
      "property" => trace.property && Atom.to_string(trace.property),
      "message" => trace.message,
      "length" => trace.length,
      "actions" => Enum.map(trace.actions, &Atom.to_string/1),
      "bindings" => Enum.map(trace.bindings, &TLA.State.Json.encode/1),
      "states" => Enum.map(trace.states, &TLA.State.Json.encode/1)
    }
  end

  def to_json(%{prefix: prefix, cycle: cycle}) do
    %{
      "type" => "liveness",
      "property" => prefix.property && Atom.to_string(prefix.property),
      "message" => prefix.message,
      "prefix" => to_json(prefix),
      "cycle" => cycle && to_json(cycle)
    }
  end

  @doc """
  The trace a `to_json/1` result came from.

  Atom names are resolved against the atoms the system already has (`TLA.State.Json`), so
  a trace belonging to a different specification fails with the name that did not resolve
  rather than by quietly decoding into something else.
  """
  def from_json!(%{"prefix" => prefix} = data) do
    %{prefix: from_json!(prefix), cycle: data["cycle"] && from_json!(data["cycle"])}
  end

  def from_json!(%{"states" => states} = data) do
    %__MODULE__{
      type: String.to_existing_atom(data["type"] || "safety"),
      property: data["property"] && TLA.State.Json.decode!(%{"a" => data["property"]}),
      message: data["message"] || "",
      length: data["length"] || max(length(states) - 1, 0),
      actions: Enum.map(data["actions"] || [], &TLA.State.Json.decode!(%{"a" => &1})),
      bindings: Enum.map(data["bindings"] || [], &TLA.State.Json.decode!/1),
      states: Enum.map(states, &TLA.State.Json.decode!/1)
    }
  end

  def from_json!(other) do
    raise ArgumentError,
          "#{inspect(other)} is not an encoded trace: expected an object with \"states\" " <>
            "(a trace) or \"prefix\" (a lasso)."
  end

  @doc """
  Generate the shortest trace from an initial state to the target.
  """
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
  def replay(graph, init_index, steps, opts \\ []) do
    initial = graph.spec.init |> Enum.at(init_index) |> apply([graph.constants])
    from(graph, initial, steps, opts)
  end

  @doc """
  A trace beginning at a state already in hand, applying `steps` in order.
  """
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
  A trace or a lasso as the behaviour it describes, with the index its cycle returns to.

  `nil` for a plain trace and for a lasso with no cycle: those are prefixes of something
  longer, and `TLA.Temporal`'s operators will say `:inconclusive` where the states do not
  reach far enough to settle a question.

  A lasso's cycle ends where it began, so the repeated final state is dropped — the
  behaviour lists each state of the cycle once and `lasso_start` says where to loop back
  to. A cycle of one state is a `terminal` stuttering forever (`02-dsl-semantics.md`
  §5.3), and comes back as the prefix with `lasso_start` on its last state.
  """
  def to_behavior(%__MODULE__{states: states}), do: {states, nil}

  def to_behavior(%{prefix: prefix, cycle: nil}), do: {prefix.states, nil}

  def to_behavior(%{prefix: prefix, cycle: %__MODULE__{} = cycle}) do
    {prefix.states ++ (cycle.states |> tl() |> Enum.drop(-1)), length(prefix.states) - 1}
  end

  @doc """
  Check that a counterexample is a behaviour the spec actually admits.

  A pure function of the trace and the spec: no oracle, no second search, no
  implementation on the other end. A checker that hands back a trace is making a claim
  about the spec, and this is the claim checked against the spec rather than against a
  fixture recording what some other tool once said.

  ## What it checks

    1. The first state is one the spec's `init` blocks produce.
    2. Every step names an action that is **enabled with that binding** in the state
       before it — `TLA.ModelChecker.enabled_steps/3`, the checker's own notion of what
       may happen next, so this cannot agree with a second enumeration instead of with
       the checker.
    3. Every step's post-state is what that action's transition actually produces. This is
       the one a trace can fail while looking entirely plausible: real states, real
       actions, and a pairing between them that is a lie.
    4. For a lasso, additionally: the cycle starts where the prefix ends, its steps are
       legal, and it **closes** — applying them returns to its own first state.

  ## What it deliberately does not check

  Whether the property is genuinely refuted along the behaviour, and whether the cycle
  satisfies the spec's fairness. Both are already checked, by `TLA.TemporalCheck`, which
  shares no code with `TLA.ModelChecker.Liveness` and is what makes that agreement
  evidence. A third implementation of the same semantics here would add a place for them
  to disagree and no new information.

  Returns `:ok`, or `{:error, message}` naming the step and what was wrong with it.
  """
  def validate(trace_or_lasso, spec, constants)

  def validate(%__MODULE__{} = trace, spec, constants) do
    spec = compiled(spec)

    with :ok <- from_init(spec, constants, trace),
         do: legal_steps(spec, constants, trace, "the trace")
  end

  def validate(%{prefix: prefix, cycle: nil}, spec, constants) do
    validate(prefix, spec, constants)
  end

  def validate(%{prefix: prefix, cycle: %__MODULE__{states: []}}, spec, constants) do
    with :ok <- validate(prefix, spec, constants),
         do: {:error, "the lasso's cycle has no states, so there is nothing to repeat."}
  end

  def validate(%{prefix: prefix, cycle: %__MODULE__{} = cycle}, spec, constants) do
    spec = compiled(spec)

    with :ok <- validate(prefix, spec, constants),
         :ok <- cycle_continues(prefix, cycle),
         :ok <- legal_steps(spec, constants, cycle, "the cycle"),
         do: cycle_closes(cycle)
  end

  @doc """
  `validate/3`, raising instead of returning an error. For a test that wants the message
  rather than a boolean.
  """
  def validate!(trace_or_lasso, spec, constants) do
    case validate(trace_or_lasso, spec, constants) do
      :ok -> :ok
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp compiled(%Spec.Compiled{} = spec), do: spec
  defp compiled(module) when is_atom(module), do: Spec.Compiled.from_module(module)

  # A trace with no states is not a short behaviour, it is not a behaviour — and it
  # reaches the validator as a corrupted one rather than as a legitimate edge case, so it
  # gets a message rather than an `:erlang.hd` crash from three functions further in.
  defp from_init(_spec, _constants, %__MODULE__{states: []}) do
    {:error, "the trace has no states, so there is no behaviour to check."}
  end

  defp from_init(spec, constants, %__MODULE__{states: [first | _]}) do
    if Enum.any?(spec.init, &(&1.(constants) == first)) do
      :ok
    else
      {:error,
       "the trace starts at a state no `init` block produces:\n\n  #{inspect(first)}\n\n" <>
         "A counterexample that does not start where the spec starts is not a behaviour " <>
         "of the spec, whatever else is true of it."}
    end
  end

  defp from_init(_spec, _constants, _trace), do: :ok

  # Zipped rather than indexed, so a trace whose `actions` and `states` disagree in length
  # is caught here as a shape error rather than silently checking the shorter of the two.
  defp legal_steps(spec, constants, %__MODULE__{} = trace, what) do
    if length(trace.actions) != length(trace.states) - 1 or
         length(trace.bindings) != length(trace.actions) do
      {:error,
       "#{what} has #{length(trace.states)} states, #{length(trace.actions)} actions and " <>
         "#{length(trace.bindings)} bindings, which cannot describe one behaviour."}
    else
      trace.states
      |> Enum.zip(tl(trace.states))
      |> Enum.zip(Enum.zip(trace.actions, trace.bindings))
      |> Enum.with_index(1)
      |> Enum.reduce_while(:ok, fn {{{pre, post}, {action, binding}}, step}, :ok ->
        case legal_step(spec, constants, pre, post, action, binding, step, what) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp legal_step(spec, constants, pre, post, action, binding, step, what) do
    cond do
      {action, binding} not in ModelChecker.enabled_steps(spec, constants, pre) ->
        {:error,
         "#{what}, step #{step}: #{inspect(action)} with #{inspect(binding)} is not " <>
           "enabled in\n\n  #{inspect(pre)}\n\n" <>
           "What is enabled there: " <>
           inspect(ModelChecker.enabled_steps(spec, constants, pre), limit: 8)}

      Spec.Compiled.action(spec, action).transition.(constants, pre, binding) != post ->
        {:error,
         "#{what}, step #{step}: #{inspect(action)} with #{inspect(binding)} is enabled " <>
           "in\n\n  #{inspect(pre)}\n\nbut produces\n\n  " <>
           inspect(Spec.Compiled.action(spec, action).transition.(constants, pre, binding)) <>
           "\n\nand the trace says the next state is\n\n  #{inspect(post)}\n\n" <>
           "Real states and a real action, paired by something that did not compute them."}

      true ->
        :ok
    end
  end

  defp cycle_continues(prefix, cycle) do
    if List.last(prefix.states) == hd(cycle.states) do
      :ok
    else
      {:error,
       "the cycle starts at\n\n  #{inspect(hd(cycle.states))}\n\nbut the prefix ends " <>
         "at\n\n  #{inspect(List.last(prefix.states))}\n\nso the lasso is two " <>
         "behaviours rather than one."}
    end
  end

  defp cycle_closes(%__MODULE__{states: states}) do
    if hd(states) == List.last(states) do
      :ok
    else
      {:error,
       "the cycle does not close: it starts at\n\n  #{inspect(hd(states))}\n\nand ends " <>
         "at\n\n  #{inspect(List.last(states))}\n\nso it cannot be repeated forever, " <>
         "which is the only thing a lasso's cycle is for."}
    end
  end

  @doc """
  Export a trace as a sequence of state diffs, for programmatic consumption.
  """
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
