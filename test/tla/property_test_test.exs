defmodule TLA.PropertyTestTest do
  @moduledoc """
  `TLA.PropertyTest.init_states/2` — the piece of Layer 3 that ExTLA hands to a consumer's
  own `check all` rather than driving itself (`05-layer3-conformance.md`).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TLA.{ModelChecker, PropertyTest, TestSpecs}

  describe "init_states/2" do
    property "every generated state is one the checker would start from" do
      constants = %{max: 3}
      expected = MapSet.new(PropertyTest.initial_states(TestSpecs.Counter, constants))

      check all(state <- PropertyTest.init_states(TestSpecs.Counter, constants)) do
        assert MapSet.member?(expected, state)
      end
    end

    # The generator's claim is about the SPEC, so the thing to check it against is the
    # checker's own answer rather than a second reading of the `init` blocks. `seed/1`
    # registers exactly these states at depth 1.
    property "and one the model checker registers at depth 1" do
      {_result, graph} =
        ModelChecker.explore(TestSpecs.TwoStarts, %{check_deadlock: false, liveness_graph: true})

      check all(state <- PropertyTest.init_states(TestSpecs.TwoStarts, %{})) do
        id = TLA.StateGraph.id_of(graph, state)

        assert id != nil, "the checker never registered #{inspect(state)}"
        assert MapSet.member?(graph.initial_states, id)
        assert TLA.StateGraph.node_record(graph, id).depth == 1
      end
    end

    property "every generated state satisfies the spec's declared types" do
      constants = %{accounts: MapSet.new([:alice, :bob]), max_balance: 2}
      spec = TLA.Spec.Compiled.from_module(TestSpecs.Transfer)
      type_ok = TLA.Spec.Type.invariant(spec, constants)

      check all(state <- PropertyTest.init_states(TestSpecs.Transfer, constants)) do
        assert type_ok == nil or type_ok.predicate.(constants, state)
      end
    end

    test "a spec with several init blocks generates from more than one of them" do
      generated =
        TestSpecs.TwoStarts
        |> PropertyTest.init_states(%{})
        |> Enum.take(200)
        |> MapSet.new()

      assert MapSet.size(generated) == 2
      assert MapSet.member?(generated, %{side: :left, steps: 0})
      assert MapSet.member?(generated, %{side: :right, steps: 0})
    end

    test "a spec with one init block generates that one" do
      assert TestSpecs.Counter
             |> PropertyTest.init_states(%{max: 3})
             |> Enum.take(20)
             |> Enum.uniq() == [%{n: 0, done: false}]
    end

    # A generator that shrank out of the spec's initial states would report failures the
    # implementation cannot produce. `member_of/1` shrinks toward the head of the list,
    # which is the first `init` block — the one most specs write as their base case.
    test "shrinking stays inside the initial states, and terminates at the first init" do
      generator = PropertyTest.init_states(TestSpecs.TwoStarts, %{})
      valid = MapSet.new(PropertyTest.initial_states(TestSpecs.TwoStarts, %{}))

      for seed <- 1..25 do
        tree = generator.generator.(:rand.seed_s(:exsss, {seed, seed, seed}), 10)
        shrunk = shrink_fully(tree)

        assert MapSet.member?(valid, shrunk),
               "shrinking left the spec's initial states: #{inspect(shrunk)}"
      end
    end
  end

  describe "what init_states/2 refuses" do
    defmodule OutsideItsType do
      @moduledoc false
      use TLA.Spec

      variable :n, type: 0..3

      init do
        n = 9
      end

      action :tick do
        require n < 3
        n = n + 1
      end
    end

    # `mix tla.check` refutes this spec at depth 1. A generator that filtered the state
    # away would leave a property passing over an empty set, which is the shape of a test
    # that looks green and checked nothing.
    test "a spec whose init is outside its declared types, naming the block and the variable" do
      error = assert_raise ArgumentError, fn -> PropertyTest.init_states(OutsideItsType, %{}) end

      message = Exception.message(error)
      assert message =~ "`init` block 0"
      assert message =~ "n = 9"
      assert message =~ "0..3"
      assert message =~ "refutes this spec at depth 1"
    end

    test "and the checker agrees about that spec" do
      result = ModelChecker.run(OutsideItsType, %{check_deadlock: false})

      assert result.status == :violation
      assert result.violation.property == :type_ok
      assert result.violation.length == 1
    end
  end

  # `StreamData.LazyTree`'s children are the shrunk alternatives; taking the first
  # repeatedly walks to a leaf, which is where shrinking would stop.
  defp shrink_fully(tree) do
    case Enum.take(tree.children, 1) do
      [] -> tree.root
      [child] -> shrink_fully(child)
    end
  end
end
