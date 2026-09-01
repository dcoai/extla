defmodule TLA.GraphAudit do
  @moduledoc """
  Re-evaluate what the search recorded, against what the spec admits (#48).

  Two of the search's records are **self-consistent when wrong** — the wrong answer looks
  exactly like the right one, and no assertion anywhere fails:

    * **Terminal and deadlocked states** come from successor generation returning nothing.
      Nothing re-checks that the state genuinely has no enabled action, so a defect that
      drops an action makes states terminal *and* removes everything beyond them. The
      graph that results is smaller, internally consistent, and matches no failing
      assertion.
    * **The edge table.** The same defect at full size. #54's sweep found that
      `drops_a_liveness_edge` is caught by **no gate at all**: dropping one out-edge per
      state leaves every temporal verdict in the corpus matching `expected.json`, because
      a missing edge makes some cycle unfindable and an unfindable cycle looks exactly
      like a property that holds.

  One check covers both. Every state's recorded out-edges are exactly the successors the
  spec admits from it; a stuck state is the degenerate case where that set is empty.

  ## Compared by identity, not by count

  `{action, binding, successor}`, as a set. A table with the right *number* of wrong edges
  is precisely what a merge or an ordering defect produces, and a count would agree with it.

  ## One walk, not one replay per state

  The graph retains no states (D-5), so an audit that asked `StateGraph.state_at/2` for
  each id would pay a replay per state — on `raft_election` that is 58,359 walks of depth
  19, and it cost 20 seconds of the corpus suite when written that way. Walking forward
  from the initial states instead produces each state once, in the course of computing the
  successors the audit needs anyway, and costs about what one search costs.

  It is still test-only, and deliberately not on `add_state/5`'s path: D-26 moved the §6
  term check there because it was 77.9% of the `raft` search and D-27 bought 5.40x on top,
  and spending that back on always-on redundancy would undo Phase 4.

  ## What the three audits cost

  `mix test` went from **64 s to 81 s** as they were added — about 17 s for three redundant
  computations over six corpus entries, one of which is 58,359 states. The bulk of it is
  `reachable/2`, an independent walk of the whole state space, which is why the partition
  and the injectivity check share one call rather than making two.

  Recorded rather than estimated, and worth stating plainly: it is a 27% suite for a check
  that closed a survivor no other gate could see.
  """

  alias TLA.{ModelChecker, Spec, StateGraph}

  @doc """
  Audit a completed graph: recorded out-edges against admitted successors, and stuck
  states against enabledness.

  Only states the search actually **expanded** are checked for edges — the keys of the
  edge table. A state held back by a `state_constraint`, or discovered past `max_states`,
  has no recorded edges because it was never expanded, and reading that as a missing edge
  would manufacture a finding out of a bound the run already reports.

  Requires the edge table; without it there is nothing to audit, and `successors/2` raises
  rather than answering from parent pointers.
  """
  @spec audit(Spec.Compiled.t(), map(), StateGraph.t()) :: :ok | {:error, String.t()}
  def audit(spec, constants, graph) do
    unless StateGraph.liveness?(graph) do
      raise ArgumentError,
            "TLA.GraphAudit.audit/3 needs the edge table. Build the graph with " <>
              "`liveness_graph: true`; parent pointers are a spanning tree and there is " <>
              "nothing in them to audit."
    end

    initial = Enum.map(spec.init, & &1.(constants))
    walk(spec, constants, graph, initial, MapSet.new(initial))
  end

  @doc """
  Every invariant partitions the reachable states into the ones it holds in and the ones
  it does not — and into nothing else.

  ## Why this is not the tautology it looks like

  `|states ⊨ I| + |states ⊨ ¬I| == distinct_states` is trivially true if `¬` is Elixir's
  `not`, and ExTLA does not retain an invariant's AST, so there is no way to compile a
  *negated* invariant and evaluate it independently. Written that way the check could not
  fail, and a check that cannot fail is worse than none.

  What makes the partition real is the **third bucket**. `TLA.ModelChecker.Safety` reads a
  predicate's result with `if` (`safety.ex:28`), so it is truthiness rather than a boolean
  that decides a verdict:

    * a predicate returning `nil` — a `Map.get/2` that missed, say — reports a
      **violation** that the spec never expressed;
    * a predicate returning `:maybe`, `0` or `""` reports **holds**, because every one of
      those is truthy.

  Both are silent, and both are the shape #48 is about: the wrong answer and the right one
  are the same word. So this counts `true` and `false` separately and requires them to sum
  to the whole — anything that is neither lands in neither count and the sum falls short.

  It also catches a predicate that **raises** on a reachable state, which today surfaces
  from inside the search rather than as a finding about the invariant.
  """
  @spec invariant_partition(map(), [map()], MapSet.t(TLA.State.t())) :: :ok | {:error, String.t()}
  def invariant_partition(constants, invariants, states) do
    total = MapSet.size(states)

    Enum.reduce_while(invariants, :ok, fn invariant, :ok ->
      case partition(invariant, constants, states) do
        {holds, fails, []} when holds + fails == total ->
          {:cont, :ok}

        {holds, fails, odd} ->
          {:halt,
           {:error,
            "invariant #{inspect(invariant.name)} does not partition the #{total} " <>
              "reachable states: #{holds} hold, #{fails} do not, and #{length(odd)} " <>
              "returned neither `true` nor `false`.\n\n" <>
              Enum.map_join(Enum.take(odd, 3), "\n\n", fn {state, value} ->
                "  #{inspect(state)}\n  -> #{inspect(value)}"
              end) <>
              "\n\n`Safety.check_invariants/4` reads this with `if`, so a truthy " <>
              "non-boolean reports `holds` and `nil` reports a violation the spec never " <>
              "expressed. Either way the verdict is decided by something other than the " <>
              "invariant."}}
      end
    end)
  end

  defp partition(invariant, constants, states) do
    Enum.reduce(states, {0, 0, []}, fn state, {holds, fails, odd} ->
      case invariant.predicate.(constants, state) do
        true -> {holds + 1, fails, odd}
        false -> {holds, fails + 1, odd}
        other -> {holds, fails, [{state, other} | odd]}
      end
    end)
  end

  @doc """
  No two distinct reachable states share a fingerprint.

  A run reports `collision_estimate` — a *probability*, from the birthday bound. Two
  distinct states sharing a fingerprint silently removes a subtree from the search and
  lowers `distinct_states`, and nothing says so: the run reports a smaller number with
  exactly the same confidence. This turns that probability into an observation.

  ## Why it changes nothing in the search

  #48 asks for a test-only mode that retains states beside their fingerprints, and warns
  that the default path must not pay for it — D-26 moved the §6 term check onto
  `add_state/5`'s miss branch because it was 77.9% of the `raft` search, and D-27 bought
  5.40x on top.

  There is no mode, and no flag, because none is needed. The states come from
  `TLA.BoundedSearch`, which finds them without the checker's help, and the fingerprint is
  observed through `StateGraph.id_of/2`: **two distinct states that collide are handed the
  same id.** So the check is made entirely from outside, `lib/` is untouched, and "the
  default path is unchanged" is a fact about the diff rather than a benchmark result.

  ## Not applicable under symmetry

  Under a symmetry reduction two distinct states sharing an id is the *point* — an orbit
  is meant to collapse (§Symmetry). The claim only means something without one, so this
  refuses rather than reporting the reduction as a defect.
  """
  @spec fingerprint_injectivity(StateGraph.t(), MapSet.t(TLA.State.t())) ::
          :ok | {:error, String.t()}
  def fingerprint_injectivity(graph, states) do
    if graph.symmetry not in [nil, []] do
      raise ArgumentError,
            "fingerprint injectivity is not a property of a symmetry-reduced graph: an " <>
              "orbit collapsing to one id is what `symmetry:` is for. Audit a run without it."
    end

    states
    |> Enum.group_by(&StateGraph.id_of(graph, &1))
    |> Enum.find(fn {_id, sharing} -> length(sharing) > 1 end)
    |> case do
      nil ->
        :ok

      {id, sharing} ->
        {:error,
         "#{length(sharing)} distinct reachable states share id #{id}, so their " <>
           "fingerprints collided:\n\n" <>
           Enum.map_join(Enum.take(sharing, 3), "\n", &"  #{inspect(&1)}") <>
           "\n\nA collision removes a subtree from the search and lowers " <>
           "`distinct_states`. Nothing reports it: the run hands back a smaller number " <>
           "with the same confidence, and `collision_estimate` says only how likely that " <>
           "was, never whether it happened."}
    end
  end

  @doc """
  Every reachable state, found without the checker's help. See `TLA.BoundedSearch`.
  """
  @spec reachable(Spec.Compiled.t(), map()) :: MapSet.t(TLA.State.t())
  def reachable(spec, constants) do
    TLA.BoundedSearch.reachable_within(spec, constants, :infinity)
  end

  defp walk(_spec, _constants, _graph, [], _seen), do: :ok

  defp walk(spec, constants, graph, [state | rest], seen) do
    steps = ModelChecker.enabled_steps(spec, constants, state)

    successors =
      Enum.map(steps, fn {action, binding} ->
        {action, binding,
         Spec.Compiled.action(spec, action).transition.(constants, state, binding)}
      end)

    case check(graph, state, steps, successors) do
      :ok ->
        fresh =
          successors
          |> Enum.map(fn {_, _, post} -> post end)
          |> Enum.reject(&MapSet.member?(seen, &1))
          |> Enum.uniq()

        walk(spec, constants, graph, rest ++ fresh, MapSet.union(seen, MapSet.new(fresh)))

      error ->
        error
    end
  end

  defp check(graph, state, steps, successors) do
    id = StateGraph.id_of(graph, state)

    cond do
      id == nil ->
        {:error,
         "the spec reaches a state the graph never registered:\n\n  #{inspect(state)}\n\n" <>
           "The search missed it, which is the one defect no other gate here can see."}

      steps == [] ->
        stuck?(graph, id, state)

      Map.has_key?(graph.edges, id) ->
        compare(graph, id, state, successors)

      true ->
        # Discovered and never expanded: held back by a state constraint, or past the cap.
        # The run reports that; it is not this audit's finding to make.
        :ok
    end
  end

  defp stuck?(graph, id, state) do
    if MapSet.member?(graph.terminal, id) or MapSet.member?(graph.deadlocked, id) do
      :ok
    else
      {:error,
       "state #{id} has no enabled action, but the search did not record it as terminal " <>
         "or deadlocked:\n\n  #{inspect(state)}"}
    end
  end

  defp compare(graph, id, state, successors) do
    admitted =
      MapSet.new(successors, fn {action, binding, post} ->
        {action, binding, StateGraph.id_of(graph, post)}
      end)

    recorded = MapSet.new(StateGraph.successors(graph, id))

    if MapSet.equal?(admitted, recorded) do
      stuck_not_claimed(graph, id, state)
    else
      {:error, difference(id, state, admitted, recorded)}
    end
  end

  # The converse of `stuck?/3`: a state with successors must NOT be recorded as
  # deadlocked. A `terminal` may have them — `02-dsl-semantics.md` §5.3 lets a predicate
  # admit a live state, and the coverage report calls that `terminal_but_live` — so only
  # the deadlock claim is contradicted here.
  defp stuck_not_claimed(graph, id, state) do
    if MapSet.member?(graph.deadlocked, id) do
      {:error,
       "state #{id} is recorded as deadlocked, but the spec enables actions in it:\n\n" <>
         "  #{inspect(state)}"}
    else
      :ok
    end
  end

  defp difference(id, state, admitted, recorded) do
    missing = MapSet.difference(admitted, recorded)
    extra = MapSet.difference(recorded, admitted)

    "state #{id}'s recorded out-edges are not the successors the spec admits.\n\n  " <>
      inspect(state) <>
      "\n\n" <>
      section("recorded but not admitted", extra) <>
      section("admitted but not recorded", missing) <>
      "\nAn edge the table is missing makes some cycle unfindable, and an unfindable " <>
      "cycle is indistinguishable from a property that holds."
  end

  defp section(label, set) do
    if MapSet.size(set) == 0 do
      ""
    else
      "  #{label} (#{MapSet.size(set)}): " <>
        inspect(Enum.sort(MapSet.to_list(set)), limit: 5) <> "\n"
    end
  end
end
