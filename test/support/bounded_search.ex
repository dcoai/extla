defmodule TLA.BoundedSearch do
  @moduledoc """
  A second, deliberately stupid search, so that "this counterexample is the shortest" is
  something the project checks rather than something it records (#47).

  A counterexample of *n* states is only the shortest if nothing violates at *n-1*.
  Nothing checked that: `expected.json` records TLC's length and the corpus compares it,
  so a search that stopped being breadth-first would be caught **only when the length
  happened to change** on one of six entries. D-27 makes that a live risk rather than a
  theoretical one — level-synchronous parallel BFS exists precisely to preserve length,
  and #54's `searches_depth_first` mutant is in the catalogue for this axis.

  ## What it shares, and what it must not

  It uses the spec's own guards and transitions, through
  `TLA.ModelChecker.enabled_steps/3`. That sharing is unavoidable and correct: those *are*
  the spec, and a re-search that re-derived them would be checking a different model.

  What it does not share is **the search**. No frontier queue, no fingerprints, no state
  graph, no symmetry, no parallelism, no state cap. It grows a set of states level by
  level and dedups by term equality — `MapSet` over the raw state map, not sha256 over a
  canonical encoding. A second implementation built out of the first's parts would fail
  together with it, which is the one thing this must not do.

  Being slow and obvious is the feature. It runs to a bounded depth on models the corpus
  already bounds, so it can afford it.

  ## What it costs, and what it covers

  **4.8 ms** on `die_hard`, the entry it runs on. Not an estimate: the whole reachable set
  there is 16 states, and enumerating it takes 0.07 ms.

  It covers `die_hard` **and no other corpus entry**, because `die_hard` is the only one
  with a violated invariant — the rest have none, so there is no counterexample whose
  length could be wrong. That is a fact about the corpus rather than a budget this
  declined to spend, and it is worth saying plainly: a check that silently applies to one
  of six entries reads like a check that applies to six.

  A liveness counterexample is deliberately out of scope. A lasso is not
  breadth-first-shortest the way a safety trace is — `test/differential/README.md` says
  why — so "nothing shorter violates" is not a claim about it that means anything.

  ## Why it removes a dependency rather than adding a check

  Shortest-ness currently rests on `expected.json` — on TLC having said 7. This makes it
  checkable from the spec alone, which is what lets it be trusted on a spec TLC has never
  seen.
  """

  alias TLA.{ModelChecker, Spec}

  @doc """
  Every state reachable in at most `steps` steps.

  Dedup is `MapSet` membership on the state term itself. That is exactly what the real
  search cannot afford — it is why `TLA.Fingerprint` exists (D-5) — and exactly what makes
  this independent of it.
  """
  @spec reachable_within(Spec.Compiled.t(), map(), non_neg_integer()) :: MapSet.t(TLA.State.t())
  def reachable_within(spec, constants, steps) do
    initial = Enum.map(spec.init, & &1.(constants))
    grow(spec, constants, MapSet.new(initial), initial, steps)
  end

  defp grow(_spec, _constants, seen, _frontier, 0), do: seen
  defp grow(_spec, _constants, seen, [], _steps), do: seen

  defp grow(spec, constants, seen, frontier, steps) do
    next =
      for state <- frontier,
          {action, binding} <- ModelChecker.enabled_steps(spec, constants, state),
          post = Spec.Compiled.action(spec, action).transition.(constants, state, binding),
          not MapSet.member?(seen, post),
          uniq: true,
          do: post

    grow(spec, constants, MapSet.union(seen, MapSet.new(next)), next, steps - 1)
  end

  @doc """
  Is `predicate` true of every state reachable in a behaviour of fewer than `length`
  states?

  `length` is a counterexample's length in **states**, as `TLA.Trace` counts it — so a
  behaviour of `length` states takes `length - 1` steps, and "shorter than that" means
  `length - 2` steps.

  Returns `true` when nothing shorter violates, which is what makes the counterexample
  shortest.
  """
  @spec nothing_violates_before?(
          Spec.Compiled.t(),
          map(),
          (TLA.State.t() -> boolean()),
          pos_integer()
        ) :: boolean()
  def nothing_violates_before?(spec, constants, predicate, length) when length >= 1 do
    steps = length - 2

    # A counterexample one state long is refuted by an initial state; there is nothing
    # shorter than that, so it is shortest by construction rather than by search.
    if steps < 0 do
      true
    else
      spec
      |> reachable_within(constants, steps)
      |> Enum.all?(predicate)
    end
  end
end
