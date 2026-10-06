defmodule ExTLA.InvariantHelpersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  use ExTLA.Invariant.Test

  alias ExTLA.TestServers.{Account, CounterRules, TrafficLight}

  @good %{count: 1, ceiling: 10}
  @doubly_bad %{count: -1, ceiling: 0}

  describe "assert_invariants/2" do
    test "passes on a state every invariant admits" do
      assert_invariants(CounterRules, @good)
    end

    # A state that breaks three invariants is three facts about the state. Reporting the
    # first hides the other two behind another run.
    test "names every invariant that failed, with its description" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_invariants(CounterRules, @doubly_bad)
        end

      assert error.message =~ "2 invariants of ExTLA.TestServers.CounterRules failed"
      assert error.message =~ ":never_negative: a counter may not go below zero"
      assert error.message =~ ":ceiling_positive: a counter counts towards something"
      assert error.message =~ "count: -1"
    end

    test "a module carrying no predicates says so rather than failing as though false" do
      error = assert_raise ArgumentError, fn -> assert_invariants(URI, @good) end

      assert error.message =~ "carries no Layer 1 predicates"
      assert error.message =~ "mode: :disabled"
    end

    # A DIFFERENT emptiness from the one above, and the one that passed (#175). `URI` is not
    # instrumented at all, which was already refused. This module is instrumented and has had
    # every invariant compiled out by `enabled: false` — so `__tla_names__(:invariant)` is
    # `[]`, the comprehension over it is `[]`, and the assertion said `:ok` for every state,
    # including the ones the invariant existed to reject.
    #
    # `refute_invariant/3` has always guarded its equivalent through `__ensure_declared__/2`.
    # The sibling did not, and the asymmetry is the finding.
    test "and a module whose invariants were all compiled out cannot be asserted about" do
      defmodule AllCompiledOut do
        use ExTLA.Invariant

        invariant :never_negative, enabled: false do
          state.count >= 0
        end
      end

      error =
        assert_raise ArgumentError, fn ->
          assert_invariants(AllCompiledOut, %{count: -999})
        end

      assert error.message =~ "declares no invariant that is compiled in"
      assert error.message =~ "would pass for every state"
      assert error.message =~ "enabled:"
    end
  end

  describe "assert_action_properties/3" do
    # The same hole, in the sibling assertion. #175 named `assert_invariants/2`; fixing only
    # the site it was found at is how a mechanism goes on running one door over, which is
    # what #192 was about.
    test "a module whose action properties were all compiled out cannot be asserted about" do
      defmodule NoPropertiesLeft do
        use ExTLA.Invariant

        action_property :never_falls, enabled: false do
          new.count >= old.count
        end
      end

      error =
        assert_raise ArgumentError, fn ->
          assert_action_properties(NoPropertiesLeft, %{count: 5}, %{count: 1})
        end

      assert error.message =~ "declares no action_property that is compiled in"
    end

    test "passes on a transition every property admits" do
      assert_action_properties(CounterRules, @good, %{count: 2, ceiling: 10})
    end

    test "names the property, and shows both states" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_action_properties(CounterRules, @good, %{count: 1, ceiling: 9})
        end

      assert error.message =~ "1 action property of ExTLA.TestServers.CounterRules failed"
      assert error.message =~ ":ceiling_never_falls: the ceiling only ever rises"
      assert error.message =~ "old:"
      assert error.message =~ "new:"
    end
  end

  describe "refute_invariant/3" do
    # The negative case is the only evidence an invariant is not vacuously `true`, and it
    # cannot be obtained from the passing side.
    test "passes when the state violates the named invariant" do
      refute_invariant(CounterRules, :never_negative, %{count: -1, ceiling: 1})
    end

    test "fails when it holds, and says why that matters" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          refute_invariant(CounterRules, :never_negative, @good)
        end

      assert error.message =~ "to be VIOLATED"
      assert error.message =~ "indistinguishable from `true`"
    end

    # A renamed declaration would otherwise turn this test green by checking nothing.
    test "fails loudly when the module declares no such invariant" do
      error =
        assert_raise ArgumentError, fn ->
          refute_invariant(CounterRules, :nonexistent, @good)
        end

      assert error.message =~ "declares no invariant named :nonexistent"
      assert error.message =~ ":never_negative"
    end
  end

  describe "valid_states/3" do
    property "keeps exactly the states the named invariant admits" do
      generator =
        ExTLA.Invariant.Test.valid_states(
          CounterRules,
          :never_negative,
          StreamData.map(StreamData.integer(-20..20), &%{count: &1, ceiling: 10})
        )

      check all(state <- generator) do
        assert state.count >= 0
        assert_invariants(CounterRules, state)
      end
    end

    # The docstring's two examples (#344): a base generator with the type's shape is
    # accepted about half the time and passes; one of the wrong shape is rejected nearly
    # always and raises. Fixed seeds, so neither depends on the draw.
    test "the documented good base generator passes and the bad one raises" do
      colour_data = StreamData.map(StreamData.integer(), &%{cycles: &1})
      good = StreamData.tuple({StreamData.member_of([:red, :yellow, :green]), colour_data})
      bad = StreamData.tuple({StreamData.atom(:alphanumeric), colour_data})
      options = [initial_seed: {0, 0, 344}, max_runs: 100]

      assert {:ok, _} =
               StreamData.check_all(valid_traffic_light_states(good), options, &{:ok, &1})

      assert_raise StreamData.FilterTooNarrowError, fn ->
        StreamData.check_all(valid_traffic_light_states(bad), options, &{:ok, &1})
      end
    end

    # The number the docs promise is the one `StreamData.filter/3` enforces. It is
    # stream_data's default, not ours, so an upgrade that changes it fails here
    # instead of leaving the docstring and spec/03 wrong.
    test "the rejection limit the docs state is the one StreamData enforces" do
      never = StreamData.tuple({StreamData.constant(:blue), StreamData.constant(%{cycles: 0})})

      error =
        assert_raise StreamData.FilterTooNarrowError, fn ->
          Enum.take(valid_traffic_light_states(never), 1)
        end

      limit = error.max_consecutive_failures
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(ExTLA.Invariant.Test)

      [doc] =
        for {{:function, :valid_states, 3}, _, _, %{"en" => doc}, _} <- docs, do: doc

      spec = File.read!(Path.expand("../../spec/03-layer1-invariants.md", __DIR__))

      assert doc =~ "#{limit} rejections in a row raise"

      assert spec =~ "#{limit} rejections in a row raise"
    end

    test "refuses a name the module does not declare" do
      assert_raise ArgumentError, fn ->
        ExTLA.Invariant.Test.valid_states(CounterRules, :nonexistent, StreamData.constant(@good))
      end
    end
  end

  describe "the helpers work on a GenServer's declarations without a running process" do
    # Which is the point: a state a server can only reach through a sequence of calls is
    # an ordinary value here.
    test "an unreachable state can still be asserted about" do
      assert_invariants(Account, %{balance: 0, deposits: 0, movements: 2, log: [:a, :b]})
      refute_invariant(Account, :audited, %{balance: 0, deposits: 0, movements: 9, log: []})
    end
  end

  defp valid_traffic_light_states(base),
    do: ExTLA.Invariant.Test.valid_states(TrafficLight, :valid_state, base)
end
