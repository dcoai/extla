---
id: pm-12
title: "Corpus: two_phase_commit and distributed_lock, both agreeing with TLC"
labels: [In-Progress]
created: 2026-08-30
gitlab_issue: 12
gitlab_synced: true
---

## Scope

Two more differential entries. D-9 makes the corpus the acceptance criterion for
Phase 1, so with one entry in it that criterion was a third met, not met.

| Entry | Distinct states | Depth | What it adds |
|---|---|---|---|
| `two_phase_commit` | 288 | 11 | The first CONSTANT, and a state space big enough that a checker exploring slightly less of it still reports success |
| `distributed_lock` | 34 | 7 | Two constants — so a *product* of param sets — and a structured value in state |

Both agree with TLC exactly, first run, on every field the corpus compares.

## Why these two, in this order

`die_hard` pins the shortest counterexample; its 16 states are checkable by eye.
Neither of these has a violation, so the **state count carries the whole comparison** —
which is the harder thing to get right and the one that fails silently. A checker that
explores 287 of 288 states reports "no violation found" in exactly the same words.

`distributed_lock` adds two things one constant cannot expose. The product of two param
sets is where successor generation gets a chance to be wrong in a way a single set
cannot show. And `pc[p] = {:holding, r}` puts a *tuple* in state, where a fingerprint
that flattened structure would stop distinguishing states — the exact failure
`TLA.Fingerprint` exists to prevent, now measured rather than argued.

It is also `spec/07-examples.md` Example 1 verbatim, which is the point: the corpus
checks the documentation rather than a paraphrase of it.

## Two things that bite when writing an entry

**TLC compares strings strictly.** `"idle" = <<"holding", r>>` *raises* rather than
returning FALSE, so `DistributedLock.tla` would not run at all with string tags. The
control-state tags are declared as `CONSTANTS` and assigned as model values in the
`.cfg`; a model value is simply unequal to anything it is not, and it reads as what it
translates to on the ExTLA side — an atom. Written up in the corpus README, because the
next entry will hit it.

**Invariant names need a stated mapping.** TLA+ modules prefix by convention
(`TPTypeOK`) while ExTLA's implicit type invariant is always `:type_ok`. The
differential test carries a per-entry `names` map rather than guessing, which also
means an invariant that goes missing from the DSL spec is *reported* rather than
silently skipped.

## One checker addition

`config.action_properties` selects which action properties a run checks, symmetric with
`config.invariants`. The state-count comparison has to run with nothing selected on
either side: `distributed_lock`'s ExTLA spec has an action property that the TLA+ module
does not, and it would otherwise halt the search early and make the counts differ for a
reason that is not a bug.

## One gap found, not closed

§1.5 cannot type the elements of a set or a sequence, so `msgs` is `:set` where TLA+
says `msgs \\subseteq Message`. The entry therefore checks a strictly weaker `type_ok`
than TLC does. Both hold, so today's comparison is unaffected — but an entry that checks
less than its TLA+ counterpart can agree with TLC for the wrong reason, which is worth
naming. Filed as its own proposal.

## Also

The README claimed "Phase 1 is done". It now says every Phase 1 *component* exists and
the acceptance gate is half met, with the per-entry numbers. Saying otherwise before the
corpus is complete would be the kind of claim this project exists not to make: the
oracle landed before the checker so the agreement could be measured rather than assumed,
and half a corpus is half a measurement.

## Next

`raft_election` (safety only — its liveness is refuted by the term bound by design),
`bounded_buffer`, and `paxos`.
