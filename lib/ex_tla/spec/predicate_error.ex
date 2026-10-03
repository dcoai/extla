defmodule ExTLA.Spec.PredicateError do
  @moduledoc """
  Raised when a predicate — `invariant`, `terminal`, `action_property`, or a
  state predicate inside a `temporal` — evaluates to something other than
  `true` or `false`.

  Elixir's `and`/`or` return their last operand, so `n >= 0 and status`
  evaluates to `status`, and a checker that tests the result for truthiness
  counts every non-`nil`, non-`false` value as "holds". A predicate that checks
  nothing would then report green — the shape Design Principle 6 forbids. The
  compiled predicate passes its result through `boolean!/3` instead, so every
  consumer (the checker, trace replay, coverage, the ledger) gets the same
  refusal, naming the declaration and the value it returned.
  """

  defexception [:module, :declaration, :value]

  @impl true
  def message(%{module: module, declaration: declaration, value: value}) do
    "#{inspect(module)}, in #{declaration}: the predicate returned #{inspect(value)}, " <>
      "which is not a boolean.\n\n" <>
      "A predicate must be `true` or `false` in every state. `and`/`or` return their last " <>
      "operand, so a non-boolean usually means a comparison is missing — `status` where " <>
      "`status == :done` was meant. A truthy value is refused rather than counted as " <>
      "holding, so a predicate that checks nothing cannot report green."
  end

  @doc """
  The predicate's result, if it is a boolean; otherwise raise naming the
  declaration it came from.
  """
  def boolean!(result, _module, _declaration) when is_boolean(result), do: result

  def boolean!(other, module, declaration) do
    raise __MODULE__, module: module, declaration: declaration, value: other
  end
end
