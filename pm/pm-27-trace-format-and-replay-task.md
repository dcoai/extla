---
id: pm-27
title: "Phase 3, slice 7: a trace format that round-trips, and mix tla.replay"
labels: [In-Progress]
created: 2026-08-31
gitlab_issue: 27
gitlab_synced: true
---

## Scope

`05-layer3-conformance.md` §`mix tla.replay`, and the serialization it needs.

| Built | Where |
|---|---|
| `TLA.State.Json` — the JSON form of a §6 state term, and back | `lib/tla/state/json.ex` |
| `TLA.Trace.to_json/1`, `from_json!/1` — traces and lassos | `lib/tla/trace.ex` |
| `Mix.Tasks.Tla.Replay` — `--trace` and `--captured` | `lib/mix/tasks/tla.replay.ex` |
| `mix tla.check --format json`, now writing the round-trippable form | `lib/mix/tasks/tla.check.ex` |

With this, `05-layer3-conformance.md` §Full verification pipeline runs end to end, and
Phase 3's module ledger in `06-architecture.md` is complete.

## The format existed and only went one way

`mix tla.check --format json` wrote states and bindings with `inspect/1` — readable by a
person, parseable by nothing. §05's own pipeline is

    mix tla.check Specs.X --format json > counterexample.json
    mix tla.replay MyApp.Server --trace counterexample.json

so the format had to round-trip before the task could exist. `TLA.State.Json` gives every
term §6 permits a JSON of its own: atoms, binaries and tuples are tagged, maps are pairs
rather than objects (a spec's keys are usually atoms and may be anything §6 allows, and a
JSON object would force them all to strings), `MapSet`s and structs keep what they are.
The human rendering is `TLA.Trace.format/1` and is untouched.

There is a test that decodes what the checker wrote and asserts the states are terms
again — `%{count: 0, status: :ready}`, not `"%{count: 0, status: :ready}"`.

## Atoms are the one real risk in reading a trace

The atom table is never garbage collected, so a decoder that creates atoms from a file
lets a large one exhaust it. Every atom a real trace mentions exists already: the spec
module that named it is loaded before its trace is read.

`String.to_existing_atom/1` raises "not an already existing atom" **without saying which**,
and the name is exactly what the message needs — a trace belonging to a different
specification is the common cause. Catching that error to improve it is not something this
codebase does, so the atom table is measured across the conversion instead: an atom that
already existed does not grow it. A file full of unknown atoms creates one of them, because
the decode stops at the first — a bounded cost for an unbounded input, which is the
property that matters.

## `--captured` needs less than `--trace`, and the task says so

`--trace` starts from *abstract* actions and needs `concrete_message/2` to produce the
message that causes each. `--captured` needs only `abstract/1` and `abstract_action/1`,
starts nothing, and is a pure check over recorded data — which is what makes it usable in
CI against a fixture or offline against an incident.

Exit code 2 is `:not_followed`, kept distinct from a violation for the reason slice 5
recorded: the spec permits a behaviour the code does not take, and which of the two is
wrong is not something the task can decide.

## Acceptance

- 17 new tests: 7 over the encoding, including a `stream_data` property over anything
  built from §6's terms and the four term kinds §6 forbids; 10 over the task, including
  the pipeline end to end — `mix tla.check --format json` writing a counterexample from
  `BuggySpec` and `mix tla.replay` driving the real server through it to the invariant it
  breaks.
- 564 tests green, `mix format --check-formatted`, `--warnings-as-errors`, and
  `bin/tlc-expected --check` clean.
