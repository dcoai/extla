defmodule TLA.Function do
  @moduledoc """
  TLA+ function operations. In TLA+, a function maps every element
  of its domain to a value. Elixir maps serve as the implementation.

  "Total over its domain" is the property that matters, and it is why `except/2`
  and `except_with/3` raise on a point outside the domain rather than adding it:
  `[f EXCEPT ![a] = v]` where `a ∉ DOMAIN f` is undefined in TLA+, and quietly
  extending the domain would produce a state that no reachable spec behavior can
  produce — while still being fingerprinted as if it were one.
  """

  @doc """
  Construct a function: `[x ∈ S ↦ expr(x)]`.

      iex> TLA.Function.construct(MapSet.new([1, 2]), &(&1 * 10))
      %{1 => 10, 2 => 20}
  """
  @spec construct(MapSet.t(), (term() -> term())) :: map()
  def construct(domain, mapping), do: Map.new(domain, &{&1, mapping.(&1)})

  @doc """
  Function set: `[S → T]` — all total functions from `S` to `T`.

  Warning: `|T|^|S|` elements. Use with small sets: three processes over four
  states is 64 functions, but five over four is already 1024.

      iex> TLA.Function.function_set(MapSet.new([:a]), MapSet.new([0, 1]))
      MapSet.new([%{a: 0}, %{a: 1}])

      iex> TLA.Function.function_set(MapSet.new([]), MapSet.new([0, 1]))
      MapSet.new([%{}])
  """
  @spec function_set(MapSet.t(), MapSet.t()) :: MapSet.t(map())
  def function_set(domain, range) do
    domain
    |> Enum.reduce([%{}], fn key, functions ->
      for f <- functions, value <- range, do: Map.put(f, key, value)
    end)
    |> MapSet.new()
  end

  @doc """
  `DOMAIN f` — the domain of a function.

      iex> TLA.Function.domain(%{a: 1, b: 2})
      MapSet.new([:a, :b])
  """
  @spec domain(map()) :: MapSet.t()
  def domain(f), do: f |> Map.keys() |> MapSet.new()

  @doc """
  `EXCEPT` — update a function at specific points:
  `[f EXCEPT ![a] = v, ![b] = w]`.

  Raises `KeyError` on a point outside the domain — see the module documentation.

      iex> TLA.Function.except(%{a: 1, b: 2}, a: 9)
      %{a: 9, b: 2}
  """
  @spec except(map(), [{term(), term()}]) :: map()
  def except(f, updates) do
    Enum.reduce(updates, f, fn {key, value}, acc -> Map.replace!(acc, key, value) end)
  end

  @doc """
  `EXCEPT` with self-reference — update using the old value:
  `[f EXCEPT ![a] = @ + 1]`.

      iex> TLA.Function.except_with(%{a: 1}, :a, &(&1 + 1))
      %{a: 2}
  """
  @spec except_with(map(), term(), (term() -> term())) :: map()
  def except_with(f, key, update_fn), do: Map.update!(f, key, update_fn)

  @doc """
  Record set: `[field1: S1, field2: S2]` — all records with fields drawn from the
  respective sets.

      iex> TLA.Function.record_set(pc: MapSet.new([:idle, :busy]), n: MapSet.new([0]))
      MapSet.new([%{pc: :idle, n: 0}, %{pc: :busy, n: 0}])
  """
  @spec record_set(keyword(MapSet.t())) :: MapSet.t(map())
  def record_set(field_specs) do
    field_specs
    |> Enum.reduce([%{}], fn {field, set}, records ->
      for record <- records, value <- set, do: Map.put(record, field, value)
    end)
    |> MapSet.new()
  end
end
