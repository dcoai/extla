# Layer 1 — invariants on a running GenServer

ExTLA tutorial. Previous: [Symmetry, and who is responsible for it](05-symmetry.md).

Everything so far has been about the specification. The implementation has not existed. Layer 1 is
the smallest step towards it, and the only part of ExTLA that needs **no specification at all**:
state a property of a GenServer's state *in the GenServer*, and have it checked after every
callback.

That makes it the easiest thing here to adopt, so start there.

## The smallest useful step

Take a server you already have — here the lock this tutorial has been specifying, written as an
ordinary GenServer. Add `use TLA.Invariant` and one property you believe about its state: the one
you would be embarrassed to be wrong about.

<!-- tla:spec -->
```elixir
defmodule Tutorial.FirstTry do
  use GenServer
  use TLA.Invariant

  invariant :holder_is_not_waiting,
    desc: "the client holding the lock is not also queued for it" do
    state.holder == nil or state.holder not in state.waiting
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts), do: {:ok, %{holder: nil, waiting: []}}

  @impl true
  def handle_call({:request, c}, _from, s), do: {:reply, :ok, %{s | waiting: s.waiting ++ [c]}}

  def handle_call({:acquire, c}, _from, %{holder: nil} = s), do: {:reply, :ok, %{s | holder: c}}
end
```

Nothing else changes: no specification, no refinement mapping, no `mix tla.check`. Run your suite,
and if the property holds the server behaves exactly as it did before. This one does not hold —
`acquire` grants the lock and forgets to take the client off the waiting list:

<!-- tla:run expect=raise match="INVARIANT VIOLATED: holder_is_not_waiting" -->
```elixir
{:ok, pid} = Tutorial.FirstTry.start_link()
:ok = GenServer.call(pid, {:request, :alice})
GenServer.call(pid, {:acquire, :alice})
```

```
** (TLA.Invariant.Violation) ═══ INVARIANT VIOLATED: holder_is_not_waiting ══════════
  the client holding the lock is not also queued for it
  module: Tutorial.FirstTry
  state:
    holder  = :alice
    waiting = [:alice]
```

The `desc:` is printed with the report, which is why it is worth writing: the reader of a failing
build is not always the author of the invariant.

That is the whole on-ramp — one property, checked after every callback, in a server that already
existed. Everything below is detail you will want once it is in.

## The four kinds of declaration

`invariant` is one of four, and the fuller version of the same server uses three of them —
`Tutorial.LockServer` below is the one the rest of this page runs against:

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

## What they mean

The blocks are bare boolean expressions, the same shape as a spec's, with one difference: `state`
is written explicitly. A spec has `variable` declarations to resolve a bare name against, and an
arbitrary GenServer has none, so Layer 1 does not guess
([`03-layer1-invariants.md`](../../spec/03-layer1-invariants.md)). An `invariant` is checked after
every callback; a `precondition` is matched against the incoming message — its pattern binds `c` —
and checked before the callback runs; a `postcondition` sees `old`, `new` and the pattern's
bindings after it returns. `action_property` is there too, with `old` and `new`.

## Used correctly, nothing changes

Used correctly, nothing is different:

<!-- tla:run expect=ok -->
```elixir
{:ok, pid} = Tutorial.LockServer.start_link()
:ok = GenServer.call(pid, {:request, :alice})
:ok = GenServer.call(pid, {:acquire, :alice})
:ok = GenServer.call(pid, {:release, :alice})
```

## Used wrongly, the callback never runs

Bob releasing a lock Alice holds:

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

## The three modes, as configuration

The report above ends in a raised exception, which in a supervised system means the server
restarts and the caller's `call` exits with the violation as its reason. That is one of three
behaviours, and which you get is decided **when the module compiles**:

<!-- tla:skip reason=config files, not a spec -->
```elixir
# config/dev.exs and config/test.exs — checks on, violations raise.
config :extla, mode: :enabled

# config/prod.exs — no code is emitted for any declaration.
config :extla, mode: :disabled
```

- **`:enabled`** — the check runs and a violation raises. Right for dev and test: a violated
  invariant is a bug, and a bug should stop the thing that has it.
- **`:log_only`** — the same report goes to the log and the callback proceeds. This is the mode
  for turning checks on in production against a system you are not willing to crash, and the
  trade is explicit: you find out, and you keep serving a state you have just declared impossible.
- **`:disabled`** — `@before_compile` emits **nothing**. Not a cheap check, not a branch that
  returns early: a module compiled `:disabled` is the module its author wrote. That is what "zero
  production cost" means here, and it is why the mode is read at compile time rather than looked
  up per call.

`:disabled` is the default under `MIX_ENV=prod`, so the safe configuration is also the one you get
by not writing any. And because the mode is compile-time, changing it recompiles the instrumented
modules — Mix knows which those are, so editing `config :extla, mode: …` rebuilds exactly them.

One consequence worth stating: **a module compiled `:disabled` cannot be asserted about.** Every
helper in the next section says so by name rather than reporting the declaration as false, because
"there is no predicate here" and "the predicate returned false" are different facts.

## Testing the declarations themselves

An invariant no test has ever seen return `false` is indistinguishable from `true` — and a `true`
invariant is checked on every transition forever while proving nothing. It is the same vacuity
`mix tla.check` reports at Layer 2, one layer down, and it is **not detectable from the passing
side**.

`TLA.Invariant.Test` checks a declaration against a *state value* rather than a running process,
which is what makes the negative case writable: a state a server can only reach through a
sequence of calls is just a map here.

<!-- tla:run expect=ok -->
```elixir
import TLA.Invariant.Test

# It holds where it should.
assert_invariants(Tutorial.LockServer, %{holder: :alice, waiting: [:bob]})

# And — the test that earns its place — it can actually fail.
refute_invariant(Tutorial.LockServer, :holder_is_not_waiting, %{holder: :alice, waiting: [:alice]})
```

In a suite that is `use TLA.Invariant.Test` after `use ExUnit.Case`. `assert_action_properties/3`
is there too, taking the old and new state.

## Telemetry

A violation emits `[:extla, :invariant, :violated]` — and one per kind, so `:action_property`,
`:precondition` and `:postcondition` have their own — with the module, the declaration's name and
the violation struct in the metadata:

<!-- tla:run expect=ok -->
```elixir
:telemetry.attach(
  "queue-violations",
  [:extla, :invariant, :violated],
  fn _event, _measurements, metadata, _config ->
    # metadata: %{module: …, name: …, violation: %TLA.Invariant.Violation{}}
    :ok = Enum.each([:module, :name, :violation], &Map.fetch!(metadata, &1))
  end,
  nil
)
```

Success events — `[:extla, :invariant, :checked]`, with timing — are opt-in and **not emitted
otherwise**: they are absent from the compiled module rather than filtered at runtime, because
`:telemetry.execute/3` costs about a microsecond even with nothing attached and this runs on every
transition. Turn them on with `config :extla, telemetry: :verbose`, which recompiles the
instrumented modules.

## What it costs, and how to pay less

Two knobs, both evaluated at **compile** time, so what you switch off is not in the module at all:

<!-- tla:skip reason=declaration options, shown on their own -->
```elixir
# Dropped entirely unless the environment opts in — for a check too costly to run everywhere.
invariant :expensive_audit, enabled: Mix.env() != :prod do
  audit(state)
end

# Checked after these callbacks only, rather than all of them.
invariant :within_capacity, callbacks: [:handle_call] do
  length(state.items) <= state.capacity
end
```

`03-layer1-invariants.md` §Performance Considerations is the fuller treatment; the short version
is that an invariant over a large collection on a hot `handle_info` is the shape to watch, and
`callbacks:` is usually the answer before `enabled:` is.

## Beyond GenServer

The same declarations work for the other OTP shapes, with one exception worth knowing
([`03-layer1-invariants.md`](../../spec/03-layer1-invariants.md) §Supported OTP Behaviors):

- **`GenServer`**, `:gen_statem` and `GenStateMachine` are wrapped the same way. For a state
  machine the specification is explicit about what `state` and the message *are*, since both are
  shaped differently there.
- **`Agent`** cannot be wrapped, and the reason is structural: `Agent.start_link/2` takes a
  function, not a behaviour module, so there is no callback module for `@before_compile` to
  instrument and nothing to carry the declarations. `TLA.Invariant.Agent` handles it by taking the
  declaring module as an argument on every call — `Checked.update(Counter, pid, &…)` — which also
  means an `Agent`'s checks **cannot be compiled away**.
- **Supervision trees** are not modelled at Layer 1 at all; `TLA.Supervisor.Spec` is deferred past
  v1 ([`06-architecture.md`](../../spec/06-architecture.md#deferred-past-v1-deliberately)).

## What Layer 1 cannot tell you

Layer 1 knows nothing about `Tutorial.Lock`. It checks the properties you wrote *about the
implementation*, in the implementation's own terms, which is useful and is also the limit of it:
`holder_is_not_waiting` could hold forever in a server that never lets anyone acquire. Relating the
code to the specification is Layer 3.

---

Next: [Layer 3 — does the implementation conform?](07-layer3.md).
