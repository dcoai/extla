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
│ModelChecker│ │ExTLA.Coverage│ │ Simulation │ │ ExTLA.Replay │ │PropertyTest│
│            │ │            │ │            │ │            │ │            │
│.run/2      │ │.init/3     │ │.run/2      │ │.counter-   │ │.action_    │
│.check_     │ │.observe_*  │ │.run_trace/2│ │ example/3  │ │ sequences/3│
│ safety/2   │ │.finalize/2 │ │            │ │.trace/3    │ │.init_      │
│.explore/2  │ │.format/1   │ │            │ │            │ │ states/2   │
│.enabled_   │ │            │ │            │ │ replay a   │ │            │
│ steps/3    │ │ never-     │ │            │ │ CE or a    │ │            │
│            │ │ enabled,   │ │            │ │ captured   │ │            │
│            │ │ vacuity    │ │            │ │ trace      │ │            │
└─────┬──────┘ └─────┬──────┘ └─────┬──────┘ └─────┬──────┘ └─────┬──────┘
      │              │              │              │              │
      │              │        ┌─────▼──────────────▼──────┐       │
      │              │        │      ExTLA.GenServer         │       │
      │              │        │  defoverridable + super    │       │
      │              │        │  ┌──────────────────────┐  │       │
      │              │        │  │ GenServer.Runtime    │  │       │
      │              │        │  │  .check_step!/5   ◄──┼──┼───────┼── THE
      │              │        │  │  .check_stuttering!  │  │       │  refinement
      │              │        │  └──────────────────────┘  │       │  check
      │              │        └─────────────┬──────────────┘       │
      │              │                      │                      │
      │              │        ┌─────────────▼──────────────┐       │
      │              │        │      ExTLA.Refinement        │       │
      │              │        │  .abstract/1               │       │
      │              │        │  .abstract_action/1        │       │
      │              │        │  .concrete_message/2  ─────┼───────┘
      │              │        │  .validate!/2 (compile)    │
      │              │        └─────────────┬──────────────┘
      │              │                      │
 ┌────▼──────────────▼──────────────────────▼────────────────────────┐
 │                        ExTLA.Spec.Compiled                           │
 │  constants · variables · init fns · actions (pure in pre+params)   │
 │  invariants · action properties · temporal formulas · fairness     │
 └────────────────────────────┬───────────────────────────────────────┘
                              │
                 ┌────────────▼────────────┐
                 │        ExTLA.Spec         │
                 │  DSL macros + the §7    │
                 │  compile-time validator │
                 └────────────┬────────────┘
                              │   rests on the foundation directly:
                              │   State · Set · Function. NOT on the
                              │   three boxes below (#282).
                              │   Set and Function are reached through
                              │   ExTLA.Spec.Helpers, which a spec body
                              │   imports and which holds no second
                              │   implementation of an operator (D-38).
                              │
   What the CHECKER and Layer 1 rest on — reached from the top row, not from the DSL:

      ┌───────────────────────┬───────────────────────┐
      ▼                       ▼                       ▼
┌──────────────┐   ┌──────────────────┐   ┌────────────────────┐
│ExTLA.Invariant │   │  ExTLA.StateGraph  │   │     ExTLA.Trace      │
│              │   │                  │   │                    │
│ Layer 1      │   │ fingerprint →    │   │ walk parents, then │
│ runtime      │   │ {parent, action, │   │ REPLAY forward to  │
│ checking     │   │  params}         │   │ regenerate states  │
│ ◄─ GenServer │   │ + SCC analysis   │   │                    │
│              │   │ ◄─ ModelChecker  │   │ ◄─ ModelChecker    │
└────┬─────────┘   └────────┬─────────┘   └─────────┬──────────┘
     │                      │                       │
┌────▼──────────────────────▼───────────────────────▼──────────┐
│                       Foundation Layer                        │
│                                                              │
│  ExTLA.State       — state snapshots and transitions           │
│  ExTLA.Fingerprint — canonical encoding + 64-bit identity      │
│  ExTLA.Temporal    — temporal operators (bounded fragment);    │
│                    fairness asks ModelChecker.enabled_       │
│                    bindings/3 back up the stack (temporal.ex)│
│  ExTLA.Set         — set operations; THE implementation        │
│  ExTLA.Function    — function operations; THE implementation   │
│  ExTLA.Config      — COMPILE-time configuration                │
└──────────────────────────────────────────────────────────────┘
```

**Nothing checks this diagram, and that is worth saying out loud.** Every other claim in
this repository that can go stale has a gate — `API_SURFACE.md` for the signatures,
`DIAGNOSTICS.md` for the kinds, `CHANGELOG.md` for what shipped, the guide harness for
every code block. A picture is prose, and prose about module structure is exactly the kind
that rots: until #282 this one drew `ModelChecker.check_liveness/2` and
`Coverage.compute/2`, neither of which has ever existed, an edge from `ExTLA.Spec` to
`ExTLA.Invariant` that the code does not have, and omitted `ExTLA.Temporal`'s call back up to
`ModelChecker.enabled_bindings/3`. It was never a copy of the code; it is a copy of the
design's module tree, from the initial commit.

**The review rule, until something better exists:** check this diagram whenever
`lib/ex_tla/*.ex` gains or loses a module, or when a box's named function changes. That is one
`grep -l` per box — `grep -rn "def check_safety(" lib/` and so on — and it is how the
corrections above were found. Generating it from source would be the real answer; it is not
a hard problem (the five `surface-drift` goldens do the same kind of work), and it is the
obvious next thing for anyone who finds this diagram wrong again.

---

## Data Flow

### Model Checking Flow (Layer 2)

```
ExTLA.Spec module
    │
    ▼ (compile-time macro expansion)
ExTLA.Spec.Compiled struct
    │
    ▼ (+ constants from config)
ExTLA.ModelChecker.run/2
    │
    ├──► ExTLA.ModelChecker.Parallel.explore/2
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
    │       └──► ExTLA.StateGraph (ETS-backed)
    │
    ├──► ExTLA.ModelChecker.Safety (checked during exploration)
    │
    ├──► ExTLA.ModelChecker.Liveness (checked after graph complete)
    │       │
    │       ├──► Compute SCCs (Tarjan's algorithm)
    │       ├──► Check temporal formulas against SCCs
    │       └──► Check fairness constraints against SCCs
    │
    └──► Result
         ├── :ok → all properties verified
         └── :violation → ExTLA.Trace counterexample
```

### Runtime Conformance Flow (Layer 3)

```
GenServer receives message
    │
    ▼
ExTLA.GenServer wrapper (defoverridable + super)
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
    │         └── any violation → raise / log per ExTLA.Config.mode
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
ExTLA.Simulation.run/2
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
    │       │       ├──► Runtime checks fire (via ExTLA.GenServer wrapper)
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
                    │      — SHARED —      │
                    │  :nodes — id→{parent,│
                    │     action, params}  │
                    │  :fps   — fp→id      │
                    └─────────────────────┘

                    ┌─────────────────────┐
                    │  Per-struct MAPS     │
                    │    — NOT shared —    │
                    │  edges   — id→[edge] │ liveness only
                    │  enabled — id→bits   │ liveness only
                    └─────────────────────┘
```

**The second box is why liveness and `workers:` are refused together** (D-27). The two
liveness structures are maps in the `ExTLA.StateGraph` struct, not ETS tables: under workers
each process would hold its own fragment, and a cycle spanning two of them would not exist
anywhere to be found. They were drawn inside the ETS box until #282 — which made the
refusal read as a policy rather than as the consequence of the storage that it is, and
left a reader of the diagram unable to derive the rule that governs the feature.

Work distribution is coordinator-push — work *sharing*, not work stealing; workers never
take from one another, so the only contended structure is ETS. It is `Task.async_stream`
over one BFS level at a time, cut into eight batches per worker, and the paragraphs below
are the whole of it.

*(A five-step message protocol stood here until #282 — a coordinator pushing batches to
worker mailboxes, workers sending frontier states back, a `:halt` message on violation.
#38 built `Task.async_stream` instead and added the true description underneath the false
one without deleting it, which was the right half of the move; the section then read as a
protocol that does not exist, followed by prose saying what does.)*

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

**Liveness is refused alongside `workers:`**, the way D-22 refuses symmetry with it, and
for the reason the second storage box above now states rather than contradicts.

---

## Implementation Phases

**This section is the record of a plan, and of its completion.** It is not the record of
what is built, and it said it was for three weeks: the four phases below were written as a
plan and ended honestly on 2026-09-01 (`d61a1df`, "Record that Phase 4 is complete, and
hand off"); on 09-02 the sentence "the single source of truth for what is built" was added
to a finished enumeration nobody was extending. Eight features shipped after it with no
home here — surfex goldens, the decision log's reopening, the temporal fragment's
compile-time bound — and the claim made each of them look like an omission rather than
like what they were, which is work done after a plan completed.

There is no Phase 5, deliberately. A fifth phase would be a third hand-maintained list of
shipped work standing beside a **gated** one: `bin/changelog_guard.exs` fails any commit
touching `lib/` that does not add a `CHANGELOG.md` entry or say in a commit trailer why it
does not. So:

- **What was planned, and that it was finished:** this section.
- **What is built:** `CHANGELOG.md`, which is gated and cannot silently stop being true.
- **What was decided along the way:** `08-decisions.md`, pinned per decision.

`README.md` points at the second rather than at this one. The original fear was right —
#73's second copy did drift, claiming two phases unbuilt a day and a half after they
shipped — and the answer to a copy that drifts is a record something checks, not a
sentence forbidding copies.

### The ordering rationale

An earlier plan made Layer 1 the MVP, on the reasoning that it is the easiest piece to
build and the easiest to adopt. That ordering was inverted for one specific reason:
**Layer 1 de-risks nothing about Layer 2.** The two share almost no machinery — Layer 1
needs `ExTLA.State` and `ExTLA.Config`, both trivial, while `ExTLA.Temporal`, `ExTLA.Set`,
`ExTLA.Function` and `ExTLA.Fingerprint` are all Layer 2's. Building Layer 1 first would
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

- `ExTLA.State`, `ExTLA.Config`, `ExTLA.Fingerprint`
- `ExTLA.Set`, `ExTLA.Function`
- `ExTLA.Spec`, `ExTLA.Spec.DSL`, `ExTLA.Spec.Compiled` — including the full compile-time
  validation pass of `02-dsl-semantics.md` §7
- `ExTLA.StateGraph` (parent-pointer model), single-threaded BFS
- `ExTLA.ModelChecker`, `ExTLA.ModelChecker.Safety` — including `terminal` states
  (`02-dsl-semantics.md` §5.3) and the implicit `type_ok` invariant (§1.5)
- `ExTLA.Trace` with replay-based state regeneration
- `ExTLA.Coverage` — action coverage and vacuity, from the first release
- `Mix.Tasks.Tla.Check`
- **The differential corpus against TLC** (`04-layer2-model-checker.md` §Differential
  testing), which is the acceptance criterion for this phase, not a follow-up

**Deliverable:** `mix tla.check MySpec` verifies safety, reports what it actually
exercised, and agrees with TLC on every spec in the corpus.

### Phase 2 — Liveness

**Complete.**

- `ExTLA.Temporal`, `ExTLA.Temporal.Fairness`
- The liveness graph: edge table and per-state ENABLED bits in `ExTLA.StateGraph`,
  built only under `check_liveness: true` (`04-layer2-model-checker.md` §State Graph)
- `ExTLA.ModelChecker.Liveness` — SCC-based, over the bounded fragment of
  `02-dsl-semantics.md` §5.1, with per-binding fairness (§5.2)
- Symmetry reduction and `--verify-symmetry` (`04-layer2-model-checker.md` §Symmetry)

**Deliverable:** temporal properties and fairness, on models large enough to matter.

### Phase 3 — Layer 1, and the conformance bridge

**Complete.**

Layer 1 is small once the runtime checking engine exists; it ships alongside Layer 3
rather than ahead of it.

- `ExTLA.Invariant`, `ExTLA.Invariant.Runtime`, `ExTLA.Invariant.Violation`
- `ExTLA.Invariant.Agent` — Layer 1 for a behaviour with no callback module of its own
- `ExTLA.Invariant.Test` — the ExUnit helpers of `03-layer1-invariants.md` §Testing
  Integration, including `refute_invariant/3`, which is the only evidence an invariant is
  not vacuously true
- `ExTLA.Refinement` with `validate!/2` at compile time
- `ExTLA.GenServer`, `ExTLA.GenServer.Runtime` — including `check_step!/5`, the
  refinement check that is the point of the layer, and `ExTLA.GenServer.Violation`,
  whose `:diverged` diff is the layer's primary output
- `ExTLA.Replay` — counterexample replay and captured-trace validation, and the
  reporting forms of each `ExTLA.GenServer.Runtime` check that a replay is built from
- `ExTLA.Simulation`, `ExTLA.Simulation.Generator`, and `ExTLA.GenServer.Driver` — the
  monitored call `ExTLA.Replay` and `ExTLA.Simulation` both drive a server through
- `Mix.Tasks.Tla.Simulate`, `Mix.Tasks.Tla.Replay`
- `ExTLA.State.Json` — the round-trippable form of a §6 state term, which is what
  makes `mix tla.check --format json` into `mix tla.replay --trace` a pipeline
  rather than two commands that print at each other

**Deliverable:** a spec, a counterexample from it, and that counterexample replayed
against the real GenServer.

### Phase 4 — Scale and ecosystem

**Complete.** All three entries are built, on the terms this section set for them.

- `ExTLA.ModelChecker.Parallel` — added only once the single-threaded checker was correct
  and had been profiled. A wrong answer computed on eight cores is still wrong, and
  parallelism makes every correctness bug harder to reproduce. Level-synchronous BFS
  (D-27), because D-9's corpus compares the *length* of the shortest counterexample and a
  free-running frontier does not preserve it. 5.40x at 8 workers; the corpus agrees with
  TLC at 1, 2, 4 and 8. Liveness is refused alongside it, as D-22 refuses symmetry.
- `ExTLA.PropertyTest` — `init_states/2` and `action_sequences/3`, drawing their choices
  from the checker's own `enabled_steps/3` rather than a second implementation.
  `Mix.Tasks.Tla.Gen.Test` is **not** built: §Deferred removes generated test files from
  v1, and `05-layer3-conformance.md` now says so where it used to specify them.
- `Mix.Tasks.Tla.Visualize` (DOT only) — over `ExTLA.StateGraph.to_dot/2` and `to_json/1`.
  Both require the edge table and refuse to draw the spanning tree of parent pointers as
  though it were the transition relation; both refuse a graph past the cap while naming
  its true count.

Entering the phase, `raft_election` took 23.4 s. It now takes 1.65 s — 2.65x from
validating each state once at discovery (D-26) and 5.40x from the workers, and the
differential corpus holds throughout.

**The plan ends here.** Work since Phase 4 — and there has been a good deal of it — is
recorded in `CHANGELOG.md` as it lands, under a gate. Nothing below this line is a status.

### Deferred past v1, deliberately

| Item | Why |
|---|---|
| `ExTLA.Supervisor.Spec` | Faithful OTP restart semantics is a research-scale problem; nothing below it needs it |
| View abstraction | Easy to make unsound; symmetry covers the common case |
| HTML/D3 visualizer | DOT is enough, and a bespoke viewer is a maintenance sink |
| Generated test *files* | `mix tla.gen.test` writes code someone then has to maintain; the property helpers give most of the value without that |
| Atomic-bound near-miss probes | `ExTLA.Coverage` derives a near-miss probe only from a top-level `or`, so an invariant written as a bare bound (`count <= max`, `size(s) < k`) reports `nil` — not measured. Pressing such a bound to equality is exactly the near miss the column exists to report, and deriving it means recognising the comparison and its edge rather than negating a disjunct. Deferred, not rejected: the shape is worth having, and reporting `nil` is honest in the meantime |

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

**The list itself is `PACKAGE_SURFACE.md`**, generated from `mix.exs` by
`mix tla.package_surface --write` and gated by `surface-drift`. This section carried a copy
of the `deps` block from the initial commit until #274 — a fence whose first line was the
comment `# mix.exs`, so it announced itself as a copy — and by then it listed `dialyxir`,
which #69 removed, omitted `surfex`, which #64 added, and pinned `ex_doc` three minor
versions behind. A copy of a file that changes on its own is the second-copy failure #73 and
#80 diagnosed, and the fix is the same one the verification ledger uses: derive it, and gate
the derivation.

What belongs here is what a list cannot say.

**Zero *required* runtime dependencies.** The core library uses only Elixir/OTP standard
modules. `stream_data` is dev/test only (property-test generation); `surfex` is dev/test only
and renders the goldens, which is why `ledger/` may depend on it and `lib/` may not. The two
optional ones — `jason` and `telemetry` — are absent-tolerant by construction: whether they
are present is decided when ExTLA itself compiles, so a consumer who takes neither carries no
code for either.

**Dev/test dependencies are not transitive**, which is what makes the split load-bearing
rather than hygiene: nothing marked `only: [:dev, :test]` reaches anyone who depends on
ExTLA. That is the answer to #1's objection that consumers would inherit a documentation
framework.

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
