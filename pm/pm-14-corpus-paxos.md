---
id: pm-14
title: "Corpus: paxos — the sixth entry, and the D-9 acceptance gate met"
labels: [In-Progress]
created: 2026-08-31
gitlab_issue: 14
gitlab_synced: true
---

## Scope

The last differential entry. With it, D-9's acceptance criterion for Phase 1 is met:
ExTLA agrees with TLC on all six corpus specs.

| Entry | Distinct states | Depth | What it adds |
|---|---|---|---|
| `paxos` | 3,921 | 17 | A guard that quantifies over a **subset** of the messages in flight |

Agrees with TLC exactly on the first run, on every field the corpus compares.

Model: 3 acceptors, 2 values, ballots `0..1`, quorums the three pairs and the full set.
Ballots `0..2` is 185,369 states and 20 seconds of TLC; the extra ballot buys another
level of the same shape, and `b = 1` already exercises the case the algorithm exists
for — a proposer at ballot 1 that must propose the value accepted at ballot 0 rather
than its own.

## Why this entry is different from the other five

Every other entry's guard tests a field of one message. `phase_2a`'s asks whether *some
set* of promises covering *some quorum* reports either no acceptance at all or a highest
acceptance whose value is the one being proposed. Enabling it means searching a powerset
of a state-dependent set, and an enabling check that is subtly too permissive proposes
values Paxos would not — which shows up nowhere except in the state count, since
`consistency` still holds in the models where the mistake is small.

It is also the entry where the DSL's "one mechanism for nondeterminism" rule earns
itself. The quorum and the promise set do not appear in the post-state, so they are not
`params:` — they belong inside a `require`, as the pure boolean the TLA+ `\E Q : \E S`
is. A DSL that made every existential a param would have generated thousands of
successors per state, all identical.

## Two gaps it found, both fixed here

**A range type could not have a negative bound.** `-1` is unary minus applied to `1` in
the Elixir AST, not an integer literal, so §1.5's `check_bound!` rejected
`type: [^acceptors ~> -1..^max_ballot]`. Paxos's `maxBal` is `-1` until the acceptor
promises something; a grammar that cannot say so cannot type the spec it is given.
Fixed in `TLA.Spec.Type` for both validation and resolution, with a test.

**A `let` read by only one of the two compiled functions warned in the other.** An
action block compiles to a guard and a transition, and both got every `let`. A binding
the guard reads and the assignments do not — `let promises = …` before a `require` — was
therefore an unused variable in the transition, and the author cannot silence it by
underscoring the name, because the other function does read it. Since a block is pure
(§3), a binding nothing reads is dead code: each function now keeps the bindings it
reads and drops the rest. The transition also stops recomputing work the guard already
did.

Both are the same pattern the corpus has produced at every entry: the design was settled
at the level of syntax, and the level below is where it gave way.

## Phase 1 is done

Not "the tests pass" — D-9's criterion, measured against TLC:

| Entry | Distinct states | Depth |
|---|---|---|
| `die_hard` | 16 | 8 |
| `two_phase_commit` | 288 | 11 |
| `distributed_lock` | 34 | 7 |
| `raft_election` | 58,359 | 19 |
| `bounded_buffer` | 4,460 | 29 |
| `paxos` | 3,921 | 17 |

Each entry was chosen for a different way the checker could be wrong, and the six
together cover: the shortest counterexample, a state count too large to eyeball, a
product of param sets, a tuple in state, params drawn from the pre-state, an end state
that is not a deadlock, a sequence where order distinguishes states, and a guard over a
subset of the network.

Not built, and raising rather than pretending: liveness, symmetry, parallel exploration,
Layers 1 and 3.

## Next

Phase 2 (liveness: the edge table, per-state ENABLED bits, Tarjan, per-binding fairness,
symmetry) or the open proposals — `[[pm-7-access-outside-domain]]`, which could change
spec semantics and is therefore cheaper to decide early, and
`[[pm-11-element-typed-collections]]`, which four of the six entries now want:
`msgs`, `messages`, `votes_granted` and `buffer` are all typed weaker here than in the
TLA+ they are checked against.

## Related

`[[pm-13-corpus-raft-and-buffer]]`, `[[pm-12-corpus-two-more-entries]]`,
`[[pm-2-tlc-oracle]]`, `08-decisions.md` D-9.
