# HANDOFF — 2026-09-01 — Phase 4 is done; start here

Supersedes `HANDOFF-2026-08-31-phase4-start.md`, which should move to `pm/closed/`.
Self-contained; read it first.

---

## WHERE THINGS STAND

**Phases 1–4 are complete**, each on the terms the project set for itself.

Phase 4's three entries in `06-architecture.md` §Phase 4 all shipped, and that section now
says so rather than listing them as intentions:

- **`TLA.ModelChecker.Parallel`** — level-synchronous BFS, one coordinator, N workers, one
  shared ETS graph. **5.40x at 8 workers.**
- **`TLA.PropertyTest`** — `init_states/2` and `action_sequences/3`. `mix tla.gen.test` is
  *not* built and §05 now says so, citing §Deferred.
- **`mix tla.visualize`** (DOT only) — over the new `TLA.StateGraph.to_dot/2` and
  `to_json/1`.

**`raft_election` went from 23.4 s to 1.65 s** across the phase — 2.65x from validating
each state once at discovery, then 5.40x from the workers — with the differential corpus
agreeing with TLC throughout, at 1, 2, 4 and 8 workers.

**650 tests, all green, ~64 s. CI green on `main`**: `check` (format / warnings-as-errors /
test) and `verify` (regenerates every `expected.json` from TLC and fails on drift).

Two milestones closed: *Scaling the search* (#33, #34) and *Graph export and property-test
surface* (#35, #36).

---

## THE FIVE DECISIONS PHASE 4 MADE

Recorded as D-26 and D-27 in `spec/08-decisions.md`; the short forms, because they
constrain what can be built next.

**1. §6's term check runs at discovery, inside the state graph** (D-26). `validate!/1` was
77.9% of the `raft` search and ran on every successor. It now runs on the fingerprint-miss
branch of `add_state/5`. Sound for a reason specific to the forbidden terms: a pid,
reference, port, fun or float is exactly a term whose encoding does not recur, so a state
carrying one never dedups and is always validated on the path that reaches it first.

**2. Parallel exploration is level-synchronous, and it is not negotiable** (D-27). D-9's
corpus compares the **length** of the shortest counterexample. A free-running frontier does
not preserve length, because a violating state can be reached along a longer path before
the shorter one is expanded. The barrier per level is what that acceptance criterion costs.

**3. Workers register their own states.** Since D-26, `add_state/5` does fingerprinting and
the §6 check as well as the ETS write — 77% of the search — so a central registrar would
leave a quarter of the work parallel, which Amdahl caps near 1.3x. `insert_new/2` makes it
safe, and is also what makes the accumulators *summable*: nothing is counted twice because
nothing is done twice.

**4. `workers:` defaults to 1**, against §04's stated `System.schedulers_online()`. A
parallel search is exhaustive either way, so cores buy speed and not a better answer, and
how much of a machine to spend is the operator's decision. `TLA.Config.workers/0` derives
it for a caller who asks.

**5. Liveness is refused alongside `workers:`**, exactly as D-22 refuses symmetry with it.
The edge table and ENABLED bits are per-struct maps, so a parallel run would answer from a
graph missing another worker's edges, and a cycle spanning two workers would not exist to
be found.

---

## WHAT IS NEXT

The queue is three items, and none of them is Phase 4.

**A. #1 — the verification ledger.** Open since the beginning and now the oldest debt: the
coverage report is not drift-gated the way `expected.json` is. This is the last
"measured, not asserted" gap in the project, and with Phase 4 done there is nothing
competing with it. **Recommended first.**

**B. #32 — `action_property` warns about an unused `old`/`new` binding.** Filed during the
Phase 4 readiness work and never evaluated. Small, and a warning in code a user did not
write is the class of defect the project has already fixed four of.

**C. #16 — solver-guided pruning.** Carries `Research`, not `Proposal`, so it is **not**
ready for `/prop-eval` or `/prop-break-down`. The work there is shaping it into a concrete
proposal.

Recommended order: **A, then B.**

---

## HOW THE WORK IS RUN

```bash
glab issue list                                    # the queue
/prop-eval <n>                                     # accept, and assign a milestone
/prop-break-down <n>                               # work items inherit that milestone
/start-work <n>                                    # In-Progress, branch issue-<n>-<name>
mix format && mix compile --warnings-as-errors && mix test && bin/tlc-expected --check
/submit-review <n>                                 # commit, MR, Review
/complete-review <n>                               # merge, close, close the milestone
```

```bash
mix tla.check Specs.X --format json                # Layer 2, machine-readable
mix tla.check Specs.X --workers 8                  # parallel safety; implies safety-only
mix tla.visualize Specs.X --output g.dot           # DOT; `dot -Tsvg g.dot -o g.svg`
mix tla.simulate MyApp.Server --traces 1000        # Layer 3, random walks
mix tla.replay MyApp.Server --trace ce.json        # Layer 3, a spec-level behaviour
mix run bench/search_profile.exs [buffer|raft]     # where the search spends its time
mix run bench/search_profile.exs workers [entry]   # the 1/2/4/8 sweep
bin/tlc-expected --check                           # the oracle gate; CI runs it
```

**`pm/` is not a complete mirror.** Issues #28–#45 live in GitLab only; older work items
have `pm/` files in `pm/closed/`. If GitLab goes unreachable, reconstruct from
`glab issue view` before it does, or work from this handoff.

**Per-milestone worktrees are not usable here.** CLAUDE.md describes
`~/Projects/claude-tools/worktree.exs`; that directory does not exist on this machine, and
neither do `mem_append.exs`, `mem_lint.exs` or `ensure_labels.exs`. Work in the main
checkout and say so.

---

## THINGS THAT WILL BITE

The previous handoff's list still holds in full. What Phase 4 added:

- **Read a wall time with the load average beside it, and interleave every A/B.** This
  keeps being the trap. A `raft` run baselined at 23.4 s came out at 30.5 s at load 7 with
  the phase numbers moving under 8%; two "before" runs on different days differed by
  1,800 ms; and on a loaded box one arm's own spread reached 10x (1.8 s to 18.9 s) while
  the arms' minima differed by 3%. **I twice nearly recorded noise as a finding** — once a
  "regression" on `buffer` from a batching change that measured *better* when measured
  properly. Alternate arms within each round, compare minima, print each run.
- **`buffer` is too small to measure.** ~150 states a level over 29 levels, spread near
  90%. One sweep put 8 workers at 1.93x and the next at 0.89x. It stays in the sweep as a
  smoke check and its numbers mean nothing.
- **Do not set `write_concurrency: :auto`.** 7.6x slower, and the mechanism is an
  *interaction*: it decentralises the table's counters, so `:ets.info/2` with `:size` must
  sum them (1,832 ns against 105 ns) — and `max_states` reads that size before every
  expanded state.
- **`distinct_generated` is not comparable across runs.** It credits the action that
  reached a state *first*, which is a fact about search order. Its total is invariant; its
  split across actions is not. Nothing in the report derives from it.
- **A run that HALTED reports counts that are a lower bound**, and under workers a looser
  and varying one — the coordinator starts a whole level at once and halts on the first
  violation it receives. Verdict and counterexample length are comparable; counts are not.
- **State ids are not comparable across runs**, and have gaps under `workers:`. They are
  allocated at discovery, so the same terminal state is 4454 on one process and 4549 on
  eight. Read ids from the node table, never as `0..state_count - 1`.
- **A process cannot receive its own call traces.** `:erlang.trace(self(), true, [:call])`
  installs cleanly and delivers nothing; trace a child instead. And `trace_pattern` on an
  unloaded module matches 0 functions and *returns 0 rather than failing*, which reads
  exactly like "the function was never called" — `Code.ensure_loaded!/1` first, and assert
  the match count.
- **`stream_data` is dev/test-only, and `lib/` code must respect that.** Both
  `TLA.PropertyTest` functions sit behind `if Code.ensure_loaded?(StreamData)`, the shape
  `TLA.Invariant.Test` established. The `else` branch is never compiled under
  `MIX_ENV=test`, so it cannot be tested — say so rather than writing a test that only
  asserts the branch you can see.
- **A deferred report is not a missing report.** Parallel coverage was going to be a
  separate work item behind a warning; running `mix tla.check --workers 8` showed it
  emitting `action :consume was never enabled` — *false*, because `never_enabled` derives
  from `enabled_in: 0`, and `--strict-coverage` fails a build on it. A warning beside a
  false statement does not make it true. The merge shipped with the coordinator.
