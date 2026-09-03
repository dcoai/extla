# Layer 3 — does the implementation conform?

Part 6 of 6 of the ExTLA tutorial. Previous: [Layer 1 — invariants on a running GenServer](06-layer1.md).

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
some predicates on it ([§What conformance means here](../../spec/05-layer3-conformance.md#what-conformance-means-here)).
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

## Simulation: random traces, every step checked

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
those were: all three, and all twenty of the abstract states [the DSL page](02-dsl.md) counted.
The seed is always
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

## Replay: the counterexample, run against the code

The loop that makes the three layers one tool. [Symmetry](05-symmetry.md)'s `Tutorial.NamedLock`
has a counterexample —
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
([§Full verification pipeline](../../spec/05-layer3-conformance.md#full-verification-pipeline)): model
check the spec, so design bugs are found before the code exists; simulate the implementation against
it, so the code is held to the design; replay any counterexample against the code, so a finding at
either level is a fact about both. `TLA.PropertyTest` hands the spec's own generators to a
`check all` of your own, for the property tests that keep it that way in CI.

## Where to next

- [`02-dsl-semantics.md`](../../spec/02-dsl-semantics.md) — the DSL, normatively. Every rule this
  page leaned on is stated there with its reason.
- [`04-layer2-model-checker.md`](../../spec/04-layer2-model-checker.md) — the checker: what a run
  computes, the JSON result schema, state constraints, symmetry, parallel exploration.
- [`05-layer3-conformance.md`](../../spec/05-layer3-conformance.md) — `TLA.GenServer`,
  `TLA.Refinement`, `TLA.Simulation`, `TLA.Replay`, and `--against-graph`, which checks Layers 2
  and 3 against each other.
- [`07-examples.md`](../../spec/07-examples.md) — whole specifications with implementations, including
  the distributed lock this tutorial's is a small cousin of.
- [`08-decisions.md`](../../spec/08-decisions.md) — why the tool is shaped the way it is, decision by
  decision.
