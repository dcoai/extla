---
id: pm-24
title: "Phase 3, slice 4: the conformance bridge — TLA.GenServer and the step check"
labels: [In-Progress]
created: 2026-08-31
gitlab_issue: 24
gitlab_synced: true
---

## Scope

`05-layer3-conformance.md` §`TLA.GenServer` and §`TLA.GenServer.Runtime`: a GenServer
checked against the specification it claims to refine, on every transition.

| Built | Where |
|---|---|
| `TLA.GenServer` — `use`, compile-time `validate!`, the callback wrappers | `lib/tla/gen_server.ex` |
| `TLA.GenServer.Runtime` — `check_step!/5` and the other nine entry points | `lib/tla/gen_server/runtime.ex` |
| `TLA.GenServer.Violation` — the five findings, and the `:diverged` diff | `lib/tla/gen_server/violation.ex` |
| The step mutants the corpus recorded in slice 1 | `test/conformance/counter/impl.ex`, `test/conformance/step_test.exs` |

Not in scope, and next: `TLA.Replay` (§367), `TLA.Simulation` (§428), `TLA.PropertyTest`,
`TLA.Supervisor.Spec`, and the `mix tla.simulate` / `mix tla.replay` tasks.

## What the step check buys, measured rather than asserted

`test/conformance/README.md` recorded three step mutants before there was anything to
check them with — the same order the TLC oracle landed in, and for the same reason. All
three are now caught and each is named as written:

| Mutant | Reported as |
|---|---|
| `CollapsesTwoSteps` — Example 4's own bug | `:diverged`, diff `status: spec :incrementing, implementation :ready` |
| `MovesWhileUnmapped` — `:get` changes the abstract state | `:unmapped_but_moved`, `count: 0 -> 1` |
| `IgnoresTheGuard` — increments from `:incrementing` | `:not_enabled` on `%{count: 0, status: :incrementing}` |

The assertion that matters most is the second one in the `CollapsesTwoSteps` test: it
checks the spec's invariants against the post-state that mutant produced, and **they
pass**. That is what a Layer 3 without a step check would have reported — conformance, on
a server that folded two abstract steps into one callback. It is the ordinary bug, not a
corner case.

## Partial params, and why the search is right rather than lenient

`abstract_action/1` cannot always supply a full binding: an implementation resolves the
spec's nondeterminism itself — it pops its own queue, picks its own message — so the
choice is not in the message. Every binding of the action's params that *extends* the
given ones is a candidate, and the step is legal if any enabled candidate reproduces the
post-state. That is still refinement: the spec permits the step via that binding, and this
is what makes `validate!/3`'s round-trip rule satisfiable at all.

Two faults are distinguished from conformance failures and raised as `ArgumentError`
rather than as violations, because they are mistakes in the *mapping* and reporting them
as `:not_enabled` would blame the implementation:

- naming an action the spec does not declare;
- binding a param the action does not take.

## Three things that had to move out of the emitted code

Elixir's type system proves things about code inside the user's module, and a wrapper
emits code the user did not write. Three constructs produced warnings *in the user's
module* about unreachable clauses the user could not see:

- the `case` on `abstract_action/1` — in a server whose messages the compiler can
  enumerate, one arm is provably dead. Now `Runtime.check_transition!/5`.
- `init/1`'s `{:ok, state} | :none` tag test. Now `Runtime.record_initial!/3`.
- the same tag test in Layer 1, fixed in #23 for the same reason.

Behind a function taking `term()` or `module()` there is nothing to infer. This is a
general rule for the emitted code of both layers, and it is recorded in §05 and §03 rather
than rediscovered a fourth time.

## Constants are resolved in one place now

`Spec.Compiled.resolve_constants/1`, used by both `mix tla.check` and Layer 3. A
specification model checked under one assignment and an implementation checked against
another are two different specifications, and a verdict from each is not a verdict about
the same thing. The Mix task keeps its own Mix-flavoured error message and nothing else.

The compiled spec and the constants are memoized per process, beside the trace:
`__tla_spec__/0` builds its struct on each call and the constants come from application
config, so both would otherwise be re-derived on every callback.

## Amendments to §05

- `Module.register_attribute(:tla_action_mappings)` is **dropped**. Nothing accumulates
  into it — the mappings live in the refinement module, and the attribute was a leftover
  from a design in which they were declared in the server.
- `init/1` is wrapped, for the trace and the spec's invariants. Its result is the first
  abstract state, so there is no step to check, but a temporal property over a behaviour
  that begins at the *second* state is a property of a different behaviour.
- `check_transition!/5`, `record_initial!/3`, `abstract!/3` and `trace/0` are added to
  §`TLA.GenServer.Runtime`.

## Acceptance

- 14 new tests: the conforming server through every spec action, its recorded trace, its
  temporal verdicts, the three step mutants, `check_step!/5` directly, the two mapping
  faults, compile-time rejection of a mapping that names no message for an action, and the
  bounded trace dropping oldest-first.
- 513 tests green, `mix format --check-formatted`, `--warnings-as-errors`, and
  `bin/tlc-expected --check` clean.
