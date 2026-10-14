defmodule ExTLA.PropertyTest do
  @moduledoc """
  StreamData generators derived from a specification, for a consumer's own property tests.

  They are the piece of Layer 3 that ExTLA does *not* drive: `ExTLA.Replay` checks an implementation against a
  trace and `ExTLA.Simulation` walks it randomly, both under ExTLA's control, while these
  hand the spec's own state space to a `check all` the consumer writes.

      property "the server conforms under any initial state" do
        check all state <- ExTLA.PropertyTest.init_states(Specs.TransferProtocol, constants) do
          ...
        end
      end

  ## `stream_data` is not a dependency of ExTLA, and these still work

  It is declared `only: [:dev, :test]`, so nothing in `lib/` may reference `StreamData`
  unconditionally. Each function below is compiled behind `Code.ensure_loaded?(StreamData)`
  — the shape `ExTLA.Invariant.Test` already uses — with an `else` clause that says so
  rather than failing as an undefined function. A consumer who wants generators declares
  `stream_data` themselves; ExTLA keeps zero runtime dependencies.

  ## No generated test files

  ExTLA does not write test modules for you. Generated test code is code someone then has
  to maintain; these property helpers give most of the value without that.
  """

  # `ExTLA.ModelChecker` is deliberately NOT aliased. Its only use is inside the
  # `Code.ensure_loaded?(StreamData)` branch below, and that branch is not compiled where
  # `stream_data` is absent — which is how this library compiles as a DEPENDENCY, since a
  # consumer does not get its dev/test deps. An alias used only there is unused there, and
  # the consumer gets a warning about code they did not write.
  #
  # `Spec` and `Type` stay: both are used outside the branch, in `compiled/1` and
  # `validated!/4` and in typespecs that exist in either case.
  alias ExTLA.Spec
  alias ExTLA.Spec.Type

  if Code.ensure_loaded?(StreamData) do
    @doc """
    A generator over the spec's initial states.

    ## Why this is a generator over a finite set

    An `init` block is a function of the constants and nothing else — nondeterminism in
    the DSL comes from `params:` and only from `params:` (`02-dsl-semantics.md` §3) — so a
    spec with three disjuncted `init` blocks has exactly three initial states, not a
    space to sample. This enumerates them and picks among them.

    It is typed as a generator anyway, and that is not a formality: it is what lets an
    initial state compose into a `check all` beside generators that really are large,
    and it shrinks toward the first `init` block, which is the one most specs write as
    their base case.

    ## What it refuses

    A state outside the permitted state terms (`02-dsl-semantics.md` §6) raises, and so does one outside the variables'
    declared types — both naming the `init` block and the variable. A spec whose `init`
    produces such a state is one `mix extla.check` would refute at depth 1, and a generator
    that quietly filtered it away would hide the same defect behind a property that
    silently tested less than it appeared to.
    """
    def init_states(spec, constants) do
      spec |> compiled() |> initial_states(constants) |> StreamData.member_of()
    end

    @doc """
    A generator over the spec's behaviours, as `{action, params}` steps.

    Every generated sequence is a **real behaviour**: it starts at one of the spec's
    initial states, and at every step the action it names is enabled with the binding it
    names. Nothing generated is a sequence the spec forbids.

    ## Where the choices come from

    `ExTLA.ModelChecker.enabled_steps/3` — the checker's own enumeration. A second
    implementation of "what may happen next" could disagree with the checker, and then a
    generated behaviour would not be one the checker explored.

    ## Why there is no refinement argument

    `ExTLA.Simulation.Generator` takes one and returns a concrete message; this returns
    `{action_name, params}` and stops there. A sequence of actions is *spec-level*, and
    mapping it to messages is the consumer's own `check all` body, which calls
    `c:ExTLA.Refinement.concrete_message/2` itself. The two signatures differ on purpose.

    ## Shrinking

    Sound, and for a structural reason: every prefix of a behaviour is a behaviour, so a
    shorter sequence from the same initial state is still one the spec admits. The length
    is generated first and shrinks toward zero, so a shrunk counterexample is a sequence
    the implementation really could have taken — a generator that shrank into an *invalid*
    sequence would report failures that cannot happen, which is the failure mode worth
    guarding.

    A walk that runs out of enabled actions stops there, so a sequence may be shorter than
    the length drawn. It is never longer than `max_length`.
    """
    def action_sequences(spec, constants, max_length \\ 20) do
      spec = compiled(spec)

      StreamData.bind(init_states(spec, constants), fn state ->
        StreamData.bind(StreamData.integer(0..max_length), fn length ->
          walk(spec, constants, state, length)
        end)
      end)
    end

    # Each step's choices depend on the state the previous step produced, so the generator
    # is built by binding rather than by composing independent ones. `bind/2` is lazy, so
    # nothing past the drawn length is ever enumerated.
    defp walk(_spec, _constants, _state, 0), do: StreamData.constant([])

    defp walk(spec, constants, state, remaining) do
      case ExTLA.ModelChecker.enabled_steps(spec, constants, state) do
        [] ->
          StreamData.constant([])

        candidates ->
          StreamData.bind(StreamData.member_of(candidates), fn {action, params} = step ->
            next = Spec.Compiled.action(spec, action).transition.(constants, state, params)

            spec
            |> walk(constants, next, remaining - 1)
            |> StreamData.map(&[step | &1])
          end)
      end
    end
  else
    @doc """
    Unavailable: `stream_data` is not loaded.

    It is a `dev`/`test`-only dependency of ExTLA, so a consumer who wants generators
    declares it themselves — and this function has a body only where it does.
    """
    def init_states(_spec, _constants) do
      raise ArgumentError,
            "ExTLA.PropertyTest.init_states/2 needs `stream_data`, which is not loaded. " <>
              "Add `{:stream_data, \"~> 1.0\", only: [:dev, :test]}` to your deps."
    end

    @doc """
    Unavailable: `stream_data` is not loaded. See `init_states/2`.
    """
    def action_sequences(_spec, _constants, _max_length \\ 20) do
      raise ArgumentError,
            "ExTLA.PropertyTest.action_sequences/3 needs `stream_data`, which is not loaded. " <>
              "Add `{:stream_data, \"~> 1.0\", only: [:dev, :test]}` to your deps."
    end
  end

  @doc false
  # Public for the `stream_data`-less build to have something to test, and because the
  # list is the useful thing when a caller wants every initial state rather than one.
  def initial_states(spec, constants) do
    spec = compiled(spec)

    spec.init
    |> Enum.with_index()
    |> Enum.map(fn {init_fn, index} ->
      validated!(spec, constants, init_fn.(constants), index)
    end)
  end

  defp compiled(%Spec.Compiled{} = spec), do: spec
  defp compiled(module) when is_atom(module), do: Spec.Compiled.from_module(module)

  defp validated!(spec, constants, state, index) do
    ExTLA.State.validate!(state)

    case Type.invariant(spec, constants) do
      nil ->
        state

      type_ok ->
        unless type_ok.predicate.(constants, state) do
          raise ArgumentError,
                "#{inspect(spec.module)}'s `init` block #{index} produces a state outside " <>
                  "the declared types: #{Type.explain(spec, constants, state)}. " <>
                  "`mix extla.check` refutes this spec at depth 1; generating from it would " <>
                  "test a state the spec itself does not admit."
        end

        state
    end
  end
end
