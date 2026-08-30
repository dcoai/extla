defmodule TLA.Spec.HelpersTest do
  use ExUnit.Case, async: true

  doctest TLA.Spec.Helpers

  alias TLA.Spec.Helpers, as: H

  describe "set operations" do
    test "build and query sets" do
      assert H.set() == MapSet.new()
      assert H.set([1, 2, 2]) == MapSet.new([1, 2])
      assert H.put(H.set([1]), 2) == MapSet.new([1, 2])
      assert H.delete(H.set([1, 2]), 2) == MapSet.new([1])
      assert H.member?(H.set([1]), 1)
      assert H.size(H.set([1, 2, 3])) == 3
    end

    test "is_set/1 distinguishes sets from the other enumerables a spec might hold" do
      assert H.is_set(MapSet.new())
      refute H.is_set([])
      refute H.is_set(%{})
    end

    test "algebra matches MapSet" do
      a = H.set([1, 2, 3])
      b = H.set([3, 4])

      assert H.union(a, b) == MapSet.new([1, 2, 3, 4])
      assert H.intersection(a, b) == MapSet.new([3])
      assert H.difference(a, b) == MapSet.new([1, 2])
      assert H.subset?(H.set([1]), a)
      refute H.subset?(b, a)
    end

    # A set is unordered, so put/delete must be order-insensitive for the
    # fingerprint to see one state where a spec author sees one state.
    test "put and delete commute into the same set" do
      one = [1, 2, 3] |> Enum.reduce(H.set(), &H.put(&2, &1)) |> H.delete(2)
      two = [3, 2, 1] |> Enum.reduce(H.set(), &H.put(&2, &1)) |> H.delete(2)

      assert one == two
    end
  end

  describe "sequence operations" do
    test "build and query sequences" do
      assert H.seq() == []
      assert H.seq([1, 2]) == [1, 2]
      assert H.append([1], 2) == [1, 2]
      assert H.head([1, 2]) == 1
      assert H.tail([1, 2]) == [2]
      assert H.len([1, 2, 3]) == 3
    end

    # TLA+ sequences are 1-indexed. Getting this wrong is silent: an off-by-one
    # subsequence is still a valid sequence, so nothing raises and the spec just
    # says something other than what its author wrote.
    test "subseq/3 is 1-indexed and inclusive at both ends" do
      s = [:a, :b, :c, :d, :e]

      assert H.subseq(s, 1, 1) == [:a]
      assert H.subseq(s, 2, 4) == [:b, :c, :d]
      assert H.subseq(s, 1, 5) == s
    end

    # Called through apply/3 deliberately: the @spec says `nonempty_list()`, which
    # is the honest domain, and a direct call would draw a type warning for being
    # outside it. What is asserted here is what happens anyway -- a spec that takes
    # the head of an empty sequence fails loudly rather than producing a value.
    test "head/1 and tail/1 raise on the empty sequence, where TLA+ leaves them undefined" do
      assert_raise ArgumentError, fn -> apply(H, :head, [[]]) end
      assert_raise ArgumentError, fn -> apply(H, :tail, [[]]) end
    end
  end

  describe "function operations" do
    test "for_each/2 builds a total function over the domain" do
      assert H.for_each(MapSet.new([:a, :b]), &Atom.to_string/1) == %{a: "a", b: "b"}
      assert H.for_each(MapSet.new(), & &1) == %{}
    end

    test "update/3 raises rather than extending the domain" do
      assert H.update(%{a: 1}, :a, &(&1 + 1)) == %{a: 2}
      assert_raise KeyError, fn -> H.update(%{a: 1}, :b, &(&1 + 1)) end
    end

    test "values, keys and domain" do
      f = %{a: 1, b: 2}

      assert Enum.sort(H.values(f)) == [1, 2]
      assert Enum.sort(H.keys(f)) == [:a, :b]
      assert H.domain(f) == MapSet.new([:a, :b])
    end
  end

  describe "arithmetic" do
    test "sum/1 is zero over an empty enumerable" do
      assert H.sum([]) == 0
      assert H.sum([1, 2, 3]) == 6
      assert H.sum(MapSet.new([1, 2, 3])) == 6
    end

    test "sum/2 maps before summing" do
      assert H.sum([{:a, 1}, {:b, 2}], fn {_, n} -> n end) == 3
      assert H.sum([], fn _ -> 1 end) == 0
    end
  end

  describe "choose/2" do
    # The point of the delegation: there is one CHOOSE, and it is deterministic.
    # A second implementation here that happened to branch would reintroduce the
    # nondeterminism mechanism 02-dsl-semantics.md §3 removed.
    test "is TLA.Set.choose/2" do
      set = MapSet.new(1..20)

      assert H.choose(set) == TLA.Set.choose(set)
      assert H.choose(set, &(&1 > 15)) == TLA.Set.choose(set, &(&1 > 15))
      assert H.choose(set, &(&1 > 15)) == 16
    end

    test "raises when nothing satisfies the predicate" do
      assert_raise ArgumentError, fn -> H.choose(MapSet.new([1]), &(&1 > 5)) end
    end
  end
end
