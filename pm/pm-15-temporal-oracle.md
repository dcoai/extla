---
id: pm-15
title: "Phase 2, slice 1: the temporal oracle — TLC's liveness verdicts in the corpus"
labels: [Planned]
created: 2026-08-31
gitlab_issue: 15
gitlab_synced: true
---

## Scope

Teach the differential corpus to carry TLC's **temporal** verdicts, before any liveness
checking exists on the ExTLA side.

This is the same ordering that made every Phase 1 number a measurement rather than a
claim: the TLC oracle landed before the checker, so agreement could be measured from the
first day the checker ran. Phase 2 repeats it. A liveness result with nothing to compare
it against is exactly the "silently weaker check" the project exists not to ship.

## What it takes

**1. Fairness in the TLA+ modules.** The three entries that declare `fairness` in the
DSL declare none in TLA+ — their `Spec` is `Init /\ [][Next]_vars` and nothing more. A
temporal property is only meaningful under the fairness the spec assumes, so each module
needs the conjuncts its ExTLA counterpart already states:

| Entry | ExTLA declares | TLA+ needs |
|---|---|---|
| `distributed_lock` | `fairness :strong, acquire_lock: [:p]`; `:weak, release_lock: [:p], return_to_idle: [:p]` | `\A p \in Procs : SF_vars(\E r \in Resources : AcquireLock(p, r))`, and WF likewise |
| `bounded_buffer` | four whole-action WF, `producer_wake: [:p]` WF, `consumer_wake: [:c]` SF | the same, per binding |
| `raft_election` | `:weak, [:handle_request_vote, :handle_vote_response]`; `:strong, [:timeout]` | whole-action WF/SF over the existential |

The per-binding form is where the correspondence has to be exact: `\A p : WF_vars(A(p))`
is not `WF_vars(\E p : A(p))`, and §5.2 exists because the second is too weak to prove
any per-process property. Getting this wrong makes the oracle agree with a checker that
is also wrong.

**2. `PROPERTIES` in the `.cfg`s**, one line per `temporal` declaration. The quantified
form — §5.1's `Enum.all?(^constant, fn x -> formula end)` — is `\A p \in Procs : F(p)`.

**3. `bin/tlc-expected` parses the temporal report.** It currently parses invariant
violations only. TLC reports a liveness failure differently: `Error: Temporal properties
were violated.` followed by a behavior that ends in a lasso — `Back to state N` — and
possibly a stuttering step. The expected shape:

```json
"properties": {
  "NoStarvation": "holds",
  "EventuallyElectLeader": {"violated": true, "lasso": {"prefix": 7, "cycle": 3}}
}
```

Whether the lasso's shape (prefix and cycle length) belongs in the fixture is the one
open question in this slice. It is the strongest comparison available — it pins the
counterexample the way `violated_at` pins an invariant's — but TLC's lasso is not
canonical the way a shortest counterexample is, so two correct checkers can report
different cycles. **Start with `holds` / `violated`, and add the lasso only if the
entries turn out to agree on it.** A fixture the checker cannot be expected to match is
worse than no fixture.

**4. Expect the safety numbers not to move.** Fairness constrains behaviors, not
reachable states, so `distinct_states` and `diameter` must be identical after adding the
conjuncts. If they move, something in the translation is wrong, and the `verify` stage
will say so — which is the point of regenerating rather than hand-editing.

## What the corpus will then be asserting

| Entry | Property | Expected |
|---|---|---|
| `distributed_lock` | `no_starvation` | holds — and only under per-binding SF, which is why §5.2 exists |
| `distributed_lock` | `lock_eventually_released` | holds |
| `bounded_buffer` | `producers_make_progress`, `consumers_make_progress`, `no_producer_starvation` | holds |
| `bounded_buffer` | `no_consumer_starvation` | holds, but only because it excepts the drained end state |
| `raft_election` | `eventually_elect_leader` | **violated** — refuted by the term bound, by design |

That last row is the one worth having. A liveness checker that reports everything as
holding is the failure mode here, and one entry that must come back violated is the only
thing that distinguishes a working checker from a broken one.

## Acceptance

`bin/tlc-expected --check` green with `properties` in every `expected.json`, the safety
numbers unchanged, and `raft_election` recorded as refuting its liveness property. No
ExTLA-side change: `check_liveness: true` still raises.

## Next slices

the liveness graph (edge table + ENABLED bits, opt-in), then Tarjan and the fragment's
semantics, then per-binding fairness, then symmetry and `--verify-symmetry`. They are
sketched in `HANDOFF-2026-08-31-phase2-start.md`; each gets its own `pm-N` when it
starts.

## Related

`04-layer2-model-checker.md` §State Graph and §`TLA.ModelChecker.Liveness`,
`02-dsl-semantics.md` §5.1 and §5.2, `08-decisions.md` D-5 (as amended), D-12, D-15.
