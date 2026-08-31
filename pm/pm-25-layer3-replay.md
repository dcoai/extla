---
id: pm-25
title: "Phase 3, slice 5: TLA.Replay — a counterexample run against the code, and a captured trace checked offline"
labels: [In-Progress]
created: 2026-08-31
gitlab_issue: 25
gitlab_synced: true
---

## Scope

`05-layer3-conformance.md` §`TLA.Replay`: `counterexample/3` and `trace/3`, and the
reporting forms of each `TLA.GenServer.Runtime` check that a replay is built from.

Not in scope, and next: `TLA.Simulation`, `TLA.Simulation.Generator`, `mix tla.simulate`
and `mix tla.replay`.

## The loop this closes

`BuggySpec` is the corpus counter with a design bug written into it: `increment` runs up
to `max_val` while the invariant says the count never exceeds two. Nothing about the
implementation is wrong — the specification contradicts itself. `mix tla.check` finds it
before any code exists, `Impl.FaithfulToABuggySpec` refines it exactly, and
`Replay.counterexample/3` runs that exact trace against the running server, which
reproduces the bug at the step the trace reaches `count: 3`.

A spec whose invariant no behaviour violates cannot produce a counterexample. That is why
the entry exists rather than being simulated with a hand-written trace: the trace under
test is the model checker's own output.

## `:not_followed` is a third outcome, and not a conformance failure

Four ways a replay stops without the implementation being wrong:

| Case | Reported |
|---|---|
| the server has no clause for the message | "permits a behaviour the implementation does not take" |
| the server stopped, or did not answer | the exit reason, or the timeout |
| the step was legal and landed somewhere else | both abstract states, side by side |
| the mapping defines no `concrete_message/2` | said by name, not an undefined function |

Each says the spec permits a behaviour the code does not take. Collapsing that into
`:violation` would report the code as wrong when the specification may be, and which of
the two is wrong is not something the checker can decide.

The third case is the one worth building for. An implementation may take a *legal* step
that is not the step the counterexample took — where an action is nondeterministic,
`concrete_message/2` cannot always name the binding the trace chose — and a replay that
only asked "was each step legal" would call that a reproduction. So the trace's own states
are the oracle beside the wrapper's checks.

## Reporting forms, because a report cannot be built by catching

`check_transition/5`, `check_step/5`, `check_stuttering/3`, `check_spec_invariants/2` and
`check_action_properties/3` now return `:ok | {:violation, Violation.t()}`, and the `!`
forms raise what they return.

A replay says *which step* failed and goes on being a value. The wrapper needs the raise;
the report needs the value; neither is derived from the other by rescuing one. Driving a
live server is the same shape from the other side: the violation raises inside the server
and arrives at the replay as a monitored `:DOWN`, so it is a message rather than something
caught.

## A bug the test ordering found

`function_exported?/3` answers about a **loaded** module, and reports every optional
callback of a cold one as absent. The first draft checked `concrete_message/2` that way,
so a perfectly drivable refinement reported itself undrivable depending on what had
happened to run before it — green on one seed, red on the next. `Code.ensure_loaded?/1`
first. Worth recording because the same trap is one `TLA.Refinement.validate!/3` avoids by
loading first, and it is invisible in any test run that touches the module earlier.

## Acceptance

- 12 new tests: the model checker's own counterexample reproduced in a running server,
  the four `:not_followed` cases, six captured-trace cases including Example 4's bug at
  the step that has it, and a lasso replayed as prefix plus one pass of its cycle.
- 525 tests green, `mix format --check-formatted`, `--warnings-as-errors`, and
  `bin/tlc-expected --check` clean.
