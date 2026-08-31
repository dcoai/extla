---
id: pm-26
title: "Phase 3, slice 6: TLA.Simulation, the message generator, and mix tla.simulate"
labels: [In-Progress]
created: 2026-08-31
gitlab_issue: 26
gitlab_synced: true
---

## Scope

`05-layer3-conformance.md` §`TLA.Simulation`, §Message Generation, and
`Mix.Tasks.Tla.Simulate`. Random walks over the real implementation, checked against the
spec at every step.

| Built | Where |
|---|---|
| `TLA.Simulation` — `run/2`, `run_trace/2`, `replay/3` | `lib/tla/simulation.ex` |
| `TLA.Simulation.Generator` — `from_spec/3`, `enabled_only/3` | `lib/tla/simulation/generator.ex` |
| `Mix.Tasks.Tla.Simulate` | `lib/mix/tasks/tla.simulate.ex` |
| `TLA.GenServer.Driver` — the monitored call both drivers share | `lib/tla/gen_server/driver.ex` |

Remaining in Phase 3: `mix tla.replay`, which needs a trace file format that round-trips —
`mix tla.check --format json` currently writes states and bindings with `inspect/1`, which
a human can read and a machine cannot parse back.

## The finding the corpus did not expect

`Impl.Conforming` — the entry the corpus calls conforming — **is** caught by the
unrestricted generator, as `:not_enabled`. Its `handle_call(:done, …)` has no guard of its
own, so it accepts `:done` in a state where the spec's `done` is disabled.

That is a true finding about the pair rather than a bug in the checker, and the resolution
is a decision about defaults rather than a fix:

- **the enabled-only generator is the default.** It asks whether the implementation
  follows the spec where the spec has something to say.
- **the unrestricted generator is opt-in** (`mix tla.simulate --unrestricted`). It asks
  whether the implementation *refuses* what the spec forbids, which is a question nearly
  every server ever written answers badly — a `handle_call` clause carries no guard unless
  someone wrote one.

Both are in the corpus now, with the verdict each produces, because the difference between
them is the difference between two claims a green run could be making.

## Three amendments to §05

- **`branches_covered` becomes `actions_covered`.** Nothing in the project defines a
  branch. The fraction of the spec's actions a run exercised at least once is the number
  the report was reaching for, and it can be computed from what happened.
- **`result` gains `seed`, `restarts`, `detail`, and the status `:error`.** The seed is
  always present, generated when the config gave none: a random run that finds something
  and cannot be re-run has found nothing anybody can act on. `:error` is a server that
  stopped or stopped answering — nothing about conformance was decided after that point,
  and calling it `:ok` would say the traces passed.
- **the generators take the refinement.** A specification has no notion of a message —
  that is what `concrete_message/2` is for — so a generator returning one needs the
  mapping. They return `{action, params, message}`, which is what lets a simulation's
  counterexample name its actions; a user-supplied generator returning a bare message
  still works.

## Failure injection checks where recovery lands, not the crash

A crash is not a step of the specification: nothing in the DSL models one. So the restart
is not checked as a transition, and what *is* checked is the recovered abstract state
against the spec's invariants. A server that comes back in a state its own specification
forbids is a finding whatever the spec says about crashing.

## The counterexample is a `TLA.Trace`

So a simulation failure can be handed straight to `TLA.Replay.counterexample/3` — there is
a test that does exactly that — printed with `TLA.Trace.format/1`, or read the way a model
checker's counterexample is. A finding arriving in a different shape from the model
checker's would be a second thing to learn for no reason.

One gap that surfaced: `Trace.format/1` prints the route and not the finding, and a
conformance violation carries its whole content in the message — which variable diverged,
which guard was false. The task prints both.

## Acceptance

- 22 new tests: 13 over the simulation and its generator, 9 over the mix task including
  its three exit codes and everything it refuses to run.
- 547 tests green, `mix format --check-formatted`, `--warnings-as-errors`, and
  `bin/tlc-expected --check` clean.
