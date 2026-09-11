defmodule TLA.StateTest do
  use ExUnit.Case, async: true

  doctest TLA.State

  alias TLA.State

  describe "new/1" do
    test "builds a state from a keyword list or a map" do
      assert State.new(x: 0, y: 1) == %{x: 0, y: 1}
      assert State.new(%{x: 0, y: 1}) == %{x: 0, y: 1}
    end
  end

  describe "get/2" do
    test "returns the variable's value" do
      assert State.get(%{x: 42}, :x) == 42
    end

    # The reason this raises rather than returning nil: a misspelled variable read
    # as nil compares unequal to whatever a guard expected, the action looks
    # disabled, and the checker explores less of the state space while reporting
    # success. Nothing in the output would distinguish that run from a sound one.
    test "raises on a variable the state does not have" do
      assert_raise KeyError, fn -> State.get(%{x: 42}, :y) end
    end
  end

  describe "prime/3" do
    test "updates one variable and leaves the rest alone" do
      assert State.prime(%{x: 0, y: 1}, :x, 2) == %{x: 2, y: 1}
    end

    test "raises rather than adding a variable the state does not have" do
      assert_raise KeyError, fn -> State.prime(%{x: 0}, :z, 1) end
    end
  end

  describe "prime_many/2" do
    test "applies every assignment" do
      assert State.prime_many(%{x: 0, y: 1, z: 2}, %{x: 9, z: 8}) == %{x: 9, y: 1, z: 8}
    end

    test "raises if any assignment names an unknown variable" do
      assert_raise KeyError, fn -> State.prime_many(%{x: 0}, %{x: 1, nope: 2}) end
    end
  end

  describe "stuttering?/1" do
    test "is true exactly when the states are equal" do
      assert State.stuttering?({%{x: 0, y: 1}, %{x: 0, y: 1}})
      refute State.stuttering?({%{x: 0, y: 1}, %{x: 1, y: 1}})
    end
  end

  describe "changed_vars/1" do
    test "returns only the variables whose values differ" do
      assert State.changed_vars({%{x: 0, y: 1}, %{x: 2, y: 1}}) == MapSet.new([:x])
    end

    test "is empty for a stuttering step" do
      assert State.changed_vars({%{x: 0}, %{x: 0}}) == MapSet.new([])
    end

    test "reports a variable present on only one side" do
      assert State.changed_vars({%{x: 0}, %{x: 0, y: 1}}) == MapSet.new([:y])
    end
  end

  describe "unchanged?/2" do
    test "checks the named variables only" do
      step = {%{x: 0, y: 1}, %{x: 2, y: 1}}
      assert State.unchanged?(step, [:y])
      refute State.unchanged?(step, [:x, :y])
      assert State.unchanged?(step, [])
    end

    test "raises on a variable neither state has" do
      assert_raise KeyError, fn -> State.unchanged?({%{x: 0}, %{x: 0}}, [:q]) end
    end
  end

  describe "validate!/1" do
    test "accepts every permitted term shape" do
      state = %{
        atoms: :ok,
        ints: -3,
        bins: "hello",
        tuples: {1, :a, "b"},
        lists: [1, [2, [3]]],
        maps: %{{:k, 1} => [:v]},
        sets: MapSet.new([1, 2, 3]),
        structs: %Range{first: 1, last: 3, step: 1}
      }

      assert State.validate!(state) == state
    end

    test "accepts the empty state" do
      assert State.validate!(%{}) == %{}
    end

    for {kind, term} <- [
          {"a pid", quote(do: self())},
          {"a reference", quote(do: make_ref())},
          {"a fun", quote(do: fn -> :x end)},
          {"a float", quote(do: 1.5)},
          # #198: `TLA.State.Json` has no encoding for a bitstring that is not whole bytes, so
          # admitting it here meant a violation found by the search was lost to the report.
          {"a bitstring", quote(do: <<1::3>>)}
        ] do
      test "rejects #{kind} held directly by a variable" do
        assert_raise TLA.State.InvalidTermError,
                     ~r/spec variable :bad holds #{unquote(kind)}/,
                     fn ->
                       State.validate!(%{bad: unquote(term)})
                     end
      end
    end

    test "names the position inside a nested term" do
      error =
        assert_raise TLA.State.InvalidTermError, fn ->
          State.validate!(%{queue: [:a, {1, self()}]})
        end

      assert Exception.message(error) =~ "spec variable :queue"
      assert Exception.message(error) =~ "element 1 -> tuple element 1"
      assert Exception.message(error) =~ "02-dsl-semantics.md §6"
    end

    test "looks inside map keys, map values, MapSets and structs" do
      for value <- [
            %{self() => :v},
            %{k: self()},
            MapSet.new([self()]),
            %Range{first: 1, last: 3, step: 1} |> Map.put(:step, self())
          ] do
        assert_raise TLA.State.InvalidTermError, fn -> State.validate!(%{v: value}) end
      end
    end

    test "the message says what is permitted, not just what was wrong" do
      error = assert_raise TLA.State.InvalidTermError, fn -> State.validate!(%{f: 0.0}) end

      message = Exception.message(error)
      assert message =~ "Permitted: atoms, integers, binaries, tuples, lists, maps, MapSets"
      assert message =~ "explored twice"
    end
  end
end
