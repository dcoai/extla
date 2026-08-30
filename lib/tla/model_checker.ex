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
  alias TLA.{Coverage, Fingerprint, Spec, State, StateGraph, Trace}

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
          optional(:invariants) => :all | [atom()],
          optional(:action_properties) => :all | [atom()]
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

          # What the run actually exercised. A green check mark is only as good
          # as what was behind it.
          coverage: Coverage.t(),
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
    invariants: :all,
    action_properties: :all
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

    # `type_ok` joins the invariants for the run, so it is checked, selectable
    # with `invariants:`, and counted in the coverage report alongside the
    # declared ones — which is why a report lists an invariant the spec never
    # declared.
    spec = %{spec | invariants: checked_invariants(spec, config.constants)}

    started = System.monotonic_time(:millisecond)
    graph = StateGraph.new(spec, config.constants, fingerprint_bits: config.fingerprint_bits)

    run = search(spec, config, graph)

    result = finish(run, System.monotonic_time(:millisecond) - started)

    {result, run.graph}
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

  defmodule Run do
    @moduledoc false
    # Everything the search threads through itself. A struct rather than a
    # widening tuple, because coverage made it a five-tuple and the next phase
    # adds the liveness graph.
    defstruct [:spec, :config, :graph, :coverage, :frontier, :found, :outcome, :invariants]
  end

  defp search(spec, config, graph) do
    invariants = Safety.selected(spec.invariants, config.invariants)

    run = %Run{
      spec: spec,
      config: config,
      graph: graph,
      coverage: Coverage.init(spec, config.constants, invariants),
      invariants: invariants,
      frontier: :queue.new(),
      found: 0,
      outcome: :ok
    }

    run = seed(run)
    if run.outcome == :ok, do: expand_frontier(run), else: run
  end

  defp seed(run) do
    run.spec.init
    |> Enum.with_index()
    |> Enum.reduce_while(run, fn {init_fn, index}, run ->
      state = run.config.constants |> init_fn.() |> State.validate!()
      {graph, id, status} = StateGraph.add_state(run.graph, state, nil, index, nil)
      run = %{run | graph: graph, found: run.found + 1} |> note_universes(state)

      case admit(run, state, id, status) do
        {:ok, run, :explore} -> {:cont, %{run | frontier: :queue.in({id, state}, run.frontier)}}
        {:ok, run, :hold} -> {:cont, run}
        {:violation, run, trace} -> {:halt, %{run | outcome: {:violation, trace}}}
      end
    end)
  end

  # The universe of parameter combinations is a property of the constants, not of
  # any one state, so it is enumerated once — on the first initial state, which
  # is a real state rather than a stand-in.
  defp note_universes(run, state) do
    if Enum.any?(Map.values(run.coverage.param_universe), &(&1 == :unknown)) do
      coverage =
        Enum.reduce(run.spec.actions, run.coverage, fn action, coverage ->
          Coverage.observe_universe(coverage, action, run.config.constants, state)
        end)

      %{run | coverage: coverage}
    else
      run
    end
  end

  # A newly discovered state is checked, then either queued for expansion or held
  # back by the state constraint. A state already seen is neither: its invariants
  # were evaluated when it was first found.
  defp admit(run, _state, _id, :existing), do: {:ok, run, :hold}

  defp admit(run, state, id, :new) do
    coverage = Coverage.observe_state(run.coverage, run.invariants, run.config.constants, state)
    run = %{run | coverage: coverage}

    case Safety.check_invariants(run.spec, run.config.constants, state, run.config.invariants) do
      {:violation, name} ->
        {:violation, run, invariant_trace(run, id, name, state)}

      :ok ->
        if constrained?(run.config, state), do: {:ok, run, :hold}, else: {:ok, run, :explore}
    end
  end

  defp expand_frontier(run) do
    case :queue.out(run.frontier) do
      {:empty, _} ->
        run

      {{:value, {id, state}}, rest} ->
        run = %{run | frontier: rest}

        if run.graph.state_count > run.config.max_states do
          %{run | outcome: :max_states_reached}
        else
          case expand(run, id, state) do
            {:ok, run} -> expand_frontier(run)
            {:violation, run, trace} -> %{run | outcome: {:violation, trace}}
          end
        end
    end
  end

  defp expand(run, id, state) do
    run.spec.actions
    |> Enum.reduce_while({:ok, run, false}, fn action, {:ok, run, live?} ->
      bindings = enabled_bindings(action, run.config.constants, state)

      case take_action(run, action, bindings, id, state) do
        {:ok, run} -> {:cont, {:ok, run, live? or bindings != []}}
        {:violation, run, trace} -> {:halt, {:violation, run, trace}}
      end
    end)
    |> case do
      {:ok, run, false} ->
        {:ok, mark_stuck(run, id, state)}

      {:ok, run, true} ->
        coverage =
          Coverage.observe_live_terminal(run.coverage, run.spec, run.config.constants, state)

        {:ok, %{run | coverage: coverage}}

      {:violation, run, trace} ->
        {:violation, run, trace}
    end
  end

  defp take_action(run, _action, [], _id, _state), do: {:ok, run}

  defp take_action(run, action, bindings, id, state) do
    bindings
    |> Enum.reduce_while({:ok, run, 0, 0}, fn params, {:ok, run, generated, distinct} ->
      next =
        run.config.constants
        |> action.transition.(state, params)
        |> State.validate!()

      run = %{run | graph: StateGraph.count_transition(run.graph), found: run.found + 1}

      case Safety.check_action_properties(
             run.spec,
             run.config.constants,
             state,
             next,
             run.config.action_properties
           ) do
        {:violation, name} ->
          {graph, next_id, _} = StateGraph.add_state(run.graph, next, id, action.name, params)
          run = %{run | graph: graph}
          {:halt, {:violation, run, action_property_trace(run, next_id, name)}}

        :ok ->
          {graph, next_id, status} =
            StateGraph.add_state(run.graph, next, id, action.name, params)

          run = %{run | graph: graph}
          distinct = if status == :new, do: distinct + 1, else: distinct

          case admit(run, next, next_id, status) do
            {:ok, run, :explore} ->
              run = %{run | frontier: :queue.in({next_id, next}, run.frontier)}
              {:cont, {:ok, run, generated + 1, distinct}}

            {:ok, run, :hold} ->
              {:cont, {:ok, run, generated + 1, distinct}}

            {:violation, run, trace} ->
              {:halt, {:violation, run, trace}}
          end
      end
    end)
    |> case do
      {:ok, run, generated, distinct} ->
        coverage =
          Coverage.observe_action(run.coverage, action.name, bindings, generated, distinct)

        {:ok, %{run | coverage: coverage}}

      {:violation, run, trace} ->
        {:violation, run, trace}
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
  @spec successors(Spec.Compiled.t(), map(), State.t()) :: [{atom(), map(), State.t()}]
  def successors(spec, %{constants: constants}, state), do: successors(spec, constants, state)

  def successors(spec, constants, state) when is_map(constants) do
    Enum.flat_map(spec.actions, fn action ->
      action
      |> enabled_bindings(constants, state)
      |> Enum.map(&{action.name, &1, action.transition.(constants, state, &1)})
    end)
  end

  @doc """
  Every parameter binding of an action whose guard holds in a state.

  Params bind left to right and each generator receives the bindings made before
  it, so a later param can be constrained by an earlier one. A generator that
  returns nothing disables the action here, exactly as a false guard would.
  """
  @spec enabled_bindings(Spec.Compiled.action_def(), map(), State.t()) :: [map()]
  def enabled_bindings(action, constants, state) do
    action
    |> bindings(constants, state)
    |> Enum.filter(&action.guard.(constants, state, &1))
  end

  @doc """
  Every parameter binding of an action in a state, guard or no guard.
  """
  @spec bindings(Spec.Compiled.action_def(), map(), State.t()) :: [map()]
  def bindings(action, constants, state) do
    Enum.reduce(action.params, [%{}], fn {name, generator}, bound ->
      for binding <- bound,
          value <- generator.(constants, state, binding),
          do: Map.put(binding, name, value)
    end)
  end

  defp mark_stuck(run, id, state) do
    graph =
      case Safety.classify_stuck(run.spec, run.config.constants, state) do
        :terminal -> StateGraph.mark_terminal(run.graph, id)
        :deadlocked -> StateGraph.mark_deadlocked(run.graph, id)
      end

    %{run | graph: graph}
  end

  defp constrained?(%{state_constraint: nil}, _state), do: false
  defp constrained?(%{state_constraint: constraint}, state), do: not constraint.(state)

  # ── Results ─────────────────────────────────────────────────────────────────

  defp finish(run, duration) do
    graph = run.graph
    config = run.config
    deadlock? = MapSet.size(graph.deadlocked) > 0

    {status, violation} =
      case run.outcome do
        {:violation, trace} ->
          {:violation, trace}

        :max_states_reached ->
          {:max_states_reached, nil}

        :ok ->
          cond do
            config.check_deadlock and deadlock? -> {:violation, deadlock_trace(run)}
            config.state_constraint != nil -> {:constrained, nil}
            true -> {:ok, nil}
          end
      end

    coverage = Coverage.finalize(run.coverage, bounded_by(status, config))

    %{
      status: status,
      states_found: run.found,
      distinct_states: graph.state_count,
      transitions: graph.transition_count,
      diameter: graph.diameter,
      deadlock: deadlock?,
      duration_ms: duration,
      violation: violation,
      coverage: coverage,
      warnings: warnings(run.spec, config, status) ++ Coverage.warnings(coverage),
      fingerprint_bits: config.fingerprint_bits,
      collision_estimate:
        Fingerprint.collision_estimate(graph.state_count, config.fingerprint_bits)
    }
  end

  defp bounded_by(:max_states_reached, _config), do: :max_states
  defp bounded_by(:violation, _config), do: :violation
  defp bounded_by(_status, %{state_constraint: nil}), do: :none
  defp bounded_by(_status, _config), do: :state_constraint

  defp invariant_trace(run, id, name, state) do
    Trace.generate(run.graph, id,
      type: :safety,
      property: name,
      message: describe_violation(run.spec, run.config.constants, name, state)
    )
  end

  # A type_ok trace says which variable, holding what, against what it declared.
  # "invariant :type_ok does not hold" would leave the reader to diff the state
  # against the declarations by eye.
  defp describe_violation(spec, constants, :type_ok, state),
    do: "type_ok: " <> Type.explain(spec, constants, state)

  defp describe_violation(_spec, _constants, name, _state),
    do: "invariant #{inspect(name)} does not hold in this state"

  defp action_property_trace(run, id, name) do
    Trace.generate(run.graph, id,
      type: :safety,
      property: name,
      message: "action property #{inspect(name)} does not hold over the last step"
    )
  end

  defp deadlock_trace(run) do
    id = run.graph.deadlocked |> Enum.sort() |> hd()

    Trace.generate(run.graph, id,
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
