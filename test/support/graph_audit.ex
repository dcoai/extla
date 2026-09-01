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
