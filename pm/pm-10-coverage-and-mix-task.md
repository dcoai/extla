---
id: pm-10
title: "TLA.Coverage, mix tla.check, TLA.Spec.Test — Phase 1 complete"
labels: [In-Progress]
created: 2026-08-30
gitlab_issue: 10
gitlab_synced: true
---

## Scope

The last three pieces of Phase 1: `TLA.Coverage`, `Mix.Tasks.Tla.Check` and
`TLA.Spec.Test`. With them the Phase 1 deliverable is met —

> `mix tla.check MySpec` verifies safety, reports what it actually exercised, and
> agrees with TLC on every spec in the corpus.

## Coverage is collected during the run, not computed after it

`04-layer2-model-checker.md` says coverage is "computed from the completed state graph;
no additional exploration". The second half is right and the first is not: the graph
deliberately retains neither states nor per-action counts (D-5), so there is nothing in
it to compute these from. The numbers are accumulated while the search runs — which
costs no additional exploration, the intent of the sentence, and is the only way to
have them at all.

## What it reports, and one thing it does not

`never_enabled` and vacuity are the load-bearing findings, and both are cheap.

**Vacuity applies only to a leads-to.** `always(P)` holding in every reachable state is
the property doing its job, not a vacuity, and flagging it would train people to ignore
the report — which is the one thing a coverage report cannot survive. A `P ~> Q` is
vacuous in two ways: `P` never held anywhere, so the implication was never triggered;
or `Q` held everywhere, so it was satisfied without reference to `P`.

Vacuity does not need the liveness graph, only the reachable states, so it is reported
in Phase 1 where the property itself is not yet checked. That is the more important
half: an unchecked property that would have been vacuous is doubly worth knowing about.

**`near_misses` is `nil` where it was not measured, never 0.** Only the top-level-`or`
shape is derived — the compiler can see which disjunct carried the invariant. §04's
other case, "some atomic bound held with equality at its edge", is not derived, and
reporting 0 for it would be a false alarm: zero near misses is a *finding*, and "we did
not look" is not.

`bounded_by` gains a `:violation` value. A run that stopped at a counterexample stopped
mid-expansion, so its counts are a lower bound for exactly the same reason a bounded
run's are; leaving it out would let a partial census read as a complete one.

## The gap in `mix tla.check`

The task was specified in full — flags, output formats, exit codes — without saying
**where a run's constants come from**. A checker cannot start without them.

They now come, in order of precedence, from application config
(`config :extla, Specs.X, constants: %{…}`) or from `constant :accounts, default: …`
beside the declaration. A constant with neither is an error naming both places. The
`default:` form is the one that needs no second file, and `TLA.ModelChecker.run/2`
ignores it entirely, so a test that passes its own constants is unaffected by what the
task would have used.

## Exit codes are the point of the task

`0` verified, `1` violation, `2` incomplete, `3` coverage failure under
`--strict-coverage`. Exit code 2 exists because "we ran out of budget" is not "it
holds", and a tool that returns them as the same number teaches its users to believe
something false. `TLA.Spec.Test.assert_spec/2` takes the same line: a bounded run
**flunks**, and `allow_incomplete: true` is how you accept one deliberately.

## Verification

293 tests. The mix-task tests run the real task and catch its exit, because the exit
code *is* the verdict — asserting against an inner function that returns a status would
test something else. Each exit code has a test, including the two that are easy to get
wrong: a bounded run exits 2 rather than 0, and `--strict-coverage` turns a warning
into exit 3 while the same spec without it exits 0.

## Phase 1 is done

Everything in `spec/06-architecture.md` §Phase 1 exists. The remaining corpus entries
— two-phase commit, distributed lock, Raft election, bounded buffer, Paxos — are the
next thing worth doing: each is a new way for the checker to be wrong, and the
mechanism for catching that is already running in CI.

## Next

Either the rest of the corpus, or Phase 2 (liveness). The corpus first: it costs less
and it tests what already exists, and D-9 makes it the acceptance criterion rather than
a follow-up.
