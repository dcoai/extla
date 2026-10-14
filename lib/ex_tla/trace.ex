defmodule ExTLA.Trace do
  @moduledoc """
  Counterexample traces.

  When the model checker finds a violation it produces a trace: the shortest
  sequence of states from an initial state to the violating one. The search is
  breadth-first and an invariant is evaluated when a state is first discovered,
  so "the first violation found" and "the shortest counterexample" are the same
  thing.

  The states are not stored during the run (`ExTLA.StateGraph`), so a trace is
  *regenerated*: the path of `{action, params}` is walked back through parent
  pointers and replayed forward from the `init` block that produced the root.
  """

  alias ExTLA.{ModelChecker, Spec, StateGraph}

  @type t :: %__MODULE__{
          type: :safety | :liveness | :deadlock,
          property: atom() | nil,
          message: String.t(),
          states: [ExTLA.State.t()],
          actions: [atom()],

          # The parameter binding of each action. `04-layer2-model-checker.md`
          # typed a trace as states plus action NAMES, but its own example output
          # prints `begin_transfer(from: alice, to: bob, amount: 3)` — and without
          # the binding a reader cannot tell which of |accounts|^2 transitions the
          # trace took, which is most of what a counterexample is for.
          bindings: [map()],

          # The number of STATES — `length(states)`, so a trace of one state has length 1 and
          # a lasso's splice drops the shared state. It once meant three things: this, one
          # less in `from_json!/1`'s fallback, and the action count in `ExTLA.Simulation` (#212).
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
  through `ExTLA.State.Json`, because `inspect/1` produces something a person can read and a
  machine cannot parse — and the conformance pipeline runs `mix extla.check --format json`
  into `mix extla.replay --trace`, which needs the second.
  """
  def to_json(%__MODULE__{} = trace) do
    %{
      "type" => Atom.to_string(trace.type),
      "property" => trace.property && Atom.to_string(trace.property),
      "message" => trace.message,
      "length" => trace.length,
      "actions" => Enum.map(trace.actions, &Atom.to_string/1),
      "bindings" => Enum.map(trace.bindings, &ExTLA.State.Json.encode/1),
      "states" => Enum.map(trace.states, &ExTLA.State.Json.encode/1)
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

  Atom names are resolved against the atoms the system already has (`ExTLA.State.Json`), so
  a trace belonging to a different specification fails with the name that did not resolve
  rather than by quietly decoding into something else.
  """
  def from_json!(%{"prefix" => prefix} = data) do
    %{prefix: from_json!(prefix), cycle: data["cycle"] && from_json!(data["cycle"])}
  end

  # A trace file is data from outside the program, and this reads its STRUCTURE before it
  # builds anything (#211). The first version read none: `"type"` went through
  # `String.to_existing_atom/1`, so `"ok"` became `:ok` and `format/1` failed later on a
  # type it does not know; a non-string type was a raw `ArgumentError`; two states and no
  # actions built a trace that could not describe one behaviour and was rendered anyway.
  @types %{"safety" => :safety, "liveness" => :liveness, "deadlock" => :deadlock}

  def from_json!(%{"states" => states} = data) when is_list(states) do
    type =
      case Map.get(data, "type", "safety") do
        given when is_map_key(@types, given) ->
          Map.fetch!(@types, given)

        other ->
          raise ArgumentError,
                "#{inspect(other)} is not a trace type: expected one of " <>
                  "#{@types |> Map.keys() |> Enum.map_join(", ", &inspect/1)}."
      end

    trace = %__MODULE__{
      type: type,
      property: data["property"] && ExTLA.State.Json.decode!(%{"a" => data["property"]}),
      message: data["message"] || "",
      length: data["length"] || length(states),
      actions: Enum.map(list!(data, "actions"), &ExTLA.State.Json.decode!(%{"a" => &1})),
      bindings: Enum.map(list!(data, "bindings"), &ExTLA.State.Json.decode!/1),
      states: Enum.map(states, &ExTLA.State.Json.decode!/1)
    }

    if misaligned?(trace) do
      raise ArgumentError,
            "the encoded trace has #{shape(trace)}, which cannot describe one behaviour: " <>
              "n states need n - 1 actions and one binding each."
    end

    trace
  end

  def from_json!(other) do
    raise ArgumentError,
          "#{inspect(other)} is not an encoded trace: expected an object with \"states\" " <>
            "(a trace) or \"prefix\" (a lasso)."
  end

  defp list!(data, key) do
    case Map.get(data, key, []) do
      list when is_list(list) ->
        list

      other ->
        raise ArgumentError,
              "the encoded trace's #{inspect(key)} is not a list: #{inspect(other)}"
    end
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
    |> well_formed!("ExTLA.Trace.from/4")
  end

  @doc """
  A trace or a lasso as the behaviour it describes, with the index its cycle returns to.

  `nil` for a plain trace and for a lasso with no cycle: those are prefixes of something
  longer, and `ExTLA.Temporal`'s operators will say `:inconclusive` where the states do not
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
       before it — `ExTLA.ModelChecker.enabled_steps/3`, the checker's own notion of what
       may happen next, so this cannot agree with a second enumeration instead of with
       the checker.
    3. Every step's post-state is what that action's transition actually produces. This is
       the one a trace can fail while looking entirely plausible: real states, real
       actions, and a pairing between them that is a lie.
    4. For a lasso, additionally: the cycle starts where the prefix ends, its steps are
       legal, and it **closes** — applying them returns to its own first state.
    5. A **stutter is final** (`02-dsl-semantics.md` §5.3). A one-state cycle with no
       actions claims the behaviour stays there forever, which is only so where nothing is
       enabled; a deadlock trace likewise has to end at a successor-less state. A stutter
       at a live state is refused, because `format/1` would render it as "has no
       successors" and so confirm a stutter placed in the wrong spot.

  ## A safety trace must also refute the property it names

  A legal path from an initial state is not yet a counterexample: a trace can describe a
  perfectly legal route to a state whose final step *satisfies* the property it is offered
  as a refutation of, and every check above would pass it. So a safety trace is
  additionally required to fail where it says it fails — a named invariant false in the
  final state, a named action property false over the final step. Neither needs a second
  implementation of anything: both predicates are already compiled on the spec.

  ## What it deliberately does not check

  For a **temporal** property, whether it is genuinely refuted along the behaviour, and
  whether the cycle satisfies the spec's fairness. Both are already checked, by
  `ExTLA.TemporalCheck`, which shares no code with `ExTLA.ModelChecker.Liveness` and is what
  makes that agreement evidence. A third implementation of the same semantics here would
  add a place for them to disagree and no new information — which is why the requirement
  above is scoped to safety.

  Returns `:ok`, or `{:error, message}` naming the step and what was wrong with it.
  """
  def validate(trace_or_lasso, spec, constants)

  def validate(%__MODULE__{} = trace, spec, constants) do
    spec = compiled(spec)

    with :ok <- from_init(spec, constants, trace),
         :ok <- legal_steps(spec, constants, trace, "the trace"),
         do: refutes_its_property(spec, constants, trace)
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
         :ok <- stutter_is_final(spec, constants, cycle),
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

  # There is deliberately no third clause. `states` is a list on every `%ExTLA.Trace{}` —
  # `[]` by default — so the two above are total, and the catch-all that used to sit here
  # returned `:ok` for a trace it could never be given. A clause that cannot run is a claim
  # nothing can check; if a malformed trace ever does reach here, the FunctionClauseError
  # names it, which is more than an `:ok` ever did (#317).

  # Zipped rather than indexed, so a trace whose `actions` and `states` disagree in length
  # is caught here as a shape error rather than silently checking the shorter of the two.
  # A trace naming no property claims nothing to refute — a captured behaviour, or a
  # deadlock, whose finding is the absence of successors rather than a false predicate.
  # A deadlock's finding is the absence of successors, so the trace has to end where there
  # are none: a last state with an enabled step is not a deadlock, whatever the trace says.
  defp refutes_its_property(spec, constants, %__MODULE__{type: :deadlock} = trace),
    do: no_enabled_step(spec, constants, List.last(trace.states), "the deadlock's last state")

  defp refutes_its_property(_spec, _constants, %__MODULE__{property: nil}), do: :ok

  defp refutes_its_property(_spec, _constants, %__MODULE__{type: :liveness}), do: :ok

  defp refutes_its_property(spec, constants, %__MODULE__{property: name} = trace) do
    invariant = Enum.find(spec.invariants, &(&1.name == name))
    action_property = Enum.find(spec.action_properties, &(&1.name == name))

    cond do
      invariant != nil -> refutes_invariant(invariant, constants, trace)
      action_property != nil -> refutes_action_property(action_property, constants, trace)
      # A property the spec does not DECLARE is not this function's finding to make — which
      # includes the implicit `type_ok`, derived from the `type:` annotations rather than
      # declared. Harmless: an invariant trace is built from the violating state's own id,
      # and for a claim about a state any path reaching it is a fair counterexample.
      true -> :ok
    end
  end

  defp refutes_invariant(invariant, constants, %__MODULE__{states: states, property: name}) do
    if invariant.predicate.(constants, List.last(states)) do
      {:error,
       "the trace names #{inspect(name)} as violated, but that invariant HOLDS in its " <>
         "final state. A legal path to a state is not a counterexample for a property the " <>
         "state satisfies."}
    else
      :ok
    end
  end

  defp refutes_action_property(property, constants, %__MODULE__{states: states, property: name}) do
    case Enum.take(states, -2) do
      [old_state, new_state] ->
        if property.predicate.(constants, old_state, new_state) do
          {:error,
           "the trace names #{inspect(name)} as violated, but that action property HOLDS " <>
             "over its final step. An action property is a claim about a STEP, so the " <>
             "offending step has to be the one the trace ends with (#112)."}
        else
          :ok
        end

      _ ->
        {:error,
         "the trace names the action property #{inspect(name)} as violated but has fewer " <>
           "than two states, so it contains no step for the property to be false over."}
    end
  end

  defp legal_steps(spec, constants, %__MODULE__{} = trace, what) do
    if misaligned?(trace) do
      {:error, "#{what} has #{shape(trace)}, which cannot describe one behaviour."}
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

  # A one-state cycle with no actions is a stutter, and §5.3 puts a stutter in one place: a
  # successor-less state. `validate/3` used to pass one at a live state — and `format/1` then
  # rendered it "has no successors: stutters there forever" — so a liveness pass that produced
  # a stutter in the wrong place had an oracle that agreed with it (#203).
  defp stutter_is_final(spec, constants, %__MODULE__{actions: [], states: [state | _]}),
    do: no_enabled_step(spec, constants, state, "the cycle's state")

  defp stutter_is_final(_spec, _constants, _cycle), do: :ok

  defp no_enabled_step(spec, constants, state, what) do
    case ModelChecker.enabled_steps(spec, constants, state) do
      [] ->
        :ok

      [{action, binding} | rest] ->
        others = if rest == [], do: "", else: " and #{length(rest)} more"

        {:error,
         "#{what} is claimed to stutter forever, but #{inspect(action)} with " <>
           "#{inspect(binding)}#{others} is enabled there. A behaviour stutters forever only " <>
           "at a state with no successors (02-dsl-semantics.md §5.3)."}
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

  # One behaviour: n states, n - 1 actions, one binding per action. Stated in the moduledoc
  # and checked in two places — `validate/3` reports it, and `to_diffs/1` refuses it.
  @doc """
  The behaviour-trace invariant, stated once.

      n states, n - 1 actions, one binding each, and `length` == n.

  A trace is a behaviour: states with the steps between them. Everything downstream reads
  it by zipping the three lists, so a trace that breaks this describes no behaviour at all
  — and `Enum.zip/2` does not say so, it silently stops at the shortest list.

  ## Why it is asserted where a trace is built

  Checking only where a trace is read (`from_json!/1`, `to_diffs/1`, `validate/3`) catches a
  malformed trace after it has left the code that broke it, often a few modules away and
  sometimes after it has already been rendered. So every producer in this library asserts
  it too, through `well_formed!/2`: a producer that breaks the invariant fails naming
  itself, which is where the fix goes.

  `length` is checked too, and it is the field most easily left behind: it counts STATES,
  so an edit that changes the lists and not the count produces a trace that reads as one
  shape and reports another.

  Returns `:ok` or `{:error, message}`.
  """
  def well_formed(%__MODULE__{} = trace) do
    cond do
      trace.states == [] ->
        {:error, "a trace has at least one state, and this one has none."}

      misaligned?(trace) ->
        {:error,
         "a trace with #{shape(trace)} cannot describe one behaviour: n states need " <>
           "n - 1 actions and one binding each."}

      trace.length != length(trace.states) ->
        {:error,
         "the trace says length #{trace.length} and carries #{length(trace.states)} " <>
           "states. `length` counts states (#212)."}

      true ->
        :ok
    end
  end

  def well_formed(%{prefix: prefix, cycle: nil}), do: well_formed(prefix)

  def well_formed(%{prefix: prefix, cycle: %__MODULE__{} = cycle}) do
    with :ok <- well_formed(prefix), do: well_formed(cycle)
  end

  @doc """
  `well_formed/1`, raising and naming the producer that broke it.

  `produced_by` is the function that built the trace, because the message is read by
  whoever has to fix it and "a trace with 4 states and 4 actions" does not say whose.

  Deliberately a raise rather than a returned error: a malformed trace is a bug in this
  library, not a condition a caller can handle, and the project's rule is to surface one at
  the earliest possible moment rather than to carry it to a consumer that will zip it away.
  """
  def well_formed!(trace, produced_by) do
    case well_formed(trace) do
      :ok ->
        trace

      {:error, message} ->
        raise ArgumentError, "#{produced_by} produced a malformed trace: #{message}"
    end
  end

  defp misaligned?(%__MODULE__{} = trace) do
    length(trace.actions) != length(trace.states) - 1 or
      length(trace.bindings) != length(trace.actions)
  end

  defp shape(%__MODULE__{} = trace) do
    "#{length(trace.states)} states, #{length(trace.actions)} actions and " <>
      "#{length(trace.bindings)} bindings"
  end

  @doc """
  Export a trace as a sequence of state diffs, for programmatic consumption.

  A misaligned trace — one whose actions, bindings and states cannot describe one behaviour —
  is refused with an `ArgumentError` rather than zipped. `Enum.zip/1` stops at the shortest
  list, so a trace one action short would render three states of four and mark the wrong
  one `[VIOLATION]`, never showing the state that actually violated.
  """
  def to_diffs(%__MODULE__{states: [_ | _]} = trace) do
    if misaligned?(trace) do
      raise ArgumentError,
            "a trace with #{shape(trace)} cannot describe one behaviour: n states need " <>
              "n - 1 actions and one binding each. Rendering it would drop the surplus and " <>
              "mark the wrong state."
    end

    diffs(trace)
  end

  def to_diffs(%__MODULE__{states: []}), do: []

  defp diffs(%__MODULE__{states: [first | rest]} = trace) do
    steps = Enum.zip([trace.actions, trace.bindings, rest])

    [%{action: nil, params: %{}, changed: first, state: first}] ++
      Enum.map(Enum.zip(steps, [first | rest]), fn {{action, params, state}, previous} ->
        changed =
          {previous, state}
          |> ExTLA.State.changed_vars()
          |> Map.new(&{&1, Map.fetch!(state, &1)})

        %{action: action, params: params, changed: changed, state: state}
      end)
  end

  @doc """
  Pretty-print a trace or a lasso, marking the variables each step changed.
  """
  def format(%{prefix: prefix, cycle: nil}), do: format(prefix)

  # A lasso's last printed state is its cycle head again, and the closing duplicate used to
  # be labelled `[VIOLATION]` like a safety trace's final state — pointing the reader at the
  # wrong thing (#212). A stuttering cycle has no duplicate: its one state IS the last.
  def format(%{prefix: _, cycle: %__MODULE__{}} = lasso) do
    {joined, {back_to, cycle}} = join(lasso)
    last_label = if cycle.actions == [], do: :violation, else: {:cycle_head, back_to}

    render(joined, last_label) <> loop_note(cycle, back_to)
  end

  def format(%__MODULE__{} = trace), do: render(trace, :violation)

  defp render(%__MODULE__{} = trace, last_label) do
    header = header(trace) <> message(trace)
    diffs = to_diffs(trace)
    last = length(diffs)

    body =
      diffs
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {diff, index} ->
        step(diff, index, index == last && last_label, trace)
      end)

    header <> "\n\n" <> body <> "\n" <> String.duplicate("═", 68) <> "\n"
  end

  @doc """
  Evaluate your own named expressions at every state of a counterexample, as a table.

      ExTLA.Trace.explore(trace,
        waiting: &length(&1.waiting),
        holder:  & &1.holder,
        quorum?: &(map_size(&1.votes) * 2 > 3)
      )

  `format/1` prints every variable of every state, which is the right default and is what
  nineteen states of five variables makes unreadable. The question a reader actually has —
  *when did the quorum first form*, *how many acceptors had promised by state 12* — is a
  **function of the state**, and this evaluates it at each one and prints a row.

  TLA+ answers the same question with the Toolbox's Trace Explorer, which needs a generated
  spec, a TLC re-run and a GUI panel. Here a `ExTLA.State.t()` is a plain map and an arbitrary
  expression over one is an anonymous function, so the apparatus is `Enum.map/2`.

  `expressions` is a **keyword list**, rendered in the order given: the caller's order is
  information, and sorting it would throw that away. Accepts a `lasso/0` as readily as a
  `t/0`, marking the states that repeat.

  ## Options

    * `:changed_only` — hide rows whose value is the same at every state. A wide trace is
      mostly repetition and the interesting row is the one that moved. Defaults to `false`.
    * `:width` — the column budget, defaulting to 68, the width `format/1` rules its banners
      at. States are chunked into groups that fit it, each group repeating the name column.
      This is a promise about the number of states, not about a single value: a value wider
      than the budget is printed in full, because truncating it would make the table lie.

  ## An expression that raises is reported, not swallowed

  A counterexample is being explored *because* something is wrong, so an expression that
  assumes an invariant the trace violates is the normal case rather than an error. That cell
  is marked `⚠` and the exception's message is printed under the table, naming the state and
  the expression — the rest of the table still renders.
  """
  defdelegate explore(trace_or_lasso, expressions, opts \\ []), to: ExTLA.Trace.Explore

  # ── Shared with ExTLA.Trace.Explore ───────────────────────────────────────────
  #
  # These four exist so the two renderings of a trace agree rather than drift: the same
  # lasso flattening, the same `action(binding)` shape, the same banner rule and the same
  # sentence about what happens after the last state printed. `@doc false` because they
  # are the shape of the output, not public API.

  @doc false
  def join(%__MODULE__{} = trace), do: {trace, nil}

  def join(%{prefix: prefix, cycle: nil}), do: {prefix, nil}

  def join(%{prefix: prefix, cycle: %__MODULE__{} = cycle}) do
    joined = %{
      prefix
      | states: prefix.states ++ tl(cycle.states),
        actions: prefix.actions ++ cycle.actions,
        bindings: prefix.bindings ++ cycle.bindings,
        length: prefix.length + cycle.length - 1
    }

    {joined, {length(prefix.states), cycle}}
  end

  @doc false
  # The whole point of a lasso: what happens after the last state printed. Without this
  # line the trace reads as though it ended, and "ended" is the one thing it did not do.
  def loop_note(%__MODULE__{actions: []}, back_to) do
    "\nState #{back_to} has no successors: the behaviour stutters there forever " <>
      "(02-dsl-semantics.md §5.3).\n"
  end

  def loop_note(%__MODULE__{states: states}, back_to) do
    "\n↺ back to state #{back_to} — states #{back_to}-#{back_to + length(states) - 2} " <>
      "repeat forever.\n"
  end

  # Every finding writes a `message` saying what was refuted and, for a temporal property,
  # what its author said it means — and until #176 nothing rendered it, so the whole of what
  # a reader was told was the banner's property NAME. `to_json/1` carried it out to a file
  # the whole time; the person reading the terminal was the one who could not see it.
  defp message(%__MODULE__{message: ""}), do: ""
  defp message(%__MODULE__{message: message}) when is_binary(message), do: "\n" <> message
  defp message(%__MODULE__{}), do: ""

  defp header(%{type: :deadlock}), do: banner("DEADLOCK")
  defp header(%{type: :safety, property: property}), do: banner("VIOLATION: #{property}")
  defp header(%{type: :liveness, property: property}), do: banner("LIVENESS: #{property}")

  @doc false
  def banner(title) do
    line = String.duplicate("═", max(0, 68 - String.length(title) - 5))
    "═══ " <> title <> " " <> line
  end

  defp step(diff, index, last, trace) do
    label =
      case {index, last} do
        {1, :violation} -> "State 1 (Init) [VIOLATION]:"
        {1, _} -> "State 1 (Init):"
        {_, :violation} -> "State #{index} [VIOLATION]:"
        {_, {:cycle_head, back_to}} -> "State #{index} (= state #{back_to}, the cycle head):"
        _ -> "State #{index}:"
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

  @doc false
  def call(action, params) when map_size(params) == 0, do: "#{action}"

  def call(action, params) do
    arguments =
      params
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map_join(", ", fn {name, value} -> "#{name}: #{inspect(value)}" end)

    "#{action}(#{arguments})"
  end
end
