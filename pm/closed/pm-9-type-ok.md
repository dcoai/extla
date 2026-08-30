---
id: pm-9
title: "The implicit type_ok invariant, and the two type forms §1.5 was missing"
labels: [In-Progress]
created: 2026-08-30
closed: 2026-08-30
gitlab_issue: 9
merge_request: 9
gitlab_synced: true
---

## Scope

Resolution of the §1.5 type grammar against a run's constants, and the implicit
`:type_ok` invariant it feeds (D-19). Types are **stored quoted** and resolved at
model-check time because nearly every useful type mentions a constant that has no
value until a run assigns one; this is the other half of that decision.

## What the implementation found

**§1.5 cannot type the spec's own worked example.** `balances` is declared
`[^accounts ~> 0..^max_balance]`, but `init` gives every account `^max_balance` and a
transfer pushes the recipient above it. The first thing the new `type_ok` invariant
did was refute §8 — before `conservation_of_money`, the violation the example is
built around, got a chance to fire.

The type is not merely wrong; it was **unwriteable**. Conservation bounds the total
across accounts, not any one of them, so the honest type is "a map from accounts to
non-negative integers" — and the grammar had no way to say "an integer". Every
expressible type for that variable was false.

So `:int` and `:nat` join the grammar, TLA+'s `Int` and `Nat`, and §8's `balances`
becomes `[^accounts ~> :nat]`. A type language in which the documented example cannot
be typed correctly is a gap in the language, not a mistake in the example.

## Decisions inside the resolution

**A function type's domain is checked for equality, not membership.** `[^accounts ~>
:nat]` means the map's keys are *exactly* the accounts. TLA+ functions are total, and
a map missing a key its domain declares is precisely what an action that forgot to
extend it produces — the failure the check exists to catch. A domain that does not
denote a set (`[:set ~> …]`) is an error naming the three forms that do.

**`type_ok` is checked first, ahead of the declared invariants.** A state outside its
declared type makes every other invariant's verdict on that state uninteresting; the
useful thing to report is that a variable holds something the spec says it cannot.

**`type_ok` cannot be declared.** A user invariant of that name would either shadow
the implicit one or be shadowed by it, and a coverage report naming `type_ok` would
then be ambiguous about which was checked. The diagnostic points at `type:`.

**A `:set`/`:seq`/`:int`/`:nat` inside a list is the literal atom.** They shadow the
literal atoms of those names at the top level of a type; inside a list — "one of the
listed literals" — there is nothing for the special form to be ambiguous with. Said in
§1.5 rather than left to be discovered.

**Resolution happens once per run, not once per state.** The constants do not change;
the state space is where the work is.

## Verification

248 tests. `die_hard`'s `TypeOK` now comes from the `type:` annotations rather than a
hand-written invariant — the same check written once — and the differential test still
agrees with TLC on it, which is the point: the implicit invariant means what the TLA+
`TypeOK` means.

The rest pin each grammar form, and three failure modes worth naming: a constant used
as `^name` that is not a set, a range bound whose constant is not an integer, and a
function domain that does not denote a set. All three raise with the variable named,
because they surface mid-run rather than at compile time.

## Next

`TLA.Coverage` and `mix tla.check` — the last two pieces of the Phase 1 deliverable.
