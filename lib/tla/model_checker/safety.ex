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
    case admitting_terminals(spec, constants, state) do
      [] -> :deadlocked
      _ -> :terminal
    end
  end

  @doc """
  The names of every `terminal` whose predicate admits `state`. Empty means a deadlock.

  `classify_stuck/3` is this with the names thrown away; the checker asks for the names so
  coverage can count which terminal ended which behaviour (#202) from one evaluation.
  """
  def admitting_terminals(spec, constants, state) do
    for terminal <- spec.terminals, terminal.predicate.(constants, state), do: terminal.name
  end

  @doc """
  The declarations a run with `only` will actually check.

  Selection exists for the differential corpus: TLC halts at the first violation
  and so does ExTLA, so reproducing TLC's per-invariant report means one run per
  invariant — and a run measuring the state count has to check nothing at all.
  """
  def selected(declarations, :all), do: declarations

  def selected(declarations, names) when is_list(names) do
    reject_unmatched!(declarations, names)
    Enum.filter(declarations, &(&1.name in names))
  end

  @doc """
  Refuse a selection naming something the spec does not declare.

  Without this, a typo checks **nothing** and the run reports `:ok` (#166):

      invariants: [:cap]         status=:violation
      invariants: [:capp] (typo) status=:ok  warnings=[]

  The filter matched no declaration, the coverage table came out empty, and the search had
  nothing to evaluate — so the run is green because it verified nothing, which is the one
  outcome Design Principle 6 exists to make impossible.

  It matters beyond a hand-typed config. `TLA.DifferentialCase` drives the whole TLC corpus
  through these selections using names read from `expected.json`, and D-9 makes agreement
  with TLC the Phase 1 acceptance gate. A misspelled name in a fixture makes
  `assert result.status == :ok` pass having compared nothing at all.
  """
  def reject_unmatched!(declarations, names) do
    declared = MapSet.new(declarations, & &1.name)

    case Enum.reject(names, &MapSet.member?(declared, &1)) do
      [] ->
        :ok

      unmatched ->
        raise ArgumentError, """
        selection names #{Enum.map_join(unmatched, ", ", &inspect/1)}, which this spec does not declare.

        Declared: #{declared |> Enum.sort() |> Enum.map_join(", ", &inspect/1)}.

        A selection that matches nothing checks nothing, and the run would report `:ok`
        having verified none of what you asked for.
        """
    end
  end
end
