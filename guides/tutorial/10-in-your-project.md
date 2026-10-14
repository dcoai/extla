# Putting a specification in your project

ExTLA tutorial. Previous: [When it explodes](09-when-it-explodes.md).

A specification is only worth having while it stays true. A spec that drifts from the system it
describes is worse than none, because it is *trusted*: people read it as a description of the
system long after it has stopped being one.

So this page is about the boring part, which is the part that decides whether any of the rest
survives contact with a real codebase.

## Where specifications live

`lib/specs/`, alongside the code, compiled with it. They are ordinary modules, so nothing else is
required — and being compiled with the application is the point: a spec in a directory Mix does
not build is a spec that stops compiling without anyone noticing.

Name them for the thing they describe rather than for what they are: `Specs.Lock`,
`Specs.JobRunner`. `mix extla.check` with no arguments finds every module in the project that
`use`s `ExTLA.Spec`, so a consistent home is enough to make "check everything" work.

The CLI takes nothing but flags, so a spec's constants and symmetry come from your application
config — the constants from `config :extla, Specs.X, constants: %{…}`, or failing that from the
`default:` beside the `constant` declaration, and symmetry from `config :extla, Specs.X,
symmetry: [:name]`:

<!-- tla:skip reason=an application config fragment, not a spec -->
```elixir
# config/config.exs
config :extla, Specs.Lock,
  constants: %{clients: MapSet.new([:alice, :bob, :carol])},
  symmetry: [:clients]
```

A constant with neither a config entry nor a `default:` is an error that names both places. The
checker's other options — `check_deadlock:`, `state_constraint:`, `invariants:` and the rest — are
options of `ExTLA.ModelChecker.run/2` and `assert_spec/2`, and cannot be set from `mix extla.check`.

## Checking them from the suite

`assert_spec` runs the checker and turns its verdict into a test result:

<!-- tla:run expect=ok -->
```elixir
import ExTLA.Spec.Test

assert_spec Tutorial.StrongLock, %{
  constants: %{clients: MapSet.new([:alice, :bob, :carol])},
  symmetry: [:clients],
  verify_symmetry: true
}
```

In a suite that is a test like any other:

<!-- tla:skip reason=an ExUnit module, run by your suite rather than by this page -->
```elixir
defmodule Specs.LockTest do
  use ExUnit.Case, async: true
  import ExTLA.Spec.Test

  @tag :spec
  test "the lock keeps mutual exclusion, and nobody starves" do
    assert_spec Specs.Lock, %{
      constants: %{clients: MapSet.new([:alice, :bob, :carol])},
      check_liveness: true,
      strict_coverage: true
    }
  end
end
```

Two options in there are worth choosing deliberately:

- **`strict_coverage: true`** fails the test on a never-enabled action or a vacuously satisfied
  property. Turn it on: those are the findings that make a green run mean something, and a warning
  nobody reads is not a gate. [Invariants](03-invariants.md) is the page for what it catches.
- **An incomplete run fails the test.** `assert_spec` treats a state limit as a failure rather
  than a pass, deliberately, because "we ran out of budget" is not "it holds". Pass
  `allow_incomplete: true` to accept a bounded run *on purpose*, and only then.

And one that is easy to miss: **from the API, liveness is checked only when you ask.**
`ExTLA.ModelChecker.run/2` and `assert_spec/2` check a spec's `temporal` properties only with
`check_liveness: true`; without it, a test of a spec whose whole point is "nobody starves" passes
on safety alone. `mix extla.check` is the other way round — it checks liveness whenever the spec
declares a `temporal` (skipping it, with a warning, under symmetry or `--workers` above 1). So a
suite should pass `check_liveness: true` for every spec with temporal properties, as the test above
does. Not together with `symmetry:`, though: the two are not sound together, and asking the API
for both raises. Check safety under the reduction, and liveness in a test without it.

## What to run in CI, and what it costs

A specification is not a unit test and should not pretend to be. The lock above checks in
milliseconds and belongs in the fast suite; the job runner from
[when it explodes](09-when-it-explodes.md) takes most of a second at four jobs, and a real
protocol can take minutes.

Tag them and exclude them by default:

<!-- tla:skip reason=an ExUnit configuration, not a spec -->
```elixir
# test/test_helper.exs
ExUnit.start(exclude: [:spec])
```

```sh
mix test                    # the fast suite
mix test --include spec     # and the specifications, in CI
```

A slow check inside the suite everyone runs on every save is a check people start skipping. The
rule is that the slow check runs on every pipeline and not on every save.

## Looking at the graph

`mix extla.visualize` renders the state space as DOT, which is the fastest way to see whether a
design goes where you thought:

```sh
mix extla.visualize Specs.Lock --output lock.dot && dot -Tsvg lock.dot -o lock.svg
```

For a two-client lock with no waiting state, the whole graph is small enough to read:

<!-- tla:spec -->
```elixir
defmodule Viz.Lock do
  use ExTLA.Spec

  constant :clients, default: set([:alice, :bob])

  variable :free, type: [true, false]
  variable :pc,   type: [^clients ~> [:idle, :holding]]

  init do
    free = true
    pc   = for_each(^clients, fn _ -> :idle end)
  end

  action :acquire, params: [c: ^clients] do
    require free and pc[c] == :idle
    free = false
    pc   = update(pc, c, fn _ -> :holding end)
  end

  action :release, params: [c: ^clients] do
    require pc[c] == :holding
    free = true
    pc   = update(pc, c, fn _ -> :idle end)
  end
end
```

```sh
mix extla.visualize Viz.Lock
```

<!-- tla:output command="mix extla.visualize Viz.Lock" -->
```
digraph "Viz.Lock" {
  rankdir=LR;
  node [shape=box, fontname="monospace", fontsize=10];
  edge [fontname="monospace", fontsize=9];

  0 [label="0\nfree = true\npc = %{alice: :idle, bob: :idle}", peripheries=2];
  1 [label="1\nfree = false\npc = %{alice: :holding, bob: :idle}"];
  2 [label="2\nfree = false\npc = %{alice: :idle, bob: :holding}"];

  0 -> 1 [label="acquire(c=:alice)"];
  0 -> 2 [label="acquire(c=:bob)"];
  1 -> 0 [label="release(c=:alice)"];
  2 -> 0 [label="release(c=:bob)"];
}
```

Initial states get a double border, declared `terminal` states a doubled octagon, deadlocked states
a fill, and a refuted run draws its counterexample emphasised. It **refuses past 500 states**
(`--max-states` changes the limit) rather than producing a hairball — a picture of the first 500
of 58,000 states would look complete and be a lie. The search stops at the same limit, since
exploring states it will not draw is wasted work, so the refusal says the specification has
**more than** 500 states rather than how many: a bounded search does not know. It exits 2, and
the remedy is the same either way — raise the flag, or shrink the model.

DOT only, deliberately: Graphviz renders it to SVG, PNG or PDF, and a bespoke viewer would be one
more thing to maintain. `--format html` is refused with a message saying so rather than silently
ignored.

## Generators from the specification

`ExTLA.PropertyTest` hands the spec's own state space to a `check all` of your own, for the property
tests that keep an implementation honest between conformance runs:

<!-- tla:skip reason=a property test, run by your suite with stream_data available -->
```elixir
property "the server survives any initial state the spec admits" do
  check all state <- ExTLA.PropertyTest.init_states(Specs.Lock, %{clients: MapSet.new([:a, :b])}) do
    # drive your implementation from `state` and assert what you like about it
    assert is_map(state)
  end
end
```

`ExTLA.PropertyTest.action_sequences/3` goes further and generates whole behaviours: lists of
`{action, params}` steps, each enabled in the state the previous one produced, starting from an
initial state and at most `max_length` long (default 20). Map each step to a message with your
refinement's `concrete_message/2`, send it, and assert about the result. Every sequence is one the
spec admits, and shrinking keeps it that way — a shorter prefix is still a real behaviour.

<!-- tla:skip reason=a property test, run by your suite with stream_data available -->
```elixir
property "the server follows any behaviour the spec admits" do
  check all steps <- ExTLA.PropertyTest.action_sequences(Specs.Lock, %{clients: MapSet.new([:a, :b])}, 10) do
    {:ok, pid} = MyApp.LockServer.start_link()

    for {action, params} <- steps do
      GenServer.call(pid, MyApp.LockRefinement.concrete_message(action, params))
    end
  end
end
```

`stream_data` is not a dependency of ExTLA — it is `only: [:dev, :test]` — so these functions are
compiled behind a check for it and tell you by name when it is absent rather than failing as an
undefined function. Declare it yourself if you want them.

## After an incident

The one that is worth knowing before you need it. `mix extla.replay --captured` takes a trace
recorded from a running system and checks it against the specification:

```sh
mix extla.replay MyApp.LockServer --captured incident.json
```

The file is an array of `{"message": …, "state": …}` entries, oldest first, where `state` is the
concrete state the implementation was in *after* that message — the same `ExTLA.State.Json`
encoding the checker writes, so there is no second format to learn. Reading it needs the optional
`{:jason, "~> 1.4"}` dependency in your project, as do `--format json` and `mix extla.replay
--trace`. Exit 0 means the captured behaviour is one the specification permits; exit 1 means it is
not, and names the step.

That turns "something went wrong in production last night" into a question the specification can
answer: not *did the code have a bug* but *was that sequence of events one the design allows at
all*. It needs only `abstract/1` and `abstract_action/1` from the refinement mapping —
`concrete_message/2` is for driving, and a capture is not driven.

## The honest close

None of this makes a specification true. It makes it *checked*, which is the only property that
survives a year of other people editing the code — and the difference between a specification you
can rely on and a document that once described the system.

---

That is the tutorial. [The reference](../reference.md) holds what you will look up from here on,
[the specification](https://github.com/dcoai/extla/blob/main/spec/README.md) is the full design,
and [the decision log](https://github.com/dcoai/extla/blob/main/spec/08-decisions.md) is why the
tool is shaped the way it is.
