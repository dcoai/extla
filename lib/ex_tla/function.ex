defmodule ExTLA.Function do
  @moduledoc """
  TLA+ function operations. In TLA+, a function maps every element
  of its domain to a value. Elixir maps serve as the implementation.

  "Total over its domain" is the property that matters, and it is why `except/2`
  and `except_with/3` raise on a point outside the domain rather than adding it:
  `[f EXCEPT ![a] = v]` where `a ∉ DOMAIN f` is undefined in TLA+, and quietly
  extending the domain would produce a state that no reachable spec behavior can
  produce — while still being fingerprinted as if it were one.

  This module holds the **only** implementation of each of these operators.
  `ExTLA.Spec.Helpers`, which a spec body imports, delegates to it and defines
  nothing of its own (D-38). Until #319 it carried a second copy, and the two had
  already drifted: `construct/2` deduplicated a sequence where `for_each/2`
  refused one, and `domain/1` answered a `MapSet` with the struct's own field
  names. #318 has the measurement.
  """

  @doc """
  Construct a function: `[x ∈ S ↦ expr(x)]`.

      iex> ExTLA.Function.construct(MapSet.new([1, 2]), &(&1 * 10))
      %{1 => 10, 2 => 20}

  `S` is a **set** — a `MapSet` or a range. A list is a *sequence*, which is a
  function on `1..Len(s)` already, and building a function over one deduplicated
  it silently (#211); a map is a function already. Both are refused by name, the
  way `ExTLA.Spec.Helpers.at/2` refuses a term that is neither. A spec body spells
  this operator `for_each/2`, which is the name the message uses.
  """
  def construct(domain, mapping) when is_struct(domain, MapSet) or is_struct(domain, Range),
    do: Map.new(domain, &{&1, mapping.(&1)})

  def construct(other, _mapping) do
    raise ArgumentError,
          "for_each/2 builds a function over a set, and #{inspect(other)} is " <>
            "#{describe_not_a_set(other)}. Pass a MapSet or a range (02-dsl-semantics.md §1.6)."
  end

  defp describe_not_a_set(list) when is_list(list),
    do: "a sequence — a function on 1..Len already, whose elements Enum.map/2 can transform"

  defp describe_not_a_set(map) when is_map(map), do: "a function already"
  defp describe_not_a_set(_other), do: "neither a set nor a range"

  @doc """
  Function set: `[S → T]` — all total functions from `S` to `T`.

  Warning: `|T|^|S|` elements. Use with small sets: three processes over four
  states is 64 functions, but five over four is already 1024.

      iex> ExTLA.Function.function_set(MapSet.new([:a]), MapSet.new([0, 1]))
      MapSet.new([%{a: 0}, %{a: 1}])

      iex> ExTLA.Function.function_set(MapSet.new([]), MapSet.new([0, 1]))
      MapSet.new([%{}])
  """
  def function_set(domain, range) do
    domain
    |> Enum.reduce([%{}], fn key, functions ->
      for f <- functions, value <- range, do: Map.put(f, key, value)
    end)
    |> MapSet.new()
  end

  @doc """
  `DOMAIN f` — the domain of a function, as a set.

      iex> ExTLA.Function.domain(%{a: 1, b: 2})
      MapSet.new([:a, :b])

  A sequence is a function on `1..Len(s)` — that is what `ExTLA.Spec.Helpers.at/2`
  applies it as — so its domain is that range (#211):

      iex> ExTLA.Function.domain([:x, :y, :z])
      MapSet.new([1, 2, 3])

  Anything else is refused by name. This was `Map.keys |> MapSet.new`, which
  raised `BadMapError` on a sequence and — because a `MapSet` is a struct and
  therefore a map — answered a **set** with the struct's own field names (#318).
  A wrong answer that looks like an answer is the failure D-20 exists to refuse.
  """
  def domain(f) when is_map(f) and not is_struct(f), do: MapSet.new(Map.keys(f))
  def domain(seq) when is_list(seq), do: MapSet.new(1..length(seq)//1)

  def domain(other) do
    raise ArgumentError,
          "domain/1 takes a function (a map) or a sequence (a list); #{inspect(other)} is " <>
            "neither (02-dsl-semantics.md §1.6)."
  end

  @doc """
  `EXCEPT` — update a function at specific points:
  `[f EXCEPT ![a] = v, ![b] = w]`.

  Raises `KeyError` on a point outside the domain — see the module documentation.

      iex> ExTLA.Function.except(%{a: 1, b: 2}, a: 9)
      %{a: 9, b: 2}
  """
  def except(f, updates) do
    Enum.reduce(updates, f, fn {key, value}, acc -> Map.replace!(acc, key, value) end)
  end

  @doc """
  `EXCEPT` with self-reference — update using the old value:
  `[f EXCEPT ![a] = @ + 1]`.

      iex> ExTLA.Function.except_with(%{a: 1}, :a, &(&1 + 1))
      %{a: 2}
  """
  def except_with(f, key, update_fn), do: Map.update!(f, key, update_fn)

  @doc """
  Record set: `[field1: S1, field2: S2]` — all records with fields drawn from the
  respective sets.

      iex> ExTLA.Function.record_set(pc: MapSet.new([:idle, :busy]), n: MapSet.new([0]))
      MapSet.new([%{pc: :idle, n: 0}, %{pc: :busy, n: 0}])
  """
  def record_set(field_specs) do
    field_specs
    |> Enum.reduce([%{}], fn {field, set}, records ->
      for record <- records, value <- set, do: Map.put(record, field, value)
    end)
    |> MapSet.new()
  end
end
