# ExTLA Specification

**ExTLA** — TLA+-inspired formal verification for Elixir/OTP systems.

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│  Layer 3: Conformance Bridge                        │
│  ExTLA.GenServer — step legality against the spec     │
│  ExTLA.Replay    — counterexample + trace validation  │
├─────────────────────────────────────────────────────┤
│  Layer 2: Specification DSL + Model Checker         │
│  ExTLA.Spec      — state machines, actions            │
│  ExTLA.Coverage  — what the run actually exercised    │
├─────────────────────────────────────────────────────┤
│  Layer 1: Runtime Invariant Checking                │
│  ExTLA.Invariant — design-by-contract for GenServers  │
├─────────────────────────────────────────────────────┤
│  Foundation: Core Types & Operators                 │
│  ExTLA.Temporal, ExTLA.Set, ExTLA.State, ExTLA.Fingerprint  │
└─────────────────────────────────────────────────────┘
```

The layers describe **verification power**, not build order. Build order is
`06-architecture.md` §Implementation Phases, and it starts with Layer 2 — see
[D-8](08-decisions.md).

## Documents

| Document | Content | Status |
|---|---|---|
| [01-foundation.md](01-foundation.md) | `ExTLA.State`, `ExTLA.Temporal`, `ExTLA.Set`, `ExTLA.Function`, `ExTLA.Fingerprint`, `ExTLA.Config` | Specified |
| [02-dsl-semantics.md](02-dsl-semantics.md) | **Normative DSL semantics.** Name resolution, types, action semantics, nondeterminism, fairness, terminal states, compile-time validation | Specified |
| [03-layer1-invariants.md](03-layer1-invariants.md) | `ExTLA.Invariant` — runtime invariant checking | Specified |
| [04-layer2-model-checker.md](04-layer2-model-checker.md) | `ExTLA.ModelChecker`, `ExTLA.StateGraph`, `ExTLA.Trace`, `ExTLA.Coverage`, state-space reduction | Specified |
| [05-layer3-conformance.md](05-layer3-conformance.md) | `ExTLA.GenServer`, `ExTLA.Refinement`, `ExTLA.Replay`, `ExTLA.Simulation` | Specified |
| [06-architecture.md](06-architecture.md) | Dependency graph, data flow, storage, phases, non-goals, performance targets | Specified |
| [08-decisions.md](08-decisions.md) | Design decisions and their rationale | Living |
| [07-examples.md](07-examples.md) | The acceptance corpus: distributed lock, Raft election, producer-consumer, counter | Specified |
| [00-prior-art.md](00-prior-art.md) | Survey of existing tools and the gap ExTLA fills | Specified |

"Specified" above describes the **document**, not the code: it means the design is written
down. What is built is recorded in [`CHANGELOG.md`](../CHANGELOG.md), which
`bin/changelog_guard.exs` gates, and deliberately nowhere else
([06-architecture.md §Implementation Phases](06-architecture.md#implementation-phases) is the
record of the plan and its completion) — a second copy of build status is what let this page claim the
project was unbuilt for four phases after it shipped.

### File naming

`NN-name.md`, zero-padded, numbered in **dependency order** — the order in which the
documents build on each other, which is also the order to read them cover to cover. The
hyphenated `NN-` prefix matches the sibling `agentronic` project's spec convention.

`README.md` keeps its name rather than taking a number: GitLab renders it automatically
when the directory is browsed, so it is the index rather than a chapter. New documents
take the next free number; renumbering an existing one breaks every inbound reference and
is not worth it — gaps are fine.

## Reading order

1. **[00-prior-art.md](00-prior-art.md)** — why this should exist at all
2. **[02-dsl-semantics.md](02-dsl-semantics.md)** — what a spec *means*; the
   normative core, and the part most likely to be wrong
3. **[07-examples.md](07-examples.md)** — what it looks like in use
4. **[06-architecture.md](06-architecture.md)** — how it gets built, and what it will not do
5. **[08-decisions.md](08-decisions.md)** — why it is shaped this way

## Design Principles

1. **Elixir-native** — specs are Elixir code, not a separate language
2. **Incremental adoption** — each layer is independently useful
3. **Zero production cost** — `:disabled` emits no code, rather than cheap code
4. **OTP-aligned** — works with GenServer, Supervisor, and OTP conventions
5. **Test-integrated** — `mix test` runs verification; no separate toolchain
6. **Never claim more than was checked** — an incomplete run fails, a bounded run says
   so, a fingerprint width reports its collision margin, and a run reports which actions
   it never enabled. A verification tool that lets a green result overstate what it
   verified is worse than no tool.

## Non-goals

ExTLA is not a theorem prover, does not explore process interleavings, does not extract
models from source code, does not generate implementations from specs, and has no
real-time or probabilistic extensions. Each has a better tool already; see
`06-architecture.md` §Non-goals and `00-prior-art.md`.

## How this specification stays true

Three rules, each learned from a document that had stopped being true while reading as
though it were.

**A decision goes in `08-decisions.md`, in the merge request that makes it.** A commit
whose subject says *rather than*, *instead*, *refuse*, *never* or *one meaning* is
recording a decision, and the place for it is a new `D-` entry or an amendment to an
existing one. The log stopped on 2026-08-31 and fifteen decisions were made over the
following three weeks in commit messages and moduledocs, where nobody looking for the
project's reasoning would find them — and one of them, #160's option sets, silently
contradicted D-18. Every decision carries a `**Pinned by:**` line naming the test that
would fail if it were reversed, or `nothing — <why>`; `test/docs/spec_decisions_test.exs`
holds the two to each other.

**An enumeration of what the code declares is generated, never written** (D-32). Five
goldens — `API_SURFACE.md`, `CLI_SURFACE.md`, `DIAGNOSTICS.md`, `PACKAGE_SURFACE.md` and
`TLA_COVERAGE.md` — are produced from source and byte-compared by the `surface-drift` job.
A table in `spec/` that lists functions, switches, diagnostics or dependencies either *is*
one of those or is checked against one. Every hand-kept list this project has had was
wrong, and none of them announced it.

**A universal claim needs a gate or a qualifier.** "Every rule here is enforced at compile
time", "every code block on this page is compiled and run", "this section is the single
source of truth for what is built" — each was written truthfully and each became false as
the thing it described grew. A sentence with *every* or *always* above a list is a claim
about the list's completeness: gate it, or say which parts it does not cover.
