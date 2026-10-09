defmodule ExTLA.ProductTest do
  @moduledoc """
  The independent n-ary product, written once (#350, #368), against an oracle that is not it.

  `ExTLA.Set.cross_many/1`, `ExTLA.Function.record_set/1`, `function_set/2` and
  `ExTLA.Symmetry.mappings/2` now all run on `ExTLA.Product.fold/3`. The oracle below is a
  plain recursion with no fold, so an agreement is between two implementations, not one
  implementation and itself.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExTLA.{Function, Set, Symmetry}

  # Every combination of one element from each of `sets`, as lists, by recursion.
  defp oracle([]), do: [[]]
  defp oracle([set | rest]), do: for(x <- set, tail <- oracle(rest), do: [x | tail])

  defp small_sets(max_sets) do
    StreamData.list_of(StreamData.list_of(StreamData.integer(0..4), max_length: 3),
      max_length: max_sets
    )
    |> StreamData.map(fn lists -> Enum.map(lists, &MapSet.new/1) end)
  end

  property "record_set/1 is the product of its fields, keyed" do
    check all(sets <- small_sets(4)) do
      keys = Enum.map(Enum.with_index(sets), fn {_, i} -> :"f#{i}" end)

      expected = MapSet.new(for combo <- oracle(sets), do: Map.new(Enum.zip(keys, combo)))

      assert Function.record_set(Enum.zip(keys, sets)) == expected
    end
  end

  property "cross_many/1 is the same product, as tuples in the sets' order" do
    check all(sets <- small_sets(4)) do
      assert Set.cross_many(sets) ==
               MapSet.new(for combo <- oracle(sets), do: List.to_tuple(combo))
    end
  end

  property "function_set/2 is the product with one range per domain key" do
    check all(
            domain <- StreamData.list_of(StreamData.atom(:alphanumeric), max_length: 3),
            range <- StreamData.list_of(StreamData.integer(0..3), max_length: 3)
          ) do
      domain = MapSet.new(domain)
      range = MapSet.new(range)
      keys = Enum.to_list(domain)

      expected =
        MapSet.new(
          for combo <- oracle(Enum.map(keys, fn _ -> range end)),
              do: Map.new(Enum.zip(keys, combo))
        )

      assert Function.function_set(domain, range) == expected
    end
  end

  test "the empty product is one empty combination, and an empty factor empties it" do
    assert Set.cross_many([]) == MapSet.new([{}])
    assert Function.record_set([]) == MapSet.new([%{}])
    assert Function.function_set(MapSet.new(), MapSet.new([1])) == MapSet.new([%{}])
    assert Set.cross_many([MapSet.new([1]), MapSet.new()]) == MapSet.new()
    assert Function.record_set(a: MapSet.new([1]), b: MapSet.new()) == MapSet.new()
  end

  # `mappings/2` returns a LIST, in an order that decides nothing (canonicalization takes a
  # minimum) but that the fold is still expected to keep. Pinned against the pre-#368 shape,
  # written out here.
  test "Symmetry.mappings/2 keeps its order" do
    constants = %{p: MapSet.new([:a, :b, :c]), q: MapSet.new([1, 2])}
    per_set = for name <- [:p, :q], do: substitutions(Enum.sort(constants[name]))

    previous =
      Enum.reduce(per_set, [%{}], fn subs, acc ->
        for base <- acc, one <- subs, do: Map.merge(base, one)
      end)

    assert Symmetry.mappings(constants, [:p, :q]) == previous
    assert length(previous) == 6 * 2
  end

  defp substitutions(elements),
    do: for(permuted <- permutations(elements), do: Map.new(Enum.zip(elements, permuted)))

  defp permutations([]), do: [[]]
  defp permutations(list), do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])
end
