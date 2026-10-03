defmodule ExTLA do
  @moduledoc """
  TLA+-inspired formal verification for Elixir/OTP systems.

  Write a specification as Elixir code, model-check it exhaustively, and check that a
  running GenServer conforms to it. Start with
  [Getting started](guides/getting-started.md); the tutorial that follows it builds one
  system across eleven pages.

  ## Three layers, each useful on its own

    * **Layer 1 — invariants on a running process.** `ExTLA.Invariant` checks properties
      after every transition of a live `GenServer`, `:gen_statem` or `Agent`. Needs no
      specification and no model checker. Under `MIX_ENV=prod` it emits no code at all.

    * **Layer 2 — the model checker.** `ExTLA.Spec` compiles a specification module;
      `ExTLA.ModelChecker` explores its state space breadth-first, checks invariants and
      temporal properties, and reports the shortest counterexample — or the lasso — when
      it finds one. `mix tla.check` is the command-line form.

    * **Layer 3 — conformance.** `ExTLA.GenServer` and `ExTLA.Refinement` map an
      implementation's state onto a specification's, so `mix tla.simulate` can ask whether
      the code does what the specification says, and `mix tla.replay` can drive a
      counterexample through the real process.

  A specification is ordinary Elixir that looks like this:

      defmodule Specs.Counter do
        use ExTLA.Spec

        constant :max_val
        variable :count, type: 0..^max_val

        init do
          count = 0
        end

        action :increment do
          require count < ^max_val
          count = count + 1
        end

        invariant :in_bounds do
          count >= 0 and count <= ^max_val
        end
      end

  It looks like Elixir and is not: `=` inside `init` or `action` is a next-state equation
  rather than a rebinding, `^name` is a constant rather than a match pin, and `require` is
  an enabling condition rather than `Kernel.SpecialForms.require/2`.
  [`02-dsl-semantics.md`](spec/02-dsl-semantics.md) is the normative account.

  ## Where things are written down

  The specification lives under `spec/`, indexed by
  [the specification index](spec/README.md), and
  [`08-decisions.md`](spec/08-decisions.md) records why the tool is shaped the way it is.

  **What is built** is in
  [`06-architecture.md` §Implementation Phases](spec/06-architecture.md#implementation-phases)
  and nowhere else, this moduledoc included. That is not tidiness: this page carried its own
  copy of the build status from the third commit of the project until #148, and by then it
  was four phases out of date on the first page of the API reference.
  """
end
