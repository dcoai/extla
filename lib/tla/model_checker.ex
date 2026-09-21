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

  `check_liveness: true` adds Phase 2's temporal checking: the search also builds the
  liveness graph, and `TLA.ModelChecker.Liveness` looks for the fair cycle that refutes a
  temporal property. It is off by default because the graph is not free
  (`bench/liveness_graph.exs`), and because a spec that declares no `temporal` has nothing
  to gain from it.

  `symmetry: [:processes]` collapses states that differ only by a permutation of an
  interchangeable constant, and `verify_symmetry: true` checks the declaration was sound
  by running the model both ways (`TLA.Symmetry`, `08-decisions.md` D-17).

  Parallel exploration arrives in a later phase; asking for it raises rather than quietly
  checking something weaker.
  """

  alias TLA.ModelChecker.{Liveness, Parallel, Safety}
  alias TLA.Spec.Type
  alias TLA.Temporal
  alias TLA.Temporal.Fairness
  alias TLA.{Coverage, Fingerprint, Profile, Spec, State, StateGraph, Symmetry, Trace}

  @type config :: %{
          optional(:constants) => map(),

          # A budget, checked before expanding each state: the search stops once the graph
          # has PASSED the limit, so the final count exceeds it rather than stopping on it.
          # `:max_states_reached` reports the count reached, never the limit. `workers:`
          # does not change that rule — see `TLA.ModelChecker.Parallel`.
          optional(:max_states) => pos_integer(),
          # Parallel state exploration: `TLA.ModelChecker.Parallel`. Defaults to 1 —
          # `TLA.Config.workers/0` derives the machine's answer for a caller who wants it,
          # but a run does not silently become parallel because the box has cores. Refused
          # together with liveness; see `reject_unimplemented!/1`.
          optional(:workers) => pos_integer(),
          optional(:check_deadlock) => boolean(),
          optional(:check_liveness) => boolean(),

          # Build the liveness graph — the edge table and the ENABLED bits of
          # `TLA.StateGraph` — without checking anything with it. `check_liveness: true`
          # implies it; on its own it is for measuring and testing the structure.
          optional(:liveness_graph) => boolean(),
          optional(:symmetry) => [atom()] | nil,
          optional(:verify_symmetry) => boolean(),
          optional(:state_constraint) => (State.t() -> boolean()) | nil,
          optional(:fingerprint_bits) => 64 | 128,

          # Per-declaration cost in reductions (#116). Off by default and free when off: the
          # closures are wrapped only when it is asked for, so an unprofiled run calls exactly
          # the functions `TLA.Spec.Compiled` holds.
          optional(:profile) => boolean(),

          # Which of the spec's invariants to check; `:all` by default. The
          # differential corpus uses it to reproduce TLC's per-invariant reports
          # from one spec, the way a TLC `.cfg` selects INVARIANTs.
          optional(:invariants) => :all | [atom()],
          optional(:action_properties) => :all | [atom()],
          optional(:temporals) => :all | [atom()]
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

          # A safety violation is a trace to the state that breaks it. A liveness
          # violation is a lasso — a prefix and the cycle it repeats forever — because
          # what refutes a temporal property is a behaviour, not a state.
          violation: Trace.t() | Trace.lasso() | nil,

          # What the run actually exercised. A green check mark is only as good
          # as what was behind it.
          coverage: Coverage.t(),

          # What each declaration cost, in reductions (#116). `nil` when `profile:` was not
          # asked for — absent-because-not-measured is not zero, the same distinction
          # `TLA.Coverage` makes for a near-miss count.
          profile: Profile.t() | nil,
          warnings: [String.t()],
          fingerprint_bits: pos_integer(),
          collision_estimate: float()
        }

  @defaults %{
    constants: %{},
    max_states: 1_000_000,

    # §04's config type says the default is `System.schedulers_online()`, and this is 1.
    # A deliberate deviation, and not a temporary one: a search is exhaustive either way,
    # so the cores buy speed rather than a better answer — and spending every scheduler on
    # the box is a decision about the machine, which belongs to whoever is running the
    # checker rather than to the checker. `TLA.Config.workers/0` derives the machine's
    # answer for a caller who wants it; nothing derives it for one who did not ask.
    workers: 1,
    check_deadlock: true,
    check_liveness: false,
    liveness_graph: false,
    symmetry: nil,
    verify_symmetry: false,
    state_constraint: nil,
    fingerprint_bits: 64,
    profile: false,
    invariants: :all,
    action_properties: :all,
    temporals: :all
  }

  @doc """
  Run the model checker on a spec module.

      TLA.ModelChecker.run(Specs.Counter, %{constants: %{max: 3}})
  """
  def run(spec, config \\ %{}) do
    {result, _graph} = explore(spec, config)
    result
  end

  @doc """
  Run only safety checking. In Phase 1 this is what `run/2` does; the separate
  name is the one that stays correct once liveness exists.
  """
  def check_safety(spec, config \\ %{}), do: run(spec, Map.put(config, :check_liveness, false))

  @doc """
  Run the model checker and return the full state graph, for inspection.
  """
  def explore(spec, config \\ %{})

  def explore(module, config) when is_atom(module),
    do: explore(Spec.Compiled.from_module(module), config)

  def explore(%Spec.Compiled{} = spec, config) do
    config = @defaults |> Map.merge(config) |> imply_liveness_graph()
    reject_unimplemented!(config)

    if config.verify_symmetry,
      do: verify_symmetry(spec, config),
      else: search_and_finish(spec, config)
  end

  # The same model, twice: once reduced and once not. What has to survive the reduction is
  # every ANSWER, not the counts — a sound reduction changes those on purpose, which is
  # what it is for. Nothing can establish soundness statically (D-17), so this is the check
  # to run once on a small constant assignment before trusting the reduction on the large
  # one, and it costs exactly one extra unreduced run.
  defp verify_symmetry(spec, config) do
    config = %{config | verify_symmetry: false}
    {reduced, graph} = search_and_finish(spec, config)
    {full, _graph} = search_and_finish(spec, %{config | symmetry: nil})

    reduced =
      case Symmetry.verify!(reduced, full, config.symmetry) do
        :ok ->
          reduced

        # A bounded comparison cannot answer. The first version of this appended the message
        # to `warnings` and left `status: :ok` -- so `mix tla.check` printed `— verified` and
        # exited 0 with "could not be verified" as a trailing line. A run that ASKED for the
        # check came back looking verified to anything reading the exit code, which is the
        # defect this milestone exists to close, introduced by the fix for it (#170).
        #
        # The status becomes the bounded run's. That is true -- the verification ran out of
        # budget -- and it routes through the existing exit-2 handling for a bounded run, so
        # nothing downstream has to learn a new status.
        {:inconclusive, message} ->
          %{
            reduced
            | status: bounded_status(reduced, full),
              warnings: reduced.warnings ++ [message]
          }
      end

    {reduced, graph}
  end

  # Whichever run hit its bound; the reduced one is checked first because if BOTH did, its
  # own status is the more honest one to report about itself.
  defp bounded_status(%{status: status}, _full)
       when status in [:max_states_reached, :constrained],
       do: status

  defp bounded_status(_reduced, %{status: status}), do: status

  defp search_and_finish(spec, config) do
    # `type_ok` joins the invariants for the run, so it is checked, selectable
    # with `invariants:`, and counted in the coverage report alongside the
    # declared ones — which is why a report lists an invariant the spec never
    # declared.
    spec = %{spec | invariants: checked_invariants(spec, config.constants)}

    # Calibrated BEFORE the run's reduction bracket opens, because calibrating spends
    # reductions of its own and they are not part of the search (#130).
    profile = if config.profile, do: Profile.init(spec), else: nil
    searched = if profile, do: Profile.instrument(spec), else: spec

    started = System.monotonic_time(:millisecond)
    reductions_before = if profile, do: Profile.reductions(), else: 0

    # The GRAPH gets the uninstrumented spec, and the search gets the wrapped one. They were the
    # same value until #133, and that is what made the profile count work the search never did:
    # `StateGraph`'s own moduledoc says the graph carries a spec because REPLAY needs it — turning
    # a `path_to/2` back into states means applying transitions — and every consumer of
    # `graph.spec` runs after the search has stopped. Regenerating a counterexample through a
    # counter charged each of its steps to the spec a second time.
    #
    # Nothing is lost by the split. The search reads `run.spec`, never `graph.spec`, so this moves
    # no search work out of the window; it only stops replay from being counted as if it were in
    # it.
    graph =
      StateGraph.new(spec, config.constants,
        fingerprint_bits: config.fingerprint_bits,
        symmetry: symmetry_mappings(config)
      )

    run = searched |> search(config, graph, profile) |> check_temporals()

    # The workers' contributions are already summed into `run.profile` by
    # `TLA.ModelChecker.Parallel.merge/2`; this adds the COORDINATOR's own, which is the
    # seeding of the initial states and their invariant checks. One code path for both
    # cases: on a single-worker run `run.profile` is still the zeroed accumulator and every
    # count is in this process's dictionary.
    profile =
      if profile do
        run.profile
        |> Profile.merge(Profile.collect(profile))
        |> Profile.finalize(Profile.reductions() - reductions_before)
      end

    result = finish(run, System.monotonic_time(:millisecond) - started, profile)

    {result, run.graph}
  end

  @doc """
  Every invariant a run will check: the spec's own, preceded by the implicit
  `:type_ok` of `02-dsl-semantics.md` §1.5 when any variable is typed.

  `type_ok` goes first deliberately. A state outside its declared type makes
  every other invariant's verdict on that state uninteresting — the useful thing
  to report is that a variable holds something the spec says it cannot.
  """
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
    #
    # `TLA.ModelChecker.Parallel` builds one of these per worker, with the accumulators
    # zeroed, and merges what comes back — so a field added here needs a merge rule there.
    @type t :: %__MODULE__{}
    defstruct [
      :spec,
      :config,
      :graph,
      :coverage,
      :frontier,
      :found,
      :outcome,
      :invariants,
      :liveness,
      # Why the liveness pass did not run, when it did not. `nil` means it ran (or was not
      # asked for). Without this a skipped pass was indistinguishable from one that found
      # nothing, and `warnings` stayed empty either way (#167).
      :liveness_skipped,
      :profile
    ]
  end

  defp search(spec, config, graph, profile) do
    invariants = Safety.selected(spec.invariants, config.invariants)

    run = %Run{
      spec: spec,
      config: config,
      graph: graph,
      coverage: Coverage.init(spec, config.constants, invariants),
      invariants: invariants,
      frontier: :queue.new(),
      found: 0,
      outcome: :ok,
      liveness: nil,
      liveness_skipped: nil,
      profile: profile
    }

    run = seed(run)

    cond do
      run.outcome != :ok -> run
      config.workers > 1 -> Parallel.explore(run)
      true -> expand_frontier(run)
    end
  end

  @doc false
  # `TLA.ModelChecker.Parallel` expands a level by folding this over a worker's batch: the
  # states it discovers land in that worker's own `frontier`, which is the next level's
  # share. Exposed rather than duplicated — a second implementation of "what a state's
  # successors are" is the one thing a parallel checker must not have, since the two could
  # disagree and only one of them is compared against TLC.
  def expand_one(run, id, state), do: expand(run, id, state)

  defp seed(run) do
    run.spec.init
    |> Enum.with_index()
    |> Enum.reduce_while(run, fn {init_fn, index}, run ->
      state = init_fn.(run.config.constants)
      {graph, id, status} = StateGraph.add_state(run.graph, state, nil, index, nil)

      run =
        %{run | graph: graph, found: run.found + 1}
        |> note_universes(state)
        |> note_fairness_index(state)

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
  # The fairness index is a function of the constants and not of any one state —
  # §5.2 restricts a quantified param to a constant or a literal, and §7 rejects a
  # state-drawn one — so it is built once, on the first initial state. A real state
  # rather than a stand-in, for the same reason `note_universes/2` uses one.
  defp note_fairness_index(%{config: %{liveness_graph: false}} = run, _state), do: run

  defp note_fairness_index(run, state) do
    if StateGraph.liveness?(run.graph) do
      run
    else
      index = Fairness.expand(run.spec, run.config.constants, state)
      %{run | graph: StateGraph.with_liveness(run.graph, index)}
    end
  end

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

  # A state is expanded exactly once, and this is the only place it is
  # materialized with its successors in hand — so it is where the liveness graph's
  # edges and ENABLED bits have to be taken. `enabled` carries the bindings the
  # search has already computed; the bits are read off those rather than
  # re-evaluated, which is why the structure costs no extra guard evaluations.
  defp expand(run, id, state) do
    liveness? = StateGraph.liveness?(run.graph)

    run.spec.actions
    |> Enum.reduce_while({:ok, run, false, [], []}, fn action,
                                                       {:ok, run, live?, enabled, edges} ->
      bindings = enabled_bindings(action, run.config.constants, state)

      case take_action(run, action, bindings, id, state, liveness?) do
        {:ok, run, action_edges} ->
          enabled = if liveness?, do: [{action.name, bindings} | enabled], else: enabled
          {:cont, {:ok, run, live? or bindings != [], enabled, action_edges ++ edges}}

        {:violation, run, trace} ->
          {:halt, {:violation, run, trace}}
      end
    end)
    |> case do
      {:ok, run, live?, enabled, edges} ->
        run = record_liveness(run, id, Enum.reverse(edges), enabled)

        if live? do
          coverage =
            Coverage.observe_live_terminal(run.coverage, run.spec, run.config.constants, state)

          {:ok, %{run | coverage: coverage}}
        else
          {:ok, mark_stuck(run, id, state)}
        end

      {:violation, run, trace} ->
        {:violation, run, trace}
    end
  end

  defp record_liveness(run, id, edges, enabled) do
    if StateGraph.liveness?(run.graph) do
      bits = enabled_bits(run.graph.fairness_index, enabled)
      %{run | graph: StateGraph.add_edges(run.graph, id, edges, bits)}
    else
      run
    end
  end

  # One bit per fairness constraint, in `fairness_index` order: is any enabled
  # binding of its action one this constraint is about? `%{}` — whole-action
  # fairness — asks only whether the action is enabled at all, which is the
  # strictly weaker question §5.2 exists to distinguish.
  # `enabled` is a list keyed by action name rather than a map: a spec has a
  # handful of actions, and this runs once per state, so a linear scan over ten
  # entries beats building a map to throw away.
  defp enabled_bits(index, enabled) do
    Enum.reduce(index, <<>>, fn {%{action: action}, binding}, bits ->
      on = Temporal.enabled_among?(bindings_of(enabled, action), binding)
      <<bits::bitstring, if(on, do: 1, else: 0)::1>>
    end)
  end

  defp bindings_of(enabled, action) do
    case List.keyfind(enabled, action, 0) do
      {^action, bindings} -> bindings
      nil -> []
    end
  end

  defp take_action(run, _action, [], _id, _state, _liveness?), do: {:ok, run, []}

  defp take_action(run, action, bindings, id, state, liveness?) do
    # Enablement is recorded HERE, before any successor exists, and not with the counts below
    # (#128). Reaching this clause means the guard admitted at least one binding, which is what
    # "enabled" means — and it stays true even if the expansion halts on a violation. Recorded at
    # the end instead, a run lost the enablement of the very action that halted it, and then
    # warned the user that the action named in its own counterexample was never enabled.
    run = %{run | coverage: Coverage.observe_enabled(run.coverage, action.name, bindings)}

    bindings
    |> Enum.reduce_while({:ok, run, 0, 0, []}, fn params,
                                                  {:ok, run, generated, distinct, edges} ->
      next = action.transition.(run.config.constants, state, params)

      run = %{run | graph: StateGraph.count_transition(run.graph), found: run.found + 1}

      # Registering the successor comes FIRST, and the order is load-bearing rather than
      # tidying. `add_state/5` is what validates `next` (§6, once per distinct state
      # rather than once per transition — #33), and an action property must never be
      # handed a state the checker has not vetted: a forbidden term would then surface
      # from inside a user's predicate instead of from the diagnostic naming the
      # variable. It also leaves one call site where there were two, on both branches of
      # a check that has to register the successor either way — a violation still needs
      # the successor's id to point its trace at.
      {graph, next_id, status} = StateGraph.add_state(run.graph, next, id, action.name, params)
      run = %{run | graph: graph}

      case Safety.check_action_properties(
             run.spec,
             run.config.constants,
             state,
             next,
             run.config.action_properties
           ) do
        {:violation, name} ->
          {:halt, {:violation, run, action_property_trace(run, id, action.name, params, name)}}

        :ok ->
          distinct = if status == :new, do: distinct + 1, else: distinct

          # Recorded whether or not the successor is new: an edge back into a state
          # already seen is exactly the edge that closes a cycle, and a cycle is
          # what liveness checking is looking for.
          edges = if liveness?, do: [{action.name, params, next_id} | edges], else: edges

          case admit(run, next, next_id, status) do
            {:ok, run, :explore} ->
              run = %{run | frontier: :queue.in({next_id, next}, run.frontier)}
              {:cont, {:ok, run, generated + 1, distinct, edges}}

            {:ok, run, :hold} ->
              {:cont, {:ok, run, generated + 1, distinct, edges}}

            {:violation, run, trace} ->
              {:halt, {:violation, run, trace}}
          end
      end
    end)
    |> case do
      {:ok, run, generated, distinct, edges} ->
        coverage = Coverage.observe_generated(run.coverage, action.name, generated, distinct)

        {:ok, %{run | coverage: coverage}, edges}

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
  def successors(spec, %{constants: constants}, state), do: successors(spec, constants, state)

  def successors(spec, constants, state) when is_map(constants) do
    Enum.flat_map(spec.actions, fn action ->
      action
      |> enabled_bindings(constants, state)
      |> Enum.map(&{action.name, &1, action.transition.(constants, state, &1)})
    end)
  end

  @doc """
  Every `{action, binding}` a state admits — the choices available from it, without
  applying any of them.

  `successors/3` answers the same question and applies the transitions, which is what the
  search needs and what a caller choosing ONE of them does not: `TLA.Simulation.Generator`
  picks a candidate and asks the refinement for a message, and
  `TLA.PropertyTest.action_sequences/3` picks one and walks. Both had their own `for`
  comprehension over `spec.actions` and `enabled_bindings/3` before this existed, which is
  two implementations of "what may happen next" that could disagree — and only one of them
  is what the differential corpus compares against TLC.

  Actions are taken in declaration order and bindings in generator order, so the list is
  the same on every run.
  """
  def enabled_steps(spec, constants, state),
    do: steps(spec, constants, state, &enabled_bindings/3)

  @doc """
  Every `{action, binding}` in a state, guard or no guard.

  The counterpart of `bindings/3` to `enabled_steps/3`'s `enabled_bindings/3`. A simulation
  that sends only enabled messages can never find an implementation that accepts one the
  spec forbids, which is why the unfiltered form is offered rather than assumed away.
  """
  def steps(spec, constants, state), do: steps(spec, constants, state, &bindings/3)

  defp steps(spec, constants, state, bindings_fun) do
    for action <- spec.actions,
        binding <- bindings_fun.(action, constants, state),
        do: {action.name, binding}
  end

  @doc """
  Every parameter binding of an action whose guard holds in a state.

  Params bind left to right and each generator receives the bindings made before
  it, so a later param can be constrained by an earlier one. A generator that
  returns nothing disables the action here, exactly as a false guard would.
  """
  def enabled_bindings(action, constants, state) do
    action
    |> bindings(constants, state)
    |> Enum.filter(&action.guard.(constants, state, &1))
  end

  @doc """
  Every parameter binding of an action in a state, guard or no guard.
  """
  def bindings(action, constants, state) do
    Enum.reduce(action.params, [%{}], fn {name, generator}, bound ->
      for binding <- bound,
          value <- generator.(constants, state, binding),
          do: Map.put(binding, name, value)
    end)
  end

  defp mark_stuck(run, id, state) do
    admitting = Safety.admitting_terminals(run.spec, run.config.constants, state)

    graph =
      case admitting do
        [] -> StateGraph.mark_deadlocked(run.graph, id)
        _ -> StateGraph.mark_terminal(run.graph, id)
      end

    %{run | graph: graph, coverage: Coverage.observe_stuck(run.coverage, admitting)}
  end

  # Liveness runs over the finished graph, and only over a finished graph: a search cut
  # short by a violation or a bound has explored part of the state space, and a temporal
  # verdict over part of it would be a claim about behaviours nobody looked at. Nor is it
  # asked when the spec deadlocks — a deadlock is a safety failure, and answering a
  # liveness question about a spec that has one answers the wrong question.
  defp check_temporals(%{config: %{check_liveness: false}} = run), do: run

  # A search the budget stopped, or a safety counterexample halted, is not asked the liveness
  # question either -- and used to say nothing about that (#208). #167 named the deadlock skip
  # and the constraint skip and left these two silent, which mattered most for the bound:
  # `mix tla.check --allow-incomplete` turns a bounded run into exit 0, and a temporal property
  # nobody checked went unmentioned in a green result.
  defp check_temporals(%{outcome: :max_states_reached} = run),
    do: %{run | liveness_skipped: :bounded}

  defp check_temporals(%{outcome: {:violation, _}} = run),
    do: %{run | liveness_skipped: :violation}

  defp check_temporals(%{outcome: outcome} = run) when outcome != :ok, do: run

  defp check_temporals(run) do
    cond do
      # A deadlock is a safety failure and a liveness question about a deadlocking spec
      # answers the wrong one -- but the run used to say NOTHING about having skipped it,
      # so a refuted property vanished with empty warnings (#167). It is skipped and named.
      run.config.check_deadlock and MapSet.size(run.graph.deadlocked) > 0 ->
        %{run | liveness_skipped: :deadlock}

      # A `state_constraint:` holds states back without expanding them, so the graph can
      # reach the end incomplete -- and asking anyway used to raise from `complete!/1`
      # AFTER the search, discarding a safety result that was valid for what it covered.
      # Declining is the honest move: the graph describes part of the state space, and a
      # liveness verdict over it would be a claim about behaviours nobody explored.
      not Liveness.answerable?(run.graph) ->
        %{run | liveness_skipped: :incomplete_graph}

      true ->
        case Liveness.check(run.spec, run.graph, run.config.temporals) do
          :ok -> run
          {:violation, name, lasso} -> %{run | liveness: {name, lasso}}
        end
    end
  end

  defp imply_liveness_graph(%{check_liveness: true} = config),
    do: %{config | liveness_graph: true}

  defp imply_liveness_graph(config), do: config

  defp symmetry_mappings(%{symmetry: names}) when names in [nil, []], do: nil
  defp symmetry_mappings(config), do: Symmetry.mappings(config.constants, config.symmetry)

  defp constrained?(%{state_constraint: nil}, _state), do: false
  defp constrained?(%{state_constraint: constraint}, state), do: not constraint.(state)

  # ── Results ─────────────────────────────────────────────────────────────────

  defp finish(run, duration, profile) do
    graph = run.graph
    config = run.config
    deadlock? = MapSet.size(graph.deadlocked) > 0

    {safety_status, safety_violation} =
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

    # A refuted temporal property does not cut the search short — the graph was complete
    # before the question was asked — so coverage is bounded by what the SAFETY pass did.
    # A found violation is never discarded, whatever else the run also was (#167).
    # `:constrained` used to swallow a lasso the liveness pass had already produced, because
    # the status is set whenever a constraint is CONFIGURED rather than when it bound the
    # run. Bounded-ness is carried separately by `coverage.bounded_by`, so nothing is lost by
    # letting the refutation win -- and a liveness verdict only exists at all when the graph
    # was complete, which `Liveness.answerable?/1` has already established.
    {status, violation} =
      case {safety_status, run.liveness} do
        {ok_or_constrained, {_name, lasso}} when ok_or_constrained in [:ok, :constrained] ->
          {:violation, lasso}

        _ ->
          {safety_status, safety_violation}
      end

    # From the SEARCH's outcome, not from the verdict derived above (#136). `safety_status` has
    # already merged two runs this field must tell apart: one that halted mid-expansion, whose
    # counts are a floor, and one whose frontier emptied and which only then reported a stuck
    # state, whose counts are a census. Both reach `:violation` there; `run.outcome` still has
    # them separate. `check_temporals/1` does not touch it, so the existing rule that coverage is
    # bounded by what the SAFETY pass did survives unchanged.
    coverage = Coverage.finalize(run.coverage, bounded_by(run.outcome, config))

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
      profile: profile,
      warnings: warnings(run, config, safety_status) ++ Coverage.warnings(coverage),
      fingerprint_bits: config.fingerprint_bits,
      collision_estimate:
        Fingerprint.collision_estimate(graph.state_count, config.fingerprint_bits)
    }
  end

  defp bounded_by(:max_states_reached, _config), do: :max_states
  defp bounded_by({:violation, _trace}, _config), do: :violation
  defp bounded_by(_outcome, %{state_constraint: nil}), do: :none
  defp bounded_by(_outcome, _config), do: :state_constraint

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

  # Built from the PRE-state's path with the offending step appended, not from the
  # post-state's id (#112). `Trace.generate/3` walks parent pointers back from one state,
  # which is the right shape for an invariant or a deadlock — those are claims about a
  # STATE, and any path reaching it is a fair counterexample. An action property is a claim
  # about a STEP, and the step is exactly what that walk loses: when the post-state was
  # already discovered by a shorter route, the pointers describe THAT route, the offending
  # step is absent, and the step the trace marks can satisfy the property. `pre_id` is the
  # node currently being expanded, so its pointers describe the route actually taken.
  defp action_property_trace(run, pre_id, action, params, name) do
    {init_index, steps} = StateGraph.path_to(run.graph, pre_id)

    Trace.replay(run.graph, init_index, steps ++ [{action, params}],
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

  defp warnings(run, config, status) do
    []
    |> temporal_warning(run.spec, config)
    |> liveness_skipped_warning(run)
    |> constrained_warning(status)
    |> symmetry_warning(config)
  end

  # n! encodings per state, and the product across sets. It is a lever to be benchmarked
  # rather than assumed (§Symmetry), so a run says what it is paying.
  defp symmetry_warning(warnings, %{symmetry: names} = config) when names not in [nil, []] do
    count = config.constants |> Symmetry.mappings(names) |> length()

    if count > 24 do
      warnings ++
        [
          "symmetry #{inspect(names)} canonicalizes each state under #{count} permutations, " <>
            "which is paid on every state discovered. Measure it against the reduction it " <>
            "buys before keeping it."
        ]
    else
      warnings
    end
  end

  defp symmetry_warning(warnings, _config), do: warnings

  defp temporal_warning(warnings, spec, %{check_liveness: false}) when spec.temporals != [] do
    warnings ++
      [
        "#{length(spec.temporals)} temporal " <>
          "#{if length(spec.temporals) == 1, do: "property was", else: "properties were"} " <>
          "declared and not checked: pass `check_liveness: true`."
      ]
  end

  defp temporal_warning(warnings, _spec, _config), do: warnings

  # A liveness pass that was ASKED FOR and did not run says so (#167). Without this the run
  # was silent about it: a spec that deadlocks and also refutes a temporal property reported
  # the deadlock with `warnings: []`, and the same spec with `check_deadlock: false` reported
  # the refutation. The `check_liveness: false` case above already warned; these did not.
  defp liveness_skipped_warning(warnings, %{liveness_skipped: nil}), do: warnings

  # Nothing to name when nothing was declared: a spec with no temporal property was not
  # deprived of a check it never asked for.
  defp liveness_skipped_warning(warnings, %{spec: %{temporals: []}}), do: warnings

  # Counts the SELECTION, not the declaration: `temporals: [:one]` with three declared used
  # to say three were not checked (#209). `:all` is every declared one.
  defp liveness_skipped_warning(warnings, %{liveness_skipped: reason, spec: spec, config: config}) do
    count =
      case config.temporals do
        :all -> length(spec.temporals)
        names -> Enum.count(spec.temporals, &(&1.name in names))
      end

    warnings ++
      [
        "#{count} temporal #{if count == 1, do: "property was", else: "properties were"} " <>
          "not checked: #{liveness_skip_reason(reason)}"
      ]
  end

  defp liveness_skip_reason(:deadlock),
    do:
      "the spec deadlocks, and a liveness question about a spec with a safety failure " <>
        "answers the wrong question. Fix the deadlock, or re-run with " <>
        "`check_deadlock: false` to ask anyway."

  defp liveness_skip_reason(:incomplete_graph),
    do:
      "a `state_constraint:` held states back, so the graph describes part of the state " <>
        "space and a liveness verdict over it would be a claim about behaviours nobody " <>
        "explored. Re-run without the constraint to ask."

  defp liveness_skip_reason(:bounded),
    do:
      "the state budget stopped the search, so the graph describes part of the state space " <>
        "and a liveness verdict over it would be a claim about behaviours nobody explored. " <>
        "Raise `max_states` to ask."

  defp liveness_skip_reason(:violation),
    do:
      "a safety counterexample halted the search before the graph was complete. Fix the " <>
        "violation to ask."

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
    if config.verify_symmetry and config.symmetry in [nil, []] do
      raise ArgumentError,
            "verify_symmetry: true with no `symmetry:` to verify. It runs the model with " <>
              "and without a reduction, and there is no reduction here."
    end

    # A symmetry-reduced graph can hold cycles the real state space does not: the quotient
    # identifies states, so a path that leaves an orbit and a path that returns to it look
    # the same. Safety survives that and liveness does not, which is why TLC warns about
    # exactly this combination — and a warning is not what this project does with an
    # unsound answer.
    if config.symmetry not in [nil, []] and config.check_liveness do
      raise ArgumentError,
            "symmetry reduction and liveness checking are not sound together: the quotient " <>
              "graph can have cycles the real state space does not, and a cycle is what a " <>
              "liveness verdict is read off. Check safety under `symmetry:`, and liveness " <>
              "without it."
    end

    # Refused for the same reason as the pairing above, and stated the same way. The
    # liveness graph is the edge table and the ENABLED bits, and both are per-struct maps
    # on the graph — `add_edges/4` writes them into the struct a single search threads,
    # not into ETS. Under workers each process would build its own fragment and they would
    # have to be merged before any cycle spanning two of them existed to be found, which
    # is a design question of its own rather than a merge. Half-building it would produce
    # a graph missing exactly the edges a liveness verdict is read off.
    if Map.get(config, :workers, 1) > 1 and (config.check_liveness or config.liveness_graph) do
      raise ArgumentError,
            "workers: #{Map.get(config, :workers)} with liveness is refused: the edge table " <>
              "and ENABLED bits are built per-process, so a parallel run would answer a " <>
              "temporal property from a graph missing the edges another worker found — and " <>
              "a cycle spanning two workers would not exist to be found at all. Check " <>
              "safety with `workers:`, and liveness on one process."
    end

    :ok
  end
end
