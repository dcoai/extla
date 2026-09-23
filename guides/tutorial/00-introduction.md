# Introduction: what this is, and where it comes from

The ExTLA tutorial starts here. It assumes you write Elixir and have never written a formal
specification.

[Getting started](../getting-started.md) is the shorter path — install, one spec, one
counterexample, half an hour. This page is the other question: *what is this, and why would I*
*reach for it?* It is prose, and it is the only page of the tutorial with no code on it.

The pages after it are the long path, and they are meant to be read in order: the mathematics
the DSL is a notation for, the DSL as it is used, what the coverage report tells you about a
verdict, temporal properties and the difference fairness makes to them, symmetry and who is
responsible for it, and then the two layers that connect a specification to running code.
**One system runs through all of it** — a lock with three clients — and each page adds something
to it.

The last three pages are the ones about your own code rather than this tutorial's: how to get
from a system you already have to a specification worth checking, what to do when the state
space explodes, and how to keep a specification in a project so it stays true. They are where
the tutorial stops being a worked example.

Every code block in this tutorial is compiled and run by ExTLA's own test suite, and every verdict
the prose quotes is asserted against the run: if a page says a spec verifies, it does, and if it
says a counterexample is seven states long, it is. The specification in
[`spec/`](../../spec/README.md) remains the authority on what the tool means, and these pages link
to it rather than restating it.

## Why verify a design at all

Tests sample. You pick inputs, or a generator picks them for you, and each run exercises one path
through the system. That works well when the interesting behaviour is a function of the input —
and badly when it is a function of *timing*, because you do not choose the interleaving. Two
processes that each work perfectly can deadlock on the one ordering your test suite never
produced, and the test that would have caught it passes ninety-nine times out of a hundred.

Worse, the bug is usually not in the code. It is in the design: the protocol admits a sequence of
steps nobody thought about. You can find that bug by writing the code, deploying it, and waiting
for the ordering to happen in production — or you can describe the design precisely enough that a
machine can enumerate *every* ordering and tell you whether any of them is bad. That is what
formal verification, in the sense this library means it, is for: **finding the design bug before
the code exists.**

### A short history, because it explains the shape of the tools

The idea that a program could be reasoned about mathematically rather than merely executed is
about sixty years old, and it arrived in recognisable stages.

**Assertions and proof (1960s–70s).** Robert Floyd's *Assigning Meanings to Programs* (1967) and
C. A. R. Hoare's *An Axiomatic Basis for Computer Programming* (1969) established that a program
could be annotated with predicates — preconditions, postconditions, invariants — and that its
correctness could be *derived*. Edsger Dijkstra's work on guarded commands and predicate
transformers pushed the same idea towards deriving the program from its specification. This is the
ancestry of every `assert`, every contract library, and of ExTLA's Layer 1.

**Temporal logic (1977).** Amir Pnueli's *The Temporal Logic of Programs* introduced reasoning
about how a program's properties evolve *over time* — not just "the balance is never negative" but
"every request is eventually answered". Concurrency needs this: the interesting properties of a
protocol are about sequences, not states.

**Model checking (early 1980s).** Edmund Clarke and E. Allen Emerson, and independently
Jean-Pierre Queille and Joseph Sifakis, proposed something different from proof: if the system has
finitely many states, *enumerate them all* and check the property mechanically. No human
ingenuity, no induction — a decision procedure. Clarke, Emerson and Sifakis received the Turing
Award for it in 2007, and it is the technique ExTLA implements.

Model checking brought its own problem, immediately: **state explosion.** A system with twenty
boolean variables has a million states; add a process and the space multiplies. Most of the
research since has been about making that tractable — symbolic representations (Randal Bryant's
binary decision diagrams, 1986; Kenneth McMillan's symbolic model checking, early 1990s),
partial-order reduction, symmetry reduction, abstraction, and lately SMT solvers. Every reduction
ExTLA offers, and every one it refuses, is a move in this space.

**Proof assistants, in parallel.** Where the state space is infinite, enumeration is not
available and mechanised proof is: Coq (now Rocq), Isabelle/HOL, Lean, and for TLA+ specifically
TLAPS. These prove more, and cost far more human effort.

**Lightweight methods (1990s–2000s).** The turn that made any of this reach working engineers was
the realisation that you do not need to verify the implementation to get most of the value — you
verify a *model* of the design, small enough to check and abstract enough to write in an
afternoon. Daniel Jackson's Alloy and Leslie Lamport's TLA+ are both of this kind, and the
canonical demonstration is Amazon's: teams applying TLA+ to S3, DynamoDB and other services found
serious bugs in designs that had already been reviewed, and said so in
[*How Amazon Web Services Uses Formal Methods*](https://lamport.azurewebsites.net/tla/formal-methods-amazon.pdf)
(CACM, 2015). That paper is the reason a working engineer has heard of this at all.

## TLA and TLA+

**TLA** is the Temporal Logic of Actions, Leslie Lamport's logic for describing systems: a
*state* is an assignment to variables, an *action* is a predicate relating a state to its
successor, and temporal operators say how properties hold along the resulting sequences. **TLA+**
is the specification language built on it, with the set theory and first-order logic to write the
predicates in. **TLC** is its model checker, **PlusCal** an algorithm language that compiles to
TLA+, and **TLAPS** its proof system. Lamport received the Turing Award in 2013, for this and for
the distributed-systems work — Paxos, logical clocks — that motivated it.

`research/tla-plus-primer.md` carries the [history and philosophy](../../research/tla-plus-primer.md#history-and-philosophy)
in full, with the timeline; this page will not restate it. What matters here is the design stance,
because ExTLA inherits it by being modelled on TLA+:

- **Mathematics rather than programming constructs.** A specification is not a program. It has no
  I/O, no threads, no memory model — it is a formula that a set of behaviours either satisfies or
  does not.
- **No special constructs for concurrency.** Sequential, concurrent and distributed systems are
  written in the same notation; concurrency is what you get when several actions are enabled at
  once, not a feature of the language.
- **Composition by conjunction.** Components combine with "and". The behaviour of the whole is
  the intersection of the constraints of the parts.
- **Abstraction is the point.** A specification says *what* a system does, not how, which is what
  keeps it short enough to check and to read.

Lamport's own summary of the philosophy: *"The best language for writing specifications is
mathematics."*

## What else exists

Formal-methods tools differ mostly in what they buy their power with. Four families are worth
knowing, because the trade is different in each.

**Explicit-state model checkers** enumerate reachable states one at a time. TLC (for TLA+) and
Spin (Gerard Holzmann's checker, taking Promela models and LTL properties) are the archetypes.
Exhaustive over the model, fully automatic, and limited by state explosion — the model has to be
*small*, which is a modelling skill rather than a tooling problem. ExTLA is of this family.

**Symbolic and SMT-based checkers** represent sets of states as formulas rather than
enumerating them, which can cover enormous spaces — nuXmv in the hardware tradition, and
[Apalache](https://apalache.informal.systems/) for TLA+ specifically, which translates a spec into
SMT constraints. They handle models an explicit checker cannot, at the cost of a translation
layer and its own restrictions on what you may write.

**Proof assistants** verify unbounded systems, with a human supplying the induction: Coq/Rocq,
Isabelle/HOL, Lean, TLAPS. They prove theorems about all parameter values rather than facts about
one small configuration — for a price in effort measured in weeks rather than hours.

**Bounded relational and refinement frameworks.** Alloy analyses a relational model exhaustively
up to a *scope* you choose, using a SAT solver, and is excellent at structural properties. The B
method and Event-B are built around stepwise refinement from an abstract specification down to
code, with the refinement obligations discharged by prover.

Beside these sit the tools that work on the implementation rather than a model: **schedule
explorers** like Concuerror, which run real code under a controlled scheduler, and **runtime
verification**, which checks properties as the system executes. ExTLA's Layer 1 is of the second
kind, and Layer 3 drives a real GenServer against the specification — but neither controls the
scheduler, so neither replaces Concuerror. `00-prior-art.md` treats it as a complement
deliberately: it finds implementation bugs where ExTLA finds design bugs.

## In Elixir and Erlang

`spec/00-prior-art.md` is the project's survey of this ground — every tool below with its authors,
status, and how it relates to ExTLA, plus the [gap analysis](../../spec/00-prior-art.md#gap-analysis)
that defines what ExTLA is for. It is the authority; this is the summary.

**Working from a formal spec.** [Erla+](https://github.com/mmhristov/Erlaplus) (Hristov and
Bieniusa, Erlang Workshop 2024) translates PlusCal specifications into executable Erlang —
spec *to* code, one direction. [Verlixir](https://www.imperial.ac.uk/media/imperial-college/faculty-of-engineering/computing/public/distinguished-projects/2324-ug-projects/Neave,-Matt-Verlixir-Verification-of-Message-Passing-Systems.pdf)
(Neave, Imperial College) goes the other way, parsing Elixir and generating Promela for Spin —
code *to* an external checker.

**Checking real code.** [McErlang](https://github.com/fredlund/McErlang) (Fredlund and Benac
Earle) replaces the BEAM's concurrency layer to explore interleavings of real Erlang programs;
mature, and unmaintained. [Concuerror](https://concuerror.com/) is active, production-ready, and
requires no changes to the code under test: it re-runs your existing tests under every
meaningfully different schedule, with dynamic partial-order reduction to keep that finite.

**Contracts.** [Corsa](https://hex.pm/packages/corsa) (Erlang Workshop 2022), with stateful and
message-aware contracts, plus [Bond](https://hex.pm/packages/bond),
[Oath](https://hex.pm/packages/oath) and ExContract — pre- and postconditions at the function
boundary, checked at runtime.

**Property-based testing.** [PropCheck](https://hex.pm/packages/propcheck) (a PropEr wrapper,
including a state-machine DSL), [Makina](https://hex.pm/packages/makina), and StreamData in the
standard library. These generate command sequences against a model — the nearest neighbour to
model checking in everyday Elixir use, and the difference is *sampling versus exhaustion*.

**Types and protocols.** Dialyzer and, in recent Elixir versions, the language's own set-theoretic
type system check what values flow where. [ElixirST](https://github.com/gertab/ElixirST)
(Tabone et al., University of Malta) checks message-passing protocols statically with session
types.

## Where ExTLA fits

**In the grand scheme:** ExTLA is an explicit-state model checker for finite models of designs,
written in and driven from Elixir, with a bridge from a checked design down to a running
GenServer. It is not a theorem prover (that is TLAPS), not a schedule explorer (that is
Concuerror), it does not extract models from source (Verlixir) and it does not generate code from
specifications (Erla+). What it does that none of the above does is let an Elixir team write the
specification *in Elixir*, check it with `mix`, and then check that the GenServer they wrote
actually refines it.

**In the Elixir environment,** the useful question is what each tool answers:

- **ExUnit** — does the code do the right thing on the examples I thought of?
- **StreamData / PropCheck** — does a property hold over many *generated* inputs or command
  sequences? Sampling, and excellent value; it will not tell you it looked everywhere.
- **Dialyzer and the type system** — do the values flowing through the code fit together?
- **Concuerror** — does *this code* misbehave under some schedule the BEAM could produce?
- **ElixirST** — do the messages between processes follow the protocol I declared?
- **ExTLA** — does the *design* admit a behaviour that violates my invariant, or fail ever to make
  progress? Answered exhaustively over a finite model, before or alongside the code, and then
  checked against the implementation.

None of these replaces another. The one gap ExTLA fills is the design-level, exhaustive,
temporal-property-bearing one — and it is the gap `00-prior-art.md` was written to establish is
real.

**Where to start** depends on what you have. A running GenServer and a property you are nervous
about: [Layer 1](06-layer1.md), invariants checked on every callback, no specification needed. A
protocol you are about to build: write the spec and check it — that is
[Getting started](../getting-started.md) and the next pages here. Both, and you want them
connected: [Layer 3](07-layer3.md).

## Sources

The two documents this page draws on both carry their own references:
[`00-prior-art.md` §Sources](../../spec/00-prior-art.md#sources) for the Elixir and Erlang work,
and [the primer's §Resources](../../research/tla-plus-primer.md#resources) for TLA+ itself —
Lamport's *Specifying Systems*, Hillel Wayne's *Practical TLA+* and Learn TLA+, Ron Pressler's
series, and the AWS paper.

---

Next: [The mathematics of TLA](01-mathematics.md).
