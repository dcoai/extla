# Prior Art: Existing Work in Formal Verification for Elixir/Erlang

A comprehensive survey of existing tools, libraries, and research relevant to ExTLA.

---

## Summary

There is **no existing library** that does what ExTLA proposes — embedding TLA+-style specification, model checking, and conformance verification directly into Elixir. However, there is significant prior work across several adjacent areas that ExTLA should learn from, build on, or integrate with.

### Landscape Map

```
                        TLA+ / Formal Spec
                              │
                    ┌─────────┴─────────┐
                    │                   │
              Erla+ (spec→code)    Verlixir (code→Spin)
                    │                   │
                    ▼                   ▼
              ┌─────────────────────────────┐
              │     GAP: ExTLA lives here   │
              │  (spec DSL + model checker  │
              │   + runtime conformance)    │
              └─────────────────────────────┘
                    ▲         ▲         ▲
                    │         │         │
            Design by     Property    Concurrency
            Contract      Testing     Testing
                │           │           │
          Bond/Oath/    PropCheck/   Concuerror
          Corsa         Makina
```

---

## Direct TLA+ / Model Checking Work

### 1. Erla+ (TLA+ → Erlang Translator)

| | |
|---|---|
| **What** | Compiler that translates PlusCal specifications into executable Erlang code |
| **Authors** | Marian Hristov, Annette Bieniusa (University of Kaiserslautern-Landau) |
| **Published** | ICFP/Erlang Workshop 2024 |
| **Repo** | [github.com/mmhristov/Erlaplus](https://github.com/mmhristov/Erlaplus) |
| **Status** | Research prototype (8 commits, academic project) |

**How it works:**
- Extends the PlusCal translator (`tla2tools.jar`) with an Erlang code generation backend
- Adds actor-style primitives to PlusCal for modeling message-passing systems
- Generates Erlang processes from PlusCal `process` declarations
- Optional `-genMain` flag generates initialization/startup boilerplate

**Examples included:** Raft consensus, Raft KVS, Semaphore protocol

**Relevance to ExTLA:**
- Erla+ goes **spec → code** (generates implementation from spec)
- ExTLA goes **spec ↔ code** (spec and implementation coexist, conformance is checked)
- Erla+ validates the idea that TLA+/PlusCal maps well to BEAM actors
- Erla+'s PlusCal extensions for actors could inform ExTLA's DSL design
- Erla+ requires Java toolchain; ExTLA would be pure Elixir

**Key insight from their paper:** *"There still exists a gap between a formal model and implementation if the model and its implementation are only loosely coupled. Developers usually overcome this gap through manual effort, which may result in the introduction of unexpected bugs."* — This is exactly the problem ExTLA Layer 3 addresses.

---

### 2. Verlixir (Elixir → Spin/Promela)

| | |
|---|---|
| **What** | Parses Elixir programs and translates them to Promela for verification with the Spin model checker |
| **Author** | Matt Neave (Imperial College London, MEng thesis 2023-2024) |
| **Paper** | [Imperial College Distinguished Projects](https://www.imperial.ac.uk/media/imperial-college/faculty-of-engineering/computing/public/distinguished-projects/2324-ug-projects/Neave,-Matt-Verlixir-Verification-of-Message-Passing-Systems.pdf) |
| **Status** | Academic thesis project |

**How it works:**
- Parses Elixir source code into an AST
- Extracts process structure and message-passing patterns
- Generates Promela models (Spin's input language)
- Properties expressed as LTL formulas, verified by Spin

**Relevance to ExTLA:**
- Verlixir goes **code → external model checker** (extracts model from code)
- ExTLA goes **spec + code → internal verification** (model checker is in Elixir)
- Verlixir requires Spin (external C tool); ExTLA would be self-contained
- Verlixir extracts models automatically; ExTLA requires explicit specs (more precise but more work)
- Verlixir's approach to parsing Elixir process patterns could inform ExTLA's automatic state machine extraction

---

### 3. McErlang (Erlang Model Checker)

| | |
|---|---|
| **What** | Model checker that replaces the Erlang runtime's concurrency layer to systematically explore process interleavings |
| **Authors** | Lars-Åke Fredlund, Clara Benac Earle (Universidad Politécnica de Madrid) |
| **Repo** | [github.com/fredlund/McErlang](https://github.com/fredlund/McErlang) |
| **Status** | Mature but not actively maintained |

**How it works:**
- Replaces the BEAM's distribution/concurrency/communication subsystem
- Simulates processes inside the model checker
- Provides direct access to complete program state
- Supports LTL property checking via Büchi automata

**Relevance to ExTLA:**
- McErlang operates at the **runtime level** (intercepts actual BEAM operations)
- ExTLA operates at the **specification level** (abstract models checked separately)
- McErlang can find bugs in existing code without modifications
- ExTLA requires specs but catches design bugs before implementation
- McErlang's approach to state capture could inform ExTLA's simulation mode

---

### 4. Concuerror (Stateless Model Checker)

| | |
|---|---|
| **What** | Stateless model checking tool that systematically explores process schedulings to find concurrency bugs |
| **Repo** | [github.com/parapluu/Concuerror](https://github.com/parapluu/Concuerror) |
| **Website** | [concuerror.com](https://concuerror.com/) |
| **Status** | Active, well-maintained |

**How it works:**
- Runs existing Erlang/Elixir test functions unmodified
- Replaces the scheduler to explore all "meaningfully different" interleavings
- Uses dynamic partial order reduction (DPOR) to prune equivalent schedules
- Detects deadlocks, race conditions, and assertion violations

**Key strength:** Requires **no modifications** to tested code — works with existing tests.

**Relevance to ExTLA:**
- Concuerror finds bugs in **implementation** by exploring schedules
- ExTLA finds bugs in **design** by exploring state spaces
- Complementary tools — Concuerror for implementation bugs, ExTLA for design bugs
- ExTLA's simulation mode (Layer 3) could optionally use Concuerror-like schedule exploration
- Concuerror's DPOR technique could inform ExTLA's state space reduction

---

## Design by Contract Libraries

### 5. Corsa (Executable Contracts for Elixir)

| | |
|---|---|
| **What** | Library for writing executable code contracts with pre/postconditions, stateful contracts, and process-aware features |
| **Published** | ACM SIGPLAN Erlang Workshop 2022; ScienceDirect 2024 |
| **Hex** | [hex.pm/packages/corsa](https://hex.pm/packages/corsa) (v0.1.2) |
| **API Docs** | [hexdocs.pm/corsa](https://hexdocs.pm/corsa/api-reference.html) |

**Key features:**
- Classical preconditions and postconditions
- **Stateful contracts** — introduces "contract state" for history-dependent behavior
- **Message-aware contracts** — can associate contracts with message reception
- Timer-based constraints (detect slow computations)
- Non-termination detection for recursive functions
- Exceptional behavior specification

**Relevance to ExTLA:**
- Corsa's **stateful contracts** are the closest existing work to ExTLA Layer 1
- Corsa's message-aware contracts map to ExTLA's action properties
- Corsa is function-oriented; ExTLA is state-machine-oriented
- ExTLA adds model checking and temporal properties, which Corsa lacks
- ExTLA could potentially use Corsa's contract infrastructure internally
- **Corsa is the most direct competitor for Layer 1**

---

### 6. Bond (Design by Contract)

| | |
|---|---|
| **What** | Feature-complete Design by Contract library for Elixir |
| **Hex** | [hex.pm/packages/bond](https://hex.pm/packages/bond) (v0.1.0) |
| **Forum** | [elixirforum.com/t/bond-design-by-contract-for-elixir/67317](https://elixirforum.com/t/bond-design-by-contract-for-elixir/67317) |

**Goal:** "The most feature-complete and thoroughly documented Design by Contract library for Elixir, with a concise and flexible syntax."

**Relevance to ExTLA:**
- Bond focuses on function-level contracts (pre/postconditions)
- ExTLA focuses on state-machine-level invariants
- Bond is v0.1.0 — early stage
- Minimal overlap; ExTLA could coexist with Bond

---

### 7. Oath (Design by Contract)

| | |
|---|---|
| **What** | Decorator-based design by contract for Elixir |
| **Author** | Chris Keathley |
| **Hex** | [hex.pm/packages/oath](https://hex.pm/packages/oath) (v0.1.1) |
| **Repo** | [github.com/keathley/oath](https://github.com/keathley/oath) |

**How it works:**
- Uses the `:decorator` library
- `@decorate pre(fn args -> ... end)` for preconditions
- `@decorate post(fn result -> ... end)` for postconditions
- Contracts can be enabled/disabled globally

**Relevance to ExTLA:**
- Lightweight function-level contracts
- No state machine awareness, no invariants, no temporal properties
- Decorator approach is ergonomically nice; ExTLA could learn from it
- Very different scope — Oath is micro, ExTLA is macro

---

### 8. ExContract

| | |
|---|---|
| **Hex** | [hex.pm/packages/ex_contract](https://hex.pm/packages/ex_contract) |

Another contract library in the space. Less documented than the others.

---

## Property-Based Testing

### 9. PropCheck (PropEr wrapper for Elixir)

| | |
|---|---|
| **What** | Elixir wrapper around the PropEr property-based testing framework |
| **Hex** | [hex.pm/packages/propcheck](https://hex.pm/packages/propcheck) (v1.5.0) |
| **Repo** | [github.com/alfert/propcheck](https://github.com/alfert/propcheck) |
| **Status** | Active, well-maintained |

**Key feature: `PropCheck.StateM.ModelDSL`**
- DSL for stateful property-based testing
- Define a model as a state machine
- Generate random command sequences
- Execute against both model and system under test
- Verify that system behavior matches model at every step

**How it works:**
1. Define model state and commands
2. PropCheck generates random command sequences
3. Phase 1: symbolic execution against model
4. Phase 2: concrete execution against SUT
5. Check postconditions match at each step

**Relevance to ExTLA:**
- PropCheck's StateM is conceptually similar to ExTLA Layer 3 simulation
- PropCheck uses **random** exploration; ExTLA uses **exhaustive** exploration
- PropCheck models are test-only; ExTLA specs are also design documentation
- ExTLA's `TLA.PropertyTest` module should **generate PropCheck/StreamData tests** from specs
- PropCheck is the natural complement — ExTLA for exhaustive checking, PropCheck for random exploration of implementation

---

### 10. Makina (Stateful PBT DSL)

| | |
|---|---|
| **What** | DSL for writing property-based testing models for stateful systems |
| **Hex** | [hex.pm/packages/makina](https://hex.pm/packages/makina) (v0.3.2) |
| **Docs** | [hexdocs.pm/makina](https://hexdocs.pm/makina/readme.html) |

**Key features:**
- Declarative DSL for defining model states and commands
- Model reuse and extension mechanisms
- Generates models compatible with PropCheck or eqc_ex
- Commands with `pre` (guards), `args` (generators), `next` (state transitions), `post` (assertions)

**DSL example:**
```elixir
defmodule MyModel do
  use Makina

  state value: 0 :: integer()

  command :increment do
    pre fn state -> state.value < 100 end
    args fn _state -> [] end
    next fn state, _args, _result -> %{state | value: state.value + 1} end
    post fn _state, _args, result -> result == :ok end
  end
end
```

**Relevance to ExTLA:**
- Makina's DSL is the closest existing Elixir DSL to ExTLA's `TLA.Spec`
- Makina focuses on **testing** (generate and run random sequences)
- ExTLA focuses on **verification** (exhaustive state space + temporal logic)
- Makina's command structure (pre/args/next/post) maps to ExTLA's action structure
- ExTLA could use Makina as a test backend, or Makina users could adopt ExTLA for stronger guarantees
- **Makina is the most direct competitor for Layer 2's DSL (but not the model checker)**

---

### 11. StreamData (Built-in Property Testing)

| | |
|---|---|
| **What** | Elixir's built-in data generation and property testing library |
| **Hex** | [hex.pm/packages/stream_data](https://hex.pm/packages/stream_data) |

StreamData provides generators but **no stateful testing DSL**. ExTLA Layer 3 would generate StreamData generators from specs.

---

## Session Types / Type-Level Verification

### 12. ElixirST (Session Types for Elixir)

| | |
|---|---|
| **What** | Session-based type system that statically verifies message-passing protocols |
| **Authors** | Gerard Tabone et al. (University of Malta) |
| **Hex** | [hex.pm/packages/elixirst](https://hex.pm/packages/elixirst) (v0.8.3) |
| **Repo** | [github.com/gertab/ElixirST](https://github.com/gertab/ElixirST) |
| **Published** | ScienceDirect 2023; AGERE Workshop 2021 |

**How it works:**
- Developers annotate public functions with session type specifications
- The type checker statically verifies that function bodies respect the session protocol
- Checks send/receive patterns match the declared session type
- Proves session fidelity (protocol adherence) and progress (no stuck states)

**Relevance to ExTLA:**
- ElixirST verifies **communication protocols** at the type level
- ExTLA verifies **state machine behavior** at the specification level
- ElixirST is static (compile-time); ExTLA is both static (model check) and dynamic (runtime)
- ElixirST checks individual process protocols; ExTLA checks system-wide properties
- Complementary: ElixirST ensures correct message structure, ExTLA ensures correct system behavior
- **Future integration point**: ExTLA specs could generate session type annotations

---

## State Machine Libraries

### 13. Machinery, FSMX, Gearbox, as_fsm, state_machine

Several Elixir libraries provide state machine DSLs:

| Library | Focus | Verification |
|---------|-------|-------------|
| [Machinery](https://github.com/joaomdmoura/machinery) | State machines for structs, Phoenix integration | Guard clauses only |
| [FSMX](https://github.com/subvisual/fsmx) | Finite state machines with Ecto | Transition validation |
| [Gearbox](https://hex.pm/packages/gearbox) | Functional state machine API | None |
| [as_fsm](https://hex.pm/packages/as_fsm) | Declarative FSM | Basic validation |
| [state_machine](https://hex.pm/packages/state_machine) | State + Ecto integration | Transition integrity |

**Relevance to ExTLA:**
- These libraries define valid transitions but don't verify system-wide properties
- No invariant checking, no temporal logic, no model checking
- ExTLA's `TLA.Spec` actions are more expressive than simple state transitions
- ExTLA could potentially be used **alongside** these libraries to verify their configurations

---

## Gap Analysis

### What Exists

| Capability | Covered By | Maturity |
|-----------|-----------|---------|
| TLA+ → Erlang code generation | Erla+ | Research prototype |
| Elixir → external model checker | Verlixir | Thesis project |
| Erlang runtime model checking | McErlang | Mature, unmaintained |
| Concurrency schedule exploration | Concuerror | Active, production-ready |
| Function pre/postconditions | Corsa, Bond, Oath | Early stage (v0.1.x) |
| Stateful property testing DSL | Makina, PropCheck StateM | Active, usable |
| Session type verification | ElixirST | Active, academic |
| State machine DSLs | Machinery, FSMX, etc. | Active, production-ready |

### What's Missing (ExTLA's Unique Value)

| Capability | Exists? | ExTLA Layer |
|-----------|---------|------------|
| TLA+-style spec DSL in Elixir | **No** | Layer 2 |
| Exhaustive model checker in Elixir | **No** | Layer 2 |
| Temporal logic (liveness, fairness) | **No** | Layer 2 |
| GenServer invariant macros | **Partial** (Corsa) | Layer 1 |
| Spec ↔ implementation refinement mapping | **No** | Layer 3 |
| Automatic conformance simulation | **No** | Layer 3 |
| Supervision tree formal modeling | **No** | Layer 3 |
| Test generation from formal specs | **No** | Layer 3 |
| Integrated spec + check + test pipeline | **No** | All layers |

### Key Differentiators

1. **No existing tool provides an Elixir-native model checker.** McErlang is Erlang-only and operates at the runtime level. Verlixir delegates to Spin. ExTLA would be the first pure-Elixir model checker.

2. **No existing tool supports temporal logic in Elixir.** Liveness, fairness, leads-to — none of the contract or testing libraries express these. ExTLA would be the first.

3. **No existing tool bridges spec to implementation in Elixir.** Erla+ generates code from specs (one-way). ExTLA maintains both and checks conformance (bidirectional).

4. **The contract libraries are function-oriented, not state-machine-oriented.** Corsa/Bond/Oath check individual function calls. ExTLA checks entire system behaviors.

---

## Integration Opportunities

### Build On

| Tool | How ExTLA Could Use It |
|------|----------------------|
| **PropCheck/StreamData** | Generate property tests from ExTLA specs (Layer 3) |
| **Concuerror** | Use as a backend for implementation-level schedule exploration |
| **Corsa** | Potentially use Corsa's contract runtime for Layer 1 preconditions |
| **Makina** | Study DSL design; ExTLA specs could generate Makina models |

### Complement

| Tool | Relationship |
|------|-------------|
| **ElixirST** | ElixirST checks message protocols; ExTLA checks state properties |
| **Concuerror** | Concuerror finds implementation bugs; ExTLA finds design bugs |
| **Dialyzer** | Dialyzer checks types; ExTLA checks behavioral properties |

### Avoid Duplicating

| Capability | Use Instead |
|-----------|------------|
| Random command generation | PropCheck / StreamData |
| Schedule exploration | Concuerror |
| Static type checking | Dialyzer / Elixir type system |
| Simple state machine validation | Existing FSM libraries |

---

## Sources

### Tools & Libraries
- [Erla+](https://github.com/mmhristov/Erlaplus) — PlusCal to Erlang translator
- [Verlixir](https://www.imperial.ac.uk/media/imperial-college/faculty-of-engineering/computing/public/distinguished-projects/2324-ug-projects/Neave,-Matt-Verlixir-Verification-of-Message-Passing-Systems.pdf) — Elixir to Spin/Promela
- [McErlang](https://github.com/fredlund/McErlang) — Erlang model checker
- [Concuerror](https://concuerror.com/) — Stateless model checker for Erlang
- [Corsa](https://hex.pm/packages/corsa) — Executable contracts for Elixir
- [Bond](https://hex.pm/packages/bond) — Design by Contract for Elixir
- [Oath](https://hex.pm/packages/oath) — Design by Contract via decorators
- [PropCheck](https://hex.pm/packages/propcheck) — Property-based testing (PropEr wrapper)
- [Makina](https://hex.pm/packages/makina) — Stateful PBT DSL
- [ElixirST](https://github.com/gertab/ElixirST) — Session types for Elixir

### Papers
- [Erla+: Translating TLA+ Models into Executable Actor-Based Implementations](https://dl.acm.org/doi/10.1145/3677995.3678190) (ICFP/Erlang 2024)
- [Executable contracts for Elixir](https://www.sciencedirect.com/science/article/abs/pii/S2352220824000737) (ScienceDirect 2024)
- [ElixirST: A session-based type system for Elixir modules](https://www.sciencedirect.com/science/article/abs/pii/S2352220823000457) (ScienceDirect 2023)
- [Session types in Elixir](https://dl.acm.org/doi/10.1145/3486601.3486708) (AGERE 2021)
- [How Amazon Web Services Uses Formal Methods](https://lamport.azurewebsites.net/tla/formal-methods-amazon.pdf) (CACM 2015)
- [Erlang/Elixir formal verification](https://elixirforum.com/t/erlang-elixir-formal-verification/10963) (Elixir Forum discussion)
- [A Beginner's Guide to TLA+ — Code BEAM V](https://www.codesync.global/media/a-beginner-s-guide-to-tla-exploring-state-machines-proving-correctness-jeff-weiss-code-beam-v/) (talk connecting TLA+ to BEAM)
