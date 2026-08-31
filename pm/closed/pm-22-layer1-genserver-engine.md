---
id: pm-22
title: "Phase 3, slice 2: Layer 1's GenServer engine — invariants on a running process"
labels: [In-Progress]
created: 2026-08-31
gitlab_issue: 22
gitlab_synced: true
---

## Scope

`03-layer1-invariants.md` §`TLA.Invariant`, §`TLA.Invariant.Runtime`, §Violation
Handling, §Telemetry Integration and §Performance Considerations, for the behaviour the
spec calls the primary target: `GenServer`.

| Built | Where |
|---|---|
| `TLA.Invariant` — the four declaration macros, `@on_definition`, `@before_compile` | `lib/tla/invariant.ex` |
| `TLA.Invariant.Runtime` — the four checks, two arities each, and `extract_state/2` | `lib/tla/invariant/runtime.ex` |
| `TLA.Invariant.Violation` — the exception, its message, and the three modes | `lib/tla/invariant/violation.ex` |

**Deliberately not in this slice**, and carried to `pm-23`: `handle_event/4` for
`GenStateMachine` and `:gen_statem`, the `Agent` wrapper, and the `TLA.Invariant.Test`
ExUnit helpers. All three are specified in §Supported OTP Behaviors and §Testing
Integration; none is reachable from the GenServer path, and holding them here would make
one MR out of two independent pieces of work. The slice is honest about being partial
against §03 as a whole — which is the failure Phase 2's ledger correction was about, and
the reason this paragraph exists rather than a summary claiming §03 is done.

## Four decisions, none of which the spec had settled

**`super`, not a renamed original.** The spec's §Compile-Time Transformation sketched a
generated `__original_handle_call__/3`. That breaks on the thing every real GenServer
has: several `handle_call/3` clauses with different patterns and guards. Renaming would
have to reproduce every clause head exactly, and a mistake silently changes dispatch.
`defoverridable` + `super` leaves the author's clauses intact and dispatches to them with
their own matching.

**`@on_definition`, not `Module.defines?/2`.** Only the callbacks the module's author
wrote are wrapped. `use GenServer` injects defaults for `handle_call/3`, `handle_cast/2`
and `handle_info/2` before `use TLA.Invariant` runs; `Module.defines?/2` cannot tell those
from the author's, `super` on one of them is deprecated, and a default that exists to stop
the server with a `:bad_call` is a transition nobody wrote. This is why `use TLA.Invariant`
belongs directly after `use GenServer` and before the callbacks — `@on_definition` sees a
definition only once it is installed. Recorded in §03.

**`callbacks:` is resolved at compile time, and so is `enabled: false`.** A hot callback
in a module with nine invariants is emitted with a call naming the two that apply, not
nine names and a runtime filter. Where a callback ends up with nothing to check, no call
is emitted for it at all. This is what forced the amendment to
`Runtime.check_invariants!/3` and `check_action_properties!/4`: they take the names.

**`:verbose` telemetry is a second arity, not a branch.** §Telemetry says success events
are *unemitted* rather than merely unfired. The quiet wrapper calls the three-argument
check, whose body contains no timing call and no `:checked` event to decline — a branch
that skips one still pays for reaching it, and a transition can fire four.

## `init/1` carries invariants and nothing else

Its result *is* the first state, so there is no pre-state for an action property or a
postcondition to compare against, and no earlier message a precondition could be about.
The wrapper for `init/1` emits invariant checks only. Recorded in §03.

## Acceptance

- 19 tests over `TLA.TestServers.Account`, a server that breaks each declaration in a
  different way, and `Quiet`, a server with none (the hook must emit no wrapper).
- `:disabled` is asserted the only way it can honestly be: `refute
  function_exported?(module, :__tla_mode__, 0)` on a module compiled under it. Not cheap
  emitted code — none.
- `enabled: false` is asserted by an invariant whose block `raise`s. If it were resolved
  at runtime the fixture would not compile.
- 472 tests green, `mix format --check-formatted`, `--warnings-as-errors`, and
  `bin/tlc-expected --check` clean.

## `telemetry` becomes an optional dependency

Second one, after `jason`, and absent-tolerant the same way: `Code.ensure_loaded?/1` at
ExTLA's own compile time decides whether `emit/2` has a body. A consumer who attaches no
handler carries no code for it. §06's "zero runtime dependencies" is amended to "zero
*required* runtime dependencies".
