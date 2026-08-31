# HANDOFF — 2026-08-31 — Phase 1 done: the corpus is complete and agrees with TLC

Supersedes `HANDOFF-2026-08-30-phase1-components.md`, which left three corpus
entries to write. All three are in. This file is self-contained; read it first.

---

## WHERE THINGS STAND

**Phase 1 is done on the terms the project set for itself.** D-9 makes the
differential corpus the acceptance criterion, and ExTLA now agrees with TLC on
all six entries — distinct states, search depth, where the search stops, every
invariant, and for `die_hard` the shortest counterexample.

| Entry | Distinct states | Depth | What it exercises |
|---|---|---|---|
| `die_hard` | 16 | 8 | The shortest counterexample, checkable by hand |
| `two_phase_commit` | 288 | 11 | A state count too large to eyeball |
| `distributed_lock` | 34 | 7 | A product of param sets; a tuple in state |
| `raft_election` | 58,359 | 19 | Params drawn from the pre-state; an end state that is not a deadlock |
| `bounded_buffer` | 4,460 | 29 | A sequence, where order distinguishes states a set would not |
| `paxos` | 3,921 | 17 | A guard quantifying over a subset of the messages in flight |

Every one agreed on the first run. 322 tests, all green, ~47s (the corpus is
most of it). CI green on `main`: `check` (format / compile with
warnings-as-errors / test) and `verify` (regenerates every `expected.json` from
TLC and fails on drift).

Not built, and raising rather than pretending: liveness (`check_liveness: true`),
symmetry (`symmetry:`, `verify_symmetry:`), parallel exploration, Layers 1 and 3.

---

## WHAT THIS SESSION CHANGED

Two MRs, both merged: !13 (`raft_election` + `bounded_buffer`, issue #13) and
!14 (`paxos`, issue #14).

**Four bugs found by writing the entries, each fixed where it was found.**

1. `spec/07-examples.md` Example 2's headline safety property was **false**.
   `handle_vote_response` did not check the response's term, so a candidate that
   timed out twice counted a vote granted in the *earlier* term and two servers
   reached `:leader` in the same term — an 8-state counterexample. Real Raft
   drops such a response; the example now does too.
2. The same example's `terminal` said the network was empty, which no reachable
   end state satisfies — nothing removes a refusal, or a grant to a server that
   has stopped being a candidate. All 655 end states were reported as deadlocks.
3. §1.5 could not express a **negative range bound**: `-1` is unary minus applied
   to `1` in the AST, not an integer literal, and Paxos's `maxBal` is `-1` until
   the acceptor promises something.
4. A **`let` read by only one of the two compiled functions** warned in the
   other. A block compiles to a guard and a transition and both got every
   binding, so `let promises = …` before a `require` was an unused variable in
   the transition — and unsilenceable, since the guard does read it. A pure block
   makes an unread binding dead code, so each function now keeps what it reads.

**Two harness changes the ending specs forced.**

- `bin/tlc-expected` takes **two TLC passes** when a spec ends. `-continue` keeps
  an invariant violation from ending the search; a reached deadlock ends it
  regardless, leaving states on the queue. `bounded_buffer` reports 4,459 states
  at depth 28 that way and 4,460 at 29 when allowed to finish. `deadlock` comes
  from the first pass, the counts and verdicts from a second with `-deadlock`.
- The corpus tests compare **where the search stops**, not TLC's deadlock
  boolean, and hold a declared `terminal` to both halves of its claim: too narrow
  and a stuck state is still a deadlock, too broad and it comes back as
  `terminal_but_live`. That pair caught bug 2.

**One test-suite change.** Each entry is its own ExUnit module
(`test/support/differential_case.ex`) with a `setup_all` that searches once —
`setup_all` cannot live inside a `describe`, and separate modules let ExUnit run
the entries concurrently. The invariants TLC says hold are checked in one run
rather than one run each.

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
```

`bin/tlc-expected --check` is the oracle gate. Run it after touching any corpus
entry; CI runs it on every pipeline.

---

## OPEN PROPOSALS

- **#1 / `pm-1-verification-ledger.md`** — drift-gated coverage golden and
  spec-version stamps. Its Phase 1 items (`TLA.Spec.version/1`, the coverage
  golden, the JSON schema) are buildable now: `TLA.Coverage` exists and
  `mix tla.check --format json` emits structured output.
- **#7 / `pm-7-access-outside-domain.md`** — `balances[from]` compiles to
  `Access.get/2`, so `f[x]` outside the domain is `nil`, and `nil >= amount` is
  silently `true` under Erlang term order. TLA+ leaves it undefined. It can change
  spec semantics, so deciding it earlier costs less.
- **#11 / `pm-11-element-typed-collections.md`** — §1.5 cannot type the elements
  of a set or a sequence. Four of the six entries now want it: `msgs`,
  `messages`, `votes_granted` and `buffer` are all typed weaker here than in the
  TLA+ they are checked against, which means each of those entries can agree with
  TLC on `type_ok` for the wrong reason.

---

## RESUME HERE

The choice is Phase 2 or the proposals above.

**Phase 2** (`spec/06-architecture.md`) is liveness, and it is a bigger piece
than anything in Phase 1: the opt-in edge table and per-fairness-constraint
ENABLED bits recorded while a state is materialized (D-5 as amended), Tarjan over
that graph, per-binding fairness (§5.2, D-15), then symmetry (D-17). Two corpus
entries already have the liveness answers written down and unchecked —
`raft_election`'s `eventually_elect_leader` is refuted by the term bound by
design, and `bounded_buffer`'s `no_consumer_starvation` excepts the drained end
state — so Phase 2 has its first two tests waiting for it.

**#7 is the cheapest thing to decide first**, because it is the one that could
change what existing specs mean.

If Phase 2 starts with liveness in the corpus, note that TLC checks temporal
properties with `PROPERTIES` in the `.cfg` and reports them differently from
invariants; `bin/tlc-expected` parses invariant violations only, and would need
to learn the temporal report shape.

The user asked for this to run **as autonomously as possible**.
