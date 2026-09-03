# Changelog

All notable changes to ExTLA are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**What is built** — module by module, phase by phase — lives in
[`spec/06-architecture.md` §Implementation Phases](spec/06-architecture.md#implementation-phases),
which is the single source of truth for that. This file records what *changed* and when, and
does not restate it.

## [Unreleased]

`mix.exs` reads `0.2.0-dev`: the `-dev` suffix is what keeps a commit from claiming to be the
release it merely follows.

### Added

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

[Unreleased]: https://gitlab.conet.yarina.org/dco-tek/extla/-/compare/v0.1.0...main
[0.1.0]: https://gitlab.conet.yarina.org/dco-tek/extla/-/tags/v0.1.0
