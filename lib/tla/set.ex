defmodule TLA.Set do
  @moduledoc """
  Set operations corresponding to TLA+ set theory operators.
  Builds on Elixir's MapSet with additional TLA+ operations.
  """

  @doc """
  `SUBSET S` — the power set (set of all subsets).

  Warning: exponential in `|S|`. Use with small sets only — a 20-element set has
  a million subsets, and each one is a `MapSet`.

      iex> TLA.Set.powerset(MapSet.new([1, 2])) |> Enum.sort_by(&MapSet.size/1)
      [MapSet.new([]), MapSet.new([1]), MapSet.new([2]), MapSet.new([1, 2])]
  """
  @spec powerset(MapSet.t()) :: MapSet.t(MapSet.t())
  def powerset(set) do
    set
    |> Enum.reduce([MapSet.new()], fn element, subsets ->
      subsets ++ Enum.map(subsets, &MapSet.put(&1, element))
    end)
    |> MapSet.new()
  end

  @doc """
  `S1 \\X S2` — Cartesian product. The set of all tuples `{a, b}` where
  `a ∈ S1` and `b ∈ S2`.

      iex> TLA.Set.cross(MapSet.new([1, 2]), MapSet.new([:a]))
      MapSet.new([{1, :a}, {2, :a}])
  """
  @spec cross(MapSet.t(), MapSet.t()) :: MapSet.t(tuple())
  def cross(s1, s2) do
    for a <- s1, b <- s2, into: MapSet.new(), do: {a, b}
  end

  @doc """
  N-ary Cartesian product: `S1 \\X S2 \\X ... \\X Sn`.

  The product of no sets is the set containing the empty tuple, not the empty
  set — which is the answer the DSL needs when an action has no parameters: one
  binding, binding nothing.

      iex> TLA.Set.cross_many([MapSet.new([1, 2]), MapSet.new([:a, :b])]) |> MapSet.size()
      4

      iex> TLA.Set.cross_many([])
      MapSet.new([{}])
  """
  @spec cross_many([MapSet.t()]) :: MapSet.t(tuple())
  def cross_many(sets) do
    sets
    |> Enum.reduce([[]], fn set, acc -> for tail <- acc, x <- set, do: [x | tail] end)
    |> Enum.map(&(&1 |> Enum.reverse() |> List.to_tuple()))
    |> MapSet.new()
  end

  @doc """
  `UNION S` — distributed union. Flattens a set of sets.

      iex> TLA.Set.distributed_union(MapSet.new([MapSet.new([1, 2]), MapSet.new([2, 3])]))
      MapSet.new([1, 2, 3])
  """
  @spec distributed_union(MapSet.t(MapSet.t())) :: MapSet.t()
  def distributed_union(set_of_sets) do
    Enum.reduce(set_of_sets, MapSet.new(), &MapSet.union(&2, &1))
  end

  @doc """
  Set mapping: `{f(x) : x ∈ S}`.

  The result may be smaller than the input — a non-injective `f` collapses
  elements, exactly as in TLA+.

      iex> TLA.Set.map(MapSet.new([1, 2, 3]), &rem(&1, 2))
      MapSet.new([0, 1])
  """
  @spec map(MapSet.t(), (term() -> term())) :: MapSet.t()
  def map(set, fun), do: MapSet.new(set, fun)

  @doc """
  Set filtering: `{x ∈ S : P(x)}`.

      iex> TLA.Set.filter(MapSet.new([1, 2, 3, 4]), &(rem(&1, 2) == 0))
      MapSet.new([2, 4])
  """
  @spec filter(MapSet.t(), (term() -> boolean())) :: MapSet.t()
  def filter(set, predicate), do: set |> Enum.filter(predicate) |> MapSet.new()

  @doc """
  `CHOOSE x ∈ S : P(x)` — deterministic selection.

  Returns the least satisfying element in Erlang term order. TLA+ requires only
  that `CHOOSE` be a function of its arguments, not that it pick any particular
  element, so any total order will do — but it must be an order that does not
  depend on how the set was built or which OTP release is running. Enumeration
  order is not such an order, and a `CHOOSE` that varied between runs would make
  the reachable state graph vary between runs, which would defeat the differential
  corpus before it detected anything.

  Raises `ArgumentError` if no element satisfies the predicate; `CHOOSE` over an
  empty set is undefined in TLA+ and silently returning `nil` would put an
  unspecified value into a state variable.

      iex> TLA.Set.choose(MapSet.new([3, 1, 2]))
      1

      iex> TLA.Set.choose(MapSet.new([3, 1, 2]), &(&1 > 1))
      2
  """
  @spec choose(MapSet.t(), (term() -> boolean())) :: term()
  def choose(set, predicate \\ fn _ -> true end) do
    set
    |> Enum.filter(predicate)
    |> case do
      [] ->
        raise ArgumentError,
              "CHOOSE over #{inspect(set)}: no element satisfies the predicate. " <>
                "CHOOSE is undefined when nothing satisfies it, so there is no value to return."

      candidates ->
        Enum.min(candidates)
    end
  end

  @doc """
  `\\A x \\in S : P(x)` — check if the predicate holds for all elements.

  Vacuously true for the empty set.

      iex> TLA.Set.for_all?(MapSet.new([2, 4]), &(rem(&1, 2) == 0))
      true
  """
  @spec for_all?(MapSet.t(), (term() -> boolean())) :: boolean()
  def for_all?(set, predicate), do: Enum.all?(set, predicate)

  @doc """
  `\\E x \\in S : P(x)` — check if the predicate holds for at least one element.

  False for the empty set.

      iex> TLA.Set.exists?(MapSet.new([1, 2]), &(&1 > 1))
      true
  """
  @spec exists?(MapSet.t(), (term() -> boolean())) :: boolean()
  def exists?(set, predicate), do: Enum.any?(set, predicate)

  @doc """
  Integer range as a `MapSet`: `a..b`.

  Empty when `a > b`, as in TLA+.

      iex> TLA.Set.range(1, 3)
      MapSet.new([1, 2, 3])

      iex> TLA.Set.range(3, 1)
      MapSet.new([])
  """
  @spec range(integer(), integer()) :: MapSet.t(integer())
  def range(a, b) when is_integer(a) and is_integer(b), do: MapSet.new(a..b//1)
end
