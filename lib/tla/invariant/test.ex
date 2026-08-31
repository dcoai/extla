defmodule TLA.Invariant.Test do
  @moduledoc """
  ExUnit helpers for testing Layer 1 declarations in isolation.

      defmodule AccountTest do
        use ExUnit.Case
        use TLA.Invariant.Test

        test "a withdrawal keeps the account whole" do
          old = %{balance: 100, deposits: 0}
          new = %{balance: 50, deposits: 0}

          assert_invariants(Account, new)
          assert_action_properties(Account, old, new)
        end

        test "and the invariant can actually fail" do
          refute_invariant(Account, :never_negative, %{balance: -1, deposits: 0})
        end
      end

  These check a *state*, not a running process. That is the point: a state a process can
  only reach through a sequence of calls is a value here, so the negative cases — the ones
  that prove a declaration is not vacuously true — can be written down directly.

  ## Why `refute_invariant/3` earns its place

  An invariant no test has ever seen return `false` is indistinguishable from `true`, and
  a `true` invariant is checked on every transition forever while proving nothing. It is
  the same vacuity `mix tla.check` reports at Layer 2 (`04-layer2-model-checker.md`
  §Coverage and Vacuity), one layer down, and it is not detectable from the passing side.

  ## A module compiled `:disabled` cannot be asserted about

  Under `mode: :disabled` the `@before_compile` hook emits no predicates — that is what
  makes the mode free. Every helper here says so by name rather than failing as though the
  declaration were false.
  """

  @doc "Imports the helpers. `use ExUnit.Case` first."
  defmacro __using__(_opts) do
    quote do
      import TLA.Invariant.Test
    end
  end

  @doc """
  Assert that `state` satisfies every invariant of `module`.

  Names *every* invariant that failed, not the first: a state that breaks three of them is
  three separate facts about the state, and reporting one hides the other two behind
  another test run.
  """
  defmacro assert_invariants(module, state) do
    quote bind_quoted: [module: module, state: state] do
      case TLA.Invariant.Test.__failing_invariants__(module, state) do
        [] ->
          :ok

        failing ->
          ExUnit.Assertions.flunk(
            TLA.Invariant.Test.__report__(module, :invariant, failing, state)
          )
      end
    end
  end

  @doc """
  Assert that the transition from `old_state` to `new_state` satisfies every action
  property of `module`. Names every one that failed.
  """
  defmacro assert_action_properties(module, old_state, new_state) do
    quote bind_quoted: [module: module, old_state: old_state, new_state: new_state] do
      case TLA.Invariant.Test.__failing_properties__(module, old_state, new_state) do
        [] ->
          :ok

        failing ->
          ExUnit.Assertions.flunk(
            TLA.Invariant.Test.__report__(
              module,
              :action_property,
              failing,
              {old_state, new_state}
            )
          )
      end
    end
  end

  @doc """
  Assert that `state` VIOLATES the named invariant of `module`.

  Fails when the invariant holds, and fails differently when `module` declares no
  invariant by that name — a renamed declaration would otherwise turn this test green by
  making it check nothing.
  """
  defmacro refute_invariant(module, name, state) do
    quote bind_quoted: [module: module, name: name, state: state] do
      TLA.Invariant.Test.__ensure_declared__(module, name)

      if TLA.Invariant.Test.__holds__(module, name, state) do
        ExUnit.Assertions.flunk("""
        Expected invariant #{inspect(name)} of #{inspect(module)} to be VIOLATED by

            #{inspect(state, pretty: true)}

        It held. An invariant no test has ever seen fail is indistinguishable from `true`.
        """)
      else
        :ok
      end
    end
  end

  if Code.ensure_loaded?(StreamData) do
    @doc """
    A generator of states satisfying `module`'s named type invariant.

    `base_generator` produces candidate states and this keeps the ones the invariant
    admits, so a property test over the result never has to state the type constraint a
    second time — a restatement is a second place for it to drift.

    Filtering rather than constructing is deliberate: the invariant is the only definition
    of the type the module actually enforces, and a generator built to mirror it would be
    a copy that can disagree with it.
    """
    @spec valid_states(module(), atom(), StreamData.t()) :: StreamData.t()
    def valid_states(module, type_invariant_name, base_generator) do
      __ensure_declared__(module, type_invariant_name)
      StreamData.filter(base_generator, &__holds__(module, type_invariant_name, &1))
    end
  else
    @doc """
    Unavailable: `stream_data` is not loaded.

    It is a `dev`/`test`-only dependency of ExTLA, so a consumer who wants generators
    declares it themselves — and this function has a body only where it does.
    """
    @spec valid_states(module(), atom(), term()) :: no_return()
    def valid_states(_module, _type_invariant_name, _base_generator) do
      raise ArgumentError,
            "TLA.Invariant.Test.valid_states/3 needs `stream_data`, which is not loaded. " <>
              "Add `{:stream_data, \"~> 1.0\", only: [:dev, :test]}` to your deps."
    end
  end

  @doc false
  def __failing_invariants__(module, state) do
    __ensure_instrumented__(module)

    for name <- module.__tla_names__(:invariant),
        !__holds__(module, name, state),
        do: name
  end

  @doc false
  def __failing_properties__(module, old_state, new_state) do
    __ensure_instrumented__(module)

    for name <- module.__tla_names__(:action_property),
        !module.__tla_action_property__(name, old_state, new_state),
        do: name
  end

  @doc false
  def __holds__(module, name, state) do
    __ensure_instrumented__(module)
    !!module.__tla_invariant__(name, state)
  end

  @doc false
  def __report__(module, kind, failing, subject) do
    label = if kind == :invariant, do: "invariant", else: "action property"

    described =
      Enum.map_join(failing, "\n", fn name ->
        case module.__tla_describe__(kind, name) do
          "" -> "  - #{inspect(name)}"
          description -> "  - #{inspect(name)}: #{description}"
        end
      end)

    subject_lines =
      case subject do
        {old_state, new_state} ->
          "old:\n\n#{inspect(old_state, pretty: true)}\n\nnew:\n\n#{inspect(new_state, pretty: true)}"

        state ->
          "state:\n\n#{inspect(state, pretty: true)}"
      end

    plural = if length(failing) == 1, do: "#{label}", else: "#{label}s"

    "#{length(failing)} #{plural} of #{inspect(module)} failed:\n\n#{described}\n\n#{subject_lines}\n"
  end

  @doc false
  def __ensure_declared__(module, name) do
    __ensure_instrumented__(module)

    unless name in module.__tla_names__(:invariant) do
      raise ArgumentError,
            "#{inspect(module)} declares no invariant named #{inspect(name)}. " <>
              "It declares: #{inspect(module.__tla_names__(:invariant))}"
    end

    :ok
  end

  @doc false
  def __ensure_instrumented__(module) do
    Code.ensure_loaded(module)

    unless function_exported?(module, :__tla_names__, 1) do
      raise ArgumentError,
            "#{inspect(module)} carries no Layer 1 predicates. Either it does not " <>
              "`use TLA.Invariant`, or it was compiled under `config :extla, mode: :disabled`, " <>
              "which emits none — see 03-layer1-invariants.md §`:disabled` emits nothing."
    end

    :ok
  end
end
