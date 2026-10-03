# The mathematics of TLA, and what it is good for

ExTLA tutorial. Previous: [Introduction](00-introduction.md).

A verdict is only worth as much as you understand it. `verified` does not mean "correct", and
knowing exactly what it *does* mean — and what a counterexample proves, and what a bound takes
away — is the difference between using this tool and believing it. That is what this page is for.

It uses TLA+'s notation beside ExTLA's, because the literature is written in it;
[`research/tla-plus-primer.md`](../../research/tla-plus-primer.md) is the reference for the
language itself and this page cites it rather than repeating it.

## 1. States, behaviours, and actions

Three definitions carry everything else.

A **state** is an assignment of a value to every variable. If a spec declares `free` and `pc`,
then `free = true, pc = %{alice: :idle}` is one state, and the *state space* is every combination
the variables' types admit.

A **behaviour** is an infinite sequence of states: `s₁ → s₂ → s₃ → …`. This is the object a
specification is about. A specification does not describe a program; it describes a **set of
behaviours** — the ones the system is allowed to exhibit. Verification asks whether every
behaviour in that set has some property.

A **step** is a pair of consecutive states, and an **action** is a predicate on such a pair. It
does not mutate anything: it *relates* a pre-state to a post-state, and is either true or false of
the pair. TLA+ writes the post-state with a prime — `count' = count + 1` is a predicate saying the
post-state's `count` is one more than the pre-state's.

This is the formal content of the DSL rule that surprises Elixir programmers most. In ExTLA:

<!-- tla:skip reason=an action body on its own, not a compilable module -->
```elixir
action :acquire, params: [c: ^clients] do
  require pc[c] == :waiting
  require free
  free = false
  pc   = update(pc, c, fn _ -> :holding end)
end
```

is not four statements. It is one predicate — *`pc[c]` was `:waiting` **and** `free` held **and**
`free'` is false **and** `pc'` is `pc` with `c` set to `:holding`* — and the `=` signs are
equations about the post-state, not assignments. Order cannot matter, because conjunction is
commutative; a variable cannot be assigned twice, because two equations about one value are a
contradiction rather than a sequence; and an unassigned variable is unchanged, because that is
what the conjunction leaves implied. [`02-dsl-semantics.md` §2](../../spec/02-dsl-semantics.md#2-an-action-block-is-a-conjunction-not-a-sequence)
states the rule; this is why it holds.

## 2. The specification formula

A complete TLA+ specification is one formula:

```
Spec == Init ∧ □[Next]_vars ∧ Fairness
```

Three conjuncts, and each does one job.

**`Init`** is a predicate on a single state, true of the states a behaviour may start in.

**`□[Next]_vars`** — read "always, Next or unchanged" — constrains every step. `Next` is the
disjunction of all the actions: *some* action relates each state to the next. `□` is the temporal
operator "in every state of the behaviour". The square brackets are the part worth pausing on:
`[Next]_vars` means `Next ∨ (vars' = vars)`, so a step in which **nothing changes** is always
allowed. Those are **stuttering** steps, and permitting them is deliberate:

- a real system can pause, crash, or be descheduled, and a specification that forbade standing
  still would be refuted by reality;
- it makes specifications composable — adding a component to a system introduces steps in which
  the original component does nothing, and those must not violate the original spec;
- and it is what makes refinement work at all, since an implementation typically takes several
  steps where the specification takes one.

The price is that stuttering forever satisfies every safety property. A specification of `Init` and
`Next` alone permits the behaviour in which the system starts and then does nothing at all,
forever. Which is what the third conjunct is for.

**`Fairness`** rules out that behaviour, by requiring that some actions eventually happen. It is
the only conjunct that is an *assumption about the implementation* rather than a description of
it — §4 returns to it.

ExTLA writes these as `init`, `action`, and `fairness` declarations rather than as a formula, and
assembles them into the same thing. There is no `spec do … end` block precisely because the
formula's shape is fixed.

## 3. Safety and liveness

Properties come in two kinds, and the difference is not stylistic — it determines what a
counterexample can even look like.

A **safety** property says nothing bad happens. Formally: it is refuted by a *finite prefix* of a
behaviour. If `count` is 11 in state 7, no continuation can repair that — the property is already
false. Invariants are the common case (`□Inv`, a predicate that must hold in every reachable
state), and so are action properties (`□[P]_vars`, a predicate on every step).

A **liveness** property says something good eventually happens, and it cannot be refuted by any
finite prefix: whatever has happened so far, the good thing might still happen next. Refuting one
requires exhibiting an *infinite* behaviour in which it never does — and since the state space is
finite, an infinite behaviour must revisit a state, so it is a **lasso**: a finite prefix, then a
cycle repeated forever.

That is why the two counterexamples in this tutorial have different shapes. An invariant violation
is a trace ending in a bad state. A refuted temporal property is a prefix plus a cycle, with a
`↺ back to state 2` line under it — [Temporal properties](04-temporal.md) shows one.

The operators ExTLA supports, in TLA+ notation and in the DSL:

| TLA+ | ExTLA | Meaning |
|---|---|---|
| `□P` | `always(P)` | in every state |
| `◇P` | `eventually(P)` | in some state |
| `P ⇝ Q` | `P ~> Q` | whenever `P` holds, `Q` holds then or later |
| `∀x ∈ C : F(x)` | `Enum.all?(^C, fn x -> F(x) end)` | one property per element |

`P ⇝ Q` is itself shorthand for `□(P ⇒ ◇Q)`. The supported fragment stops there, deliberately and
[in writing](../../spec/02-dsl-semantics.md#5-1-the-supported-temporal-fragment-is-bounded-say-so):
it is what can be decided by analysing the graph's strongly-connected components, and a formula
outside it is a compile error rather than a weaker check performed quietly.

## 4. Fairness, and why liveness needs it

An action is **ENABLED** in a state when some binding of its parameters makes its guard true —
when the system *could* take it. Fairness constrains behaviours in which an action is enabled and
never taken.

| | TLA+ | Requires the action to be taken if it is |
|---|---|---|
| **Weak** | `WF_vars(A)` | *continuously* enabled from some point on |
| **Strong** | `SF_vars(A)` | enabled *infinitely often*, even intermittently |

Weak fairness is the weaker assumption and the commoner one: a process that can always proceed
eventually does. Strong fairness is what you need when the opportunity comes and goes — a lock is
free, someone takes it, it is free again — because such an action is never *continuously* enabled,
and weak fairness therefore promises nothing about it. [Temporal properties](04-temporal.md) is
this paragraph made concrete: the same lock, the same property, refuted under weak fairness and
holding under strong.

One subtlety that the DSL takes seriously. `WF_vars(A)` treats the action as a whole: if *some*
binding is continuously enabled, *some* binding is eventually taken. For a per-process property
that is useless — one process starving while others take turns satisfies it. What is needed is
`∀p ∈ Procs : WF_vars(A(p))`, a separate constraint per binding, which ExTLA writes
`fairness :weak, acquire: [:c]`
([§5.2](../../spec/02-dsl-semantics.md#5-2-fairness-is-declared-per-action-or-per-parameter-binding)).

Fairness is an **assumption**, not a fact. Writing it down is a claim that the scheduler,
the network, or the runtime will not starve that step forever — and if the claim is false, a
liveness verdict established under it says nothing about the real system.

## 5. Refinement is implication

An implementation conforms to a specification when **every behaviour it can exhibit is a
behaviour the specification allows.** With a mapping from concrete states to abstract ones, that is
just implication between formulas:

```
Impl ⇒ Spec
```

The mapping — the *refinement* — is what makes the two comparable: it says what the
implementation's `%{holder: :alice, waiting: [:bob]}` *means* as the specification's `free` and
`pc`. Given it, conformance is a claim about every step: the abstract pre-state must have enabled
the named action, and the action must relate it to exactly the abstract post-state.

This is why [Layer 3](07-layer3.md) checks *steps* rather than states. An implementation whose
abstract states all satisfy the invariants has proved something much weaker — it may still take a
step from one legal state to another legal state by a transition the specification does not have,
which is a real bug and invisible to any invariant. Implication is between behaviours, so
conformance has to be checked per step.

## 6. How this verifies an algorithm

Two routes lead from a specification to a verdict, and it is worth knowing which one you are on.

**By induction.** To prove `□Inv` for all parameter values, show two things: `Init ⇒ Inv`, and
`Inv ∧ Next ⇒ Inv'`. If the invariant holds initially, and every action preserves it, then it
holds in every reachable state — of any size of system, unboundedly. This is what TLAPS and the
proof assistants do, and it needs a human to find an inductive invariant strong enough to be
preserved, which is genuinely hard.

**By exhaustion.** Fix the constants — three clients, not *n* — and the state space becomes
finite. Then enumerate it: start from the initial states, apply every action to every state, and
check the invariants in each new one. No ingenuity required. This is model checking, it is what
`mix extla.check` does, and the mechanics are visible in the report — breadth-first, so the first
violating state found is the *nearest* one, which is why a counterexample is the shortest.

Here is the lock this tutorial is built around — the same three actions and the same invariant
the [next page](02-dsl.md) develops, with six clients rather than three so that its state space is
large enough for a bound to bite. It is declared here rather than borrowed because this page is
read *before* that one, and every code block in these guides is compiled from the page it appears
on.

<!-- tla:spec -->
```elixir
defmodule Math.Lock do
  use ExTLA.Spec

  constant :clients, default: set([:a, :b, :c, :d, :e, :f])

  variable :free, type: [true, false]
  variable :pc,   type: [^clients ~> [:idle, :waiting, :holding]]

  init do
    free = true
    pc   = for_each(^clients, fn _ -> :idle end)
  end

  action :request, params: [c: ^clients] do
    require pc[c] == :idle
    pc = update(pc, c, fn _ -> :waiting end)
  end

  action :acquire, params: [c: ^clients] do
    require pc[c] == :waiting
    require free
    free = false
    pc   = update(pc, c, fn _ -> :holding end)
  end

  action :release, params: [c: ^clients] do
    require pc[c] == :holding
    free = true
    pc   = update(pc, c, fn _ -> :idle end)
  end

  invariant :mutual_exclusion do
    Enum.count(^clients, fn c -> pc[c] == :holding end) <= 1
  end
end
```

```sh
mix extla.check Math.Lock
```

<!-- tla:check module=Math.Lock expect=ok states=256 depth=8 -->
```
Math.Lock — verified
  256 distinct states, 1056 transitions, depth 8, 41ms
```

### What that verdict claims, exactly

**A counterexample is a proof.** When the checker reports a violation it hands you a sequence of
concrete steps from an initial state to a state where a named property is false. You can follow it
by hand and confirm each step is one the specification permits. It is not evidence of a bug; it is
a demonstration of one, and it stays true no matter how the tool is later improved.

**A green run is a proof about the model.** `verified` above means: every state reachable *from
these initial states*, *under these constants*, satisfies every invariant. It says nothing about
seven clients. It says nothing about the code. It says nothing about a client that can crash, if
the specification has no action for crashing — the model contains exactly what you wrote, and
verifying it proves the design has no bug **of the kind expressible in it**.

This is why small models are not a limitation to be apologised for. Bugs in concurrent designs
almost always show up at small parameters — two or three processes are enough for nearly every
interleaving bug there is — so a small model that you can actually check exhaustively is worth far
more than a large one you cannot.

**And a bounded run is not a verdict at all.** If the search stops early the answer is not "no bug
found" but "the question was not answered", and the tool must not blur the two. The same
specification, given a state limit smaller than its state space:

```sh
mix extla.check Math.Lock --max-states 100
```

<!-- tla:check module=Math.Lock expect=incomplete max_states=100 states=101 -->
```
Math.Lock — INCOMPLETE (state limit)
  101 distinct states, 208 transitions, depth 5, 12ms
```

Exit code **2**, not 0 — a separate code from both success and violation, because "we ran out of
budget" is not "it holds". A run cut short by a state constraint reports the same way. Nothing was
found; nothing was established either.

## What the method is useful for

- **Concurrent and distributed protocol design** — consensus, replication, leader election, cache
  coherence, two-phase commit, locking. Anything whose failures are orderings.
- **Properties you can state but cannot test** — mutual exclusion over all interleavings, "no
  message is lost", "every waiter is eventually served".
- **Designs, before the code exists.** This is the cheapest possible moment to find a protocol bug,
  and the reason to write the specification first.
- **Small models that generalise.** Two or three of everything, exhaustively.
- **Finding out what your design actually says.** Writing the specification is itself most of the
  value; a surprising number of bugs surface while trying to state the invariant precisely.
- **Keeping a design and an implementation in step**, which is what Layers 1 and 3 add to the
  usual TLA+ story.

## What it is not useful for

- **Performance, latency, or throughput.** A specification has no notion of time or cost. It will
  tell you a design is correct and nothing about whether it is fast.
- **Real-time deadlines and probabilities.** Timed and probabilistic model checking are different
  disciplines with different tools, and both are
  [non-goals](../../spec/06-architecture.md#non-goals) — no clocks, no distributions.
- **Verifying the implementation itself.** Layer 3 checks that a GenServer refines the spec on the
  behaviours it is driven through — real evidence, but sampled, not exhaustive. A proof about the
  code would need a different tool entirely.
- **Data-heavy state.** A specification whose variables hold realistic payloads has an
  astronomical state space. Abstract the data away — most protocol bugs do not depend on the bytes.
- **Unbounded parameters.** "Correct for all *n*" is an induction proof, not a model check. If you
  need it, TLAPS or a proof assistant is the tool.
- **Anything where you will not maintain the specification.** A spec that drifts from the system it
  describes is worse than none, because it is trusted. This is the defect the whole of this
  project's drift-gating exists to prevent, and it applies to your specs as much as to these
  guides.
- **Replacing tests.** It checks a model of the design. The code still has to be tested.

The trade, in one sentence: **model checking buys you exhaustiveness over a small abstraction of
your design, and it buys it by giving up on everything the abstraction left out.** Knowing what
you left out is the skill.

---

Next: [The DSL in practice](02-dsl.md).
