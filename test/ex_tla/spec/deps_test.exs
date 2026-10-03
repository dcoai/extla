defmodule ExTLA.Spec.DepsTest do
  @moduledoc """
  The dependency analysis behind property-directed slicing (#87, #91).

  The tests are ordered the way the module is built: **widening first**. A read set is `:all`
  unless every node is recognised, and the tests that prove the widening are the ones that make
  the narrowing safe. An analysis tested only on the cases it handles is an analysis that will
  narrow on the case nobody thought of.
  """
  use ExUnit.Case, async: true

  alias ExTLA.Spec.Deps

  @declared [:count, :status, :buffer]

  defp reads(quoted), do: Deps.expression(quoted, @declared)

  describe "widening — the default, and the soundness argument" do
    test "an unrecognised local call widens to every variable" do
      # It could be a macro, and a macro expands AFTER this walk — so a variable reference it
      # introduces is invisible here. Nothing else in this module is allowed to assume otherwise.
      assert reads(quote(do: mystery_helper(1))) == :all
    end

    test "widening propagates out of a nested position" do
      assert reads(quote(do: count + mystery_helper(2))) == :all
    end

    test "widening survives a subsequent narrow term rather than being overwritten" do
      assert reads(quote(do: mystery_helper(1) and count > 0)) == :all
    end

    test "an unknown call inside a container widens" do
      assert reads(quote(do: {count, mystery_helper(1)})) == :all
    end
  end

  describe "variable references" do
    test "a bare declared name is a read" do
      assert reads(quote(do: count)) == MapSet.new([:count])
    end

    test "an undeclared name is not a variable" do
      assert reads(quote(do: whatever)) == MapSet.new([])
    end

    test "several variables accumulate" do
      assert reads(quote(do: count > 0 and status == :ready)) ==
               MapSet.new([:count, :status])
    end
  end

  describe "what is not state" do
    test "a pinned constant contributes nothing" do
      # A constant cannot make two states differ, so it can never be in a cone of influence.
      assert reads(quote(do: ^max_val)) == MapSet.new([])
    end

    test "a comparison against a constant reads only the variable" do
      assert reads(quote(do: count < ^max_val)) == MapSet.new([:count])
    end

    test "literals depend on nothing" do
      assert reads(quote(do: 42)) == MapSet.new([])
      assert reads(quote(do: :ready)) == MapSet.new([])
      assert reads(quote(do: "text")) == MapSet.new([])
    end
  end

  describe "remote calls are walked, not widened" do
    test "arguments of a remote call are read" do
      # A remote call cannot hide a read: its arguments are already in this AST, and a function
      # cannot reach a spec variable that was not passed to it.
      assert reads(quote(do: MapSet.member?(buffer, count))) ==
               MapSet.new([:buffer, :count])
    end

    test "a remote call with no variables reads nothing" do
      assert reads(quote(do: MapSet.new([1, 2]))) == MapSet.new([])
    end
  end

  describe "operators and containers" do
    test "arithmetic and comparison are walked" do
      assert reads(quote(do: count + 1 > 3)) == MapSet.new([:count])
    end

    test "a list is walked" do
      assert reads(quote(do: [count, status])) == MapSet.new([:count, :status])
    end

    test "a tuple is walked" do
      assert reads(quote(do: {count, status})) == MapSet.new([:count, :status])
    end

    test "an if is walked through all branches" do
      assert reads(quote(do: if(count > 0, do: status, else: buffer))) ==
               MapSet.new([:count, :status, :buffer])
    end
  end

  describe "block/3 over classified statements" do
    test "assignments are writes and their right-hand sides are reads" do
      classified = [{:assign, :count, quote(do: count + 1), []}]

      assert Deps.block(classified, @declared) ==
               %{reads: MapSet.new([:count]), writes: MapSet.new([:count])}
    end

    test "a guard contributes reads and no writes" do
      classified = [{:guard, quote(do: status == :ready), []}]

      assert Deps.block(classified, @declared) ==
               %{reads: MapSet.new([:status]), writes: MapSet.new([])}
    end

    test "a write without a corresponding read is recorded as such" do
      # `count = 0` depends on nothing: the cone must not pick up `count` merely because it is
      # assigned, or every action would appear to read what it writes.
      classified = [{:assign, :count, quote(do: 0), []}]

      assert Deps.block(classified, @declared) ==
               %{reads: MapSet.new([]), writes: MapSet.new([:count])}
    end

    test "a let binds a local name that then shadows a declared variable" do
      classified = [
        {:let, quote(do: count), quote(do: buffer), []},
        {:assign, :status, quote(do: count), []}
      ]

      # `buffer` is read by the let's right-hand side; the later `count` is the LOCAL binding,
      # not the state variable, so it is not a read.
      assert Deps.block(classified, @declared) ==
               %{reads: MapSet.new([:buffer]), writes: MapSet.new([:status])}
    end

    test "widening anywhere in a body widens the whole body" do
      classified = [
        {:guard, quote(do: count > 0), []},
        {:assign, :status, quote(do: mystery_helper(1)), []}
      ]

      assert %{reads: :all, writes: writes} = Deps.block(classified, @declared)
      assert writes == MapSet.new([:status])
    end
  end
end
