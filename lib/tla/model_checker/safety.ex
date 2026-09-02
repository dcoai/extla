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

  @doc """
  Check the selected invariants against a single state.

  `only` restricts the check to named invariants, the way a TLC `.cfg` selects
  which of a module's invariants a run checks; `:all` is every declared one.
  """
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
  def check_action_properties(spec, constants, old_state, new_state, only \\ :all) do
    spec.action_properties
    |> selected(only)
    |> Enum.find_value(:ok, fn property ->
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
  def classify_stuck(spec, constants, state) do
    if Enum.any?(spec.terminals, & &1.predicate.(constants, state)),
      do: :terminal,
      else: :deadlocked
  end

  @doc """
  The declarations a run with `only` will actually check.

  Selection exists for the differential corpus: TLC halts at the first violation
  and so does ExTLA, so reproducing TLC's per-invariant report means one run per
  invariant — and a run measuring the state count has to check nothing at all.
  """
  def selected(declarations, :all), do: declarations

  def selected(declarations, names) when is_list(names),
    do: Enum.filter(declarations, &(&1.name in names))
end
