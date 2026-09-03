# Temporal properties, and the difference fairness makes

ExTLA tutorial. Previous: [Invariants](03-invariants.md).

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
([§5.1](../../spec/02-dsl-semantics.md#5-1-the-supported-temporal-fragment-is-bounded-say-so)); a
formula outside it is a compile error, never a silently weaker check.

A temporal property is checked when the spec declares one; `--safety-only` turns it off. And the
first thing you learn on checking one is that a leads-to is refuted by a system that is merely
*allowed* to stop — so a spec with a temporal property needs to say which actions the system can be
relied on to take. That is **fairness**, and there are two strengths of it.

## Weak fairness, refuted

**Weak** fairness on an action says: if the action stays enabled from some point on, it is
eventually taken. Declared per client — `acquire: [:c]` is one constraint for each value of `c`,
and `02-dsl-semantics.md` §5.2 says why the whole-action form would not do:

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

## Strong fairness, holding

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

## Per client, not per action

One more version, because it is the mistake `02-dsl-semantics.md` §5.2 exists to name. `fairness :strong, [:acquire]`
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
constraint to ([§5.2](../../spec/02-dsl-semantics.md#5-2-fairness-is-declared-per-action-or-per-parameter-binding)).

---

Next: [Symmetry, and who is responsible for it](05-symmetry.md).
