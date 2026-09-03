# ExTLA Architecture

System architecture, module dependency graph, and implementation strategy.

---

## Module Dependency Graph

```
                              ┌──────────────┐
                              │  mix tla.*   │  Mix tasks
                              │  CLI entry   │
                              └──────┬───────┘
                                     │
       ┌──────────────┬──────────────┼──────────────┬──────────────┐
       ▼              ▼              ▼              ▼              ▼
┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐
│ModelChecker│ │TLA.Coverage│ │ Simulation │ │ TLA.Replay │ │PropertyTest│
│            │ │            │ │            │ │            │ │            │
│.run/2      │ │.compute/2  │ │.run/2      │ │.counter-   │ │.action_    │
│.check_     │ │.format/1   │ │.run_trace/2│ │ example/3  │ │ sequences/3│
│ safety/2   │ │            │ │            │ │.trace/3    │ │            │
│.check_     │ │ never-     │ │            │ │            │ │            │
│ liveness/2 │ │ enabled,   │ │            │ │ replay a   │ │            │
│.explore/2  │ │ vacuity    │ │            │ │ CE or a    │ │            │
│            │ │            │ │            │ │ captured   │ │            │
│            │ │            │ │            │ │ trace      │ │            │
└─────┬──────┘ └─────┬──────┘ └─────┬──────┘ └─────┬──────┘ └─────┬──────┘
      │              │              │              │              │
      │              │        ┌─────▼──────────────▼──────┐       │
      │              │        │      TLA.GenServer         │       │
      │              │        │  defoverridable + super    │       │
      │              │        │  ┌──────────────────────┐  │       │
      │              │        │  │ GenServer.Runtime    │  │       │
      │              │        │  │  .check_step!/5   ◄──┼──┼───────┼── THE
      │              │        │  │  .check_stuttering!  │  │       │  refinement
      │              │        │  └──────────────────────┘  │       │  check
      │              │        └─────────────┬──────────────┘       │
      │              │                      │                      │
      │              │        ┌─────────────▼──────────────┐       │
      │              │        │      TLA.Refinement        │       │
      │              │        │  .abstract/1               │       │
      │              │        │  .abstract_action/1        │       │
      │              │        │  .concrete_message/2  ─────┼───────┘
      │              │        │  .validate!/2 (compile)    │
      │              │        └─────────────┬──────────────┘
      │              │                      │
 ┌────▼──────────────▼──────────────────────▼────────────────────────┐
 │                        TLA.Spec.Compiled                           │
 │  constants · variables · init fns · actions (pure in pre+params)   │
 │  invariants · action properties · temporal formulas · fairness     │
 └────────────────────────────┬───────────────────────────────────────┘
                              │
                 ┌────────────▼────────────┐
                 │        TLA.Spec         │
                 │  DSL macros + the §7    │
                 │  compile-time validator │
                 └────────────┬────────────┘
                              │
      ┌───────────────────────┼───────────────────────┐
      ▼                       ▼                       ▼
┌──────────────┐   ┌──────────────────┐   ┌────────────────────┐
│TLA.Invariant │   │  TLA.StateGraph  │   │     TLA.Trace      │
│              │   │                  │   │                    │
│ Layer 1      │   │ fingerprint →    │   │ walk parents, then │
│ runtime      │   │ {parent, action, │   │ REPLAY forward to  │
│ checking     │   │  params}         │   │ regenerate states  │
│              │   │ + SCC analysis   │   │                    │
└────┬─────────┘   └────────┬─────────┘   └─────────┬──────────┘
     │                      │                       │
┌────▼──────────────────────▼───────────────────────▼──────────┐
│                       Foundation Layer                        │
│                                                              │
│  TLA.State       — state snapshots and transitions           │
│  TLA.Fingerprint — canonical encoding + 64-bit identity      │
│  TLA.Temporal    — temporal operators (bounded fragment)     │
│  TLA.Set         — extended set operations                   │
│  TLA.Function    — TLA+ function operations                  │
│  TLA.Config      — COMPILE-time configuration                │
└──────────────────────────────────────────────────────────────┘
```

---

## Data Flow

### Model Checking Flow (Layer 2)

```
TLA.Spec module
    │
    ▼ (compile-time macro expansion)
TLA.Spec.Compiled struct
    │
    ▼ (+ constants from config)
TLA.ModelChecker.run/2
    │
    ├──► TLA.ModelChecker.Parallel.explore/2
    │       │
    │       ├──► Generate initial states from Init
    │       │
    │       ├──► BFS loop:
    │       │     1. Pop state from frontier
    │       │     2. For each action:
    │       │        a. Check enabling condition
    │       │        b. Compute successor state(s)
    │       │        c. Check invariants on new state
    │       │        d. Check action properties on transition
    │       │        e. Add to graph if new (fingerprint check)
    │       │        f. (liveness) record out-edges + ENABLED bits
    │       │     3. Successor-less: terminal if a `terminal` admits it, else deadlock
    │       │     4. Repeat until frontier empty or violation found
    │       │
    │       └──► TLA.StateGraph (ETS-backed)
    │
    ├──► TLA.ModelChecker.Safety (checked during exploration)
    │
    ├──► TLA.ModelChecker.Liveness (checked after graph complete)
    │       │
    │       ├──► Compute SCCs (Tarjan's algorithm)
    │       ├──► Check temporal formulas against SCCs
    │       └──► Check fairness constraints against SCCs
    │
    └──► Result
         ├── :ok → all properties verified
         └── :violation → TLA.Trace counterexample
```

### Runtime Conformance Flow (Layer 3)

```
GenServer receives message
    │
    ▼
TLA.GenServer wrapper (defoverridable + super)
    │
    ├──► 1. pre_abstract = Refinement.abstract(pre_state)
    │
    ├──► 2. result = super(msg, ...)          # the developer's own clauses
    │
    ├──► 3. post_abstract = Refinement.abstract(extract_state(result))
    │
    ├──► 4. Refinement.abstract_action(msg)
    │         │
    │         ├── {action, params} ──► check_step!/5
    │         │                          │
    │         │                          ├─ guard held on pre_abstract?
    │         │                          │    no  → :not_enabled
    │         │                          └─ spec transition == post_abstract?
    │         │                               no  → :diverged  (with a var diff)
    │         │
    │         └── :unmapped ───────────► check_stuttering!/3
    │                                      └─ post == pre?
    │                                           no  → :unmapped_but_moved
    │
    ├──► 5. Check spec invariants on post_abstract
    ├──► 6. Check action properties on (pre_abstract, post_abstract)
    │         └── any violation → raise / log per TLA.Config.mode
    │
    ├──► 7. Append to the bounded per-process behavior trace
    │
    └──► 8. Return the original callback result
```

Step 4 is the refinement check. An earlier version of this flow computed the
abstract action and then discarded it, checking only steps 5 and 6 — which
verifies that a projection of the state satisfies some predicates, not that the
implementation follows the specification. See `05-layer3-conformance.md`
§What conformance means here.

### Simulation Flow (Layer 3)

```
TLA.Simulation.run/2
    │
    ├──► For each trace (1..config.traces):
    │       │
    │       ├──► Start GenServer with initial args
    │       │
    │       ├──► For each step (1..config.max_steps):
    │       │       │
    │       │       ├──► Get current abstract state via Refinement
    │       │       ├──► Generate random enabled message
    │       │       │    (from spec action params or custom generator)
    │       │       ├──► Send message to GenServer
    │       │       ├──► Runtime checks fire (via TLA.GenServer wrapper)
    │       │       ├──► Optionally inject failure (kill + restart)
    │       │       └──► Record step in trace
    │       │
    │       ├──► Retrieve accumulated trace
    │       ├──► Check temporal properties against trace
    │       └──► Stop GenServer
    │
    └──► Aggregate results across all traces
```

---

## Storage Strategy

| Data | Storage | Reason |
|------|---------|--------|
| State graph nodes (`{parent, action, params}`) | ETS | Concurrent read/write from workers; fixed size per node |
| State fingerprints | ETS | O(1) duplicate detection |
| Liveness edges and ENABLED bits (`check_liveness: true` only) | ETS | Tarjan needs real out-edges; fairness needs ENABLED per state, and the state is gone |
| BFS frontier | `:queue` in the coordinator | FIFO ordering, single writer |
| Explored states themselves | **Not stored** | Regenerated by replay when a trace is needed |
| Per-process behavior trace | Process dictionary, bounded | Per-process, no contention; written only by its owning process |
| Compiled spec | Module attributes | Compile-time, zero runtime cost |
| Config | `Application.compile_env` | Lets `:disabled` emit no code at all |

The row that matters is the fourth. The graph retains a fixed-size record per visited
state — parent pointer, action, params — and never the state itself; a state is
materialized only while its successors are computed, then discarded. Memory therefore
scales with the state *count* rather than with state *size*, and a trace is
reconstructed by replaying actions forward from Init when one is needed, which is at
most once per run. `04-layer2-model-checker.md` §State Graph specifies this.

## Concurrency Architecture (Model Checker)

```
                    ┌─────────────────────┐
                    │    Coordinator       │
                    │                     │
                    │  - Manages frontier  │
                    │  - Distributes work  │
                    │  - Collects results  │
                    │  - Halts on error    │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
        ┌─────▼─────┐   ┌─────▼─────┐   ┌─────▼─────┐
        │  Worker 1  │   │  Worker 2  │   │  Worker N  │
        │            │   │            │   │            │
        │ - Pull     │   │ - Pull     │   │ - Pull     │
        │   states   │   │   states   │   │   states   │
        │ - Compute  │   │ - Compute  │   │ - Compute  │
        │   next     │   │   next     │   │   next     │
        │ - Check    │   │ - Check    │   │ - Check    │
        │   safety   │   │   safety   │   │   safety   │
        │ - Write    │   │ - Write    │   │ - Write    │
        │   to ETS   │   │   to ETS   │   │   to ETS   │
        └────────────┘   └────────────┘   └────────────┘
              │                │                │
              └────────────────┼────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │    ETS Tables        │
                    │                     │
                    │  :nodes — id→{parent,│
                    │     action, params}  │
                    │  :fps   — fp→id      │
                    │  :edges — id→[edge]  │ liveness only
                    │  :enab  — id→bits    │ liveness only
                    └─────────────────────┘
```

Work distribution is coordinator-push — work *sharing*, not work stealing; workers never
take from one another, so the only contended structure is ETS:
1. Coordinator pushes batches of states to worker mailboxes
2. Workers process their batch, writing results to ETS
3. Workers send new frontier states back to coordinator
4. When a worker's batch is empty, coordinator sends more
5. On violation, coordinator sends `:halt` to all workers

**The rounds are BFS levels, and that is load-bearing** (D-27). The coordinator dispatches
one whole level and waits for every worker before dispatching the next, rather than
letting workers pull from a running frontier. D-9's acceptance criterion compares the
**length** of the shortest counterexample against TLC's, and a free-running frontier does
not preserve it — a violating state can be reached along a longer path before the shorter
one has been expanded. The barrier per level is what that criterion costs.

**Workers register states themselves**, calling `StateGraph.add_state/5` rather than
sending successors back for the coordinator to register. Since #33 that call performs
fingerprinting and the §6 term check as well as the ETS write, and the three together are
77% of the `raft` search — so registering centrally would leave about a quarter of the
work parallel. What makes it safe is `insert_new/2`: of two workers that discover the same
state, exactly one claims it.

**Liveness is refused alongside `workers:`**, the way D-22 refuses symmetry with it. The
edge table and ENABLED bits above are drawn as ETS tables and are built as per-struct maps;
under workers each process would hold a fragment, and a cycle spanning two of them would
not exist to be found.

---

## Implementation Phases

**This section is the single source of truth for what is built.** Each phase below carries
its own status, and nothing else in the repository restates it — `README.md` links here
rather than keeping a second copy, because the second copy is what drifted (#73: it claimed
Phases 1 and 2 were done and Phase 3 and 4 were "not yet", two phases after they shipped).

### The ordering rationale

An earlier plan made Layer 1 the MVP, on the reasoning that it is the easiest piece to
build and the easiest to adopt. That ordering was inverted for one specific reason:
**Layer 1 de-risks nothing about Layer 2.** The two share almost no machinery — Layer 1
needs `TLA.State` and `TLA.Config`, both trivial, while `TLA.Temporal`, `TLA.Set`,
`TLA.Function` and `TLA.Fingerprint` are all Layer 2's. Building Layer 1 first would
therefore ship into a market that already holds Corsa, Bond, Oath and ExContract, with
no differentiator, while the genuinely unproven part — whether the DSL of
`02-dsl-semantics.md` can be compiled and checked at all — stays untested.

The prior-art survey records what happens to projects in this space that spend their
early effort on breadth: McErlang is unmaintained, Verlixir is a thesis, Erla+ has eight
commits. The model checker is the moat; it is built first, and Layer 1 falls out of the
runtime checking engine it requires.

### Phase 1 — Prove the DSL (v0.1)

**Complete.**

**Goal:** a spec written in the DSL compiles, and its safety properties are checked
correctly.

- `TLA.State`, `TLA.Config`, `TLA.Fingerprint`
- `TLA.Set`, `TLA.Function`
- `TLA.Spec`, `TLA.Spec.DSL`, `TLA.Spec.Compiled` — including the full compile-time
  validation pass of `02-dsl-semantics.md` §7
- `TLA.StateGraph` (parent-pointer model), single-threaded BFS
- `TLA.ModelChecker`, `TLA.ModelChecker.Safety` — including `terminal` states
  (`02-dsl-semantics.md` §5.3) and the implicit `type_ok` invariant (§1.5)
- `TLA.Trace` with replay-based state regeneration
- `TLA.Coverage` — action coverage and vacuity, from the first release
- `Mix.Tasks.Tla.Check`
- **The differential corpus against TLC** (`04-layer2-model-checker.md` §Differential
  testing), which is the acceptance criterion for this phase, not a follow-up

**Deliverable:** `mix tla.check MySpec` verifies safety, reports what it actually
exercised, and agrees with TLC on every spec in the corpus.

### Phase 2 — Liveness

**Complete.**

- `TLA.Temporal`, `TLA.Temporal.Fairness`
- The liveness graph: edge table and per-state ENABLED bits in `TLA.StateGraph`,
  built only under `check_liveness: true` (`04-layer2-model-checker.md` §State Graph)
- `TLA.ModelChecker.Liveness` — SCC-based, over the bounded fragment of
  `02-dsl-semantics.md` §5.1, with per-binding fairness (§5.2)
- Symmetry reduction and `--verify-symmetry` (`04-layer2-model-checker.md` §Symmetry)

**Deliverable:** temporal properties and fairness, on models large enough to matter.

### Phase 3 — Layer 1, and the conformance bridge

**Complete.**

Layer 1 is small once the runtime checking engine exists; it ships alongside Layer 3
rather than ahead of it.

- `TLA.Invariant`, `TLA.Invariant.Runtime`, `TLA.Invariant.Violation`
- `TLA.Invariant.Agent` — Layer 1 for a behaviour with no callback module of its own
- `TLA.Invariant.Test` — the ExUnit helpers of `03-layer1-invariants.md` §Testing
  Integration, including `refute_invariant/3`, which is the only evidence an invariant is
  not vacuously true
- `TLA.Refinement` with `validate!/2` at compile time
- `TLA.GenServer`, `TLA.GenServer.Runtime` — including `check_step!/5`, the
  refinement check that is the point of the layer, and `TLA.GenServer.Violation`,
  whose `:diverged` diff is the layer's primary output
- `TLA.Replay` — counterexample replay and captured-trace validation, and the
  reporting forms of each `TLA.GenServer.Runtime` check that a replay is built from
- `TLA.Simulation`, `TLA.Simulation.Generator`, and `TLA.GenServer.Driver` — the
  monitored call `TLA.Replay` and `TLA.Simulation` both drive a server through
- `Mix.Tasks.Tla.Simulate`, `Mix.Tasks.Tla.Replay`
- `TLA.State.Json` — the round-trippable form of a §6 state term, which is what
  makes `mix tla.check --format json` into `mix tla.replay --trace` a pipeline
  rather than two commands that print at each other

**Deliverable:** a spec, a counterexample from it, and that counterexample replayed
against the real GenServer.

### Phase 4 — Scale and ecosystem

**Complete.** All three entries are built, on the terms this section set for them.

- `TLA.ModelChecker.Parallel` — added only once the single-threaded checker was correct
  and had been profiled. A wrong answer computed on eight cores is still wrong, and
  parallelism makes every correctness bug harder to reproduce. Level-synchronous BFS
  (D-27), because D-9's corpus compares the *length* of the shortest counterexample and a
  free-running frontier does not preserve it. 5.40x at 8 workers; the corpus agrees with
  TLC at 1, 2, 4 and 8. Liveness is refused alongside it, as D-22 refuses symmetry.
- `TLA.PropertyTest` — `init_states/2` and `action_sequences/3`, drawing their choices
  from the checker's own `enabled_steps/3` rather than a second implementation.
  `Mix.Tasks.Tla.Gen.Test` is **not** built: §Deferred removes generated test files from
  v1, and `05-layer3-conformance.md` now says so where it used to specify them.
- `Mix.Tasks.Tla.Visualize` (DOT only) — over `TLA.StateGraph.to_dot/2` and `to_json/1`.
  Both require the edge table and refuse to draw the spanning tree of parent pointers as
  though it were the transition relation; both refuse a graph past the cap while naming
  its true count.

Entering the phase, `raft_election` took 23.4 s. It now takes 1.65 s — 2.65x from
validating each state once at discovery (D-26) and 5.40x from the workers, and the
differential corpus holds throughout.

### Deferred past v1, deliberately

| Item | Why |
|---|---|
| `TLA.Supervisor.Spec` | Faithful OTP restart semantics is a research-scale problem; nothing below it needs it |
| View abstraction | Easy to make unsound; symmetry covers the common case |
| HTML/D3 visualizer | DOT is enough, and a bespoke viewer is a maintenance sink |
| Generated test *files* | `mix tla.gen.test` writes code someone then has to maintain; the property helpers give most of the value without that |
| Atomic-bound near-miss probes | `TLA.Coverage` derives a near-miss probe only from a top-level `or`, so an invariant written as a bare bound (`count <= max`, `size(s) < k`) reports `nil` — not measured. Pressing such a bound to equality is exactly the near miss the column exists to report, and deriving it means recognising the comparison and its edge rather than negating a disjunct. Deferred, not rejected: the shape is worth having, and reporting `nil` is honest in the meantime |

---

## Non-goals

Stating these keeps the scope honest, and each has a better tool already:

- **ExTLA is not a theorem prover.** It checks bounded models exhaustively and observed
  behaviors concretely. It does not prove a spec correct for all parameters, and it does
  not prove that an implementation refines a spec — it checks that the behaviors it saw
  did. TLAPS proves; ExTLA checks.
- **ExTLA does not explore process interleavings.** It finds design bugs in a state
  machine, not scheduling bugs in running code. Concuerror does that, with DPOR, on
  unmodified tests. The two are complementary and should be used together.
- **ExTLA does not extract models from source.** Specs are written, not inferred.
  Verlixir explores inference; the precision ExTLA wants comes from an explicit spec.
- **ExTLA does not generate implementations from specs.** That is Erla+.
- **No real-time or probabilistic extensions.** No clocks, no distributions. TLA+ itself
  keeps these at arm's length for good reasons.

---

## Dependencies

```elixir
# mix.exs
defp deps do
  [
    # Required
    {:stream_data, "~> 1.0", only: [:dev, :test]},

    # Optional — enhanced visualization, and observability
    {:jason, "~> 1.4", optional: true},     # JSON export for state graphs
    {:telemetry, "~> 1.0", optional: true}, # Layer 1 violation events (03 §Telemetry)

    # Development
    {:ex_doc, "~> 0.31", only: :dev, runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
  ]
end
```

**Zero *required* runtime dependencies.** The core library uses only Elixir/OTP standard
modules. `stream_data` is dev/test only (for property test generation). The two optional
ones are absent-tolerant by construction: whether they are present is decided when ExTLA
itself compiles, so a consumer who takes neither carries no code for either.

---

## Performance Targets

These are **targets to measure against, not claims**. Each is recorded here with the
thing that actually bounds it, so a miss is diagnosable rather than embarrassing.

| Operation | Target | What bounds it |
|-----------|--------|----------------|
| Layer 1 check overhead | < 5 microseconds per transition | The library's own cost only; the predicate's cost is the author's |
| State fingerprint | < 5 microseconds | `term_to_binary(:deterministic)` + SHA-256, dominated by state size |
| Layer 3 step legality check | ~1 action application | Cheaper than the invariants evaluated beside it |
| States/second, single worker | 10K-50K | Closure application per action per state, plus fingerprinting |
| States/second, 8 workers | 5-6x single-worker | ETS contention on the fingerprint table |
| Memory per state in the graph | ~64 bytes for safety; + ~16 bytes per out-edge for liveness | Parent pointer + action + params, plus the edge table when asked for; independent of state size either way |
| Practical graph size | 10M+ states | ~640MB of ETS at 64 bytes/state |

The states/second figures were revised down from an earlier draft's "> 100K single
worker / > 500K with 8". That number is above what TLC achieves on the JVM, and ExTLA
does strictly more work per state: closure application rather than compiled predicate
evaluation, plus a cryptographic fingerprint rather than a 32-bit hash. Publishing an
unreachable target would only mean reporting failure against ExTLA's own spec forever.

The memory row is the one that changed most, and for the better: an earlier draft
retained every explored state (~1KB each, so ~10GB at the 10M-state target). Storing
only parent pointers makes the practical ceiling a function of state count alone.

**Nothing here is a commitment until it is benchmarked.** The differential corpus
(`04-layer2-model-checker.md` §Differential testing) doubles as the benchmark suite, since
it already runs the same specs through TLC.
