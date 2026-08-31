---
id: pm-11
title: "The §1.5 grammar cannot type the elements of a set or a sequence"
labels: [In-Progress]
created: 2026-08-30
gitlab_issue: 11
gitlab_synced: true
---

## Problem

Found while translating `two_phase_commit` for the differential corpus (pm-12). Its
TLA+ `TPTypeOK` includes:

```tla
Message == [type : {"Prepared"}, rm : RM] \cup [type : {"Commit", "Abort"}, rm : {"tm"}]
msgs \subseteq Message
```

The ExTLA side can only say `variable :msgs, type: :set`. §1.5's `:set` and `:seq` are
documented as "any `MapSet` / any list; **element types unconstrained**", and there is
no syntax for constraining them.

So the corpus entry checks a strictly weaker `type_ok` than TLC does. Both hold, so the
comparison is unaffected today — but the differential corpus is the project's only
oracle, and an entry that checks less than its TLA+ counterpart is an entry that can
agree with TLC for the wrong reason.

## Why it matters beyond this entry

A collection is where a spec's shape errors hide. `msgs` holding a malformed message,
`log` holding an entry with a missing field, `pending` holding a bare atom instead of a
`{to, amount}` pair — none of these are caught by `:set`, and each is exactly the sort
of thing an action written in a hurry produces. The implicit `type_ok` invariant is the
project's answer to "did a variable go somewhere the spec says it cannot", and for the
two collection types the answer is currently "we did not look".

TLA+ has `SUBSET T` and `Seq(T)` for this, and every corpus entry from here on will
want one or the other.

## Options

1. **`{:set, t}` / `{:seq, t}`** — reuse the tuple form. Terse, but collides with the
   tuple type `{t1, t2}`: `{:set, :nat}` is already a legal *tuple of the literal atom
   `:set` and a natural*. Rejected unless the collision is designed away.
2. **`[t]` for a sequence, `%MapSet{}`-ish for a set.** `[t]` collides with the
   existing "one of the listed literals" (`[:a, :b]`) whenever the list has one element
   — `[:idle]` would become ambiguous between "the literal `:idle`" and "a sequence of
   `:idle`s".
3. **`set(t)` and `seq(t)` as call forms.** No collision: `:set` bare keeps its meaning,
   `set(t)` is new syntax, and it reads like the `TLA.Spec.Helpers` constructors of the
   same names. Costs one grammar rule each.
4. **A predicate escape hatch** — `type: {:where, fn v -> … end}`. Maximally general and
   the least checkable; it also puts a closure where D-19 deliberately put a quoted
   expression, so the type could no longer be rendered in a violation message.

Option 3 is the one to take unless something better appears. It also extends naturally:
`[^accounts ~> seq(:nat)]` says what the transfer spec's `log` actually holds.

## Acceptance

`two_phase_commit`'s `msgs` typed as tightly as its TLA+ `Message`, and the differential
entry still agreeing with TLC. A test that a malformed element is reported as a
`type_ok` violation naming the variable, the element and the expected element type.

## Decision — option 3, plus the record form it needs

**Taken: `set(t)` and `seq(t)` as call forms**, exactly as this proposal argued.
`{:set, t}` collides with the tuple type, `[t]` collides with "one of these literals",
and the call form reads like the `TLA.Spec.Helpers` constructor of the same name.

**Plus `%{k: t, …}` for a record**, which the proposal did not anticipate and which the
first entry needed. `msgs \subseteq Message` is a set of *records*; `set(t)` with no way
to write `t` for a message would have closed the gap for `set(^servers)` and left every
message set exactly where it was. TLA+ writes the same thing as a record set,
`[type : {"Prepared"}, rm : RM]`, so the correspondence is direct.

**Plus arithmetic range bounds.** `bounded_buffer`'s items are numbered from zero, so
TLC's `Item` is `[producer : Producers, seq : 0..(MaxItems - 1)]`. A bound grammar that
could not say `0..(^max_items - 1)` would have forced the ExTLA type one element wider
than the TLA+ one — the same "weaker than the oracle" problem, one level down.

Recorded as D-21; the grammar table in §1.5 now carries all three.

## What changed in the corpus

Four entries now check what TLC checks:

| Entry | Was | Is |
|---|---|---|
| `two_phase_commit` | `msgs :set`, `tm_prepared :set` | `set(%{type: :prepared, rm: ^rms} \| %{type: [:commit, :abort], rm: :tm})`, `set(^rms)` |
| `raft_election` | `messages :set`, `votes_granted :set` | the two-record union, and `set(^servers)` |
| `bounded_buffer` | `buffer :seq` | `seq(%{producer: ^producers, seq: 0..(^max_items - 1)})` |
| `paxos` | `msgs :set` | the four-record union |
| `distributed_lock` | `waiting :set` | `set(^processes)` |

All six entries still agree with TLC exactly — the same state counts and diameters, now
established against a `type_ok` that is no weaker than the `TypeOK` it is compared to.

## Related

`[[pm-9-type-ok]]`, `[[pm-13-corpus-raft-and-buffer]]`, `[[pm-14-corpus-paxos]]`,
`02-dsl-semantics.md` §1.5, `08-decisions.md` D-19 and D-21.
