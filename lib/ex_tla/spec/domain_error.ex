defmodule ExTLA.Spec.DomainError do
  @moduledoc """
  Raised by `f[x]` where `x` is outside the domain of `f`
  (`02-dsl-semantics.md` §1.6, D-20).

  TLA+ leaves `f[x]` undefined there, and `ExTLA.Spec.Helpers.at/3` — what `f[x]`
  compiles to inside a spec block — raises rather than returning `nil`, for the
  reason `01-foundation.md` gives for reading a variable that is not there.
  """

  defexception [:collection, :key, :where]

  @impl true
  def message(%{collection: f, key: key, where: where}) when is_map(f) and not is_struct(f) do
    "#{applied(where, key)}: #{inspect(key)} is not in the domain " <>
      "#{inspect(Enum.sort(Map.keys(f)))}." <> why()
  end

  def message(%{collection: seq, key: key, where: where}) when is_list(seq) do
    "#{applied(where, key)}: #{inspect(key)} is outside #{domain_of(seq)}, so this " <>
      "application is undefined." <> why()
  end

  def message(%{collection: other, key: key, where: where}) do
    "#{applied(where, key)}: #{inspect(other)} is neither a function nor a sequence, " <>
      "so it cannot be applied." <> why()
  end

  defp applied(nil, key), do: "f[#{inspect(key)}]"
  defp applied(where, key), do: "#{where}[#{inspect(key)}]"

  defp domain_of([]), do: "the empty domain of the empty sequence"
  defp domain_of(seq), do: "1..#{length(seq)}, the domain of a sequence of that length"

  defp why do
    "\n\nTLA+ leaves `f[x]` undefined outside the domain of `f`. Returning nil " <>
      "instead\nwould be the failure 01-foundation.md describes for reading a variable " <>
      "that is\nnot there: nil compares unequal to whatever the guard expected, the action\n" <>
      "looks disabled, and the checker explores a smaller state space and reports\nsuccess."
  end
end
