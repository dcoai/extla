---
id: pm-20
title: "Close Phase 2: the behaviour-level temporal operators and StateGraph.sccs/1"
labels: [In-Progress]
created: 2026-08-31
gitlab_issue: 20
gitlab_synced: true
---

## Scope

Phase 2's deliverable shipped; three of its modules were partial against their own
specifications, and the phase ledger said otherwise. This closes the gap.

| Specified | Was |
|---|---|
| `TLA.Temporal` — 8 functions (`01-foundation.md`) | 1 built (`enabled?/4`) |
| `TLA.Temporal.Fairness` — `weak_fairness/3`, `strong_fairness/3` | neither; the rules lived privately in `ModelChecker.Liveness` |
| `TLA.StateGraph.sccs/1` (`04-layer2-model-checker.md`) | not built; Tarjan was private in `Liveness` |

`to_dot/2` and `to_json/1` are also specified on `TLA.StateGraph` and are **not** in
scope: they belong to Phase 4's `mix tla.visualize`.

## What makes them more than dead code

The obvious objection to building these now is that nothing calls them until Layer 3.
The answer is that they are an independent implementation of semantics the project
already implements once — `TLA.ModelChecker.Liveness` reasons about strongly connected
components of the state graph; these walk a list of states, and they share no code.

So the corpus checks them against each other. Every counterexample the checker hands back
is re-evaluated: the property must come back `:violated`, and the lasso's cycle must
satisfy every fairness constraint the spec declares. The second half is the assertion
that would have caught the cycle-construction bug found by eye in slice 3.

## The shape question

`01-foundation.md` typed every operator `:: boolean()`; `05-layer3-conformance.md`
requires `:holds | :violated | :inconclusive`. §05 is right and §01 is stale — a prefix
can refute `[]P` and satisfy `<>P` and can do neither the other way round. Recorded as
D-23.

## As built

**The cross-check earned its keep immediately.** `raft_election`'s counterexample comes
back `:violated` from the operators, and all three of its fairness constraints hold on the
cycle — evaluated by code that has never seen a strongly connected component. The two
implementations agree on the corpus, which is the whole argument for building the second
one now rather than when Layer 3 asks for it.

**The distinction §5.2 exists for, on one concrete cycle.** `TLA.TestSpecs.WeaklyFair`'s
counterexample is a behaviour where `weak_fairness/5` returns `:holds` and
`strong_fairness/5` returns `:violated` for the same constraint, the same cycle and the
same starving process. That is the whole of the difference between the two, made
executable: acquiring is disabled wherever the competitor holds the lock, which satisfies
WF and not SF.

**`enabled` had to become an argument.** `01-foundation.md` typed
`weak_fairness(behavior, action, vars)`. `ENABLED <A>_v` quantifies over every state `A`
could lead to, and a behaviour holds only the states that happened — so no function of the
observed steps can answer it, and the signature was not implementable as written.
`constraint_predicates/3` builds both predicates from a spec instead. Recorded in D-23
alongside the verdict change.

**`sccs/1` was pure profit.** Tarjan moved from private-in-`Liveness` to
`TLA.StateGraph.sccs/1` and `sccs/2`, which is where §State Graph specified it and where
it belongs — components are a fact about the edge table, while "can a behaviour cycle
here forever" is a further question about fairness. `Liveness` calls it and lost thirty
lines. Its order is reverse-topological and stable, which is now stated and asserted,
because a counterexample read off the first fair component must not move between runs.

**The lasso closes.** `TLA.Trace.to_behavior/1` turns a lasso into `{behavior,
lasso_start}`, dropping the cycle's repeated final state so each state is listed once. A
stuttering cycle — a `terminal` (§5.3) — comes back as the prefix with `lasso_start` on
its last state, which is exactly right: the behaviour loops on the state the spec ended
in.

**Phase 2's ledger is now true.** Every module in `06-architecture.md` §Phase 2 is built
to its specification, with two amendments recorded rather than assumed.

## Related

`01-foundation.md` §`TLA.Temporal`, `05-layer3-conformance.md`
§`check_temporal_properties/2`, `08-decisions.md` D-23.
