# Changelog

All notable changes to ExTLA are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**What is built** — module by module, phase by phase — lives in
[`spec/06-architecture.md` §Implementation Phases](spec/06-architecture.md#implementation-phases),
which is the single source of truth for that. This file records what *changed* and when, and
does not restate it.

## [Unreleased]

`mix.exs` reads `0.3.21-dev`: the `-dev` suffix is what keeps a commit from claiming to be the
release it merely follows.

### Fixed

- **`enabled:` on a Layer 1 declaration only ever worked for a literal `false`, so the
  documented way to compile out an expensive check did nothing** (#149). `03-layer1-invariants.md`
  §162 specifies the option as evaluated at compile time, and §634 gives the idiom:

  ```elixir
  invariant :expensive_check, enabled: Mix.env() == :test do
    deep_structural_audit(state)
  end
  ```

  Declaration options are stored with `Macro.escape/1` and read back as literals, which is
  right for `desc:` and `callbacks:`. It is wrong for this one: `Mix.env() == :test` was kept
  as a `{:==, _, _}` tuple, and the filter that decides emission keeps everything but `false`
  and `nil`. A tuple is truthy, so **every expression enabled the declaration**, whatever it
  evaluated to. The option worked for the one input that makes it pointless, since a literal
  `false` is indistinguishable from deleting the declaration.

  **A stock production release was not affected** — `MIX_ENV=prod` resolves the whole layer to
  `:disabled`, so lever 3 saved what lever 1 did not. What paid for it was `:dev`, which is
  `:enabled` by default and is where "compile this out except in test" most obviously means
  something, and any deployment setting `mode:` explicitly, `:log_only` in staging being the
  documented case.

  `enabled:` is now evaluated in the caller at its compile time, so `Mix.env()`, a module
  attribute and `Application.compile_env/3` all work — the last of which also registers its
  recompilation dependency properly, which evaluating it by hand would not. A value that is
  not a boolean is refused naming the declaration rather than accepted as truthy. The option
  covers all four declaration kinds, three of which had no test for it at all.

  **This changes behaviour for existing code.** A declaration carrying
  `enabled: <any expression>` was being emitted regardless and now is not, if the expression
  is false where the module compiles. That is the point, and it is worth checking against any
  suite that was passing because a check it thought disabled was in fact running.

- **A `temporal` block accepted an assignment, so one mistyped `==` produced a property that
  always passed** (#150). `02-dsl-semantics.md` §1.2 makes `=` on a declared variable a compile
  error outside `init` and `action`, and that rule was enforced for `invariant`, `terminal` and
  `action_property` — all three reach it through `TLA.Spec.Block.desugar_predicate!/2`.
  `temporal` does not desugar; it goes to `TLA.Spec.Temporal.parse!/2`, which never saw the
  check. So `temporal :no_starvation do waiting = [] end` compiled.

  **It is the one declaration whose failure is silent.** An invariant that never fires shows up
  in the coverage report as never enabled. A temporal formula built from an assignment is not
  refutable, so the search reports that the property *holds* — a green verdict for a property
  that checked nothing, which is Design Principle 6 defeated by one character, underneath the
  vacuity detection that exists to catch exactly this one layer down.

  The rule now lives in one place, `TLA.Spec.Block.reject_assignment!/2`, called from both
  paths, so the two forms cannot drift into two dialects again. Neither path descends into
  nested expressions — `always(x = 1)` is still accepted — and that limit is now shared rather
  than differing between them; widening it is a separate decision, since `=` inside a call is
  legal Elixir a spec author could conceivably mean.

## [0.3.20] — 2026-09-09

**A minor line, and the patch number does not start at zero.** Two of the changes below move
the public surface in ways a patch number promises not to: `TLA.Coverage`'s `observe_action/5`
is gone, replaced by `observe_enabled/3` and `observe_generated/4`; and a `schema_version: 1`
JSON document, which `mix tla.check` wrote under v0.2.0, is now refused rather than read. Three
more are additions — `TLA.Trace.explore/3`, `mix tla.explore`, and `TLA.Profile` with
`mix tla.check --profile`. `RELEASING.md`'s bar is whether someone decides the public surface
moved, and it moved on five counts.

The `20` is the commit count since the last of those five landed (#135, `bf14e81`), not since
`v0.2.0`. Everything after it — #137 through #147 — is fixes and CI work that a patch number
describes correctly, so the version says both things at once: the line opened there, and twenty
commits of patch-level work followed. `v0.3.0` is tagged at `bf14e81` to mark the opening;
`RELEASING.md` §*The base tag is a marker* says why that tag has to exist.

### Added

- **`TLA.Trace.explore/3` — evaluate your own named expressions at every state of a
  counterexample** (#115, #120). A trace is nineteen raw variable dumps and the reader does the
  arithmetic; this puts named expressions down the rows and states across the columns, so the
  question a reader actually has ("when did quorum form?") is answered by looking rather than by
  counting.

  ```elixir
  TLA.Trace.explore(trace,
    waiting: &length(&1.waiting),
    holder:  & &1.holder,
    quorum?: &(map_size(&1.votes) * 2 > 3)
  )
  ```

  Three arguments rather than two, deliberately: options live in `opts`, so an expression named
  `:changed_only` stays representable and cannot silently become a flag. Rows render in the order
  given — the caller's order is information, so it is not sorted.

  **Columns are chunked to a width budget** (`width: 68`, matching `format/1`'s banners) with the
  name column repeated in each chunk, because the trace that motivated the feature does not fit on
  one screen and `changed_only: true` cannot be relied on to narrow it — an expression that moves
  at every step is exactly the case that stays wide.

  An expression that raises is reported **at the state it raised in**, carrying
  `Exception.message/1`; the rest of the table still renders. A failure that is displayed and
  attributed beats one swallowed into a blank cell. Lassos go through `to_behavior/1`, so the
  repeating columns are marked, and a `cycle: nil` lasso is not given a fabricated cycle.

- **`mix tla.explore` — the same table from the command line, over a saved counterexample**
  (#115, #121).

  ```
  mix tla.explore Specs.DistributedLock --trace counterexample.json \
    --expr "waiting: length(state.waiting)" \
    --expr "quorum?: map_size(state.votes) * 2 > 3" \
    --changed-only
  ```

  An expression is a function and cannot be written on a command line, so `--expr` is repeatable
  and each one is compiled with the state's variables in scope — the TLA+ Toolbox's approach, and
  it needs no DSL macro. Dropping the `name:` prefix uses the expression text as the row label. An
  `--expr` that does not compile fails with the text, the reason, and **which** of several `--expr`
  flags it was, rather than a bare `CompileError` from inside the task.

  It reads what `mix tla.check --format json` writes, in either shape — the whole document or a
  single trace lifted out of it — and lassos work. The `<module>` argument is required because
  `Trace.from_json!/1` resolves atoms through `String.to_existing_atom/1`, so the spec module has
  to be loaded before a saved trace can decode.

  Note the word: this explores a **saved counterexample**, not the state space.
  `TLA.ModelChecker.explore/2` is the other thing, and the task name is the one place `explore`
  appears unqualified.

- `TLA.Profile` and `mix tla.check --profile` — what each of *your* declarations cost, per
  invariant, action guard, transition, action property and terminal (#116, #130). `TLA.Coverage`
  says how often the checker asked; this says what the answer cost, which is the half a spec
  author can act on.

  **Measured in reductions, not milliseconds.** Every performance number this project had was
  caveated by a CPU model and a load average — `bench/search_profile.baseline.md` records a
  `raft` run swinging from 23.4 s to 30.5 s on machine load alone — and a ranking that changes
  with the load average is not a finding. Under 32 competing processes the same fixed workload
  spread 100.3% in wall time and not at all in reductions.

  The cost reported is the per-evaluation **floor** times the evaluations, not the accumulated
  total: accumulating gave spreads of 26.7% and 47.8% between identical runs, while every
  declaration's floor came back a single value across eight loaded runs. Anything above the floor
  in one evaluation is the scheduler, not the predicate. A predicate whose cost genuinely varies
  with the state is the one thing a floor cannot see, so it is flagged rather than averaged away.

  Off by default, and free when off — the closures `TLA.Spec.Compiled` already holds are wrapped
  only when a profile is asked for, so no macro work and no recompilation is involved.

  Correct under `--workers` (#131): reductions are per-process, so each task collects its own
  contribution and `TLA.ModelChecker.Parallel.merge/2` sums them beside `TLA.Coverage.merge/2`.
  Per-declaration evaluation counts under `--workers 8` are identical to the single-worker
  counts, which is the property a merge can silently break while leaving the totals plausible.

### Fixed

- **The profile counted counterexample regeneration and liveness evaluation as if they were
  search work, so per-declaration transition counts were too high** (#133). **The numbers change**
  — a profile taken before this version is not comparable with one taken after it, and the
  direction is always downward.

  Two paths, and the larger was not the one that raised the issue. A **refuted** run replays its
  counterexample to turn a path back into states, which applied each transition once more per
  appearance in the trace: `audit_log` reported `record` 4 times against a search that applied it
  twice. A **`check_liveness: true`** run rebuilds *every* state to evaluate predicates over it,
  which inflated by roughly a whole extra search — 10 against 5 on a six-state spec — with no
  violation and no counterexample involved.

  The cause was one value doing two jobs: the instrumented spec was handed both to the search and
  to `TLA.StateGraph`, and everything that consults the graph's spec runs *after* the search has
  stopped. The graph now keeps the uninstrumented copy. Only `{:transition, _}` entries were ever
  affected — replay applies transitions and nothing else, so guards, invariants and action
  properties were always right.

  Guarded by an identity rather than by fixtures (#139): for a profiled run the sum of transition
  evaluations equals `result.transitions`, since the graph's counter is incremented on the line
  after each application. Asserted across eleven configurations, including `--workers` and
  `verify_symmetry`.

- **`coverage.bounded_by` said the counts were partial when a completed search merely found a
  deadlock** (#136). A deadlock is detected after the frontier empties, so such a run has counted
  everything — but it reached the same `:violation` as a run that stopped mid-expansion on an
  invariant, and `TLA_COVERAGE.md` marked its sections `LOWER BOUNDS` with a `≥` on every count
  that was in fact exact. The value is now derived from the search's own outcome rather than
  from the verdict it produced, so a completed search reports `:none` whatever it found.

  No new value and no schema change: the field means *are these counts complete, and if not why*,
  and `status: :violation` with `bounded_by: :none` is the correct pair — a problem was found,
  and everything was searched. Four of the ten `LOWER BOUNDS` sections in the golden lose the
  marking; the six that were genuinely truncated keep it.

- **A run that halted mid-expansion reported the offending action as never enabled** (#128). A
  counterexample would name `compact` in its trace while the coverage report in the same result
  called it never enabled and warned that its guard was broken. `TLA.Coverage.observe_action/5`
  is replaced by `observe_enabled/3` and `observe_generated/4`, because *was this action enabled
  here* and *how many states did it generate* are different facts known at different moments:
  enablement is now recorded when the guard admits a binding, which is true whether or not the
  expansion finishes.

  It was an off-by-one for as long as the checker has existed and became a false claim only when
  the true count is one — `die_hard`'s actions are enabled in eleven or twelve states, so losing
  one left eleven and looked like nothing. `TLA_COVERAGE.md` moves accordingly: one action per
  violating spec gains the occurrence it had been losing.

  `--strict-coverage` no longer fails a build on an action that was never enabled in a run
  bounded by `max_states` or a `state_constraint`: such a run cannot tell an action whose guard
  is never true from one whose states it never reached. A **complete** run still accuses.

### Changed

- **`spec/04-layer2-model-checker.md` now documents `mix tla.check`'s options correctly** (#132,
  #134). The spec denied that `--workers` was a flag — it has been one since Phase 4, and the same
  file documents `workers:` nine hundred lines earlier, so it disagreed with the code and with
  itself. Four of the nine switches were missing from the option lists (`--format`, `--max-states`,
  `--safety-only`, `--workers`), and the Usage block demonstrated two that have never existed
  (`--graph`, `--output`; `mix tla.visualize` is the task that draws graphs).

  No behaviour changes here — this is documentation catching up with the task. It is recorded
  because an example that cannot be run is worse than an absent one: a reader tries it and gets
  `OptionParser` refusing a flag the specification just showed them.

- **`mix tla.check --format json` is now `schema_version: 2`**, gaining a `profile` key that is
  `null` unless the run was profiled. Purely additive, and it bumps anyway: "additive changes do
  not count" is the reasoning that makes a version stop meaning anything, and this one exists so
  a reader can refuse a shape it does not know rather than misread it. `TLA.Mix.TraceFile`
  refuses a version-1 document naming both versions, and re-running `mix tla.check --format json`
  regenerates it.

## [0.2.0] — 2026-09-04

The documentation release. A getting-started guide and an eleven-page tutorial, with every
code block compiled from the page itself and every claimed verdict — status, property,
counterexample length, state count, never-enabled actions — asserted by the test suite, so a
guide that drifts from the tool fails the build. The gate came first and a throwaway guide
proved it went red, because nobody retrofits a gate to prose that already passes.

Two library changes travel with it. `TLA.Spec.Deps` records each block's read and write
variable sets at compile time — the foundation property-directed slicing needs (#87), and
sound by widening rather than by narrowing. And `TLA.Trace.validate/3` now requires a
**safety** trace to refute the property it names, a stricter contract than v0.1.0's and the
check that would have caught #112.

Still pre-1.0: the public surface may still move, and `spec/06-architecture.md` §Deferred is
written in terms of "past v1". Still not on Hex — that remains a separate decision.

### Changed

- `guides/tutorial/06-layer1.md` now covers what a team needs in order to adopt Layer 1: the
  smallest useful step (one invariant on a server you already have, no specification at all), a
  plain invariant violation, the three modes as real per-environment configuration and what
  `:disabled` actually means, `enabled:`/`callbacks:` for cost, `TLA.Invariant.Test` — including
  `refute_invariant`, because an invariant never seen false is indistinguishable from `true` —
  telemetry, and the other OTP behaviours including why an `Agent`'s checks cannot be compiled
  away (#104, #109).

- `guides/tutorial/03-invariants.md` now teaches writing properties, not only reading the report:
  a method for choosing what to assert, `desc:`, `action_property` as a section of its own with a
  step no invariant could catch — and **deadlock and `terminal`**, which is the first failure a
  reader meets and had two dismissive sentences in the whole tutorial. A one-shot lock that
  finishes its work is shown refuted as a DEADLOCK, fixed by declaring its end state at the same
  fifteen states, and then with a `terminal` broad enough to admit a live state (#104, #108).

- The tutorial's pages carry subheadings throughout, so every one has sidebar sub-entries and can
  be scanned; `05-symmetry.md` and `06-layer1.md` had none. `assert_spec` moves off the symmetry
  page — it is how a specification stays true as code changes, which nobody looks for under
  symmetry reduction — and the brittle "Part N of 8" headers are gone: a page states its
  predecessor, so adding one no longer renumbers the rest (#107).

### Added

- `guides/tutorial/09-when-it-explodes.md` — what to do when a run does not come back, every lever
  measured on one specification: reading a bounded run, shrinking constants (1,331 states to 64),
  symmetry (1,331 to 286), `--workers` and when it costs more than it saves, `--safety-only`,
  `state_constraint` with the two lessons people miss — a constraint that excludes little buys nothing, and one that restricts the
  variables your property is about buys a green run that means nothing — and fingerprint width.
- `guides/tutorial/10-in-your-project.md` — where specifications live, `assert_spec` with
  `strict_coverage`, what to run in CI and why a slow gate belongs outside `mix test`,
  `mix tla.visualize` with a real graph, `TLA.PropertyTest`, and `mix tla.replay --captured` for
  after an incident (#104, #111).

- `guides/tutorial/08-modelling.md` — deriving a specification from a system, on a job runner the
  tutorial has not already solved: which fields are state and which are derivable (with the
  measurement that a derivable field costs no states but buys an obligation, and a counterexample
  about your own bookkeeping when you get it wrong), constants against bounds, what is abstracted
  away and what that costs, how big to make it — 64 states at two jobs, 512 at three — and what
  was left out entirely (#104, #110).

- A gate over the **built** documentation: every internal link in `doc/*.html` must resolve, and a
  `docs` CI job builds the docs so it actually runs. It found ExDoc's sidebar home link 404ing on
  all 84 generated pages, and the README's `LICENSE` link 404ing on the front page — neither
  visible to a gate over source markdown, because the generator writes those links itself
  (#102, #103).
- `guides/tutorial/01-mathematics.md` — states, behaviours and actions; the specification formula
  and stuttering; safety versus liveness and why their counterexamples have different shapes;
  ENABLED and the two fairness strengths; refinement as implication; how a model check verifies an
  algorithm, and what a green run, a counterexample and a bounded run each claim — with the
  bounded run demonstrated rather than described. Plus what the method is and is not useful for
  (#101).
- The guide harness takes `max_states=` and `expect=incomplete`, so a page teaching that a bounded
  run is not a verdict must produce one (#101).
- `guides/tutorial/00-introduction.md` — the history and purpose of formal verification, TLA and
  TLA+ and where they come from, a survey of the other tool families and of the Elixir/Erlang work,
  and where ExTLA sits in both. It summarises and links `spec/00-prior-art.md` rather than copying
  it, and `research/tla-plus-primer.md` now ships and renders so its citations resolve (#100).
- The tutorial is a multi-page guide under `guides/tutorial/`, read in order, and guides are
  checked in sorted path order — a page may use a module an earlier page compiled, and the
  numbering is that dependency (#99).
- Every relative link in a guide is checked: the file exists and the anchor is a heading it has,
  using ExDoc's own slug. The check #96 and #97 ran by hand, made a test — it caught eleven links
  the split had broken before anyone read the page (#99).
- `guides/getting-started.md` — installation to a deliberate invariant violation, read action
  by action — and the tutorial: the DSL in practice, the coverage report, weak against
  strong fairness on one spec, symmetry and `--verify-symmetry`, Layer 1 on a GenServer, and
  Layer 3 conformance through simulation and replay. Every code block in a guide is compiled
  from the page itself and its claimed verdict — status, property, counterexample length,
  state count, never-enabled actions, an unsound symmetry, a simulation finding, a raise — is
  asserted by the test suite, so a guide that drifts from the tool fails the build (#95, #96,
  #97). Both ship in the package and render under `mix docs` in a Guides group.
- `TLA.Spec.Deps` — each action's read and write variable sets, and each invariant's read set,
  derived from the block AST at compile time and carried on the compiled spec. Widening is the
  default: a read set is `:all` unless every node is recognised (#91).
- `bin/check-stream-data-fallbacks.exs`, run by CI's `consumer-compile` job: the three
  `stream_data` fallback functions now execute on every pipeline and are asserted to raise with
  a message naming the missing dependency. They had never been run anywhere (#90).
- CI records the memory ceiling, host memory, load and core count in every job log (#86, #88).

### Fixed

- An `action_property` counterexample pointed at the wrong step. The trace was built from the
  post-state's graph id, so when that state had already been discovered by a shorter route the
  parent pointers described *that* route: the offending step was absent and the step the trace
  marked could satisfy the property it was offered as a refutation of. It is now built from the
  pre-state's path with the offending step appended. Invariant and deadlock traces are unchanged
  and correctly so — those are claims about a state, where any path reaching it is a fair
  counterexample (#112, #113).
- `TLA.Trace.validate/3` now requires a **safety** trace to refute the property it names — an
  invariant false in the final state, an action property false over the final step. It previously
  checked only that a trace was a legal path from an initial state, which a fabricated
  counterexample passes; that is how the defect above went unnoticed. The docstring's
  "deliberately does not check" section is corrected to say the exclusion is liveness-only, where
  `TLA.TemporalCheck` is an independent implementation (#112, #113).

- The near-miss column's documentation. `getting-started.md` called it opt-in and said an
  invariant "declares what a near miss would be"; it is **derived** from the invariant's shape —
  a top-level `or` yields a probe and anything else reports `nil`, meaning *not measured*. The
  guide now says which shape produces one, `spec/04` no longer contradicts itself about the
  atomic-bound case, and that case is recorded as deferred rather than described as though it
  worked. `near_miss/1`'s two outcomes are pinned by doctests (#105, #106).

- The documentation's home link. `README.md` and `spec/README.md` both derived the id `readme`,
  ExDoc disambiguated them to `readme-1`/`readme-2`, and `main: "readme"` went on naming a page no
  build produced. The spec index is now `spec-readme` with a real sidebar title, leaving `readme`
  to the page that should own it; `LICENSE` ships as an extra so the README's link to it resolves
  (#102, #103).

- The coverage task's drift and missing-file branches are tested; both had never executed (#84).
- `README.md`, the phase-4 handoff and `.gitlab-ci.yml`'s header each asserted something no
  longer true. Phase status now lives only in `spec/06-architecture.md` §Implementation Phases
  (#80).
- Test artifacts under `tmp/` are untracked and ignored (#81).

### Infrastructure

- CI fetches the `surfex` dependency over the CI job token; it had been declared over SSH, which
  the runner image cannot use, leaving `main` red for five merges with all three `verify` gates
  reporting `skipped` rather than `success` (#71).
- Merges now require a passing pipeline, and a **skipped** pipeline does not count (#72).

## [0.1.0] — 2026-09-02

The first tagged release. Four implementation phases, complete on the terms
`spec/06-architecture.md` set for each.

Pre-1.0 deliberately: the public surface may still move, and `spec/06-architecture.md`
§Deferred is written in terms of "past v1". This tag is a reference point, not a
compatibility promise.

### Added

- **Phase 1 — the DSL and safety checking.** Specifications written as Elixir
  (`TLA.Spec`), exhaustive breadth-first model checking (`TLA.ModelChecker`), the implicit
  `type_ok` invariant, shortest-counterexample traces, and `TLA.Coverage` reporting what a
  run actually exercised. `mix tla.check`.
- **Phase 2 — liveness.** Temporal properties and weak/strong per-binding fairness over an
  SCC-based liveness graph, lasso counterexamples, and symmetry reduction with
  `verify_symmetry:` to make an unsound declaration detectable.
- **Phase 3 — Layer 1 and the conformance bridge.** Invariants on running processes
  (`TLA.GenServer`, `TLA.Invariant`), `TLA.Refinement`, and checking an implementation
  against a spec: `mix tla.simulate` and `mix tla.replay`.
- **Phase 4 — scale and ecosystem.** Level-synchronous parallel exploration
  (`TLA.ModelChecker.Parallel`, **5.40x at 8 workers**), `TLA.PropertyTest`, and
  `mix tla.visualize` (DOT).
- **The verification ledger.** `TLA_COVERAGE.md`, a drift-gated record of every spec item
  and the evidence covering it, with per-item content versions and a `spec_version:` stamp
  that makes a stale refinement mapping a compile error.
- **Measured gates.** `mix tla.mutants` and a 13-mutant catalogue, `TLA.Trace.validate/3`,
  `TLA.GraphAudit`, `TLA.Conformance.against_graph/3`, and generated models via
  `TLA.SpecGenerator`.

### Verified against

- **TLC, on every entry of the differential corpus** — `die_hard`, `two_phase_commit`,
  `distributed_lock`, `raft_election`, `bounded_buffer` and `paxos` — agreeing on distinct
  states, depth, where the search stops, every invariant, every temporal property, and the
  shortest counterexample where one exists. `expected.json` is regenerated from TLC on every
  pipeline, so these are measurements rather than fixtures. This is the project's acceptance
  criterion (`spec/08-decisions.md` D-9), not a follow-up to it.

### Performance

- `raft_election` went from 23.4 s to 1.65 s during Phase 4 — 2.65x from validating each
  state once at discovery (D-26), then 5.40x from the workers (D-27) — with the corpus
  agreeing with TLC at 1, 2, 4 and 8 workers throughout.

### Not included

- No Hex release. This tag marks a point in history; publishing is a separate decision.
- `Mix.Tasks.Tla.Gen.Test`, HTML/D3 visualisation, `TLA.Supervisor.Spec` and view
  abstraction are deferred past v1 — see `spec/06-architecture.md` §Deferred for why each.

[Unreleased]: https://gitlab.conet.yarina.org/dco-tek/extla/-/compare/v0.3.20...main
[0.3.20]: https://gitlab.conet.yarina.org/dco-tek/extla/-/tags/v0.3.20
[0.2.0]: https://gitlab.conet.yarina.org/dco-tek/extla/-/tags/v0.2.0
[0.1.0]: https://gitlab.conet.yarina.org/dco-tek/extla/-/tags/v0.1.0
