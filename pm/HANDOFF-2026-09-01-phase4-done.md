# HANDOFF — 2026-09-01 — Phase 4 and *What the gates catch* are done; start here

Supersedes `HANDOFF-2026-08-31-phase4-start.md`, now in `pm/closed/`.
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

## SINCE THEN: two milestones closed

### *Warnings a consumer inherits* (#32, #51)

Two compile warnings that reached consumers and that ExTLA's own CI could not see, for the
same reason each time: **the condition producing them does not hold when ExTLA compiles
itself.**

- **#32** — a one-sided `action_property` warned about a binding the author never wrote.
  `quote generated: true` is the mechanism for suppressing that and it does not reach a
  node injected with `unquote/1`, so the flag went on the variables where they are built.
  The neighbouring macros are safe because their vars are `__MODULE__`-context and
  hygienic; `old`/`new` are `nil`-context of necessity, because the author writes them.
  **`extc` can now drop its `EXTC_SKIP_SPECS` workaround.**
- **#51** — an unused alias, visible only where `stream_data` is absent, which is how the
  library compiles as a dependency and never how it compiles here. The fix is one line;
  the guard is the point: a blocking **`consumer-compile`** job runs
  `MIX_ENV=prod mix compile --force --warnings-as-errors`.

**The lesson generalises, and is why these were one milestone:** ask what configuration
this project never builds itself in. Both defects lived exactly there.

Still open and *not* solved by that job: the `else` branches of all three
`Code.ensure_loaded?(StreamData)` gates compile clean but remain **unexercised**. Linting
them is not running them.

### *What the gates catch* is done

Five proposals (#46-#50), closed. The project's correctness gates were assertions about
themselves; they are now measurements.

- **#46** — `mix tla.mutants`, a 13-mutant catalogue, and `test/mutation/survivors.json`
  drift-gated in both directions. **11 killed, 1 survived, 1 timeout**, 8m33s, its own CI
  job.
- **#47** — `TLA.Trace.validate/3`, and an independent bounded re-search. Nothing had
  checked that a trace's consecutive states were connected by the actions it names.
- **#48** — `TLA.GraphAudit`: the edge table and stuck states against what the spec admits,
  the invariant partition, and fingerprint injectivity.
- **#49** — `TLA.Conformance.against_graph/3` and `mix tla.simulate --against-graph`.
- **#50** — `TLA.SpecGenerator` and seven metamorphic properties at unbounded extent.

**733 tests, ~78 s** (64 s before; the audits cost ~17 s and it is recorded in
`GraphAudit`'s moduledoc).

### The four findings worth carrying

1. **The sweep corrected its author twice.** `param_universe_from_the_right` survives the
   *corpus* and dies only in the suite — #39 had claimed the tests catch it, and they do,
   just not there. And `ignores_a_guard` can never be killed by a gate that has to finish.
2. **`drops_a_liveness_edge` survived every gate** and nobody predicted it. A missing
   out-edge makes a cycle unfindable, and an unfindable cycle is indistinguishable from a
   property that holds. #59 killed it.
3. **Two proposals asked for checks that could not fail.** #48's invariant partition is a
   tautology if `¬` is Elixir's `not`; what makes it real is the third bucket, since
   `Safety.check_invariants/4` reads the predicate with `if` and a truthy non-boolean
   silently reports `holds`. #49 asked for an implementation-vs-mapping split that
   `test/conformance/README.md` already says is undecidable. Both shipped in the shape that
   can fail, with the reasoning on the issues.
4. **Generated models do not make the corpus redundant, and #50 slightly overstated the
   case.** Of four mutants, three die to these properties and `drops_a_binding` does not —
   because every arm drops the same binding and agrees perfectly on a wrong answer, and
   because `BoundedSearch` and `GraphAudit` share `enabled_steps/3`, which is what the
   mutant patches. A defect in what the guards and transitions *mean* is invisible to
   everything that reads them. Only TLC sees it.

---

## WHAT IS NEXT

**A. #1 — the verification ledger.** Accepted, with its own milestone (*The verification
ledger*) and its three open questions answered at evaluation: per-item hashing, a HARD gate
from day one, and the file at the project root. **Not yet broken down.** One thing needs a
human decision before it can move: section (c) — extracting the generic golden machinery
into a shared leaf library — says "awaiting approval" and is agentronic's call under the
Cross-Project Boundary Rule. It has **not** been filed. The milestone builds ExTLA's own
renderer for its own golden, which does not presuppose the extraction.

**B. #16 — solver-guided pruning.** Still `Research`, so not ready for `/prop-eval` or
`/prop-break-down`. The work there is shaping it into a concrete proposal.

That is the whole queue. *Warnings a consumer inherits* (#32, #51) closed on 2026-09-01.

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
MIX_ENV=prod mix compile --warnings-as-errors      # the library as a consumer gets it
mix tla.mutants                                    # what the gates catch; writes survivors.json
mix tla.mutants --check                            # the drift gate (CI, ~8.5 min)
mix test --include mutation                        # the harness's own tests
mix tla.simulate MyApp.Server --against-graph      # Layer 2 vs Layer 3 containment
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

**Per-milestone worktrees ARE usable here.** An earlier revision of this handoff claimed
`~/Projects/claude-tools/` did not exist on this machine. That was wrong, and corrected on
2026-09-02 (#73/#80): all eleven scripts are present, including `worktree.exs`,
`mem_append.exs`, `mem_lint.exs` and `ensure_labels.exs`. `mem_append.exs` and `mem_lint.exs`
were both run successfully that day.

Use the main checkout anyway when only one milestone is active and one instance is running —
worktrees exist to parallelise *across* milestones, and a seeded one costs ~1.4 GB. The point
of this correction is that the option is available, not that it is always right.

**The lesson is about handoffs, not about worktrees.** "That directory does not exist" is a
claim with a one-second check behind it and a day of misdirection in front of it. A handoff
is read first and trusted; do not assert environment facts in one — say how to check.

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
- **Ask what configuration this project never builds itself in.** Both warnings in
  *Warnings a consumer inherits* lived exactly there — one needs a one-sided
  `action_property`, which no fixture here has, and one needs a build without
  `stream_data`, which nothing here was. `consumer-compile` closes the second; the first
  now has a test that reads stderr rather than a fixture.
- **A gate that cannot fail is worse than no gate**, and two proposals asked for one. Check
  whether a proposed check has an input that makes it red *before* building it: the
  invariant partition (#58) and the implementation-vs-mapping split (#60) both needed
  reshaping, and both reshapings are on their issues.
- **A metamorphic property sees only what differs between its arms.** A defect affecting
  every arm equally is invisible to it, and re-derivations that share `enabled_steps/3`
  inherit anything wrong with the spec's guards and transitions. That is the boundary of
  what the non-oracle gates can reach.
- **A deferred report is not a missing report.** Parallel coverage was going to be a
  separate work item behind a warning; running `mix tla.check --workers 8` showed it
  emitting `action :consume was never enabled` — *false*, because `never_enabled` derives
  from `enabled_in: 0`, and `--strict-coverage` fails a build on it. A warning beside a
  false statement does not make it true. The merge shipped with the coordinator.
