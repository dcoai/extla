# Symmetry, and who is responsible for it

ExTLA tutorial. Previous: [Temporal properties, and the difference fairness makes](04-temporal.md).

Alice, Bob and Carol are interchangeable. A state in which Alice holds the lock and Bob waits is,
for every property in the spec, the same state as one in which Bob holds it and Alice waits — and
the checker explores both. **Symmetry reduction** declares a constant whose elements cannot be told
apart, and the checker then keeps one representative of each set of states that differ only by a
permutation of them. For *n* interchangeable elements the state space shrinks by up to *n*!, and
that is the difference between tractable and not for exactly the systems this tool is for
([§Symmetry](../reference.md#symmetry)).

## Declaring it

The declaration sits beside the constants, in config:

<!-- tla:skip reason=a config.exs fragment, not a spec -->
```elixir
config :extla, Tutorial.StrongLock, symmetry: [:clients]
```

```sh
mix extla.check Tutorial.StrongLock --verify-symmetry
```

<!-- tla:check module=Tutorial.StrongLock expect=ok states=20 depth=5 -->
<!-- tla:check module=Tutorial.StrongLock expect=ok symmetry=clients verify_symmetry=true states=7 depth=5 -->
```
Tutorial.StrongLock — verified
  7 distinct states, 18 transitions, depth 5, 1ms

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
deserve a closer look: the warnings, and the flag on the command line.

The first warning is the checker's general one for any run that declares a `temporal` and does
not check it. The `check_liveness: true` it suggests is a key in the config you pass to
`ExTLA.ModelChecker.run/2` or `assert_spec/2`; `mix extla.check` has no such flag, because it
checks liveness by itself whenever it can. The second warning is the one that says why it could
not here.

## Why liveness is refused alongside it

The second warning is that symmetry and liveness are refused together. The reduced graph
identifies states, so a path that leaves an orbit and one that returns to it look alike, and the
quotient can contain cycles the real system does not have — and a cycle is exactly what a liveness
verdict is read off. Rather than answer with something it cannot stand
behind, the checker checks safety under the reduction and tells you to check the temporal
properties in a run without it. (`--workers` is refused alongside liveness for a neighbouring
reason, [§Parallel exploration](../reference.md#parallel-exploration).)

## Soundness is yours, and the flag is what makes a mistake visible

The other thing is the flag on the command line. **Nothing can establish that a `symmetry:`
declaration is sound.** A constant flows into arbitrary Elixir, and whether some invariant or
guard treats Alice differently from Carol is not a question a compiler can answer
([§Symmetry](../reference.md#symmetry)). Soundness is the author's obligation, exactly as it is in
TLC.
What `--verify-symmetry` does is make a wrong declaration **detectable**: it runs the model both
ways and fails if any verdict differs — the status, what was refuted, which actions never fired.
Not the counts; a sound reduction changes those on purpose.

## A declaration that is wrong

Here is a declaration that is wrong, on a spec whose one invariant can tell the clients apart:

<!-- tla:spec -->
```elixir
defmodule Tutorial.NamedLock do
  use ExTLA.Spec

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

<!-- tla:check module=Tutorial.NamedLock expect=violation property=carol_never_holds length=3 output=abridged -->
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
  refuted: nil with the reduction, :carol_never_holds without
  never_enabled: [] with the reduction, [:release] without

Something in the spec can tell the elements of [:clients] apart — an
`Enum.at`, a sort, a comparison on names, a dependence on list position — so
collapsing them dropped a state whose verdict mattered. Nothing can check this
statically (08-decisions.md D-17); this is the check that catches it.
```

Exit code 1, the same as a violation, because the answer the reduced run gave cannot be trusted.
The check is cheap on a small constant assignment; run it once per spec before trusting the
reduction on the large one.

---

Next: [Layer 1 — invariants on a running GenServer](06-layer1.md).
