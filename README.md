# ExTLA

Describe your system's states, find the invalid ones automatically, and check that your
GenServers behave as described.

Concurrency bugs live in message orderings. An LLM-written GenServer can pass every test,
because its tests try the orderings the model thought of, which are the ones the code already
handles. A fix for one race can leave the same race one call over, and nothing notices.

ExTLA checks every ordering instead. You state what the system may do, and what must never
happen, in a few dozen lines of Elixir that a person can read and agree with. ExTLA explores
every state that description reaches, within the bounds you set, and returns the shortest path
to any broken rule. It then checks the running code against the same description. Each result
says what it covered, so a green run, whether you or an agent reads it, means what it says.

> **Experimental.** The checker agrees with TLC, the reference TLA+ model checker, on every
> specification in its differential corpus, but the interface can still change between minor
> versions, as it did in v0.4.0.

## Installation

Add `extla` to your dependencies in `mix.exs`:

<!-- tla:deps -->
```elixir
def deps do
  [
    {:extla, "~> 0.5.0"}
  ]
end
```

Add `{:jason, "~> 1.4"}` too if you want JSON output (`--format json`, and the saved
counterexamples `mix extla.explore` and `mix extla.replay --trace` read).

## Example

A specification is an Elixir module: the state, the steps that change it, and the rules
every reachable state must keep.

<!-- tla:spec -->
```elixir
defmodule Specs.Counter do
  use ExTLA.Spec

  variable :count, type: 0..3
  variable :status, type: [:ready, :busy]

  init do
    count = 0
    status = :ready
  end

  action :start do
    require status == :ready and count < 3
    status = :busy
  end

  action :finish do
    require status == :busy
    count = count + 1
    status = :ready
  end

  invariant :in_bounds do
    count <= 3
  end
end
```

```sh
mix extla.check Specs.Counter
```

`mix extla.check` explores every state the spec reaches, checks each invariant and temporal
property, and prints the shortest counterexample when one fails, with a report of what the
run exercised. The other tasks:

```
mix extla.simulate  MyApp.Counter   # run random traces of an ExTLA.GenServer against its spec
mix extla.replay    MyApp.Counter   # drive it through a counterexample, or check a captured trace
mix extla.explore   Specs.Counter   # evaluate your own expressions over a saved counterexample
mix extla.visualize Specs.Counter   # render the state graph as DOT
mix extla.stamp                     # report or update the spec_version: stamps on refinement mappings
```

## Resources

- [Getting started](guides/getting-started.md): install, one specification and one
  counterexample, in half an hour.
- [Tutorial](guides/tutorial/00-introduction.md): eleven pages, one lock running through all of
  them, ending with how to keep a specification in a project of your own.
- [API documentation](https://hexdocs.pm/extla): every module, starting at `ExTLA`.
- [TLA+ primer](research/tla-plus-primer.md): the ideas ExTLA borrows, for readers new to them.
- [Specification](https://github.com/dcoai/extla/blob/main/spec/README.md): the full design,
  with its principles and non-goals.
- [Design decisions](https://github.com/dcoai/extla/blob/main/spec/08-decisions.md): why it is
  shaped the way it is.
- [Prior art](https://github.com/dcoai/extla/blob/main/spec/00-prior-art.md): what else exists
  for Elixir and Erlang, and where ExTLA fits.
- [Changelog](CHANGELOG.md): what changed in each release.
- [Contributing](https://github.com/dcoai/extla/blob/main/CONTRIBUTING.md): how changes are
  made and checked.
- [License](LICENSE): MIT.
