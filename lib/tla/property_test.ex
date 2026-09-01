defmodule TLA.PropertyTest do
  @moduledoc """
  StreamData generators derived from a specification, for a consumer's own property tests.

  `05-layer3-conformance.md` §`TLA.PropertyTest` specifies these. They are the piece of
  Layer 3 that ExTLA does *not* drive: `TLA.Replay` checks an implementation against a
  trace and `TLA.Simulation` walks it randomly, both under ExTLA's control, while these
  hand the spec's own state space to a `check all` the consumer writes.

      property "the server conforms under any initial state" do
        check all state <- TLA.PropertyTest.init_states(Specs.TransferProtocol, constants) do
          ...
        end
      end

  ## `stream_data` is not a dependency of ExTLA, and these still work

  It is declared `only: [:dev, :test]`, so nothing in `lib/` may reference `StreamData`
  unconditionally. Each function below is compiled behind `Code.ensure_loaded?(StreamData)`
  — the shape `TLA.Invariant.Test` already uses — with an `else` clause that says so
  rather than failing as an undefined function. A consumer who wants generators declares
  `stream_data` themselves; ExTLA keeps zero runtime dependencies (§06 §Dependencies).

  ## What is deferred

  `generate_test_module/3`, which §05 also specifies. `06-architecture.md` §Deferred
  removes generated test *files* from v1: "`mix tla.gen.test` writes code someone then has
  to maintain; the property helpers give most of the value without that". These are those
  helpers.
  """

  alias TLA.ModelChecker
  alias TLA.Spec
  alias TLA.Spec.Type

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

    A state outside §6's permitted terms raises, and so does one outside the variables'
    declared types — both naming the `init` block and the variable. A spec whose `init`
    produces such a state is one `mix tla.check` would refute at depth 1, and a generator
    that quietly filtered it away would hide the same defect behind a property that
    silently tested less than it appeared to.
    """
    @spec init_states(module() | Spec.Compiled.t(), map()) :: StreamData.t(TLA.State.t())
    def init_states(spec, constants) do
      spec |> compiled() |> initial_states(constants) |> StreamData.member_of()
    end

    @doc """
    A generator over the spec's behaviours, as `{action, params}` steps.

    Every generated sequence is a **real behaviour**: it starts at one of the spec's
    initial states, and at every step the action it names is enabled with the binding it
    names. Nothing generated is a sequence the spec forbids.

    ## Where the choices come from

    `TLA.ModelChecker.enabled_steps/3` — the checker's own enumeration, the one the
    differential corpus compares against TLC. A second implementation of "what may happen
    next" could disagree with it, and only one of the two is measured.

    ## Why there is no refinement argument

    `TLA.Simulation.Generator` takes one and returns a concrete message; this returns
    `{action_name, params}` and stops there. A sequence of actions is *spec-level*, and
    mapping it to messages is the consumer's own `check all` body — §05's usage example
    calls `concrete_message/2` there itself. The two signatures differ on purpose.

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
    @spec action_sequences(module() | Spec.Compiled.t(), map(), pos_integer()) ::
            StreamData.t([{atom(), map()}])
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
      case ModelChecker.enabled_steps(spec, constants, state) do
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
    @spec init_states(module() | Spec.Compiled.t(), map()) :: no_return()
    def init_states(_spec, _constants) do
      raise ArgumentError,
            "TLA.PropertyTest.init_states/2 needs `stream_data`, which is not loaded. " <>
              "Add `{:stream_data, \"~> 1.0\", only: [:dev, :test]}` to your deps."
    end

    @doc """
    Unavailable: `stream_data` is not loaded. See `init_states/2`.
    """
    @spec action_sequences(module() | Spec.Compiled.t(), map(), pos_integer()) :: no_return()
    def action_sequences(_spec, _constants, _max_length \\ 20) do
      raise ArgumentError,
            "TLA.PropertyTest.action_sequences/3 needs `stream_data`, which is not loaded. " <>
              "Add `{:stream_data, \"~> 1.0\", only: [:dev, :test]}` to your deps."
    end
  end

  @doc false
  # Public for the `stream_data`-less build to have something to test, and because the
  # list is the useful thing when a caller wants every initial state rather than one.
  @spec initial_states(module() | Spec.Compiled.t(), map()) :: [TLA.State.t()]
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
    TLA.State.validate!(state)

    case Type.invariant(spec, constants) do
      nil ->
        state

      type_ok ->
        unless type_ok.predicate.(constants, state) do
          raise ArgumentError,
                "#{inspect(spec.module)}'s `init` block #{index} produces a state outside " <>
                  "the declared types: #{Type.explain(spec, constants, state)}. " <>
                  "`mix tla.check` refutes this spec at depth 1; generating from it would " <>
                  "test a state the spec itself does not admit."
        end

        state
    end
  end
end
