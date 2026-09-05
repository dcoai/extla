# Changelog

All notable changes to ExTLA are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**What is built** — module by module, phase by phase — lives in
[`spec/06-architecture.md` §Implementation Phases](spec/06-architecture.md#implementation-phases),
which is the single source of truth for that. This file records what *changed* and when, and
does not restate it.

## [Unreleased]

`mix.exs` reads `0.2.1-dev`: the `-dev` suffix is what keeps a commit from claiming to be the
release it merely follows.

### Added

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

### Changed

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

[Unreleased]: https://gitlab.conet.yarina.org/dco-tek/extla/-/compare/v0.2.0...main
[0.2.0]: https://gitlab.conet.yarina.org/dco-tek/extla/-/tags/v0.2.0
[0.1.0]: https://gitlab.conet.yarina.org/dco-tek/extla/-/tags/v0.1.0
