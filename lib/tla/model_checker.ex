defmodule TLA.ModelChecker do
  @moduledoc """
  Exhaustive state-space model checker for `TLA.Spec` modules. Analogous to TLC
  for TLA+.

  Phase 1 is the single-threaded, breadth-first safety checker
  (`spec/06-architecture.md` §Phase 1). Breadth-first is not an implementation
  detail: an invariant is evaluated when a state is first discovered, so the
  first violation found is at minimal distance from `init` and the trace is the
  shortest counterexample. A depth-first search would report *a* counterexample,
  which is a much less useful thing to hand someone.

  Liveness (`check_liveness: true`), parallel exploration, symmetry reduction and
  the `type_ok` invariant arrive in later phases; asking for one raises rather
  than quietly checking something weaker.
  """

  alias TLA.ModelChecker.Safety
  alias TLA.Spec.Type
  alias TLA.{Fingerprint, Spec, State, StateGraph, Trace}

  @type config :: %{
          optional(:constants) => map(),
          optional(:max_states) => pos_integer(),
          optional(:workers) => pos_integer(),
          optional(:check_deadlock) => boolean(),
          optional(:check_liveness) => boolean(),
          optional(:symmetry) => [atom()] | nil,
          optional(:verify_symmetry) => boolean(),
          optional(:state_constraint) => (State.t() -> boolean()) | nil,
          optional(:fingerprint_bits) => 64 | 128,

          # Which of the spec's invariants to check; `:all` by default. The
          # differential corpus uses it to reproduce TLC's per-invariant reports
          # from one spec, the way a TLC `.cfg` selects INVARIANTs.
          optional(:invariants) => :all | [atom()]
        }

  @type result :: %{
          status: :ok | :violation | :max_states_reached | :constrained | :deadlock,
          states_found: non_neg_integer(),
          distinct_states: non_neg_integer(),
          transitions: non_neg_integer(),

          # The BFS level at which the frontier empties — the number of states on
          # the longest shortest-path from an initial state. TLC reports it as
          # "the depth of the complete state graph search", and it catches a
          # search that stopped early but happened to reach the same state count.
          diameter: non_neg_integer(),
          deadlock: boolean(),
          duration_ms: non_neg_integer(),
          violation: Trace.t() | nil,
          warnings: [String.t()],
          fingerprint_bits: pos_integer(),
          collision_estimate: float()
        }

  @defaults %{
    constants: %{},
    max_states: 1_000_000,
    check_deadlock: true,
    check_liveness: false,
    symmetry: nil,
    verify_symmetry: false,
    state_constraint: nil,
    fingerprint_bits: 64,
    invariants: :all
  }

  @doc """
  Run the model checker on a spec module.

      TLA.ModelChecker.run(Specs.Counter, %{constants: %{max: 3}})
  """
  @spec run(module() | Spec.Compiled.t(), config()) :: result()
  def run(spec, config \\ %{}) do
    {result, _graph} = explore(spec, config)
    result
  end

  @doc """
  Run only safety checking. In Phase 1 this is what `run/2` does; the separate
  name is the one that stays correct once liveness exists.
  """
  @spec check_safety(module() | Spec.Compiled.t(), config()) :: result()
  def check_safety(spec, config \\ %{}), do: run(spec, Map.put(config, :check_liveness, false))

  @doc """
  Run the model checker and return the full state graph, for inspection.
  """
  @spec explore(module() | Spec.Compiled.t(), config()) :: {result(), StateGraph.t()}
  def explore(spec, config \\ %{})

  def explore(module, config) when is_atom(module),
    do: explore(Spec.Compiled.from_module(module), config)

  def explore(%Spec.Compiled{} = spec, config) do
    config = Map.merge(@defaults, config)
    reject_unimplemented!(config)

    declared = spec
    spec = %{spec | invariants: checked_invariants(spec, config.constants)}

    started = System.monotonic_time(:millisecond)
    graph = StateGraph.new(spec, config.constants, fingerprint_bits: config.fingerprint_bits)

    {graph, outcome, states_found} = search(spec, config, graph)

    result =
      finish(
        declared,
        config,
        graph,
        outcome,
        states_found,
        System.monotonic_time(:millisecond) - started
      )

    {result, graph}
  end

  @doc """
  Every invariant a run will check: the spec's own, preceded by the implicit
  `:type_ok` of `02-dsl-semantics.md` §1.5 when any variable is typed.

  `type_ok` goes first deliberately. A state outside its declared type makes
  every other invariant's verdict on that state uninteresting — the useful thing
  to report is that a variable holds something the spec says it cannot.
  """
  @spec checked_invariants(module() | Spec.Compiled.t(), map()) :: [Spec.Compiled.invariant_def()]
  def checked_invariants(module, constants) when is_atom(module),
    do: module |> Spec.Compiled.from_module() |> checked_invariants(constants)

  def checked_invariants(%Spec.Compiled{} = spec, constants) do
    case Type.invariant(spec, constants) do
      nil -> spec.invariants
      type_ok -> [type_ok | spec.invariants]
    end
  end

  # ── The search ──────────────────────────────────────────────────────────────

  defp search(spec, config, graph) do
    {graph, frontier, outcome, found} = seed(spec, config, graph)

    case outcome do
      :ok -> expand_frontier(spec, config, graph, :queue.from_list(frontier), found)
      _ -> {graph, outcome, found}
    end
  end

  defp seed(spec, config, graph) do
    spec.init
    |> Enum.with_index()
    |> Enum.reduce_while({graph, [], :ok, 0}, fn {init_fn, index}, {graph, frontier, _, found} ->
      state = config.constants |> init_fn.() |> State.validate!()
      {graph, id, status} = StateGraph.add_state(graph, state, nil, index, nil)
      found = found + 1

      case admit(spec, config, graph, state, id, status) do
        {:ok, graph, :explore} -> {:cont, {graph, frontier ++ [{id, state}], :ok, found}}
        {:ok, graph, :hold} -> {:cont, {graph, frontier, :ok, found}}
        {:violation, graph, trace} -> {:halt, {graph, {:violation, trace}, found}}
      end
    end)
    |> case do
      {graph, frontier, :ok, found} -> {graph, frontier, :ok, found}
      {graph, outcome, found} -> {graph, [], outcome, found}
    end
  end

  # A newly discovered state is checked, then either queued for expansion or
  # held back by the state constraint. A state already seen is neither.
  defp admit(_spec, _config, graph, _state, _id, :existing), do: {:ok, graph, :hold}

  defp admit(spec, config, graph, state, id, :new) do
    case Safety.check_invariants(spec, config.constants, state, config.invariants) do
      {:violation, name} ->
        {:violation, graph, invariant_trace(graph, id, name, spec, config.constants, state)}

      :ok ->
        if constrained?(config, state), do: {:ok, graph, :hold}, else: {:ok, graph, :explore}
    end
  end

  defp expand_frontier(spec, config, graph, frontier, found) do
    case :queue.out(frontier) do
      {:empty, _} ->
        {graph, :ok, found}

      {{:value, {id, state}}, rest} ->
        if graph.state_count > config.max_states do
          {graph, :max_states_reached, found}
        else
          case expand(spec, config, graph, id, state, rest, found) do
            {:ok, graph, frontier, found} ->
              expand_frontier(spec, config, graph, frontier, found)

            {:violation, graph, trace, found} ->
              {graph, {:violation, trace}, found}
          end
        end
    end
  end

  defp expand(spec, config, graph, id, state, frontier, found) do
    successors = successors(spec, config, state)

    if successors == [] do
      {:ok, mark_stuck(spec, config, graph, id, state), frontier, found}
    else
      Enum.reduce_while(successors, {:ok, graph, frontier, found}, fn
        {action, params, next}, {:ok, graph, frontier, found} ->
          next = State.validate!(next)
          graph = StateGraph.count_transition(graph)
          found = found + 1

          case Safety.check_action_properties(spec, config.constants, state, next) do
            {:violation, name} ->
              {graph, next_id, _} = StateGraph.add_state(graph, next, id, action, params)

              {:halt,
               {:violation, graph, action_property_trace(graph, next_id, name, state, next),
                found}}

            :ok ->
              {graph, next_id, status} = StateGraph.add_state(graph, next, id, action, params)

              case admit(spec, config, graph, next, next_id, status) do
                {:ok, graph, :explore} ->
                  {:cont, {:ok, graph, :queue.in({next_id, next}, frontier), found}}

                {:ok, graph, :hold} ->
                  {:cont, {:ok, graph, frontier, found}}

                {:violation, graph, trace} ->
                  {:halt, {:violation, graph, trace, found}}
              end
          end
      end)
    end
  end

  @doc """
  Every successor of a state: one per action, per binding of that action's
  params, whose guard holds.

  Nondeterminism comes from `params:` and only from `params:`
  (`02-dsl-semantics.md` §3), so this is the whole of it. Actions are taken in
  declaration order and bindings in generator order, which makes the search
  deterministic — a checker whose state graph varied between runs could not be
  compared to TLC.
  """
  @spec successors(Spec.Compiled.t(), config(), State.t()) :: [{atom(), map(), State.t()}]
  def successors(spec, config, state) do
    Enum.flat_map(spec.actions, fn action ->
      action
      |> bindings(config.constants, state)
      |> Enum.filter(&action.guard.(config.constants, state, &1))
      |> Enum.map(&{action.name, &1, action.transition.(config.constants, state, &1)})
    end)
  end

  @doc """
  Every parameter binding of an action in a state.

  Params bind left to right and each generator receives the bindings made before
  it, so a later param can be constrained by an earlier one. A generator that
  returns nothing disables the action here, exactly as a false guard would.
  """
  @spec bindings(Spec.Compiled.action_def(), map(), State.t()) :: [map()]
  def bindings(action, constants, state) do
    Enum.reduce(action.params, [%{}], fn {name, generator}, bound ->
      for binding <- bound,
          value <- generator.(constants, state, binding),
          do: Map.put(binding, name, value)
    end)
  end

  defp mark_stuck(spec, config, graph, id, state) do
    case Safety.classify_stuck(spec, config.constants, state) do
      :terminal -> StateGraph.mark_terminal(graph, id)
      :deadlocked -> StateGraph.mark_deadlocked(graph, id)
    end
  end

  defp constrained?(%{state_constraint: nil}, _state), do: false
  defp constrained?(%{state_constraint: constraint}, state), do: not constraint.(state)

  # ── Results ─────────────────────────────────────────────────────────────────

  defp finish(spec, config, graph, outcome, states_found, duration) do
    deadlock? = MapSet.size(graph.deadlocked) > 0

    {status, violation} =
      case outcome do
        {:violation, trace} ->
          {:violation, trace}

        :max_states_reached ->
          {:max_states_reached, nil}

        :ok ->
          cond do
            config.check_deadlock and deadlock? ->
              {:violation, deadlock_trace(graph)}

            config.state_constraint != nil ->
              {:constrained, nil}

            true ->
              {:ok, nil}
          end
      end

    %{
      status: status,
      states_found: states_found,
      distinct_states: graph.state_count,
      transitions: graph.transition_count,
      diameter: graph.diameter,
      deadlock: deadlock?,
      duration_ms: duration,
      violation: violation,
      warnings: warnings(spec, config, status),
      fingerprint_bits: config.fingerprint_bits,
      collision_estimate:
        Fingerprint.collision_estimate(graph.state_count, config.fingerprint_bits)
    }
  end

  defp invariant_trace(graph, id, name, spec, constants, state) do
    Trace.generate(graph, id,
      type: :safety,
      property: name,
      message: describe_violation(spec, constants, name, state)
    )
  end

  # A type_ok trace says which variable, holding what, against what it declared.
  # "invariant :type_ok does not hold" would leave the reader to diff the state
  # against the declarations by eye.
  defp describe_violation(spec, constants, :type_ok, state),
    do: "type_ok: " <> Type.explain(spec, constants, state)

  defp describe_violation(_spec, _constants, name, _state),
    do: "invariant #{inspect(name)} does not hold in this state"

  defp action_property_trace(graph, id, name, _old, _new) do
    Trace.generate(graph, id,
      type: :safety,
      property: name,
      message: "action property #{inspect(name)} does not hold over the last step"
    )
  end

  defp deadlock_trace(graph) do
    id = graph.deadlocked |> Enum.sort() |> hd()

    Trace.generate(graph, id,
      type: :deadlock,
      property: nil,
      message:
        "this state has no successors and no `terminal` predicate admits it. If it is a " <>
          "legitimate end state, declare it: `terminal :name do … end` " <>
          "(02-dsl-semantics.md §5.3)."
    )
  end

  defp warnings(spec, config, status) do
    []
    |> temporal_warning(spec, config)
    |> constrained_warning(status)
  end

  defp temporal_warning(warnings, spec, %{check_liveness: false}) when spec.temporals != [] do
    warnings ++
      [
        "#{length(spec.temporals)} temporal " <>
          "#{if length(spec.temporals) == 1, do: "property was", else: "properties were"} " <>
          "declared and not checked: liveness arrives in Phase 2."
      ]
  end

  defp temporal_warning(warnings, _spec, _config), do: warnings

  defp constrained_warning(warnings, :constrained) do
    warnings ++
      [
        "a state constraint bounded this run, so it is not an exhaustive search and the " <>
          "state counts are a lower bound."
      ]
  end

  defp constrained_warning(warnings, _status), do: warnings

  # ── Phase boundaries ────────────────────────────────────────────────────────

  defp reject_unimplemented!(config) do
    if config.check_liveness do
      raise ArgumentError,
            "check_liveness: true is not implemented yet. Liveness needs the edge table and " <>
              "the per-state ENABLED bits of the liveness graph, which arrive in Phase 2 " <>
              "(spec/06-architecture.md). Reporting temporal properties as holding without " <>
              "them would be the silent-unsoundness this project exists to avoid."
    end

    if config.symmetry not in [nil, []] or config.verify_symmetry do
      raise ArgumentError,
            "symmetry reduction is not implemented yet; it arrives in Phase 2 " <>
              "(spec/06-architecture.md)."
    end

    :ok
  end
end
