---
id: pm-2
title: "TLC oracle: bin/tlc-expected, the die_hard corpus entry, and the verify stage"
labels: [In-Progress]
created: 2026-08-30
gitlab_issue: 2
gitlab_synced: true
---

## Problem

D-9 makes the differential corpus the **acceptance criterion for Phase 1**, not a
follow-up to it: `mix tla.check` is done when it agrees with TLC on every entry. But
the corpus was a README describing a layout, with nothing in it and no way to produce
anything. That ordering has a failure mode worth naming, because it is the one this
project is most exposed to.

If the oracle arrives after the checker, then for the whole of Phase 1 the only
available answer to "is the BFS right?" is the BFS's own output. State counts get
eyeballed once, written into a test, and become the fixture. The test then asserts
that the checker still does what it did the day it was written — which is a
regression test, not a correctness test, and it is precisely the wrong test for the
one component whose bugs are silent. A model checker that explores 15 of 16 states
reports "no violation found" in exactly the same words as one that explores all 16.

So the oracle lands first, before `TLA.State`.

## Scope

- `bin/tlc-expected` — fetch and checksum `tla2tools.jar`, run TLC over an entry,
  write `expected.json`; `--check` re-runs and fails on drift.
- `test/differential/die_hard/` — `DieHard.tla`, `DieHard.cfg`, `expected.json`.
- A `verify` stage in CI running `bin/tlc-expected --check`.
- `test/differential/README.md` brought in line with what the script emits.

Out of scope: `spec.ex` for `die_hard` (needs a DSL that does not exist yet) and the
remaining five corpus entries. The first entry proves the mechanism; the rest are
cheap once it exists, and are better added beside the checker features they exercise.

## Design notes

**One TLC run, not two.** TLC halts at the first invariant violation and then never
prints a state count, so the two things the corpus compares would come from two
different searches. `-continue` makes it report every violation *and* finish the
search. The catch is that under `-continue` TLC still prints "Model checking
completed. No error has been found." at the end, above reported violations — so
completion is read from the state-count line, and violations are parsed from the
`Error: Invariant X is violated.` reports, never from that summary.

**Shortest counterexample.** TLC's default search is breadth-first, so the first
report for a given invariant is at minimal depth; later reports for the same
invariant are other violating states at the same or greater depth and are discarded.
`-workers 1` keeps the run deterministic.

**Why `expected.json` is generated and never hand-edited.** It is the definition of
"correct" for the checker. A human who edits it to make a failing test pass has
edited the definition. The `verify` job regenerates it from TLC on every pipeline and
diffs, so that edit fails CI rather than quietly redefining the target.

**Why the jar version is pinned by SHA-256.** TLC's state counts are the fixture, so
the tool that produces them is part of the fixture. Bumping the pin is a reviewable
commit in which every `expected.json` is expected to change.

**Two fields beyond the README's three.** `diameter` (BFS depth at which the frontier
empties) catches a search that terminated early but coincidentally reached the same
state count. `deadlock` is recorded because D-16 made terminal states a declaration
rather than a flag, so "TLC found a successor-less state" is now something ExTLA must
agree about rather than something a config option suppresses.

## Why `die_hard`

The smallest spec exercising all three comparisons at once: 16 distinct states, an
invariant that holds (`TypeOK`), and one violated at a known depth (`NotSolved`, at 7
states). Its counterexample is the solution to the puzzle, so the shortest-trace
comparison is checkable by hand — a checker reporting a longer trace has not searched
breadth-first, and one reporting no trace cannot find bugs at all.

## Verification

`bin/tlc-expected die_hard` reproduces `distinct_states: 16`, `diameter: 8`,
`NotSolved` violated at 7 states — the known 6-step solution. `--check` passes on the
committed file and fails, with a diff, on a one-character edit to it. The `.cfg`
parsers were exercised against both `CONSTANTS`/`INVARIANTS` block form and
`CONSTANT`/`INVARIANT` single-line form. `.gitlab-ci.yml` passes the server's CI lint.

## Next

`TLA.State`, `TLA.Config`, `TLA.Fingerprint` — first code, now with somewhere to
check it against.
