# HANDOFF — 2026-08-31 — Phase 4 can start; start here

Supersedes `HANDOFF-2026-08-31-phase3-done.md`. Self-contained; read it first.

Phases 1, 2 and 3 are done on the terms the project set for itself. Phase 4's entry
condition is met and its shape is measured rather than assumed. **The first thing to do is
not Phase 4** — see WHAT IS NEXT.

---

## WHERE THINGS STAND

**Phase 1 and 2** — the model checker, safety and liveness, measured against TLC. The
differential corpus (`test/differential/`, D-9) is the acceptance criterion: ExTLA agrees
with TLC on all six entries — distinct states, search depth, where the search stops, every
invariant, every temporal property, and the **length** of the shortest counterexample.

**Phase 3** — Layer 1 (runtime invariants on GenServers, `:gen_statem` and `Agent`s, plus
the ExUnit helpers) and Layer 3 (the conformance bridge, replay, simulation, and the two
mix tasks). §03 and §05 are complete against their own specifications. The pipeline in §05
§Full verification pipeline runs end to end, as a test.

**Milestone *Parallel-exploration readiness*** (#28, closed) — the three items §06 asks
for before `TLA.ModelChecker.Parallel`:

- **#29** `workers: n > 1` **raises**. It used to be accepted and ignored: a
  single-threaded run reported as `:ok` for a request for four processes.
- **#30** `bench/search_profile.exs` and `bench/search_profile.baseline.md`. Not a
  profiler — `:eprof` lives in OTP's `tools`, absent from this build and from CI's image —
  so each phase is measured by doing it through the checker's own public functions.
- **#31** the graph's tables are `:public`, insertion is race-free (`insert_new` + an
  atomic id), and 24 processes registering the same state concurrently get one id.

568 tests, all green, ~80s. CI green on `main`: `check` (format / warnings-as-errors /
test) and `verify` (regenerates every `expected.json` from TLC and fails on drift).

---

## THE TWO NUMBERS THAT SHOULD SHAPE PHASE 4

From `bench/search_profile.baseline.md`, `raft_election` at the corpus constants — 58,359
states, 255,270 transitions, 23.4s on one core:

**The shared table is 0.2% of the search.** §06 §Concurrency Architecture is written around
ETS as "the only contended structure". It is, and it is nearly free. 93% of the work is
per-successor computation over no shared state at all. **A parallel design's cost is
coordination — batching, collecting the frontier, merging accumulators — not contention.**
This is why #31 shipped `:public` and deliberately *not* `write_concurrency`: it measures
1.39x slower single-writer, and what lock granularity a coordinator wants depends on how it
batches its writes.

**`State.validate!` is 78% of that search**, and it runs on every successor including
states already seen — 255,270 validations where 58,359 would do. That is #33.

---

## WHAT IS NEXT

**A. #33 — validate once, at discovery.** The largest win available, on one core, and it
comes first: parallelising before it spends most of the parallelism on work #33 deletes.
It is a proposal rather than a patch because "validate at discovery" is a claim about
§6's guarantee (a forbidden term surfaces, naming the variable) and not only about speed.
The subtlety to settle is ordering: validation must stay *before* the state is
fingerprinted for dedup, since a forbidden term is exactly what makes a fingerprint
unreliable.

**B. #34 — parallel exploration.** Filed and shaped, four work items, with the design
constraint that matters written down: **level-synchronous BFS**, because D-9's corpus
compares the *length* of the shortest counterexample. Length, not route — a parallel run
may return a different trace of the same length and the corpus still holds; a free-running
frontier can change the length, which trades the acceptance criterion for throughput.
Liveness is out of scope and should *refuse* alongside `workers:`, the way D-22 refuses
symmetry with liveness.

**C. #1 — the verification ledger.** Open since the beginning: the coverage report is not
drift-gated the way `expected.json` is. The last "measured, not asserted" gap.

**D. Phase 4's other two entries, unfiled.** `mix tla.visualize` (DOT only) needs
`TLA.StateGraph.to_dot/2` and `to_json/1`, both specified in §State Graph and both unbuilt
— no open design question. `TLA.PropertyTest` is greenfield; generated test *files*
(`mix tla.gen.test`) are deferred past v1 deliberately (§06 §Deferred).

**E. #32** — filed by someone else during the last session: `action_property` warning about
an unused `old`/`new` binding. Not evaluated here.

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
mix tla.simulate MyApp.Server --traces 1000        # Layer 3, random walks
mix tla.replay MyApp.Server --trace ce.json        # Layer 3, a spec-level behaviour
mix run bench/search_profile.exs [buffer|raft]     # where the search spends its time
bin/tlc-expected --check                           # the oracle gate; CI runs it
```

**`pm/` is not a complete mirror right now.** Issues #28–#34 live in GitLab only; the older
work items have `pm/` files and are in `pm/closed/`. If GitLab goes unreachable, reconstruct
from `glab issue view` output before it does, or work from this handoff.

**Per-milestone worktrees are not usable here.** CLAUDE.md describes
`~/Projects/claude-tools/worktree.exs`; that directory does not exist on this machine, and
neither do `mem_append.exs`, `mem_lint.exs` or `ensure_labels.exs`. Work in the main
checkout and say so.

---

## THINGS THAT WILL BITE

- **Read a wall time with the load average beside it.** A `raft` run that baselines at
  23.4s came out at 30.5s on a box at load 7, with the measured phase numbers moving under
  8%. Any A/B that is not *interleaved* on the same machine will find regressions that are
  not there. `bench/search_profile.baseline.md` says this too.
- **Do not emit a `case` on a tagged return into a user's module.** Elixir's type system
  proves things *inside* that module, so `case Runtime.initial_state(super(arg))` has a
  provably dead arm — and the warning names the user's module, about code they did not
  write. Four constructs hit this; all now live behind a function taking `term()` or
  `module()`.
- **`Application.compile_env/3` does not expand inside a function body.** Why
  `TLA.Invariant.Agent`'s entry points are functions, and why `:disabled` costs an export
  lookup there (D-25).
- **`function_exported?/3` answers about a LOADED module.** Put `Code.ensure_loaded?/1` in
  front of it, or an optional callback on a cold module reports as absent depending on test
  order.
- **Never create atoms from a file.** `TLA.State.Json` decodes with
  `String.to_existing_atom/1`. An earlier version measured `:erlang.system_info(:atom_count)`
  across the conversion to name the missing atom, and CI refuted it: the count is global, so
  a concurrent test creating an atom looks like this one.
- **Comparing two `run/2` results with `==` includes `duration_ms`.** That test passes only
  when both runs land in the same millisecond.
- **A liveness verdict needs a complete graph.** `Liveness.check/3` raises rather than
  answer from a partial edge table, and a Layer 3 trace has no lasso, so the temporal
  properties needing one are `:inconclusive` by construction.
- **`params` from `abstract_action/1` may be partial, and that is not leniency.** Every
  binding extending the given ones is a candidate; the step is legal if an *enabled* one
  reproduces the post-state.
- **A mapping fault is not a conformance failure**, and `:not_followed` is not one either:
  the spec permits a behaviour the code does not take, and which of the two is wrong is not
  something a checker can decide.
