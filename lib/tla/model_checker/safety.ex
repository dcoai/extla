defmodule TLA.ModelChecker.Safety do
  @moduledoc """
  Safety property checking: invariants and action properties, checked
  incrementally during state exploration.

  Invariants are evaluated once per *distinct* state, when it is first
  discovered. Action properties are evaluated once per *transition*, including
  transitions into a state already seen — the property constrains the step, not
  the destination, so a second way of reaching the same state is a second thing
  to check.
  """

  alias TLA.Spec.Compiled
  alias TLA.State

  @doc """
  Check the selected invariants against a single state.

  `only` restricts the check to named invariants, the way a TLC `.cfg` selects
  which of a module's invariants a run checks; `:all` is every declared one.
  """
  @spec check_invariants(Compiled.t(), map(), State.t(), :all | [atom()]) ::
          :ok | {:violation, atom()}
  def check_invariants(spec, constants, state, only \\ :all) do
    spec.invariants
    |> selected(only)
    |> Enum.find_value(:ok, fn invariant ->
      if invariant.predicate.(constants, state), do: nil, else: {:violation, invariant.name}
    end)
  end

  @doc """
  Check all action properties against a transition.
  """
  @spec check_action_properties(Compiled.t(), map(), State.t(), State.t()) ::
          :ok | {:violation, atom()}
  def check_action_properties(spec, constants, old_state, new_state) do
    Enum.find_value(spec.action_properties, :ok, fn property ->
      if property.predicate.(constants, old_state, new_state),
        do: nil,
        else: {:violation, property.name}
    end)
  end

  @doc """
  Classify a state that produced no successors: `:terminal` if a `terminal`
  predicate admits it (`02-dsl-semantics.md` §5.3), `:deadlocked` otherwise.

  A `terminal` says *which* states are meant to be final, which is why it is
  preferred over `check_deadlock: false` — that turns the check off for every
  other state in the spec at the same time.
  """
  @spec classify_stuck(Compiled.t(), map(), State.t()) :: :terminal | :deadlocked
  def classify_stuck(spec, constants, state) do
    if Enum.any?(spec.terminals, & &1.predicate.(constants, state)),
      do: :terminal,
      else: :deadlocked
  end

  @doc """
  The invariants a run with `only` will actually check.
  """
  @spec selected([Compiled.invariant_def()], :all | [atom()]) :: [Compiled.invariant_def()]
  def selected(invariants, :all), do: invariants

  def selected(invariants, names) when is_list(names),
    do: Enum.filter(invariants, &(&1.name in names))
end
