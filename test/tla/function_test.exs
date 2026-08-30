defmodule TLA.FunctionTest do
  use ExUnit.Case, async: true

  doctest TLA.Function

  alias TLA.Function, as: F

  describe "construct/2" do
    test "is total over the domain" do
      f = F.construct(MapSet.new([:a, :b, :c]), fn _ -> 0 end)
      assert F.domain(f) == MapSet.new([:a, :b, :c])
    end

    test "an empty domain gives the empty function" do
      assert F.construct(MapSet.new(), &Function.identity/1) == %{}
    end
  end

  describe "function_set/2" do
    # |T|^|S|, not |S|^|T| -- a function fixes a value for each element of the
    # DOMAIN, so the domain is the exponent.
    test "has |range|^|domain| elements" do
      domain = MapSet.new([:a, :b, :c])
      range = MapSet.new([0, 1])

      assert MapSet.size(F.function_set(domain, range)) == 8
      assert MapSet.size(F.function_set(range, domain)) == 9
    end

    test "every member is total over the domain" do
      domain = MapSet.new([:a, :b])
      functions = F.function_set(domain, MapSet.new([0, 1]))

      assert Enum.all?(functions, &(F.domain(&1) == domain))
    end

    test "an empty domain gives exactly one function, the empty one" do
      assert F.function_set(MapSet.new(), MapSet.new([1, 2])) == MapSet.new([%{}])
    end

    # There is no total function into an empty range, so the set is empty --
    # distinct from the empty-domain case above, which has exactly one.
    test "an empty range with a non-empty domain gives no functions" do
      assert F.function_set(MapSet.new([:a]), MapSet.new()) == MapSet.new()
    end
  end

  describe "domain/1" do
    test "returns the keys as a set" do
      assert F.domain(%{a: 1, b: 2}) == MapSet.new([:a, :b])
      assert F.domain(%{}) == MapSet.new()
    end
  end

  describe "except/2" do
    test "updates the named points and leaves the rest alone" do
      assert F.except(%{a: 1, b: 2, c: 3}, a: 9, c: 7) == %{a: 9, b: 2, c: 7}
    end

    test "applies updates left to right" do
      assert F.except(%{a: 1}, a: 2, a: 3) == %{a: 3}
    end

    test "with no updates is the identity" do
      assert F.except(%{a: 1}, []) == %{a: 1}
    end

    # [f EXCEPT ![a] = v] with a outside DOMAIN f is undefined in TLA+. Extending
    # the domain instead would produce a state no reachable behavior can produce,
    # and it would be fingerprinted as if it were one.
    test "raises rather than extending the domain" do
      assert_raise KeyError, fn -> F.except(%{a: 1}, b: 2) end
    end
  end

  describe "except_with/3" do
    test "updates using the old value" do
      assert F.except_with(%{count: 1}, :count, &(&1 + 1)) == %{count: 2}
    end

    test "raises rather than extending the domain" do
      assert_raise KeyError, fn -> F.except_with(%{a: 1}, :b, &(&1 + 1)) end
    end
  end

  describe "record_set/1" do
    test "has the product of the field set sizes" do
      records = F.record_set(pc: MapSet.new([:idle, :busy]), n: MapSet.new([0, 1, 2]))

      assert MapSet.size(records) == 6
      assert Enum.all?(records, &(Map.keys(&1) == [:n, :pc]))
    end

    test "is empty if any field set is empty" do
      assert F.record_set(a: MapSet.new([1]), b: MapSet.new()) == MapSet.new()
    end

    test "with no fields is the set containing the empty record" do
      assert F.record_set([]) == MapSet.new([%{}])
    end
  end
end
