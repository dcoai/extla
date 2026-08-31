---
id: pm-17
title: "Phase 2, slice 2: the liveness graph — an edge table and ENABLED bits, opt-in"
labels: [In-Progress]
created: 2026-08-31
gitlab_issue: 17
gitlab_synced: true
---

## Scope

The structure liveness checking runs over, and nothing that runs over it yet.

`spec/04-layer2-model-checker.md` §State Graph: when it is asked for, the checker also
records, per state,

    state_id => [{action, params, successor_id}]     # every out-edge
    state_id => enabled_bits                         # one bit per fairness constraint

plus the `fairness_index` those bits are indexed by — `spec/02-dsl-semantics.md` §5.2's
expansion of `acquire_lock: [:p]` into one constraint per element of `^processes`.

**The parent-pointer graph cannot support liveness.** It is a spanning tree: every node
has one in-edge, it is acyclic by construction, and an SCC search over it would find only
trivial components and report every property as holding. That is why this is a separate,
opt-in structure (D-5 as amended), and why `successors/2` already raises rather than
derive anything from parent pointers. This slice is what stops it raising.

**Fairness needs ENABLED per state, and states are discarded.** The bits have to be
recorded while the state is materialized. That is the same split TLC makes: safety on
fingerprints alone, liveness on a second graph paid for only when asked for.

## What it takes

1. `TLA.Temporal.enabled?/4` — ENABLED for an action, optionally restricted to one
   binding of its leading params. It has to come from the same binding-and-guard code
   the edges come from, or a bit could disagree with the edge beside it.
2. `TLA.Temporal.Fairness.expand/3` — the §5.2 expansion into
   `[{fairness_def, binding}]`, once the constants are known. §7 already guarantees the
   quantified params are a leading prefix and are not state-drawn.
3. `TLA.StateGraph.add_edges/4`, and the `edges` / `enabled` / `fairness_index` fields
   filled in rather than `nil`.
4. `TLA.ModelChecker` records both while a state is expanded, where the enabled bindings
   are already computed — so the bits cost no extra guard evaluations.

## The option

`check_liveness: true` **still raises**. A run that returns `:ok` having been asked to
check liveness and having checked none would be exactly the silent-unsoundness the
project exists to avoid, and slice 3 is what makes the answer real.

The graph is built by `liveness_graph: true`, which claims only what it does. Slice 3
makes `check_liveness: true` imply it.

## Measurement

The slice touches the hot path, so `raft_election` (58,359 states) is measured with the
option off and on. Off must be unchanged; on is the price of the structure, and it is
recorded here rather than assumed.

## Acceptance

- `successors/2` returns the real out-edges, and the edge table contains a cycle that the
  parent-pointer tree does not — the failure this design already caught once.
- Every state's recorded edges equal `TLA.ModelChecker.successors/3` recomputed for that
  state, over a corpus entry.
- Every recorded bit equals `TLA.Temporal.enabled?/4` recomputed for that constraint.
- `distributed_lock` expands to six constraints: SF for each of two processes, WF for
  each of two, twice over. `raft_election` expands to three whole-action constraints.
- `check_liveness: true` still raises; the safety numbers are unchanged with the option
  off, and the corpus still agrees with TLC.

## As built

**The measurement, which is why the slice was separate.** `bench/liveness_graph.exs`
reproduces it.

| Entry | States | Edges | Time | Heap |
|---|---|---|---|---|
| `raft_election` | 58,359 | 255,270 | 22.6s → 26.0s (+15%) | 24MB → 75MB |
| `bounded_buffer` | 4,460 | 15,776 | 0.31s → 0.35s (+11%) | 1MB → 5MB |

Safety-only is unchanged; the search takes the same path and does the same work.

**§State Graph's "roughly 16 bytes per edge" was wrong, by a factor of thirteen.** The
measured figure is 206 bytes per edge on `raft_election` and 270 on `bounded_buffer`. The
estimate was the cost of `{action, successor_id}` and forgot the binding — and a binding
is a map, holding a whole message record where the param is a message, which is exactly
what `handle_request_vote` binds. The spec now carries the measured number and the reason
the estimate missed. The property D-5 exists for survives: the cost is a function of the
branching factor and of how large a *binding* is, and still not of how large a *state*
is.

**The bits cost no guard evaluations.** The search already computes the enabled bindings
of every action while it expands a state — they are what it turns into edges — so the
bits are read off those rather than re-derived. `TLA.Temporal.enabled?/4` exists for
recomputing one from a state, which is what the tests check the recorded bits against;
the checker uses `enabled_among?/2` on what it has. The bindings are carried as an assoc
list keyed by action rather than a map: a spec has a handful of actions, this runs once
per state, and a linear scan over ten entries beats building a map to throw away — worth
1.5 points of the 15%.

**`check_liveness: true` still raises**, and the graph is built by `liveness_graph: true`.
A run that returned `:ok` having been asked to check liveness and having checked none is
the failure this project is organised around not shipping, and the option that means "I
checked liveness" should start meaning it on the day it is true. `liveness_graph: true`
claims only what it does. Slice 3 makes `check_liveness: true` imply it.

**A partial graph is not checkable, and that is now written down.** Only an expanded
state has edges, so a run stopped by `max_states`, held back by a state constraint, or
halted by a safety violation leaves a partial edge table. Slice 3 has to refuse one:
a liveness verdict read off it would be a claim about behaviours that were never
explored. Noted in `TLA.StateGraph` and in §State Graph.

## Related

`04-layer2-model-checker.md` §State Graph, `01-foundation.md` §`TLA.Temporal`,
`02-dsl-semantics.md` §5.2 and §5.3, `08-decisions.md` D-5 (as amended).
