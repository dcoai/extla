# HANDOFF — 2026-08-31 — Phase 3 is done; start here

Supersedes `HANDOFF-2026-08-31-phase3-layers-built.md`. Self-contained; read it first.

**Phase 3 is complete against its own ledger.** Every module `06-architecture.md` §Phase 3
lists is built, and its deliverable — *a spec, a counterexample from it, and that
counterexample replayed against the real GenServer* — runs end to end in
`test/mix/tla_replay_test.exs`. What is left is a choice again, and the options are at the
bottom.

---

## WHERE THINGS STAND

**Phases 1 and 2** are done on the terms the project set for itself: the differential
corpus is the acceptance criterion (D-9), and ExTLA agrees with TLC on all six entries —
distinct states, depth, where the search stops, every invariant, every temporal property,
and the shortest counterexample where there is one.

**Phase 3, in seven merged MRs:**

| # | What |
|---|---|
| 21 | `TLA.Refinement`, `validate!/3`, and the conformance corpus with six mapping mutants |
| 22 | Layer 1's GenServer engine — the macros, the wrapping, `:disabled` emitting nothing |
| 23 | Layer 1 for `:gen_statem` and `Agent`, and `TLA.Invariant.Test` |
| 24 | The conformance bridge: `TLA.GenServer`, `check_step!/5`, and the three step mutants |
| 25 | `TLA.Replay` — a counterexample run against the code, a captured trace checked offline |
| 26 | `TLA.Simulation`, its message generator, and `mix tla.simulate` |
| 27 | A trace format that round-trips, and `mix tla.replay` |

564 tests, all green, ~80s. CI green on `main`: `check` (format / warnings-as-errors /
test) and `verify` (regenerates every `expected.json` from TLC and fails on drift).

**§03 and §05 are complete against their own specifications**, and that was checked rather
than asserted — it is the failure Phase 2's ledger correction was about. `TLA.PropertyTest`
and `mix tla.gen.test` are Phase 4; `TLA.Supervisor.Spec` and generated test *files* are
deferred past v1 deliberately (§06 §Deferred).

---

## THE THREE ROWS THAT CARRY THE LAYER

**`CollapsesTwoSteps`** — Example 4's own bug, an `increment` that also does `done`'s work.
**Every invariant of the spec holds in its post-state.** A Layer 3 that checked only
invariants and action properties reports conformance on it. The step check reports
`:diverged` with the one-variable diff on `status`, and the corpus test asserts *both*
halves.

**`Impl.Conforming` under the unrestricted generator** — caught as `:not_enabled`. Its
`handle_call(:done, …)` has no guard of its own, so it accepts `:done` where the spec's
`done` is disabled. A true finding about the pair, and about nearly every server ever
written — which is why the enabled-only generator is the default and the other is
`mix tla.simulate --unrestricted`.

**`BuggySpec` replayed** — a specification that contradicts itself, a server that refines
it exactly, and `mix tla.check --format json | mix tla.replay --trace` reproducing the
design bug in the running code.

---

## WHAT IS NEXT

**A. #1, the verification ledger.** Small, open since the beginning, and the last
"measured, not asserted" gap: the coverage report is not drift-gated the way
`expected.json` is. Buildable now, and Phase 3 made it more valuable — there is more to
cover.

**B. Phase 4's parallel exploration.** `workers:` still raises. The ETS shape the graph has
was chosen for it, and it is the cheapest large factor left after symmetry. Nothing in the
corpus says the state-space wall is being hit yet.

**C. Phase 4's `TLA.PropertyTest` / `mix tla.gen.test`.** The property helpers, not the
generated files — §06 defers the files deliberately.

**D. `mix tla.visualize`** (DOT only). `TLA.StateGraph.to_dot/2` and `to_json/1` are
specified in §State Graph and still unbuilt.

**E. #16's diagnostics half.** Not solver-guided pruning — proving a `terminal` admits
exactly the stuck states, proving a guard unsatisfiable before the run, proving `type_ok`
inductive.

Recommendation: **A, then B.** A is small and closes a stated gap; B is the only item that
changes what size of specification the tool can be pointed at.

---

## HOW THE WORK IS RUN

```bash
glab issue list                                    # the queue
glab issue create --label In-Progress --title …    # one pm/ file per issue, mirrored
git checkout -b feat/<slice>
mix format && mix compile --warnings-as-errors && mix test && bin/tlc-expected --check
glab mr create --source-branch <branch> --target-branch main --title … --yes
until … glab ci status --branch <branch> --live=false …                 # wait for green
glab mr merge <n> --yes --remove-source-branch && glab issue close <n>
```

`pm/` mirrors the GitLab issues; a closed one moves to `pm/closed/`.

```bash
mix tla.check Specs.X --format json                # Layer 2, machine-readable
mix tla.simulate MyApp.Server --traces 1000        # Layer 3, random walks
mix tla.replay MyApp.Server --trace ce.json        # Layer 3, a spec-level behaviour
mix tla.replay MyApp.Server --captured incident.json
bin/tlc-expected --check                           # the oracle gate; CI runs it
```

---

## THINGS THAT WILL BITE

- **Do not emit a `case` on a tagged return into a user's module.** Elixir's type system
  proves things *inside* that module, so a `case` on `Runtime.initial_state(super(arg))`
  has a provably dead arm — and the warning names the user's module, about code they did
  not write. Four constructs hit this; all now live behind a function taking `term()` or
  `module()`. Recorded in §03 and §05.
- **`Application.compile_env/3` does not expand inside a function body.** Why
  `TLA.Invariant.Agent`'s entry points are functions, and why `:disabled` costs an export
  lookup there (D-25).
- **`function_exported?/3` answers about a LOADED module** and reports every optional
  callback of a cold one as absent. A drivable refinement reported itself undrivable
  depending on test order until `Code.ensure_loaded?/1` went in front of it.
- **A state machine's state is the `{state_name, data}` pair, everywhere** (D-24), and
  `:gen_statem`'s returns need their own extraction: `{:stop, reason, data}` and a
  GenServer's `{:stop, reason, state}` are the same shape carrying different things.
- **`params` from `abstract_action/1` may be partial, and that is not leniency.** Every
  binding extending the given ones is a candidate; the step is legal if an *enabled* one
  reproduces the post-state.
- **A mapping fault is not a conformance failure.** An unknown action name or a param the
  action does not take raises `ArgumentError` — reporting them as `:not_enabled` blames
  the implementation for a mistake in the mapping.
- **`:not_followed` is not a conformance failure either.** The spec permits a behaviour the
  code does not take, and which of the two is wrong is not something a checker can decide.
- **Never create atoms from a trace file.** The table is not collected. `TLA.State.Json`
  measures the atom table across the conversion rather than catching
  `String.to_existing_atom/1`'s error, which does not name the atom that failed.
- **A liveness verdict needs a complete graph** (unchanged): `Liveness.check/3` raises
  rather than answer from a partial edge table. A Layer 3 trace has no lasso, so the
  temporal properties needing one are `:inconclusive` by construction.

---

## OPEN ISSUES

- **#1 / `pm-1-verification-ledger.md`** — drift-gated coverage golden and spec-version
  stamps.
- **#16 / `pm-16-solver-guided-pruning.md`** — `Research`.
