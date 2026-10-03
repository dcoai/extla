defmodule ExTLA.PropertyTestTest do
  @moduledoc """
  `ExTLA.PropertyTest.init_states/2` — the piece of Layer 3 that ExTLA hands to a consumer's
  own `check all` rather than driving itself (`05-layer3-conformance.md`).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExTLA.{ModelChecker, PropertyTest, TestSpecs}

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
        id = ExTLA.StateGraph.id_of(graph, state)

        assert id != nil, "the checker never registered #{inspect(state)}"
        assert MapSet.member?(graph.initial_states, id)
        assert ExTLA.StateGraph.node_record(graph, id).depth == 1
      end
    end

    property "every generated state satisfies the spec's declared types" do
      constants = %{accounts: MapSet.new([:alice, :bob]), max_balance: 2}
      spec = ExTLA.Spec.Compiled.from_module(TestSpecs.Transfer)
      type_ok = ExTLA.Spec.Type.invariant(spec, constants)

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

  describe "action_sequences/3" do
    @constants %{max: 2}

    property "every generated sequence is a behaviour the spec admits" do
      spec = ExTLA.Spec.Compiled.from_module(TestSpecs.Counter)
      initial = PropertyTest.initial_states(spec, @constants)

      check all(sequence <- PropertyTest.action_sequences(TestSpecs.Counter, @constants, 8)) do
        # Replayed against the checker's own notion of what is enabled, not against a
        # second reading of the spec: the generator's whole claim is that it agrees with
        # the checker, so checking it against itself would establish nothing.
        Enum.reduce(sequence, hd(initial), fn {action, params}, state ->
          enabled = ModelChecker.enabled_steps(spec, @constants, state)

          assert {action, params} in enabled,
                 "#{action} with #{inspect(params)} is not enabled in #{inspect(state)}"

          ExTLA.Spec.Compiled.action(spec, action).transition.(@constants, state, params)
        end)
      end
    end

    property "and one the model checker walks, step for step" do
      spec = ExTLA.Spec.Compiled.from_module(TestSpecs.TwoStarts)

      {_result, graph} =
        ModelChecker.explore(TestSpecs.TwoStarts, %{check_deadlock: false, liveness_graph: true})

      check all(sequence <- PropertyTest.action_sequences(TestSpecs.TwoStarts, %{}, 4)) do
        # Every state the sequence passes through is a state the search registered, and
        # every step is an edge the search recorded. A sequence that left the graph would
        # be a behaviour the checker says does not exist.
        [initial] = Enum.take(PropertyTest.initial_states(spec, %{}), 1)

        Enum.reduce(sequence, initial, fn {action, params}, state ->
          id = ExTLA.StateGraph.id_of(graph, state)
          next = ExTLA.Spec.Compiled.action(spec, action).transition.(%{}, state, params)
          next_id = ExTLA.StateGraph.id_of(graph, next)

          assert id != nil and next_id != nil
          assert {action, params, next_id} in ExTLA.StateGraph.successors(graph, id)

          next
        end)
      end
    end

    property "no sequence is longer than max_length" do
      check all(
              max <- StreamData.integer(1..6),
              sequence <- PropertyTest.action_sequences(TestSpecs.Counter, @constants, max)
            ) do
        assert length(sequence) <= max
      end
    end

    # The soundness property. A generator that shrank into an invalid sequence would
    # report failures the implementation cannot produce — every prefix of a behaviour is a
    # behaviour, and this asserts the generator honours that rather than assuming it.
    test "shrinking yields sequences that are still replayable" do
      spec = ExTLA.Spec.Compiled.from_module(TestSpecs.Counter)
      generator = PropertyTest.action_sequences(TestSpecs.Counter, @constants, 6)

      for seed <- 1..25 do
        tree = generator.generator.(:rand.seed_s(:exsss, {seed, seed, seed}), 10)

        for candidate <- [tree.root | Enum.take(shrunk_values(tree), 8)] do
          assert replayable?(spec, @constants, candidate),
                 "shrinking produced a sequence the spec does not admit: #{inspect(candidate)}"
        end
      end
    end

    test "a spec that runs out of enabled actions stops there rather than hanging" do
      # `TwoStarts` allows exactly two `step`s and then has no enabled action at all.
      # Nothing can extend a sequence past that, and asking for 50 must neither produce
      # one nor loop looking for one.
      sequences =
        TestSpecs.TwoStarts
        |> PropertyTest.action_sequences(%{}, 50)
        |> Enum.take(30)

      assert Enum.all?(sequences, &(length(&1) <= 2)),
             "expected short sequences, got #{inspect(Enum.map(sequences, &length/1))}"
    end

    test "a length of zero is a behaviour too" do
      assert [] in Enum.take(PropertyTest.action_sequences(TestSpecs.Counter, @constants, 3), 40)
    end
  end

  # §05's own usage example, run rather than quoted. It is the shape the module exists to
  # support: the generator hands back spec-level steps, and the consumer's own body maps
  # them to messages with `concrete_message/2` and checks the abstraction after each.
  describe "the usage example from 05-layer3-conformance.md" do
    alias ExTLA.Conformance.Counter.Impl
    alias ExTLA.Conformance.Counter.Refinement
    alias ExTLA.Conformance.Counter.Spec, as: CounterSpec

    property "the server conforms under random action sequences" do
      constants = %{max_val: 5}
      compiled = ExTLA.Spec.Compiled.from_module(CounterSpec)

      check all(
              actions <- PropertyTest.action_sequences(CounterSpec, constants, 10),
              max_runs: 25
            ) do
        {:ok, pid} = Impl.Conforming.start_link()

        for {action, params} <- actions do
          GenServer.call(pid, Refinement.concrete_message(action, params))

          abstract = Refinement.abstract(:sys.get_state(pid))

          assert ExTLA.ModelChecker.Safety.check_invariants(
                   compiled,
                   constants,
                   abstract,
                   :all
                 ) == :ok
        end

        GenServer.stop(pid)
      end
    end
  end

  describe "what init_states/2 refuses" do
    defmodule OutsideItsType do
      @moduledoc false
      use ExTLA.Spec

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

  defp shrunk_values(tree), do: Stream.map(tree.children, & &1.root)

  defp replayable?(spec, constants, sequence) do
    [initial] = Enum.take(PropertyTest.initial_states(spec, constants), 1)

    Enum.reduce_while(sequence, {true, initial}, fn {action, params}, {_, state} ->
      if {action, params} in ModelChecker.enabled_steps(spec, constants, state) do
        next = ExTLA.Spec.Compiled.action(spec, action).transition.(constants, state, params)
        {:cont, {true, next}}
      else
        {:halt, {false, state}}
      end
    end)
    |> elem(0)
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
