---
id: pm-19
title: "Phase 2, slice 5: symmetry reduction, and the check that a declaration deserved it"
labels: [In-Progress]
created: 2026-08-31
gitlab_issue: 19
gitlab_synced: true
---

## Scope

`symmetry:` and `verify_symmetry:`, the last of Phase 2.

`symmetry: [:processes]` says the elements of `^processes` are interchangeable. States
that differ only by a permutation of them are one state, so the reachable space shrinks
by up to *n*!. The mechanism is canonical form: before a state is fingerprinted it is
rewritten under every permutation and the smallest encoding wins, so two symmetric states
share a fingerprint by construction.

## What it assumes, and who checks it

Nothing verifies that a declaration is sound, and `08-decisions.md` D-17 is the decision
not to pretend otherwise — a constant flows into arbitrary Elixir, so the check is
undecidable, and any conservative approximation rejects the `Enum.all?(^processes, …)`
every real spec is built from.

`verify_symmetry: true` makes a wrong declaration *detectable*: the same model, run with
and without the reduction, failing if any **verdict** differs. Not the counts — a sound
reduction changes those on purpose.

## Measurement

The reduction is a lever to be benchmarked, not assumed: *n*! encodings per state against
up to *n*! fewer states. `bench/symmetry.exs` is where that gets a number.

## Acceptance

- A reduced run reaches the same verdict as an unreduced one on a spec that deserves it,
  over fewer states, and every state it keeps is one the unreduced run also found.
- An unsound declaration is caught by `verify_symmetry: true`, with a message that says
  what differed.
- `mix tla.check --verify-symmetry`, with `symmetry:` declared beside the constants.
- Symmetry and liveness together are refused rather than warned about.

## As built

**The numbers, and the spec's estimate was pessimistic.** §Symmetry predicted "a wash in
wall-clock at best" at two or three elements. `raft_election` at three servers is 3.5x
faster, because canonicalizing costs *n*! *encodings* and each state avoided costs a
whole successor generation.

| Model | Permutations per state | States | Time |
|---|---|---|---|
| `raft_election`, 3 servers | 6 | 58,359 → 9,871 | 23.3s → 6.6s |
| `distributed_lock`, 3 procs, 2 resources | 12 | 184 → 26 | 11ms → 6ms |
| `distributed_lock`, 2 procs, 2 resources | 4 | 34 → 12 | 1ms → 1ms |

`verify_symmetry: true` confirms both of the larger declarations are sound.

**Symmetry and liveness are refused together, recorded as D-22.** The quotient graph
identifies states, so a path that leaves an orbit and one that returns to it look the
same, and the quotient can hold cycles the real state space does not — which is exactly
what a liveness verdict is read off. TLC warns about the same combination and runs
anyway; a warning is not what this project does with an unsound answer. `mix tla.check`
under a `symmetry:` declaration checks safety and says in its warnings why the temporal
properties were left alone.

**No corpus entry declares a `SYMMETRY`,** and that is the same decision from the TLC
side: three entries could, but TLC's symmetry sets and its `PROPERTIES` are not sound
together either, so an entry that declared one would give up the temporal verdicts slice
1 exists to record. The reduction is measured on those models instead, by
`bench/symmetry.exs`, rather than left as a claim.

**The reduction keeps a real state, not a normalized one.** Canonical form decides
identity; the state the graph files is the first of its orbit to be *discovered*. So
parent pointers, edges and traces are all about a state the spec can actually reach, and
a counterexample replays to a genuine behaviour. The test for it compares the reduced
run's states against the unreduced run's and asserts a strict subset.

**Making the unsound fixture deterministic took two goes.** `TLA.TestSpecs.Asymmetric`
has an invariant naming one process, so collapsing the two hides the state that breaks
it — but *which* state survives is whichever was discovered first, and drawing the param
from a `MapSet` left that to the set's iteration order. It draws from a literal list
instead. It also needed a `terminal`: without one both runs stop on the deadlock and
report a violation, for different reasons, and the fixture stops being about symmetry.

## Related

`04-layer2-model-checker.md` §Symmetry, `08-decisions.md` D-17.
