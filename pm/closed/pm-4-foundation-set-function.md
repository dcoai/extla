---
id: pm-4
title: "Foundation: TLA.Set and TLA.Function"
labels: [In-Progress]
created: 2026-08-30
closed: 2026-08-30
gitlab_issue: 4
merge_request: 5
gitlab_synced: true
---

## Scope

The remaining foundation modules that do not depend on the DSL: TLA+ set theory
(`TLA.Set`) and TLA+ functions as total maps (`TLA.Function`), both specified in
`spec/01-foundation.md`. `TLA.Temporal` is the third of the trio and is deliberately
left out — `enabled?/4` takes a `TLA.Spec.Compiled.action_def()`, which does not
exist yet.

## Two decisions the spec did not settle

**1. What `CHOOSE` chooses.** The spec said "returns the same element for the same
inputs" without saying which. Enumeration order over a `MapSet` would satisfy the
letter of that and fail its purpose: it is stable for a given map value on a given
OTP release, and nothing guarantees it across releases. A `CHOOSE` that varied
between runs would make the reachable state graph vary between runs, which defeats
the differential corpus before it detects anything. It is now the least satisfying
element in Erlang term order — a total order that is a function of the set's value
alone. TLA+ requires only that `CHOOSE` be a function of its arguments, so this is a
valid refinement, and it is now written into the spec.

**2. `cross_many([])`.** Unspecified, and the DSL depends on the answer: an action
with no parameters has exactly one binding, binding nothing. The product of no sets
is therefore `MapSet.new([{}])`, not the empty set — the empty set would mean a
parameterless action can never fire. Written into the spec.

## One spec bug

`function_set/2` was documented as `|S|^|T|` elements. A function fixes a value for
each element of the *domain*, so the domain is the exponent: `|T|^|S|`. The
consequence is not just arithmetic — with the sizes reversed, a reader sizing a model
would pick exactly the wrong set to keep small. Two edge cases that the corrected
form makes visible are now stated and tested: an empty domain gives exactly one
function (the empty one), while an empty range with a non-empty domain gives none.

## Also carried forward from pm-3

`except/2` and `except_with/3` raise on a point outside the domain, for the same
reason `TLA.State.prime/3` does: `[f EXCEPT ![a] = v]` with `a ∉ DOMAIN f` is
undefined in TLA+, and quietly extending the domain produces a state no reachable
behavior can produce, which the fingerprint would then faithfully record as if it
were one.

## Verification

108 tests overall, 31 doctests. `choose/2` is checked to give the same answer for the
same set built ascending, descending and shuffled — the property the whole decision
rests on. The `function_set/2` cardinality test asserts both `|T|^|S|` and its
transpose so a future reversal cannot pass.

## Next

The DSL: `TLA.Spec`, `TLA.Spec.DSL`, `TLA.Spec.Compiled`, and the compile-time
validator of `02-dsl-semantics.md` §7 — the genuinely unproven part of the design.
