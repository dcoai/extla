defmodule TLA.InvariantHelpersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  use TLA.Invariant.Test

  alias TLA.TestServers.{Account, CounterRules}

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

      assert error.message =~ "2 invariants of TLA.TestServers.CounterRules failed"
      assert error.message =~ ":never_negative: a counter may not go below zero"
      assert error.message =~ ":ceiling_positive: a counter counts towards something"
      assert error.message =~ "count: -1"
    end

    test "a module carrying no predicates says so rather than failing as though false" do
      error = assert_raise ArgumentError, fn -> assert_invariants(URI, @good) end

      assert error.message =~ "carries no Layer 1 predicates"
      assert error.message =~ "mode: :disabled"
    end
  end

  describe "assert_action_properties/3" do
    test "passes on a transition every property admits" do
      assert_action_properties(CounterRules, @good, %{count: 2, ceiling: 10})
    end

    test "names the property, and shows both states" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_action_properties(CounterRules, @good, %{count: 1, ceiling: 9})
        end

      assert error.message =~ "1 action property of TLA.TestServers.CounterRules failed"
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
        TLA.Invariant.Test.valid_states(
          CounterRules,
          :never_negative,
          StreamData.map(StreamData.integer(-20..20), &%{count: &1, ceiling: 10})
        )

      check all(state <- generator) do
        assert state.count >= 0
        assert_invariants(CounterRules, state)
      end
    end

    test "refuses a name the module does not declare" do
      assert_raise ArgumentError, fn ->
        TLA.Invariant.Test.valid_states(CounterRules, :nonexistent, StreamData.constant(@good))
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
end
