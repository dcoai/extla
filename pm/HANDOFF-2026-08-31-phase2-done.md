# HANDOFF — 2026-08-31 — Phase 2 shipped; start here

Supersedes `HANDOFF-2026-08-31-phase2-start.md`. Self-contained; read it first.

**Phase 2 is done.** Liveness, fairness and symmetry all work and are all measured
against TLC. What is next is a choice rather than a queue, and the options are at the
bottom.

---

## WHERE THINGS STAND

**Phases 1 and 2 are done on the terms the project set for itself.** D-9 makes the
differential corpus the acceptance criterion, and ExTLA agrees with TLC on all six
entries — distinct states, search depth, where the search stops, every invariant, the
shortest counterexample where there is one, and now every temporal property.

| Entry | Distinct states | Depth | Temporal |
|---|---|---|---|
| `die_hard` | 16 | 8 | — |
| `two_phase_commit` | 288 | 11 | — |
| `distributed_lock` | 34 | 7 | 2 hold |
| `raft_election` | 58,359 | 19 | 1 **violated** |
| `bounded_buffer` | 4,460 | 29 | 4 hold |
| `paxos` | 3,921 | 17 | — |

`raft_election`'s `eventually_elect_leader` is the row that matters: a liveness checker
that answers "holds" to everything agrees with every other row in the table. ExTLA
refutes it with a seven-state prefix ending in the split vote at `max_term`, stuttering
there forever — the same shape TLC prints, whose behaviour ends `State 8: Stuttering`.

409 tests, all green, ~77s (`raft_election`'s liveness run is most of it). CI green on
`main`: `check` (format / compile with warnings-as-errors / test) and `verify`
(regenerates every `expected.json` from TLC and fails on drift).

**Built in Phase 2, in five MRs:**

- **The temporal oracle** (#15). Fairness conjuncts in the TLA+ modules, `PROPERTIES` in
  the `.cfg`s, and `bin/tlc-expected` recording a verdict per property from a run of its
  own — TLC names no property when one fails, and `-continue` does not cover a temporal
  violation any more than it covers a deadlock.
- **The liveness graph** (#17). `TLA.Temporal.enabled?/4`, `TLA.Temporal.Fairness.expand/3`
  for §5.2's per-binding expansion, and `TLA.StateGraph` recording every out-edge and one
  ENABLED bit per fairness constraint while each state is materialized. 15% on the search
  and 206 bytes per edge — §State Graph's "roughly 16 bytes" forgot the binding, and a
  binding is a map. `bench/liveness_graph.exs`.
- **The checker** (#18). `TLA.ModelChecker.Liveness`: Tarjan over the edge table, the
  fairness rules on each component, the Emerson–Lei split when strong fairness is what
  broke, the §5.1 fragment's six shapes, and lasso counterexamples. Slice 4 of the old
  plan was absorbed: the per-binding index already existed, so there was nothing left to
  build.
- **Symmetry** (#19). Canonical form before fingerprinting, `verify_symmetry: true`
  comparing verdicts rather than counts, and D-22 refusing symmetry and liveness in the
  same run. `raft_election` at three servers is 58,359 → 9,871 states and 23.3s → 6.6s;
  `bench/symmetry.exs`.
- **The ledger correction** (#20). The four MRs above met Phase 2's *deliverable* while
  leaving three of its modules partial against their own specifications:
  `TLA.Temporal` had one of its eight functions, `TLA.Temporal.Fairness` neither of its
  two, and `TLA.StateGraph.sccs/1` was private inside `Liveness`. All built, with two
  amendments recorded as D-23 — temporal operators over a finite trace return
  `:holds | :violated | :inconclusive` rather than a boolean, and `ENABLED` is an
  argument to the fairness operators because a behaviour cannot answer it.

**Not built, and raising rather than pretending:** parallel exploration (`workers:`),
Layer 1 invariants, Layer 3 conformance, `view:`. `TLA.StateGraph.to_dot/2` and
`to_json/1` are specified in §State Graph and belong to Phase 4's `mix tla.visualize`.

**Phase 2's ledger is true as it stands.** Every module in `06-architecture.md` §Phase 2
is built to its specification. That was worth checking rather than asserting: it was not
true after the fourth MR, and the summary said it was.

**Open issues:** **#1 / `pm-1-verification-ledger.md`** — a drift-gated coverage golden
and spec-version stamps, buildable now. **#16 / `pm-16-solver-guided-pruning.md`** — a
`Research` item on whether an SMT solver could prune the search, and why the parts worth
doing first are diagnostics rather than pruning.

---

## HOW THE WORK IS RUN

Process, from the project's labels:
`Proposal -> Accepted -> Planned -> In-Progress -> Review (MR) -> merge`.

Each work item is a `pm/pm-N-*.md` file mirrored to a GitLab issue, an MR that closes it,
and a move to `pm/closed/` in the *next* MR. **GitLab does not auto-close issues from
`Closes #N`** on this instance — close them with `glab issue close N` after merging.

Every MR: push, wait for the pipeline, merge only on green.

```bash
glab ci status --branch <branch> --live=false
glab mr merge <n> --yes --remove-source-branch
bin/tlc-expected --check          # the oracle gate; CI runs it every pipeline
mix run bench/liveness_graph.exs  # what the liveness graph costs
mix run bench/symmetry.exs        # what symmetry buys
```

---

## THINGS THAT WILL BITE

- **The parent-pointer graph cannot support liveness**, and the edge table is why. It is a
  spanning tree: every node has one in-edge and it is acyclic by construction. Anything
  that "derives successors from parent pointers" is the bug this design caught twice.
- **A liveness verdict needs a complete graph.** Only an expanded state has out-edges, so
  a run stopped by `max_states`, held back by a state constraint, or halted by a safety
  violation leaves a partial edge table — and an unexpanded state is indistinguishable
  from one that ends the spec, which is exactly the shape that refutes a liveness
  property. `Liveness.check/3` raises rather than answer.
- **A counterexample the spec's own fairness forbids is not a counterexample.** The
  printed cycle visits, for each constraint, a state where it is disabled or an edge that
  takes it. Getting that wrong produces a plausible-looking lasso that the assumptions
  rule out, and no verdict test catches it — which is why the corpus now re-evaluates
  every counterexample with `TLA.Temporal` and `TLA.TemporalCheck`, code that shares
  nothing with the checker that produced it.
- **TLC's liveness reporting is thin.** It names no property when one fails, and it stops
  the search where it happens to be — which is why `bin/tlc-expected` runs the safety pass
  from a `.cfg` with `PROPERTIES` stripped and each property from a `.cfg` of its own.
- **Symmetry soundness is the author's obligation** (D-17), and `verify_symmetry: true` on
  a small constant assignment is the only thing that catches a wrong one. It compares
  verdicts, never counts.

---

## WHAT IS NEXT — a choice, not a queue

**A. Phase 3, Layer 1 and Layer 3** (`spec/03-layer1-invariants.md`,
`spec/05-layer3-conformance.md`). Runtime invariants on real modules, and checking an
implementation against the spec it claims to refine. This is the half of the project's
premise that nothing else in the Elixir ecosystem does — Layer 2 alone is "TLC, in
Elixir", and Layer 3 is the reason for writing the spec in Elixir in the first place.

**B. Phase 4, parallel exploration.** `workers:` raises today. The ETS shape the graph
already has was chosen for it. It is the cheapest large factor left after symmetry, and
the 10M-state target in `06-architecture.md` is what it is for.

**C. #1, the verification ledger.** Small, and it closes the last "measured, not
asserted" gap: the coverage report is not drift-gated the way `expected.json` is.

**D. #16's diagnostics half.** Not the solver-guided pruning — the parts that pay without
touching the search: proving a `terminal` admits exactly the stuck states, proving a
guard unsatisfiable before the run, proving `type_ok` inductive.

My recommendation is **A**. Phase 2 finished the checker; what the project claims that
nothing else does is Layer 3, and a model checker with no way to connect a spec to the
code it describes is a tool people admire and do not adopt. **B** is the right answer
instead only if the specs people are actually writing are hitting the state-space wall,
and nothing in the corpus says they are yet — `raft_election` under symmetry is 6.6
seconds.

The user asked for this to run **as autonomously as possible**.
