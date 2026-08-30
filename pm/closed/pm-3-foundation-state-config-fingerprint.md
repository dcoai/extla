---
id: pm-3
title: "Foundation: TLA.State, TLA.Config, TLA.Fingerprint"
labels: [In-Progress]
created: 2026-08-30
closed: 2026-08-30
gitlab_issue: 3
merge_request: 4
gitlab_synced: true
---

## Scope

The first three modules of Phase 1 (`spec/06-architecture.md` §Phase 1), and the
first ExTLA code of any kind. All three are specified in `spec/01-foundation.md`;
this is implementation, not design, with three exceptions recorded below.

- `TLA.State` — state as a plain map, priming, stepwise comparison, and the §6
  permitted-terms check.
- `TLA.Fingerprint` — canonical encoding and truncated SHA-256 identity.
- `TLA.Config` — compile-time `mode/0`, runtime `max_states/0` and `workers/0`.

## Three things the spec did not settle

**1. Where the §6 permitted-terms check lives.** `02-dsl-semantics.md` §6 says
assigning a pid, reference, port, fun or float to a spec variable "is a runtime error
from the checker naming the variable", but no module owned that check. It is
`TLA.State.validate!/1`: it walks a state, raises `TLA.State.InvalidTermError` naming
the variable and the position inside it (`element 1 -> tuple element 1`), and returns
the state so it threads into the expansion pipeline the checker will have. Added to
`spec/01-foundation.md` §Core Functions in the same commit, rather than left as an
undocumented function.

**2. What a missing variable does.** The spec gave `get/2` and `unchanged?/2` no
behavior for a variable the state does not have. They raise, and `prime/3` raises on
a variable it would otherwise add. The argument is the same one that rules out
`phash2` one module over: a misspelled variable read as `nil` compares unequal to
whatever the guard expected, so the action looks disabled, so the checker explores
less and still reports success — and nothing in the output distinguishes that run
from a sound one. Written up in `spec/01-foundation.md` §Reading a variable that is
not there.

**3. `mode/0` can only be called from a module body.** Discovered by the test:
`Application.compile_env/3` raises "cannot be called inside functions". So the
Layer 1 and 3 `@before_compile` hooks must resolve it into a module attribute
(`@tla_mode TLA.Config.mode()`) and branch on that while emitting wrappers. This is
the shape those hooks want anyway — `:disabled` emitting *no wrapper* is a decision
made while the module body is expanded, not inside a function already emitted — but
it is a constraint on Layer 1's implementation and is now recorded in the spec
rather than waiting to be rediscovered in Phase 3.

## Verification

49 tests, 11 of them doctests. The two that matter most:

- **`canonical/1` is insertion-order independent** for a 64-key map and a 64-element
  MapSet — maps past the flatmap threshold are the case `:deterministic` exists for,
  and the one where dropping it would cost duplicate exploration of equal states.
- **`collision_estimate/2` reproduces the table** in `01-foundation.md` §Why not
  `:erlang.phash2/1` to two decimal places. If the test and the table ever disagree,
  one of them is wrong, and the table is the argument for the whole module.

`compute/2` raises on any width other than 64 or 128: a silently accepted `bits: 32`
would be an unsound run reported as a sound one.

## Not here

`TLA.Set`, `TLA.Function` and `TLA.Temporal` — `TLA.Temporal.enabled?/4` takes a
`TLA.Spec.Compiled.action_def()` and cannot be written before the DSL exists.

## Next

`TLA.Set` and `TLA.Function`, then the DSL and its §7 compile-time validator — the
genuinely unproven part of the design.
