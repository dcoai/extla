# The DSL in practice

ExTLA tutorial. Previous: [The mathematics of TLA](01-mathematics.md).

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

(The second invariant is there for [Invariants](03-invariants.md), which is about reading what
the checker says of it.)

## Three kinds of name

Inside a spec block, a name means one of three things, and the spelling tells you which
([§1](../../spec/02-dsl-semantics.md#1-the-three-name-classes)). A **pinned** name, `^clients`, is a
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

## Types

`type:` is a small language of its own ([§1.5](../../spec/02-dsl-semantics.md#1-5-type-annotations)):
a list of literals is a choice among them, `a..b` is a range, `[^clients ~> t]` is a map whose keys
are exactly the clients and whose values have type `t` — a TLA+ function — and there are unions
(`^clients | :none`), tuples, records, `set(t)` and `seq(t)`. The type is not a restriction on
exploration; it is checked as an invariant, and [Invariants](03-invariants.md) says what that
means.

## Nondeterminism is `params:`, and only `params:`

`action :request, params: [c: ^clients]` is three actions, one per client, and the checker tries
every one in every state. That is where all the branching in a spec comes from. A `params:` entry
may draw from a constant, from a literal range or list, or from the state — `params: [c: fn s ->
s.some_set end]` — and a state function that returns nothing disables the action, exactly as a
false guard would ([§3](../../spec/02-dsl-semantics.md#3-nondeterminism-comes-from-params-and-only-from-params)).
The body, given its params, is deterministic.

## An action is a conjunction

The rule most likely to surprise an Elixir programmer
([§2](../../spec/02-dsl-semantics.md#2-an-action-block-is-a-conjunction-not-a-sequence)): the lines of
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

## The run

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
that report is the [next page](03-invariants.md).

---

Next: [Invariants](03-invariants.md).
