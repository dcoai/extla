---
id: pm-16
title: "Could a solver prune branches of the state graph?"
labels: [Research]
created: 2026-08-31
gitlab_issue: 16
gitlab_synced: true
---

## The question

Can a constraint/SMT solver prove that parts of the state space need not be explored,
so the checker does less work for the same verdict?

## Four different things that could mean

They have very different costs, and only some of them are pruning.

**1. Dead-action pruning.** Prove `Reachable ⇒ ¬Guard(a)` for an action, and stop
generating its successors. With only `type_ok` as the over-approximation of `Reachable`
this catches a typo'd guard — which `TLA.Coverage` already reports as `never_enabled`,
though only *after* a run. As real pruning it needs a strengthened inductive invariant,
which is the hard part and is most of what an IC3/PDR engine does.

**2. Property-directed slicing (cone of influence).** Drop the variables the property
under check does not depend on, and states that differ only in those collapse. No solver
needed — dependency analysis over the block ASTs does it. This is likely the largest
easy win available: `bounded_buffer` checked for `counts_consistent` does not need the
*contents* of `buffer`, only its length, and the contents are most of its 4,460 states.

**3. Partial-order reduction.** Independent actions commute, so one interleaving of a
diamond stands for all of them. This is the classic big win for exactly the specs in
this corpus — `two_phase_commit`, `raft_election`, `paxos` are mostly independent
per-process steps. It needs an *independence relation*, usually approximated
syntactically ("these two actions touch disjoint variables"); a solver's role is to
discharge the obligation properly — "do `A(p)` and `B(q)` commute from every state
satisfying the invariant?" — which turns a conservative syntactic guess into a proof.

**4. Symbolic checking outright** (BDD, SAT-based BMC, IC3/k-induction). Not pruning:
replacing enumeration. A different engine with different failure modes, and it gives up
the property Phase 1 was built around — the *shortest* counterexample, breadth-first, in
states an author can read.

## The obstacle specific to this project

Guards and actions are **arbitrary Elixir closures**, by design: §3 makes an action body
a pure deterministic function of `(pre_state, params)`, and D-5's whole memory model
rests on that. A solver needs formulas, not closures.

So any solver work needs a **solver-facing IR extracted from the block AST** — the ASTs
are available at compile time, and §1.5's `type:` grammar already gives finite domains
for every variable, which is a real head start. The IR would cover a subset: comparisons,
arithmetic, membership, map/set/sequence operations over finite domains. Anything outside
the subset yields no proof.

That is the shape that makes this safe: **the pruner may always decline.** No proof, no
pruning, fall back to enumeration. An optimization that is allowed to give up is one that
cannot be silently unsound — and silent unsoundness is the thing this project exists not
to ship.

## What it would cost, honestly

- **An external dependency.** There is no mature native SMT solver for the BEAM. This
  means Z3 over a port with SMT-LIB2, for a library whose only runtime dependency today
  is an optional `jason`. That is a packaging decision, not just an engineering one.
- **Solver calls must not be per state.** A per-state call is a catastrophe at 58k
  states: the search is currently ~2.6k states/second, and a solver call is milliseconds.
  Any viable design makes calls per *action* or per *action pair*, once, before the
  search — the results are then constants for the whole run.
- **The reduction has to be verifiable.** The precedent exists: D-17 and
  `verify_symmetry: true` run the same model with and without the reduction and fail on
  any difference in verdict. A pruner needs the same escape hatch, and the comparison
  must be on **verdicts**, not state counts — a sound reduction changes the count on
  purpose, so equal counts is the wrong test.

## Where a solver pays off immediately, without touching the search

This is the part worth doing first, because it needs no reduction to be sound and no
change to the hot path:

- **Proving a `terminal` predicate admits exactly the stuck states.** Writing
  `raft_election` produced a terminal that admitted *none* of its 655 end states, and
  what caught it was running the checker. `Stuck(s) ⇔ Terminal(s)` is an SMT query.
- **Proving a guard unsatisfiable** — `never_enabled` before the run rather than after.
- **Proving `type_ok` inductive**, which would turn it from "checked in every reachable
  state" into "true by construction".
- **Discharging D-17's symmetry obligation** on the IR subset. The spec calls that
  undecidable in general and puts it on the author; on a decidable subset a solver can
  discharge it, and the honest version is "proved for these actions, unproven for
  those".

## Recommendation

Not now, and not first. In order:

1. **Phase 2**, which is queued and whose value is a capability, not a speed-up.
2. **Slicing (2)**, then **POR (3)** — both are ordinary explicit-state techniques, both
   need no external dependency, and POR is where the real factor is for message-passing
   specs.
3. **A solver for the diagnostics above**, behind an optional dependency.
4. **Solver-guided pruning of the search** only if 2 and 3 have shown where the state
   space actually goes.

The current corpus cannot justify any of it on runtime grounds — 58,359 states in 22
seconds is not a problem to solve. What would justify it is the target in
`06-architecture.md`: 10M states. The measurement to take *before* deciding is where the
time goes at that scale — successor generation, fingerprinting, or genuine state-space
size. Only the third is what a solver addresses.

## Related

`04-layer2-model-checker.md` §State-space reduction (state constraints, symmetry, view
abstraction — the manual versions of this), `08-decisions.md` D-5, D-17,
`[[pm-1-verification-ledger]]`.
