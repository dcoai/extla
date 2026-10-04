defmodule ExTLA.Spec.HelpersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest ExTLA.Spec.Helpers

  alias ExTLA.Spec.Helpers, as: H

  describe "at/2 — function application" do
    test "applies a function and a sequence" do
      assert H.at(%{alice: 3, bob: 0}, :bob) == 0
      assert H.at([:a, :b, :c], 1) == :a
      assert H.at([:a, :b, :c], 3) == :c
    end

    # The failure D-20 exists to close: Access.get/2 returns nil here, and
    # `nil >= 2` is true under Erlang term order, so the guard that reads a key
    # it does not have enables its action anyway.
    test "raises outside the domain of a function" do
      error =
        assert_raise ExTLA.Spec.DomainError, fn -> H.at(%{alice: 3}, :carol, "balances") end

      message = Exception.message(error)

      assert message =~ "balances[:carol]"
      assert message =~ "not in the domain [:alice]"
    end

    test "raises outside the domain of a sequence, which is 1..Len" do
      assert_raise ExTLA.Spec.DomainError, fn -> H.at([:a, :b], 0) end
      assert_raise ExTLA.Spec.DomainError, fn -> H.at([:a, :b], 3) end
      assert_raise ExTLA.Spec.DomainError, fn -> H.at([], 1) end
    end

    test "raises on a term that is neither a function nor a sequence" do
      error = assert_raise ExTLA.Spec.DomainError, fn -> H.at(MapSet.new([1]), 1) end

      assert Exception.message(error) =~ "neither a function nor a sequence"
    end

    # A keyword list is a list, so its key is not an index. Inside a spec block
    # that is the right answer: state is maps and sequences.
    test "raises on a keyword list indexed by its key" do
      assert_raise ExTLA.Spec.DomainError, fn -> H.at([mode: :fast], :mode) end
    end
  end

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

    # #197. `subseq/3` was `Enum.slice(seq, m - 1, n - m + 1)`, which has Elixir's index
    # semantics: a zero index wrapped to the end, a negative one counted from the end, and an
    # off-by-one produced a valid sequence that was not the one the author wrote — silently,
    # where `at/2` raises for the identical slip.
    test "subseq/3 refuses an index outside 1..len, as at/2 does" do
      s = [1, 2, 3]

      for {m, n} <- [{0, 1}, {-1, -1}, {2, 4}, {4, 4}] do
        error = assert_raise ExTLA.Spec.DomainError, fn -> H.subseq(s, m, n) end
        assert Exception.message(error) =~ "SubSeq(s, #{m}, #{n})", inspect({m, n})
        assert Exception.message(error) =~ "outside 1..3", inspect({m, n})
      end
    end

    # TLC's `SubSeq(s, m, n)` with `n < m` is `<<>>` before any bound is examined, so
    # `SubSeq(<<>>, 2, 0)` is `<<>>` and not an error. This used to be a `FunctionClauseError`.
    test "subseq/3 with n < m is the empty sequence, whatever the bounds" do
      assert H.subseq([], 2, 0) == []
      assert H.subseq([1, 2, 3], 3, 2) == []
      assert H.subseq([1, 2, 3], 7, 5) == []
    end

    test "subseq/3 refuses a non-sequence where len/1 and at/2 already do" do
      assert_raise ExTLA.Spec.DomainError, fn -> H.subseq(MapSet.new([1, 2]), 1, 1) end
    end

    # The index is generated out of domain rather than filtered for (#341). A filter clause
    # rejects into the generator before it, which gives up after ten rejections in a row;
    # `m not in 1..length(s)` rejected up to 6 draws in 21, so about one run in 12,000 raised
    # FilterTooNarrowError (CI seed 796610). These are the same values, below 1 or above the
    # length, and `length(s) <= 6` keeps the upper range non-empty.
    property "subseq/3 and at/2 agree on every out-of-domain index" do
      check all(
              s <- list_of(integer(), max_length: 6),
              m <- one_of([integer(-8..0), integer((length(s) + 1)..12)])
            ) do
        assert_raise ExTLA.Spec.DomainError, fn -> H.at(s, m) end
        assert_raise ExTLA.Spec.DomainError, fn -> H.subseq(s, m, m) end
      end
    end

    property "subseq/3 in domain is the 1-indexed inclusive slice" do
      check all(
              s <- list_of(integer(), min_length: 1, max_length: 6),
              m <- integer(1..length(s)//1),
              n <- integer(m..length(s)//1)
            ) do
        assert H.subseq(s, m, n) == Enum.map(m..n, &H.at(s, &1))
      end
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

    # #211. `at/2` applies a list as a function on 1..Len; `domain/1` raised `BadMapError` on
    # the same list, and `for_each/2` built a function over a list, deduplicating silently.
    # The three now agree about what a function is.
    test "domain/1 answers 1..Len for a sequence, as at/2 applies one" do
      assert H.domain([:x, :y, :z]) == MapSet.new([1, 2, 3])
      assert H.domain([]) == MapSet.new()

      for i <- H.domain([:x, :y, :z]), do: assert(H.at([:x, :y, :z], i) in [:x, :y, :z])

      assert_raise ArgumentError, ~r/neither/, fn -> H.domain(MapSet.new([1])) end
    end

    test "for_each/2 ranges over a set or a range, and refuses a sequence by name" do
      assert H.for_each(1..3, &(&1 * 2)) == %{1 => 2, 2 => 4, 3 => 6}

      error = assert_raise ArgumentError, fn -> H.for_each([:a, :a, :b], fn _ -> 0 end) end
      assert error.message =~ "is a sequence"

      error = assert_raise ArgumentError, fn -> H.for_each(%{a: 1}, fn _ -> 0 end) end
      assert error.message =~ "is a function already"
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
    test "is ExTLA.Set.choose/2" do
      set = MapSet.new(1..20)

      assert H.choose(set) == ExTLA.Set.choose(set)
      assert H.choose(set, &(&1 > 15)) == ExTLA.Set.choose(set, &(&1 > 15))
      assert H.choose(set, &(&1 > 15)) == 16
    end

    test "raises when nothing satisfies the predicate" do
      assert_raise ArgumentError, fn -> H.choose(MapSet.new([1]), &(&1 > 5)) end
    end
  end
end
