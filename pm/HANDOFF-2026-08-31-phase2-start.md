# HANDOFF — 2026-08-31 — Phase 1 shipped; start here for Phase 2

Supersedes `HANDOFF-2026-08-31-phase1-done.md`. Self-contained; read it first.

**The next piece of work is Phase 2 — liveness.** The plan is at the bottom, and its
first slice is written up in `pm/pm-15-temporal-oracle.md` (issue #15).

---

## WHERE THINGS STAND

**Phase 1 is done on the terms the project set for itself.** D-9 makes the
differential corpus the acceptance criterion, and ExTLA agrees with TLC on all
six entries — distinct states, search depth, where the search stops, every
invariant, and for `die_hard` the shortest counterexample.

| Entry | Distinct states | Depth | What it exercises |
|---|---|---|---|
| `die_hard` | 16 | 8 | The shortest counterexample, checkable by hand |
| `two_phase_commit` | 288 | 11 | A state count too large to eyeball |
| `distributed_lock` | 34 | 7 | A product of param sets; a tuple in state |
| `raft_election` | 58,359 | 19 | Params drawn from the pre-state; an end state that is not a deadlock |
| `bounded_buffer` | 4,460 | 29 | A sequence, where order distinguishes states a set would not |
| `paxos` | 3,921 | 17 | A guard quantifying over a subset of the messages in flight |

338 tests, all green, ~48s (the corpus is most of it). CI green on `main`:
`check` (format / compile with warnings-as-errors / test) and `verify`
(regenerates every `expected.json` from TLC and fails on drift).

**Built:** the DSL and its §7 compile-time validator; `TLA.State`, `TLA.Config`,
`TLA.Fingerprint`, `TLA.Set`, `TLA.Function`; `TLA.StateGraph`; breadth-first
`TLA.ModelChecker` with `terminal` states and the implicit `type_ok`;
`TLA.Trace`; `TLA.Coverage`; `mix tla.check`; `TLA.Spec.Test`.

**Not built, and raising rather than pretending:** liveness
(`check_liveness: true`), symmetry (`symmetry:`, `verify_symmetry:`), parallel
exploration, Layers 1 and 3.

**Open issues:** **#1 / `pm-1-verification-ledger.md`** — a drift-gated coverage
golden and spec-version stamps, buildable now, not Phase 2. **#15** is Phase 2's
first slice, below. **#16 / `pm-16-solver-guided-pruning.md`** is a `Research`
item, not queued work: whether an SMT solver could prune the search, what the
four things that question can mean cost, and why the parts worth doing first are
diagnostics rather than pruning.

---

## HOW THE WORK IS RUN

Process, from the project's labels:
`Proposal -> Accepted -> Planned -> In-Progress -> Review (MR) -> merge`.

Each work item is a `pm/pm-N-*.md` file mirrored to a GitLab issue, an MR that
closes it, and a move to `pm/closed/` in the *next* MR. **GitLab does not
auto-close issues from `Closes #N`** on this instance — close them with
`glab issue close N` after merging.

Every MR: push, wait for the pipeline, merge only on green.

```bash
glab ci status --branch <branch> --live=false
glab mr merge <n> --yes --remove-source-branch
bin/tlc-expected --check      # the oracle gate; CI runs it every pipeline
```

---

## PHASE 2 — THE PLAN

`spec/06-architecture.md` lists Phase 2 as `TLA.Temporal`,
`TLA.Temporal.Fairness`, the liveness graph, `TLA.ModelChecker.Liveness`, and
symmetry. In dependency order, as five slices:

**Slice 1 — the temporal oracle (`pm-15`, issue #15; written up, not started).** Teach
`bin/tlc-expected` to record TLC's temporal verdicts, and give the TLA+ modules
the fairness conjuncts their ExTLA counterparts already declare. Nothing on the
ExTLA side. This is first for the reason the TLC oracle came before the checker
in Phase 1: a liveness answer with nothing to compare it to is a claim.

**Slice 2 — the liveness graph.** Under `check_liveness: true`, `TLA.StateGraph`
also records per state: every out-edge `{action, params, successor_id}`, and one
ENABLED bit per fairness constraint, computed while the state is materialized.
`successors/2` reads the edge table and raises without one. This is the slice
that touches the hot path, so measure the cost on `raft_election` (58k states)
before and after.

**Slice 3 — Tarjan and the fragment.** `TLA.ModelChecker.Liveness`: SCCs over the
edge table, and the §5.1 fragment's semantics on top of them — `always`,
`eventually`, `~>`, and the `Enum.all?(^constant, …)` quantifier, which expands
into one instance per element. A `terminal` state is a self-loop for this
purpose: stuttering there forever is a legal behavior, so a leads-to whose
consequent has not held by then is violated there. Counterexamples are lassos
(prefix + cycle), which `TLA.Trace` has to learn to render.

**Slice 4 — per-binding fairness.** `fairness :strong, acquire_lock: [:p]` expands
into one constraint per element of `^processes`, each with its own ENABLED
computed over the remaining params. `\A p : SF(A(p))` is not `SF(\E p : A(p))`,
and §5.2 exists because the second is too weak to prove any per-process
property. `distributed_lock`'s `no_starvation` is the test: it holds only under
the per-binding reading.

**Slice 5 — symmetry.** Independent of the liveness work and could go first if
liveness stalls. Canonicalize before fingerprinting; `verify_symmetry: true`
runs the model with and without the reduction and fails on any difference.
Soundness is the author's obligation (D-17) — the compiler does not verify it,
and an earlier draft that promised to was promising the undecidable.

### Two things to know before starting

- **The parent-pointer graph cannot support liveness.** It is a spanning tree:
  every node has one in-edge, it is acyclic by construction, and an SCC search
  over it would find only trivial components and report every property as
  holding. That is why the edge table is a separate, opt-in structure (D-5 as
  amended). Anything that "derives successors from parent pointers" is the bug
  this design already caught once.
- **Fairness needs ENABLED per state, and states are discarded.** The bits have
  to be recorded while the state is materialized. This is the same split TLC
  makes: safety on fingerprints alone, liveness on a second graph paid for only
  when asked for.

### What "done" looks like

The corpus, again — not "the tests pass":

| Entry | Property | Expected |
|---|---|---|
| `distributed_lock` | `no_starvation` | holds, and only under per-binding SF |
| `bounded_buffer` | its four temporal properties | hold |
| `raft_election` | `eventually_elect_leader` | **violated**, refuted by the term bound by design |

That last row is the one that matters. A liveness checker that reports
everything as holding is the failure mode here, and an entry that must come back
violated is what distinguishes a working checker from a broken one.

The user asked for this to run **as autonomously as possible**.
