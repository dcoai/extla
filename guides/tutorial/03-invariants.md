# Invariants

Part 2 of 6 of the ExTLA tutorial. Previous: [The DSL in practice](02-dsl.md).

An `invariant` is a boolean over the variables that must hold in every reachable state. The
checker evaluates each one in each state it discovers, and stops at the first state where one is
false — that is the counterexample [Getting started](../getting-started.md) ends with. This section
is about the other outcome: what the report says when every invariant *holds*, and why that is
worth reading.

## `type_ok` is an invariant you did not write

The `type:` on each variable is checked as an invariant named `type_ok`, in every state, which is
why the table lists one the spec never declared. A state outside its type is reported as a
violation of it. The type is not used to prune the search: a spec whose action drives a variable
out of range does not get a smaller state space, it gets a counterexample.

## The near-miss column

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

## An action that was never enabled

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
per state ([§4](../../spec/02-dsl-semantics.md#4-action_property-uses-old-and-new)) — and a `terminal`
declares which successor-less states are final on purpose, so they are not reported as deadlocks
([§5.3](../../spec/02-dsl-semantics.md#5-3-terminal-states-are-declared-not-inferred)).

---

Next: [Temporal properties, and the difference fairness makes](04-temporal.md).
