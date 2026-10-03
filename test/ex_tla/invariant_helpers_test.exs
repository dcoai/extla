defmodule ExTLA.InvariantHelpersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  use ExTLA.Invariant.Test

  alias ExTLA.TestServers.{Account, CounterRules}

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
end
