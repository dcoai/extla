---
id: pm-18
title: "Phase 2, slice 3: Tarjan, the §5.1 fragment, and lasso counterexamples"
labels: [In-Progress]
created: 2026-08-31
gitlab_issue: 18
gitlab_synced: true
---

## Scope

`TLA.ModelChecker.Liveness`, and `check_liveness: true` meaning it.

A liveness property is refuted by an infinite behaviour, and an infinite behaviour in a
finite graph is a lasso: a finite prefix, then a cycle repeated forever. The states a
behaviour visits infinitely often are a strongly connected set, so the search is for a
strongly connected component the property forbids cycling in and the fairness constraints
permit cycling in.

## What it takes

1. **SCCs over the edge table** — Tarjan, restricted to a subgraph, with a stuck state as
   a self-loop (§5.3: stuttering there forever is a legal behaviour).
2. **The fairness rules** on a component: WF(A) broken when A is enabled in *every* state
   and taken by no edge inside; SF(A) broken when it is enabled in *some* state and taken
   by no edge inside. A broken WF kills every strongly connected subset too; a broken SF
   does not, so the component is split on the states where the constraint is enabled and
   searched again. That split is the whole of the Emerson–Lei shape, and the reason this
   is not "Tarjan, then filter".
3. **The §5.1 fragment**, six shapes, each a question about components. A nesting outside
   them raises rather than being approximated.
4. **Lassos in `TLA.Trace`** — a prefix and a cycle, printed as one numbered trace with a
   line saying what happens after the last state.
5. **The corpus comparison**: ExTLA's verdict against TLC's, per property.

## What "done" looks like

The corpus, not "the tests pass":

| Entry | Property | Expected |
|---|---|---|
| `distributed_lock` | `no_starvation` | holds, and only under per-binding SF |
| `distributed_lock` | `lock_eventually_released` | holds |
| `bounded_buffer` | its four temporal properties | hold |
| `raft_election` | `eventually_elect_leader` | **violated** |

That last row is the one that matters. A liveness checker that reports everything as
holding agrees with every other row.

## As built

**Slice 4 is absorbed.** The plan kept per-binding fairness back as a slice of its own,
but slice 2 already expanded `acquire_lock: [:p]` into one constraint per process with
its own ENABLED bit, so the WF/SF rules here read those constraints without knowing
whether they came from a per-binding declaration or a whole-action one. There was nothing
left to build. What slice 4 was really for — the demonstration that it *matters* — is
here instead, twice: `distributed_lock`'s `no_starvation` holds against TLC, and
`TLA.TestSpecs.WeaklyFair` is the same spec with acquiring only weakly fair, refuted with
p1 waiting while p2 takes the lock and gives it back forever. What remains of Phase 2 is
slice 5, symmetry.

**Verdicts, all seven agreeing with TLC.**

| Entry | Property | TLC | ExTLA |
|---|---|---|---|
| `distributed_lock` | `no_starvation`, `lock_eventually_released` | holds | holds |
| `bounded_buffer` | all four | holds | holds |
| `raft_election` | `eventually_elect_leader` | violated | violated |

`raft_election`'s counterexample is a seven-state prefix ending in the split vote at
`max_term`, which stutters there forever — the same shape TLC prints, whose behaviour
ends `State 8: Stuttering`.

**Two bugs in the cycle construction, both found by looking at the output.** The first
printed "State 1 has no successors" for a state that plainly had two: the closed walk was
empty when nothing forced it anywhere, and the fallback only looked for a self-edge. The
second was worse and would not have been caught by a verdict test: a constraint satisfied
by a state where it is *disabled* was recorded as needing no target, so the walk could go
round without ever visiting that state — printing a cycle the spec's own fairness
forbids, as a counterexample. A counterexample that the assumptions rule out is not one.

**What it costs.** `raft_election` is 27s all in, against 26s for the graph alone: the
Tarjan pass and the state materialization are about a second on 58,359 states and 255,270
edges. Predicates are evaluated in one pass over the graph, in id order, holding only the
states that still have children to regenerate — the same bound the search itself keeps.

**`always(pred)` skips the component search.** Every reachable state has a fair
continuation, because a walk to a bottom component is always available and a bottom
component is always fair: nothing leaves it, so every action enabled inside it has its
edge inside it. So an `always` is refuted by a state, and its lasso has no cycle.

**`mix tla.check` checks liveness whenever the spec declares a `temporal`,** and
`--safety-only` — which existed and did nothing — now turns it off.

## Related

`04-layer2-model-checker.md` §`TLA.ModelChecker.Liveness`, `02-dsl-semantics.md` §5.1,
§5.2 and §5.3, `08-decisions.md` D-5 (as amended).
