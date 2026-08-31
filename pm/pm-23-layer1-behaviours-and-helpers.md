---
id: pm-23
title: "Phase 3, slice 3: Layer 1 for state machines and Agents, and the ExUnit helpers"
labels: [In-Progress]
created: 2026-08-31
gitlab_issue: 23
gitlab_synced: true
---

## Scope

The rest of `03-layer1-invariants.md`: §Supported OTP Behaviors beyond `GenServer`, and
§Testing Integration. With this, every module the section specifies is built.

| Built | Where |
|---|---|
| `handle_event/4` — `:gen_statem` and `GenStateMachine` | `lib/tla/invariant.ex`, `lib/tla/invariant/runtime.ex` |
| `TLA.Invariant.Agent` — `start_link/3`, `update/4`, `cast/3`, `get_and_update/4`, `get/4` | `lib/tla/invariant/agent.ex` |
| `TLA.Invariant.Test` — `assert_invariants/2`, `assert_action_properties/3`, `refute_invariant/3`, `valid_states/3` | `lib/tla/invariant/test.ex` |

## A bug in slice 2, found by building the state machine path

`init/1` was wrapped with `extract_state(result, nil)`, whose fallback clause returns the
pre-state — `nil`, for an `init`. So a server whose `init/1` returned `:ignore` or a bare
`{:stop, reason}` had its invariants checked **against `nil`**: a refusal to start was
reported as a violated invariant, or as whatever the predicate raised when it reached into
`nil`.

Fixed by giving `init` its own wrapper and its own runtime entry point: the state is a
`{:ok, state} | :none` tag, and `:none` checks nothing. `TLA.TestServers.Refusing` covers
both refusals and the started case.

The tag test is in `Runtime` rather than in the emitted code, and that is not a style
choice. Inside a given module `super(arg)` has a known return type, so a `case` on the tag
has a clause the compiler can prove unreachable — and Elixir's type system reports it, as
a warning, in the user's module, about code the user did not write. Behind a function
taking `term()` there is nothing to prove.

## Two decisions the spec had not settled

**D-24 — a state machine's `state` is the `{state_name, data}` pair, and its message is
the event content.** `:gen_statem` splits what TLA+ calls the state across two arguments
and neither half is it: a machine in `:red` with a corrupt counter is in a bad state, and
so is one whose counter is fine and whose colour is not a colour. Preconditions match the
event *content* rather than `{event_type, content}` so that `precondition {:withdraw,
amount}` is the same declaration on either behaviour — the event type is OTP's transport,
and a specification's properties are not about how a message arrived.

Two consequences: a module defining `handle_event/4` is instrumented as a state machine
throughout, `init/1` included (`{:ok, name, data}`, which the shared extraction would read
as `{:ok, state, extra}` and hand the invariant a bare `:red`); and `:gen_statem`'s
returns need their own extraction, because `{:stop, reason, data}` and a GenServer's
`{:stop, reason, state}` are the same shape carrying different things.

**D-25 — an `Agent`'s checks are runtime-dispatched, and `:disabled` is not free for
them.** These were macros in a first draft, on the reasoning that applies everywhere else
in Layer 1: resolve the mode where the call compiles, and emit the plain `Agent` call
under `:disabled`. That draft does not compile — `Application.compile_env/3`, which is how
the mode is read at all, cannot expand inside a function body, and an `Agent` call site is
always inside one. The alternative was to leave `Agent` unsupported, which §Supported OTP
Behaviors does not permit. So the cost is stated: one `function_exported?/3` per
transition under `:disabled`, in code the author wrote explicitly rather than code a hook
injected.

## `refute_invariant/3` is the helper that earns the module

An invariant no test has ever seen return `false` is indistinguishable from `true`, and a
`true` invariant is checked on every transition forever while proving nothing. It is the
vacuity `mix tla.check` reports at Layer 2 (`04-layer2-model-checker.md` §Coverage and
Vacuity), one layer down, and it is not detectable from the passing side. The helpers make
the negative case writable: a state a server can only reach through a sequence of calls is
an ordinary value here.

Three deliberate refusals in the helpers:

- A module carrying no predicates **raises** rather than failing as though the declaration
  were false — otherwise `mode: :disabled` reports as a broken invariant.
- `refute_invariant/3` raises for a name the module does not declare. A renamed
  declaration would otherwise turn the test green by checking nothing.
- `assert_invariants/2` names **every** invariant that failed. A state that breaks three
  is three facts about the state; reporting one hides the other two behind another run.

`valid_states/3` filters a base generator rather than constructing states, because the
invariant is the only definition of the type the module enforces and a generator built to
mirror it is a copy that can disagree with it. It has a body only where `stream_data` is
loaded — the absent-tolerance `jason` and `telemetry` already get.

## Acceptance

- 27 new tests: a `:gen_statem` traffic light (legal cycle, illegal transition, corrupt
  data under `:keep_state`, event-content precondition, statem `init/1`, and every
  `:gen_statem` return shape), the two `init/1` refusals, six `Agent` cases, and 11 over
  the helpers including a `stream_data` property.
- 499 tests green, `mix format --check-formatted`, `--warnings-as-errors`, and
  `bin/tlc-expected --check` clean.
