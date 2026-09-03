# Tutorial

[Getting started](getting-started.md) took one spec from `mix deps.get` to a counterexample. This
is the long path: the DSL as it is used, what the coverage report can tell you about a verdict,
temporal properties and the difference fairness makes to them, symmetry and who is responsible for
it, and then the two layers that connect a specification to running code.

One system runs through the whole of it — a lock with three clients — and each section adds
something to it. Every code block on this page is compiled and run by ExTLA's own test suite, and
every verdict the prose quotes is asserted against the run; the specification in [`spec/`](../spec/README.md)
remains the authority, and this page links to it rather than restating it.

## 1. The DSL in practice

Here is the lock, for three clients this time. Each client is idle, waiting, or holding; the lock
is free or not; any waiting client may take a free lock.

<!-- tla:spec -->
```elixir
defmodule Tutorial.Lock do
  use TLA.Spec

  constant :clients, default: set([:alice, :bob, :carol])

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

  invariant :holding_means_taken do
    Enum.all?(^clients, fn c -> pc[c] != :holding end) or free == false
  end
end
```

(The second invariant is there for §2, which is about reading what the checker says of it.)

### Three kinds of name

Inside a spec block, a name means one of three things, and the spelling tells you which
([§1](../spec/02-dsl-semantics.md#1-the-three-name-classes)). A **pinned** name, `^clients`, is a
constant: fixed for a whole run, supplied by `default:` or by config. A **bare** name, `free` or
`pc`, is a state variable: on the right of `=` it is the value before the step, on the left it is
the value after. And `let x = …` binds a local, which is ordinary Elixir and means nothing to the
checker. The compiler holds you to this — a constant written without its pin is an error rather
than a variable that happens not to exist:

<!-- tla:compile_error match="referenced without `^`" -->
```elixir
defmodule Tutorial.Unpinned do
  use TLA.Spec

  constant :limit, default: 3
  variable :n, type: 0..3

  init do
    n = 0
  end

  action :tick do
    require n < limit
    n = n + 1
  end
end
```

The message names the rule and the section that states it.

### Types

`type:` is a small language of its own ([§1.5](../spec/02-dsl-semantics.md#1-5-type-annotations)):
a list of literals is a choice among them, `a..b` is a range, `[^clients ~> t]` is a map whose keys
are exactly the clients and whose values have type `t` — a TLA+ function — and there are unions
(`^clients | :none`), tuples, records, `set(t)` and `seq(t)`. The type is not a restriction on
exploration; it is checked as an invariant, and §2 says what that means.

### Nondeterminism is `params:`, and only `params:`

`action :request, params: [c: ^clients]` is three actions, one per client, and the checker tries
every one in every state. That is where all the branching in a spec comes from. A `params:` entry
may draw from a constant, from a literal range or list, or from the state — `params: [c: fn s ->
s.some_set end]` — and a state function that returns nothing disables the action, exactly as a
false guard would ([§3](../spec/02-dsl-semantics.md#3-nondeterminism-comes-from-params-and-only-from-params)).
The body, given its params, is deterministic.

### An action is a conjunction

The rule most likely to surprise an Elixir programmer
([§2](../spec/02-dsl-semantics.md#2-an-action-block-is-a-conjunction-not-a-sequence)): the lines of
an action are not executed one after another. Every `require` is a guard on the state before the
step; every assignment is an equation about the state after it; every right-hand side reads the
pre-state, whatever order the lines are in; and a variable not assigned is unchanged. So a variable
cannot be assigned twice — that is two equations about one value, not a last write winning:

<!-- tla:compile_error match="assigned 2 times" -->
```elixir
defmodule Tutorial.Twice do
  use TLA.Spec

  variable :n, type: 0..3

  init do
    n = 0
  end

  action :tick do
    n = 1
    n = 2
  end
end
```

And every name on the left of `=` must be a declared variable — the compiler will not invent one:

<!-- tla:compile_error match="undeclared variable" -->
```elixir
defmodule Tutorial.Undeclared do
  use TLA.Spec

  variable :n, type: 0..3

  init do
    n = 0
  end

  action :tick do
    m = n + 1
  end
end
```

### The run

```sh
mix tla.check Tutorial.Lock
```

<!-- tla:check module=Tutorial.Lock expect=ok states=20 depth=5 -->
```
Tutorial.Lock — verified
  20 distinct states, 48 transitions, depth 5, 8ms

--- COVERAGE: Tutorial.Lock ----------------------------------------

Actions                   enabled in      states     distinct
  acquire                            7          12          12
  release                           12          12           0
  request                           16          24           7


Invariants                  evaluated   near-miss
  holding_means_taken               20          12
  mutual_exclusion                  20           -
  type_ok                           20           -
--------------------------------------------------------------------
```

Twenty states for three clients, and every one of them satisfies both invariants. The rest of
that report is §2.

## 2. Invariants

An `invariant` is a boolean over the variables that must hold in every reachable state. The
checker evaluates each one in each state it discovers, and stops at the first state where one is
false — that is the counterexample [Getting started](getting-started.md) ends with. This section
is about the other outcome: what the report says when every invariant *holds*, and why that is
worth reading.

### `type_ok` is an invariant you did not write

The `type:` on each variable is checked as an invariant named `type_ok`, in every state, which is
why the table lists one the spec never declared. A state outside its type is reported as a
violation of it. The type is not used to prune the search: a spec whose action drives a variable
out of range does not get a smaller state space, it gets a counterexample.

### The near-miss column

`holding_means_taken` reads *nobody is holding, or the lock is not free* — an implication, in the
`p or q` shape. Such an invariant can hold two ways: trivially, because `p` was true and `q` did not
matter, or because `p` was false and `q` carried it. The second is a **near miss**: a state in which
the invariant was actually pressed against. Of twenty states, twelve had a holder, and in each of
them `free == false` is what kept the invariant true.

`mutual_exclusion` shows `-`: it has no top-level `or`, so there is no non-trivial branch to
count, and the column says *not measured* rather than pretending. An invariant that IS measured
and reports `0` is flagged `<-- never at risk`: it held in every state without ever being pressed,
which is indistinguishable from `true`, and is the first thing to be suspicious of when a spec
verifies too easily.

### An action that was never enabled

The other way a spec verifies for the wrong reason. Add a `cancel` action to the lock — a waiting
client may give up — and make the mistake that is easiest to make:

<!-- tla:spec -->
```elixir
defmodule Tutorial.CancelLock do
  use TLA.Spec

  constant :clients, default: set([:alice, :bob, :carol])

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

  action :cancel, params: [c: ^clients] do
    require pc[c] == :wating
    pc = update(pc, c, fn _ -> :idle end)
  end

  invariant :mutual_exclusion do
    Enum.count(^clients, fn c -> pc[c] == :holding end) <= 1
  end

  invariant :holding_means_taken do
    Enum.all?(^clients, fn c -> pc[c] != :holding end) or free == false
  end
end
```

```sh
mix tla.check Tutorial.CancelLock
```

<!-- tla:check module=Tutorial.CancelLock expect=ok states=20 never_enabled=cancel -->
```
Tutorial.CancelLock — verified
  20 distinct states, 48 transitions, depth 5, 1ms

--- COVERAGE: Tutorial.CancelLock ----------------------------------

Actions                   enabled in      states     distinct
  acquire                            7          12          12
  cancel                             0           0           0   <-- NEVER ENABLED
  release                           12          12           0
  request                            16          24           7


Invariants                  evaluated   near-miss
  holding_means_taken               20          12
  mutual_exclusion                  20           -
  type_ok                           20           -

1 warning. Re-run with --strict-coverage to fail on these.
--------------------------------------------------------------------
warning: action :cancel was never enabled
```

`:wating` is not `:waiting`, and `pc[c]` is never equal to it, so `cancel` is never enabled — and
the spec **verifies**, with the same twenty states as before. Every invariant holds in a system that
has no cancellation in it. Nothing about the verdict is wrong; what is wrong is what it is a
verdict about. The coverage table is the only place that shows, and `--strict-coverage` is how you
make it exit 3 rather than print a warning.

Two other kinds of property belong to this family and are not built here: an `action_property`
constrains a *step* — `old` and `new` are bound, and it holds or fails per transition rather than
per state ([§4](../spec/02-dsl-semantics.md#4-action_property-uses-old-and-new)) — and a `terminal`
declares which successor-less states are final on purpose, so they are not reported as deadlocks
([§5.3](../spec/02-dsl-semantics.md#5-3-terminal-states-are-declared-not-inferred)).

## 3. Temporal properties, and the difference fairness makes

Nothing so far says the lock ever *does* anything. A spec in which every client waits forever
satisfies `mutual_exclusion` perfectly. Liveness is the other half: what must eventually happen.

<!-- tla:skip reason=a fragment of the modules below, shown on its own first -->
```elixir
temporal :no_starvation do
  Enum.all?(^clients, fn c -> (pc[c] == :waiting) ~> (pc[c] == :holding) end)
end
```

`p ~> q` is *leads-to*: whenever `p` holds, `q` holds at that point or later. The `Enum.all?` over
a constant is TLA+'s `\A c \in Clients`, one property per client. `always`, `eventually` and `~>`
are the operators, and the fragment they may form is bounded and stated
([§5.1](../spec/02-dsl-semantics.md#5-1-the-supported-temporal-fragment-is-bounded-say-so)); a
formula outside it is a compile error, never a silently weaker check.

A temporal property is checked when the spec declares one; `--safety-only` turns it off. And the
first thing you learn on checking one is that a leads-to is refuted by a system that is merely
*allowed* to stop — so a spec with a temporal property needs to say which actions the system can be
relied on to take. That is **fairness**, and there are two strengths of it.

### Weak fairness, refuted

**Weak** fairness on an action says: if the action stays enabled from some point on, it is
eventually taken. Declared per client — `acquire: [:c]` is one constraint for each value of `c`,
and §5.2 says why the whole-action form would not do:

<!-- tla:spec -->
```elixir
defmodule Tutorial.WeakLock do
  use TLA.Spec

  constant :clients, default: set([:alice, :bob, :carol])

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

  invariant :holding_means_taken do
    Enum.all?(^clients, fn c -> pc[c] != :holding end) or free == false
  end

  temporal :no_starvation do
    Enum.all?(^clients, fn c -> (pc[c] == :waiting) ~> (pc[c] == :holding) end)
  end

  fairness :weak, acquire: [:c], release: [:c]
end
```

```sh
mix tla.check Tutorial.WeakLock
```

<!-- tla:liveness module=Tutorial.WeakLock expect=violation property=no_starvation -->
```
Tutorial.WeakLock — LIVENESS: no_starvation
  20 distinct states, 48 transitions, depth 5, 19ms

═══ LIVENESS: no_starvation ════════════════════════════════════════

State 1 (Init):
  free = true
  pc   = %{alice: :idle, bob: :idle, carol: :idle}

── request(c: :alice) ────────────────────

State 2:
  free = true
  pc   = %{alice: :waiting, bob: :idle, carol: :idle}   ← changed

── request(c: :bob) ────────────────────

State 3:
  free = true
  pc   = %{alice: :waiting, bob: :waiting, carol: :idle}   ← changed

── acquire(c: :bob) ────────────────────

State 4:
  free = false   ← changed
  pc   = %{alice: :waiting, bob: :holding, carol: :idle}   ← changed

── release(c: :bob) ────────────────────

State 5 [VIOLATION]:
  free = true   ← changed
  pc   = %{alice: :waiting, bob: :idle, carol: :idle}   ← changed

════════════════════════════════════════════════════════════════════
↺ back to state 2 — states 2-4 repeat forever.
```

A liveness counterexample is not a trace that ends in a bad state; it is a **lasso** — a prefix,
then a cycle the system can repeat forever, along which the property never comes true. Read the
last line first: from state 5 the system is back in state 2, and states 2 to 4 repeat. Alice asks
for the lock in state 2 and is still waiting when the cycle closes. Bob requests, acquires and
releases, forever, and every step of that is one the fairness constraints permit — because
`acquire(c: :alice)` is *not continuously enabled*. It is disabled every time Bob holds the lock.
Weak fairness obliges nothing about an action that keeps being switched off, and this is exactly
the behaviour it does not rule out.

### Strong fairness, holding

**Strong** fairness says: if the action is enabled *infinitely often* — even intermittently — it
is eventually taken. That is the guarantee a lock needs, since a lock is by nature free only now
and then:

<!-- tla:spec -->
```elixir
defmodule Tutorial.StrongLock do
  use TLA.Spec

  constant :clients, default: set([:alice, :bob, :carol])

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

  invariant :holding_means_taken do
    Enum.all?(^clients, fn c -> pc[c] != :holding end) or free == false
  end

  temporal :no_starvation do
    Enum.all?(^clients, fn c -> (pc[c] == :waiting) ~> (pc[c] == :holding) end)
  end

  fairness :strong, acquire: [:c]
  fairness :weak, release: [:c]
end
```

```sh
mix tla.check Tutorial.StrongLock
```

<!-- tla:liveness module=Tutorial.StrongLock expect=ok -->
```
Tutorial.StrongLock — verified
  20 distinct states, 48 transitions, depth 5, 3ms
```

The same twenty states, the same transitions, the same property — and it holds. Nothing changed
but the assumption about how the system is scheduled, which is what fairness is: a claim about the
implementation, that it will not starve an intermittently-enabled step. `release` keeps weak
fairness, because a holder's `release` stays enabled until it is taken, and weak is enough.

### Per client, not per action

One more version, because it is the mistake §5.2 exists to name. `fairness :strong, [:acquire]`
without the `[:c]` is strong fairness on the action as a whole: if *some* client's `acquire` is
enabled infinitely often, *some* client eventually acquires. Bob acquiring satisfies that. Alice
waits forever anyway:

<!-- tla:spec -->
```elixir
defmodule Tutorial.WholeActionLock do
  use TLA.Spec

  constant :clients, default: set([:alice, :bob, :carol])

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

  invariant :holding_means_taken do
    Enum.all?(^clients, fn c -> pc[c] != :holding end) or free == false
  end

  temporal :no_starvation do
    Enum.all?(^clients, fn c -> (pc[c] == :waiting) ~> (pc[c] == :holding) end)
  end

  fairness :strong, [:acquire]
  fairness :weak, release: [:c]
end
```

<!-- tla:liveness module=Tutorial.WholeActionLock expect=violation property=no_starvation -->
```
Tutorial.WholeActionLock — LIVENESS: no_starvation
```

Same lasso as the weak one. TLA+ writes `\A c \in Clients : SF_vars(Acquire(c))`, and so does
ExTLA — `acquire: [:c]`. The named params must draw from a constant, for the reason the compiler
gives if you try otherwise: a state-drawn param has no fixed set of bindings to attach a
constraint to ([§5.2](../spec/02-dsl-semantics.md#5-2-fairness-is-declared-per-action-or-per-parameter-binding)).

## 4. Symmetry, and who is responsible for it

Alice, Bob and Carol are interchangeable. A state in which Alice holds the lock and Bob waits is,
for every property in the spec, the same state as one in which Bob holds it and Alice waits — and
the checker explores both. **Symmetry reduction** declares a constant whose elements cannot be told
apart, and the checker then keeps one representative of each set of states that differ only by a
permutation of them. For *n* interchangeable elements the state space shrinks by up to *n*!, and
that is the difference between tractable and not for exactly the systems this tool is for
([§Symmetry](../spec/04-layer2-model-checker.md#symmetry)).

The declaration sits beside the constants, in config:

<!-- tla:skip reason=a config.exs fragment, not a spec -->
```elixir
config :extla, Tutorial.StrongLock, symmetry: [:clients]
```

```sh
mix tla.check Tutorial.StrongLock --verify-symmetry
```

<!-- tla:check module=Tutorial.StrongLock expect=ok states=20 depth=5 -->
<!-- tla:check module=Tutorial.StrongLock expect=ok symmetry=clients verify_symmetry=true states=7 depth=5 -->
```
Tutorial.StrongLock — verified
  7 distinct states, 18 transitions, depth 5, 4ms

--- COVERAGE: Tutorial.StrongLock ----------------------------------

Actions                   enabled in      states     distinct
  acquire                            3           6           3
  release                            3           3           0
  request                            5           9           3


Invariants                  evaluated   near-miss
  holding_means_taken                7           3
  mutual_exclusion                   7           -
  type_ok                            7           -
--------------------------------------------------------------------
warning: 1 temporal property was declared and not checked: pass `check_liveness: true`.
warning: liveness was not checked: symmetry reduction and liveness are not sound together — the quotient graph can have cycles the real state space does not. Check the temporal properties in a run without `symmetry:`.
```

Seven states instead of twenty, and the same verdict on every invariant. Two things in that output
deserve a closer look.

The second warning is [D-22](../spec/08-decisions.md): symmetry and liveness are refused
together. The reduced graph identifies states, so a path that leaves an orbit and one that returns
to it look alike, and the quotient can contain cycles the real system does not have — and a cycle
is exactly what a liveness verdict is read off. Rather than answer with something it cannot stand
behind, the checker checks safety under the reduction and tells you to check the temporal
properties in a run without it. (`--workers` is refused alongside liveness for a neighbouring
reason, [D-27](../spec/08-decisions.md).)

The first thing is the flag on the command line. **Nothing can establish that a `symmetry:`
declaration is sound.** A constant flows into arbitrary Elixir, and whether some invariant or
guard treats Alice differently from Carol is not a question a compiler can answer — an earlier
draft of this project promised to, and was promising the undecidable
([D-17](../spec/08-decisions.md)). Soundness is the author's obligation, exactly as it is in TLC.
What `--verify-symmetry` does is make a wrong declaration **detectable**: it runs the model both
ways and fails if any verdict differs — the status, what was refuted, which actions never fired.
Not the counts; a sound reduction changes those on purpose.

Here is a declaration that is wrong, on a spec whose one invariant can tell the clients apart:

<!-- tla:spec -->
```elixir
defmodule Tutorial.NamedLock do
  use TLA.Spec

  constant :clients, default: set([:alice, :bob, :carol])

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

  invariant :carol_never_holds do
    pc[:carol] != :holding
  end
end
```

Without any reduction, that invariant is simply false — Carol requests, Carol acquires, two steps:

<!-- tla:check module=Tutorial.NamedLock expect=violation property=carol_never_holds length=3 -->
```
Tutorial.NamedLock — VIOLATION: carol_never_holds
  10 distinct states, 12 transitions, depth 3, 0ms
```

Declare `symmetry: [:clients]` for it and the reduction collapses the state in which Carol holds
the lock into the one in which Alice does. The invariant does not mention Alice. It *holds* under
the reduction — a real violation, hidden by a declaration the spec did not deserve. With
`--verify-symmetry`:

<!-- tla:check module=Tutorial.NamedLock expect=unsound_symmetry symmetry=clients -->
```
Tutorial.NamedLock — UNSOUND SYMMETRY

symmetry: [:clients] is not sound for this spec. The same model gives different
answers with and without the reduction:
  status: :ok with the reduction, :violation without
  never_enabled: [] with the reduction, [:release] without
  refuted: nil with the reduction, :carol_never_holds without
Something in the spec can tell the elements of [:clients] apart — an
`Enum.at`, a sort, a comparison on names, a dependence on list position — so
collapsing them dropped a state whose verdict mattered. Nothing can check this
statically (08-decisions.md D-17); this is the check that catches it.
```

Exit code 1, the same as a violation, because the answer the reduced run gave cannot be trusted.
The check is cheap on a small constant assignment; run it once per spec before trusting the
reduction on the large one.

In a test, the same run is `assert_spec` with a config, which fails the test on a violation and —
deliberately — on a run that hit a state limit, because an unfinished run is not a pass:

<!-- tla:run expect=ok -->
```elixir
import TLA.Spec.Test

assert_spec Tutorial.StrongLock, %{
  constants: %{clients: MapSet.new([:alice, :bob, :carol])},
  symmetry: [:clients],
  verify_symmetry: true
}
```

## 5. Layer 1 — invariants on a running GenServer

Everything so far has been about the specification. The implementation has not existed. Layer 1
is the smallest step towards it: state a property of a GenServer's state *in the GenServer*, and
have it checked after every callback.

<!-- tla:spec -->
```elixir
defmodule Tutorial.LockServer do
  use GenServer
  use TLA.Invariant

  invariant :holder_is_not_waiting do
    state.holder == nil or state.holder not in state.waiting
  end

  precondition {:release, c}, desc: "only the holder releases" do
    state.holder == c
  end

  postcondition {:acquire, c} do
    new.holder == c and c not in new.waiting
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts), do: {:ok, %{holder: nil, waiting: []}}

  @impl true
  def handle_call({:request, c}, _from, s), do: {:reply, :ok, %{s | waiting: s.waiting ++ [c]}}

  def handle_call({:acquire, c}, _from, %{holder: nil} = s),
    do: {:reply, :ok, %{s | holder: c, waiting: List.delete(s.waiting, c)}}

  def handle_call({:release, c}, _from, s),
    do: {:reply, :ok, %{s | holder: nil, waiting: List.delete(s.waiting, c)}}
end
```

The blocks are bare boolean expressions, the same shape as a spec's, with one difference: `state`
is written explicitly. A spec has `variable` declarations to resolve a bare name against, and an
arbitrary GenServer has none, so Layer 1 does not guess
([`03-layer1-invariants.md`](../spec/03-layer1-invariants.md)). An `invariant` is checked after
every callback; a `precondition` is matched against the incoming message — its pattern binds `c` —
and checked before the callback runs; a `postcondition` sees `old`, `new` and the pattern's
bindings after it returns. `action_property` is there too, with `old` and `new`.

Used correctly, nothing is different:

<!-- tla:run expect=ok -->
```elixir
{:ok, pid} = Tutorial.LockServer.start_link()
:ok = GenServer.call(pid, {:request, :alice})
:ok = GenServer.call(pid, {:acquire, :alice})
:ok = GenServer.call(pid, {:release, :alice})
```

Used wrongly, the callback never runs. Bob releasing a lock Alice holds:

<!-- tla:run expect=raise match="only the holder releases" -->
```elixir
{:ok, pid} = Tutorial.LockServer.start_link()
:ok = GenServer.call(pid, {:request, :alice})
:ok = GenServer.call(pid, {:acquire, :alice})
GenServer.call(pid, {:release, :bob})
```

```
** (TLA.Invariant.Violation) ═══ PRECONDITION VIOLATED: handle_call ═════════════════════════════
  only the holder releases
  module: Tutorial.LockServer
  message: {:release, :bob}
  state:
    holder  = :alice
    waiting = []
```

The server raises, which in a supervised system means it restarts and the caller's `call` exits
with the violation as its reason. That is the `:enabled` mode. `:log_only` logs the same report and
lets the callback proceed, and `:disabled` — the default under `MIX_ENV=prod` — compiles the checks
out entirely: a module compiled `:disabled` is the module its author wrote, which is what "zero
production cost" means. The mode is `config :extla, mode: …`, read at compile time.

Layer 1 knows nothing about `Tutorial.Lock`. It checks the properties you wrote *about the
implementation*, in the implementation's own terms, which is useful and is also the limit of it:
`holder_is_not_waiting` could hold forever in a server that never lets anyone acquire. Relating the
code to the specification is Layer 3.

## 6. Layer 3 — does the implementation conform?

A specification describes abstract states and the steps between them. An implementation has
concrete state — a map with `holder` and `waiting` in it — and messages. Conformance means that
every step the implementation takes, seen through a mapping to the abstract state, is a step the
specification allows. The mapping is a **refinement**:

<!-- tla:spec -->
```elixir
defmodule Tutorial.Refinement do
  use TLA.Refinement

  def abstract(%{holder: holder, waiting: waiting}) do
    pc =
      Map.new([:alice, :bob, :carol], fn c ->
        {c,
         cond do
           holder == c -> :holding
           c in waiting -> :waiting
           true -> :idle
         end}
      end)

    %{free: holder == nil, pc: pc}
  end

  def abstract_action({:request, c}), do: {:request, %{c: c}}
  def abstract_action({:acquire, c}), do: {:acquire, %{c: c}}
  def abstract_action({:release, c}), do: {:release, %{c: c}}
  def abstract_action(_), do: :unmapped

  def concrete_message(:request, %{c: c}), do: {:request, c}
  def concrete_message(:acquire, %{c: c}), do: {:acquire, c}
  def concrete_message(:release, %{c: c}), do: {:release, c}
end
```

`abstract/1` maps a concrete state to the spec's variables — exactly the spec's variables, same
keys, same shapes. `abstract_action/1` maps a message to the spec action it performs, with its
params; `:unmapped` is not a shrug but a claim, that the message does not move the abstract state,
and it is checked as one. `concrete_message/2` is the inverse, and it is what lets the spec drive
the implementation. The mapping is validated when the server compiles: one that forgets a variable
or an action fails the build.

Now the server, with the mapping attached:

<!-- tla:spec -->
```elixir
defmodule Tutorial.CheckedLockServer do
  use GenServer
  use TLA.GenServer, spec: Tutorial.Lock, refinement: Tutorial.Refinement

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts), do: {:ok, %{holder: nil, waiting: []}}

  @impl true
  def handle_call({:request, c}, _from, s), do: {:reply, :ok, %{s | waiting: s.waiting ++ [c]}}

  def handle_call({:acquire, c}, _from, %{holder: nil} = s),
    do: {:reply, :ok, %{s | holder: c, waiting: List.delete(s.waiting, c)}}

  def handle_call({:release, c}, _from, %{holder: c} = s), do: {:reply, :ok, %{s | holder: nil}}
end
```

`use TLA.GenServer` wraps every callback (Layer 1 is built in). After each one, the pre- and
post-states go through `abstract/1`, the message through `abstract_action/1`, and the step is
checked for **legality**: the named action's guard must have held in the abstract pre-state, and
the spec's transition from that state must produce exactly the abstract post-state. That second
half is the refinement check, and it is what makes this conformance rather than a projection with
some predicates on it ([§What conformance means here](../spec/05-layer3-conformance.md#what-conformance-means-here)).
Acquire without having requested, which the code is perfectly willing to do and the spec is not:

<!-- tla:run expect=raise match="NOT ENABLED" -->
```elixir
{:ok, pid} = Tutorial.CheckedLockServer.start_link()
GenServer.call(pid, {:acquire, :alice})
```

```
═══ CONFORMANCE: NOT ENABLED ═════════════════════════════════════════════════
  The implementation took :acquire, which the spec does not permit here.
  The guard is false in this state for every binding the mapping admits.
  abstract pre-state:
        free = true
        pc = %{alice: :idle, bob: :idle, carol: :idle}
  spec:   Tutorial.Lock
```

### Simulation: random traces, every step checked

Driving the server by hand finds what you thought to try. `mix tla.simulate` generates messages
from the spec — those whose action is enabled in the current abstract state, via
`concrete_message/2` — and runs them against the live server, checking every step as above:

```sh
mix tla.simulate Tutorial.CheckedLockServer --seed 1
```

<!-- tla:simulate module=Tutorial.CheckedLockServer expect=ok -->
```
Tutorial.CheckedLockServer — NO FINDING
  100 traces, 2500 steps, 0 restarts, 179ms, seed 1
  covered 100% of the spec's actions: acquire x800, release x738, request x962
  20 distinct abstract states
```

A run like this has checked the traces it drew and nothing else, and the report says which actions
those were: all three, and all twenty of the abstract states §1 counted. The seed is always
printed so that a finding can be run again.

Here is a server with a bug in it. On `release` it puts the client back on the waiting list — an
off-by-one in somebody's idea of a queue:

<!-- tla:spec -->
```elixir
defmodule Tutorial.LeakyLockServer do
  use GenServer
  use TLA.GenServer, spec: Tutorial.Lock, refinement: Tutorial.Refinement

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts), do: {:ok, %{holder: nil, waiting: []}}

  @impl true
  def handle_call({:request, c}, _from, s), do: {:reply, :ok, %{s | waiting: s.waiting ++ [c]}}

  def handle_call({:acquire, c}, _from, %{holder: nil} = s),
    do: {:reply, :ok, %{s | holder: c, waiting: List.delete(s.waiting, c)}}

  def handle_call({:release, c}, _from, %{holder: c} = s),
    do: {:reply, :ok, %{s | holder: nil, waiting: s.waiting ++ [c]}}
end
```

```sh
mix tla.simulate Tutorial.LeakyLockServer --seed 1
```

<!-- tla:simulate module=Tutorial.LeakyLockServer expect=violation match="DIVERGED" -->
```
Tutorial.LeakyLockServer — CONFORMANCE VIOLATION: diverged
  100 traces, 447 steps, 0 restarts, 32ms, seed 1
  covered 100% of the spec's actions: acquire x100, release x100, request x247
  20 distinct abstract states

═══ CONFORMANCE: DIVERGED ════════════════════════════════════════════════════
  :release is enabled, but the spec's transition does not produce what the
  implementation produced. Closest candidate binding: %{c: :alice}
  variables that differ:
        pc:
          spec:           %{alice: :idle, bob: :waiting, carol: :waiting}
          implementation: %{alice: :waiting, bob: :waiting, carol: :waiting}
  abstract pre-state:
        free = false
        pc = %{alice: :holding, bob: :waiting, carol: :waiting}
  spec:   Tutorial.Lock

═══ VIOLATION: diverged ════════════════════════════════════════════
…
── release(c: :alice) ────────────────────

State 6 [VIOLATION]:
  free = true   ← changed
  pc   = %{alice: :waiting, bob: :waiting, carol: :waiting}   ← changed
════════════════════════════════════════════════════════════════════
```

Every invariant of `Tutorial.Lock` holds in that post-state. Alice is waiting, nobody holds, the
lock is free — a state the spec has. What the spec does not have is a `release` step that lands
there, and that is why the *step* is what gets checked. The finding is a `TLA.Trace`, the same
shape the model checker produces, and the report shows the whole behaviour that led to it.

### Replay: the counterexample, run against the code

The loop that makes the three layers one tool. §4's `Tutorial.NamedLock` has a counterexample —
Carol requests, Carol acquires — found by the checker before any code existed. `TLA.Replay` drives
a server through that exact sequence, via `concrete_message/2`, and checks each state it reaches
against the trace's:

<!-- tla:run expect=ok -->
```elixir
result = TLA.ModelChecker.run(Tutorial.NamedLock, %{constants: %{clients: MapSet.new([:alice, :bob, :carol])}})
%{status: :violation} = result

report = TLA.Replay.counterexample(Tutorial.CheckedLockServer, result.violation)
%{status: :ok, steps_checked: 2} = report
```

`:ok` here means **reproduced**: the running server performed both steps and arrived, state for
state, where the checker said it would. The abstract finding is a fact about the code. And a
Layer 3 finding replays the same way — the leaky server's trace, run against the leaky server,
diverges at the same step:

<!-- tla:run expect=ok -->
```elixir
simulation = TLA.Simulation.run(Tutorial.LeakyLockServer, %{traces: 100, max_steps: 25, seed: 1})
%{status: :violation} = simulation

report = TLA.Replay.counterexample(Tutorial.LeakyLockServer, simulation.violation)
%{status: :violation, violation: %{kind: :diverged}} = report
```

From the shell the counterexample travels as JSON — `mix tla.check --format json` writes it, and
`mix tla.replay` reads it:

```sh
mix tla.check Tutorial.NamedLock --format json > counterexample.json
mix tla.replay Tutorial.CheckedLockServer --trace counterexample.json
```

`mix tla.replay` exits 0 when the behaviour was reproduced, 1 on a conformance violation, and 2
when the implementation *could not follow* the trace — which is not a conformance failure: the spec
permits a behaviour the code does not take, and which of the two is wrong is not something the tool
can decide. It says so, rather than guessing.

That is the whole pipeline
([§Full verification pipeline](../spec/05-layer3-conformance.md#full-verification-pipeline)): model
check the spec, so design bugs are found before the code exists; simulate the implementation against
it, so the code is held to the design; replay any counterexample against the code, so a finding at
either level is a fact about both. `TLA.PropertyTest` hands the spec's own generators to a
`check all` of your own, for the property tests that keep it that way in CI.

## Where to next

- [`02-dsl-semantics.md`](../spec/02-dsl-semantics.md) — the DSL, normatively. Every rule this
  page leaned on is stated there with its reason.
- [`04-layer2-model-checker.md`](../spec/04-layer2-model-checker.md) — the checker: what a run
  computes, the JSON result schema, state constraints, symmetry, parallel exploration.
- [`05-layer3-conformance.md`](../spec/05-layer3-conformance.md) — `TLA.GenServer`,
  `TLA.Refinement`, `TLA.Simulation`, `TLA.Replay`, and `--against-graph`, which checks Layers 2
  and 3 against each other.
- [`07-examples.md`](../spec/07-examples.md) — whole specifications with implementations, including
  the distributed lock this tutorial's is a small cousin of.
- [`08-decisions.md`](../spec/08-decisions.md) — why the tool is shaped the way it is, decision by
  decision.
