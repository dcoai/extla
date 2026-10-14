# Putting a specification in your project

ExTLA tutorial. Previous: [When it explodes](09-when-it-explodes.md).

A specification is only worth having while it stays true. A spec that drifts from the system it
describes is worse than none, because it is *trusted* — and that is not a hypothetical: it is the
defect this project has spent most of its own gates preventing, and it applies to your
specifications exactly as it applies to these guides.

So this page is about the boring part, which is the part that decides whether any of the rest
survives contact with a real codebase.

## Where specifications live

`lib/specs/`, alongside the code, compiled with it. They are ordinary modules, so nothing else is
required — and being compiled with the application is the point: a spec in a directory Mix does
not build is a spec that stops compiling without anyone noticing.

Name them for the thing they describe rather than for what they are: `Specs.Lock`,
`Specs.JobRunner`. `mix extla.check` with no arguments finds every module in the project that
`use`s `ExTLA.Spec`, so a consistent home is enough to make "check everything" work.

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

This project does the same thing one layer up: its mutation sweep is a separate CI job precisely
because a thirteen-minute gate inside `mix test` is a gate people start skipping. The rule is that
the slow check runs on every pipeline and not on every save.

## Looking at the graph

`mix extla.visualize` renders the state space as DOT, which is the fastest way to see whether a
design goes where you thought:

```sh
mix extla.visualize Specs.Lock --output lock.dot && dot -Tsvg lock.dot -o lock.svg
```

For a two-client lock with no waiting state, the whole graph is small enough to read:

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
rather than producing a hairball, and the refusal names the true count — a picture of the first
500 of 58,000 states would look complete and be a lie.

DOT only, deliberately: `06-architecture.md` defers an HTML viewer as "a maintenance sink", so
`--format html` is refused with a message naming that decision rather than silently ignored.

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
encoding the checker writes, so there is no second format to learn. Exit 0 means the captured
behaviour is one the specification permits; exit 1 means it is not, and names the step.

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
