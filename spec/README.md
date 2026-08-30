# ExTLA Specification

**ExTLA** — TLA+-inspired formal verification for Elixir/OTP systems.

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│  Layer 3: Conformance Bridge                        │
│  TLA.GenServer — step legality against the spec     │
│  TLA.Replay    — counterexample + trace validation  │
├─────────────────────────────────────────────────────┤
│  Layer 2: Specification DSL + Model Checker         │
│  TLA.Spec      — state machines, actions            │
│  TLA.Coverage  — what the run actually exercised    │
├─────────────────────────────────────────────────────┤
│  Layer 1: Runtime Invariant Checking                │
│  TLA.Invariant — design-by-contract for GenServers  │
├─────────────────────────────────────────────────────┤
│  Foundation: Core Types & Operators                 │
│  TLA.Temporal, TLA.Set, TLA.State, TLA.Fingerprint  │
└─────────────────────────────────────────────────────┘
```

The layers describe **verification power**, not build order. Build order is
`06-architecture.md` §Implementation Phases, and it starts with Layer 2 — see
[D-8](08-decisions.md).

## Documents

| Document | Content | Status |
|---|---|---|
| [01-foundation.md](01-foundation.md) | `TLA.State`, `TLA.Temporal`, `TLA.Set`, `TLA.Function`, `TLA.Fingerprint`, `TLA.Config` | Specified |
| [03-layer1-invariants.md](03-layer1-invariants.md) | `TLA.Invariant` — runtime invariant checking | Specified |
| [02-dsl-semantics.md](02-dsl-semantics.md) | **Normative DSL semantics.** Name resolution, action semantics, nondeterminism, compile-time validation | Specified |
| [04-layer2-model-checker.md](04-layer2-model-checker.md) | `TLA.ModelChecker`, `TLA.StateGraph`, `TLA.Trace`, `TLA.Coverage`, state-space reduction | Specified |
| [05-layer3-conformance.md](05-layer3-conformance.md) | `TLA.GenServer`, `TLA.Refinement`, `TLA.Replay`, `TLA.Simulation` | Specified |
| [06-architecture.md](06-architecture.md) | Dependency graph, data flow, storage, phases, non-goals, performance targets | Specified |
| [08-decisions.md](08-decisions.md) | Design decisions and their rationale | Living |
| [07-examples.md](07-examples.md) | The acceptance corpus: distributed lock, Raft election, producer-consumer, counter | Specified |
| [00-prior-art.md](00-prior-art.md) | Survey of existing tools and the gap ExTLA fills | Specified |

No implementation exists yet. Every "Specified" above means the design is written down,
not that it is built.

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
