# Getting started

One sitting, one spec, one green run — and then one red one, because a model checker is an
abstraction until it hands you a concrete sequence of steps that reaches a state you said was
impossible. That moment is the point of this guide, and everything before it is setup.

Every code block on this page is compiled and run by ExTLA's own test suite, and every verdict
the prose quotes is asserted against the run. If the page says a spec verifies, it does; if it
says a trace is seven states long, it is.

## 1. Add ExTLA to a project

ExTLA is not on Hex. Point a Mix project at the repository and its tag:

<!-- tla:skip reason=a mix.exs fragment, not a spec -->
```elixir
def deps do
  [
    {:extla, git: "https://gitlab.conet.yarina.org/dco-tek/extla.git", tag: "v0.1.0"}
  ]
end
```

```sh
mix deps.get
```

ExTLA has no runtime dependencies of its own, so it goes in as a plain dependency: there is
nothing to keep out of production with `only:` or `runtime: false`.

## 2. Write a spec

A spec is an ordinary Elixir module that says `use TLA.Spec`. Put this one anywhere Mix compiles,
`lib/specs/lock.ex` say.

It describes a lock shared by two clients. Each client is idle, or waiting for the lock, or
holding it, and the lock is free or not. That is the whole state.

<!-- tla:spec -->
```elixir
defmodule Specs.Lock do
  use TLA.Spec

  constant :clients, default: set([:alice, :bob])

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

Reading it top to bottom:

- **`constant`** is something fixed for a whole run — here, who the clients are. Constants are
  written with a pin, `^clients`, wherever they are used. `default:` is the value `mix tla.check`
  uses when nothing else supplies one.
- **`variable`** is state. `free` is a boolean; `pc` is a map from each client to what that
  client is doing (TLA+ would call it a function). The `type:` is checked in every state the
  checker reaches, as an invariant named `type_ok` you get without declaring it.
- **`init`** assigns every variable its starting value. `for_each` builds the map.
- **`action`** is one atomic step the system can take. `require` is its guard: the action is
  *enabled* in a state only when every `require` holds there. The assignments describe the next
  state; a variable that is not assigned keeps its value. `params:` says the action exists once
  per client, and the checker tries every one.
- **`invariant`** is what must hold in every reachable state. This one is the lock property: at
  most one client is holding.

Two rules that will surprise an Elixir programmer, and are exactly what make this a specification
rather than a program: an action body is a *simultaneous* assignment, so every right-hand side
reads the state before the step, whatever order the lines are in; and there is no sequencing
inside an action — an action is atomic, all of it or none of it. The grammar and its semantics are
in [`02-dsl-semantics.md`](../spec/02-dsl-semantics.md); this page does not repeat them.

## 3. Check it, and read the output

```sh
mix tla.check Specs.Lock
```

<!-- tla:check module=Specs.Lock expect=ok states=8 depth=4 -->
```
Specs.Lock — verified
  8 distinct states, 14 transitions, depth 4, 8ms

--- COVERAGE: Specs.Lock -------------------------------------------

Actions                   enabled in      states     distinct
  acquire                            3           4           4
  release                            4           4           0
  request                            5           6           3


Invariants                  evaluated   near-miss
  mutual_exclusion                   8           -
  type_ok                            8           -
--------------------------------------------------------------------
```

The checker started from the initial state and took every enabled action, in every state it
found, until nothing new appeared. Then it said what it saw. (The time is the one thing that will
differ on your machine.)

**`verified`** means every reachable state satisfied every invariant, and the exploration was
complete: there is no `--max-states` cap and no state constraint that stopped it early. A run that
*was* cut short reports `INCOMPLETE` and exits 2 instead of 0, because "we ran out of budget" is
not "it holds".

**`8 distinct states`** is the size of the whole state space for two clients. Every configuration
of `free` and `pc` the system can ever be in is one of those eight. **`14 transitions`** are the
edges between them. **`depth 4`** is how far from the initial state the search had to go: the
longest of the shortest paths, counted in states with the initial state as the first — here, the
initial state, `alice` requests, `alice` acquires, `bob` requests, and there is nowhere further
from the start than that.

Then the coverage table, which is the part worth learning to read, because it is where a spec that
verifies *for the wrong reason* gives itself away.

For each action: **`enabled in`** is the number of states in which its guard held for at least one
`params:` binding; **`states`** is how many successor states firing it produced; **`distinct`** is
how many of those had not been seen before. `release` produced 4 successors and 0 distinct ones,
which is right: releasing always returns the system to a state that was already reached on the
way in. An action with `0` in the first column is flagged `<-- NEVER ENABLED`, and that is the
warning to take seriously. A spec whose `cancel` action is never enabled has verified a system
with no cancellation in it — every invariant holds, and none of them was tested against the thing
you wrote the action for. `--strict-coverage` turns that warning into exit code 3.

For each invariant, **`evaluated`** is the number of states it was checked in, and it should equal
the number of distinct states. The **`near-miss`** column is `-` here because neither invariant
declares what a near miss would be; it is opt-in, and not needed today.

## 4. Break it on purpose

The `acquire` action does two things in one atomic step: it checks that the lock is free, and it
takes the lock. Now suppose the implementation does not. It reads `free`, sees `true`, and *then*,
as a separate step, sets it to `false` — a check-then-act that every programmer has written at
least once. Say that in the spec by splitting `acquire` in two. The only difference from
`Specs.Lock` is that one action became `see_free` and `take`, with a new `:ready` state in
between:

<!-- tla:spec -->
```elixir
defmodule Specs.SplitLock do
  use TLA.Spec

  constant :clients, default: set([:alice, :bob])

  variable :free, type: [true, false]
  variable :pc,   type: [^clients ~> [:idle, :waiting, :ready, :holding]]

  init do
    free = true
    pc   = for_each(^clients, fn _ -> :idle end)
  end

  action :request, params: [c: ^clients] do
    require pc[c] == :idle
    pc = update(pc, c, fn _ -> :waiting end)
  end

  action :see_free, params: [c: ^clients] do
    require pc[c] == :waiting
    require free
    pc = update(pc, c, fn _ -> :ready end)
  end

  action :take, params: [c: ^clients] do
    require pc[c] == :ready
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
mix tla.check Specs.SplitLock
```

<!-- tla:check module=Specs.SplitLock expect=violation invariant=mutual_exclusion length=7 -->
```
Specs.SplitLock — VIOLATION: mutual_exclusion
  16 distinct states, 25 transitions, depth 7, 11ms

═══ VIOLATION: mutual_exclusion ════════════════════════════════════

State 1 (Init):
  free = true
  pc   = %{alice: :idle, bob: :idle}

── request(c: :alice) ────────────────────

State 2:
  free = true
  pc   = %{alice: :waiting, bob: :idle}   ← changed

── request(c: :bob) ────────────────────

State 3:
  free = true
  pc   = %{alice: :waiting, bob: :waiting}   ← changed

── see_free(c: :alice) ────────────────────

State 4:
  free = true
  pc   = %{alice: :ready, bob: :waiting}   ← changed

── see_free(c: :bob) ────────────────────

State 5:
  free = true
  pc   = %{alice: :ready, bob: :ready}   ← changed

── take(c: :alice) ────────────────────

State 6:
  free = false   ← changed
  pc   = %{alice: :holding, bob: :ready}   ← changed

── take(c: :bob) ────────────────────

State 7 [VIOLATION]:
  free = false
  pc   = %{alice: :holding, bob: :holding}   ← changed

════════════════════════════════════════════════════════════════════


--- COVERAGE: Specs.SplitLock --------------------------------------

Actions                   enabled in      states     distinct
  release                            4           4           0
  request                            7           8           3
  see_free                           5           6           5
  take                               5           6           6


Invariants                  evaluated   near-miss
  mutual_exclusion                  16           -
  type_ok                           16           -

This run stopped at a counterexample, mid-expansion: the numbers are a lower bound, not a census.
--------------------------------------------------------------------
```

The exit code is 1, and the checker has printed a **counterexample**: a sequence of actions,
starting from the initial state, that ends in a state where `mutual_exclusion` is false. Read it
action by action. Both clients request. Alice looks at the lock and sees it free. *Bob looks at
the lock and sees it free too*, because Alice has not taken it yet. Alice takes it. Bob takes it.
State 7 has two holders.

Three things about this trace are worth knowing.

It is **the shortest one**. The checker explores breadth-first, so the first violating state it
meets is the one nearest the start, and there is no five-state trace that reaches this bug. Seven
states is the least it takes.

It is **complete evidence**. Every state is printed in full, and `← changed` marks what the
action altered, so there is no interpretation to do: you can follow the chain by hand from
`init` and confirm each step is an action the spec allows. `mix tla.replay` can drive an
implementation through the same sequence.

And **the numbers below it are a lower bound**. The run stopped when it found the violation, so
the coverage table describes what had been explored by then, and it says so. Do not read `16
distinct states` as the size of this system's state space.

The fix is the spec you already wrote. In `Specs.Lock`, checking the lock and taking it are one
action, and an action is atomic — that spec *claims* the implementation does both in one
indivisible step, and `verified` is the reward for a claim that holds. `Specs.SplitLock` makes the
weaker, more honest claim about a check-then-act implementation, and the checker found the
interleaving that breaks it in milliseconds. Which spec is right is a question about your
code, and it is the question the tool exists to make you answer.

## Where to next

- [The tutorial](tutorial/02-dsl.md) — the same lock, taken further: the coverage report,
  liveness and what fairness does to it, symmetry, and then checking a running GenServer against
  the spec.
- `mix help tla.check` — the flags, and the exit codes.
- [`02-dsl-semantics.md`](../spec/02-dsl-semantics.md) — the DSL, normatively: the three name
  classes, what an action body means, where nondeterminism comes from, types.
- [`04-layer2-model-checker.md`](../spec/04-layer2-model-checker.md) — the checker: what a run
  computes, the coverage report in full, liveness and fairness, symmetry.
- [`07-examples.md`](../spec/07-examples.md) — the acceptance corpus: whole specs with
  implementations checked against them.
