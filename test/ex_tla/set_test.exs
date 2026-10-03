defmodule ExTLA.SetTest do
  use ExUnit.Case, async: true

  doctest ExTLA.Set

  alias ExTLA.Set, as: S

  describe "powerset/1" do
    test "has 2^n elements and contains the empty set and the set itself" do
      set = MapSet.new([1, 2, 3])
      p = S.powerset(set)

      assert MapSet.size(p) == 8
      assert MapSet.member?(p, MapSet.new())
      assert MapSet.member?(p, set)
    end

    test "the powerset of the empty set is the set containing the empty set" do
      assert S.powerset(MapSet.new()) == MapSet.new([MapSet.new()])
    end
  end

  describe "cross/2 and cross_many/1" do
    test "cross/2 has |S1| * |S2| elements" do
      assert MapSet.size(S.cross(MapSet.new(1..3), MapSet.new(1..4))) == 12
    end

    test "cross/2 with an empty operand is empty" do
      assert S.cross(MapSet.new([1]), MapSet.new()) == MapSet.new()
      assert S.cross(MapSet.new(), MapSet.new([1])) == MapSet.new()
    end

    test "cross_many/1 preserves the order of the sets in each tuple" do
      product = S.cross_many([MapSet.new([1]), MapSet.new([:a]), MapSet.new(["x"])])
      assert product == MapSet.new([{1, :a, "x"}])
    end

    test "cross_many/1 of one set gives 1-tuples, not bare elements" do
      assert S.cross_many([MapSet.new([1, 2])]) == MapSet.new([{1}, {2}])
    end

    # The DSL needs this: an action with no parameters has exactly one binding,
    # binding nothing. The empty set would mean the action can never fire.
    test "cross_many/1 of no sets is the set containing the empty tuple" do
      assert S.cross_many([]) == MapSet.new([{}])
    end

    test "cross_many/1 with any empty operand is empty" do
      assert S.cross_many([MapSet.new([1]), MapSet.new(), MapSet.new([2])]) == MapSet.new()
    end
  end

  describe "distributed_union/1" do
    test "flattens and deduplicates" do
      sets = MapSet.new([MapSet.new([1, 2]), MapSet.new([2, 3]), MapSet.new()])
      assert S.distributed_union(sets) == MapSet.new([1, 2, 3])
    end

    test "the union of no sets is empty" do
      assert S.distributed_union(MapSet.new()) == MapSet.new()
    end
  end

  describe "map/2 and filter/2" do
    test "map/2 collapses elements under a non-injective function, as TLA+ does" do
      assert S.map(MapSet.new(1..10), &rem(&1, 3)) == MapSet.new([0, 1, 2])
    end

    test "filter/2 keeps only satisfying elements" do
      assert S.filter(MapSet.new(1..6), &(&1 > 4)) == MapSet.new([5, 6])
      assert S.filter(MapSet.new(1..6), fn _ -> false end) == MapSet.new()
    end
  end

  describe "choose/2" do
    # CHOOSE must be a function of its arguments: two equal sets built differently,
    # in any order, must yield the same element. A CHOOSE that varied between runs
    # would make the reachable state graph vary between runs.
    test "is independent of how the set was built" do
      built_up = Enum.reduce(1..64, MapSet.new(), &MapSet.put(&2, &1))
      built_down = Enum.reduce(64..1//-1, MapSet.new(), &MapSet.put(&2, &1))
      shuffled = MapSet.new(Enum.shuffle(1..64))

      assert built_up == built_down
      assert S.choose(built_up) == S.choose(built_down)
      assert S.choose(built_up) == S.choose(shuffled)
    end

    test "returns the least element in term order" do
      assert S.choose(MapSet.new([3, 1, 2])) == 1
      assert S.choose(MapSet.new([:b, :a])) == :a
    end

    test "applies the predicate before choosing" do
      assert S.choose(MapSet.new(1..10), &(&1 > 7)) == 8
    end

    test "raises when nothing satisfies the predicate" do
      assert_raise ArgumentError, ~r/no element satisfies the predicate/, fn ->
        S.choose(MapSet.new([1, 2]), &(&1 > 5))
      end
    end

    test "raises on the empty set" do
      assert_raise ArgumentError, fn -> S.choose(MapSet.new()) end
    end
  end

  describe "for_all?/2 and exists?/2" do
    test "quantify as TLA+ does over the empty set" do
      assert S.for_all?(MapSet.new(), fn _ -> false end)
      refute S.exists?(MapSet.new(), fn _ -> true end)
    end

    test "for_all? is false as soon as one element fails" do
      refute S.for_all?(MapSet.new(1..5), &(&1 < 5))
    end

    test "exists? is true as soon as one element passes" do
      assert S.exists?(MapSet.new(1..5), &(&1 == 5))
    end
  end

  describe "range/2" do
    test "is inclusive at both ends" do
      assert S.range(1, 3) == MapSet.new([1, 2, 3])
      assert S.range(0, 0) == MapSet.new([0])
    end

    test "is empty when the bounds are reversed, as in TLA+" do
      assert S.range(3, 1) == MapSet.new()
    end

    test "handles negative bounds" do
      assert S.range(-2, 1) == MapSet.new([-2, -1, 0, 1])
    end
  end
end
