defmodule TLA.Spec.HelpersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest TLA.Spec.Helpers

  alias TLA.Spec.Helpers, as: H

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
        assert_raise TLA.Spec.DomainError, fn -> H.at(%{alice: 3}, :carol, "balances") end

      message = Exception.message(error)

      assert message =~ "balances[:carol]"
      assert message =~ "not in the domain [:alice]"
    end

    test "raises outside the domain of a sequence, which is 1..Len" do
      assert_raise TLA.Spec.DomainError, fn -> H.at([:a, :b], 0) end
      assert_raise TLA.Spec.DomainError, fn -> H.at([:a, :b], 3) end
      assert_raise TLA.Spec.DomainError, fn -> H.at([], 1) end
    end

    test "raises on a term that is neither a function nor a sequence" do
      error = assert_raise TLA.Spec.DomainError, fn -> H.at(MapSet.new([1]), 1) end

      assert Exception.message(error) =~ "neither a function nor a sequence"
    end

    # A keyword list is a list, so its key is not an index. Inside a spec block
    # that is the right answer: state is maps and sequences.
    test "raises on a keyword list indexed by its key" do
      assert_raise TLA.Spec.DomainError, fn -> H.at([mode: :fast], :mode) end
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
        error = assert_raise TLA.Spec.DomainError, fn -> H.subseq(s, m, n) end
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
      assert_raise TLA.Spec.DomainError, fn -> H.subseq(MapSet.new([1, 2]), 1, 1) end
    end

    property "subseq/3 and at/2 agree on every out-of-domain index" do
      check all(
              s <- list_of(integer(), max_length: 6),
              m <- integer(-8..12),
              m not in 1..length(s)//1
            ) do
        assert_raise TLA.Spec.DomainError, fn -> H.at(s, m) end
        assert_raise TLA.Spec.DomainError, fn -> H.subseq(s, m, m) end
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
