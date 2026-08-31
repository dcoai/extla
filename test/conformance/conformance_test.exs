defmodule TLA.ConformanceTest do
  use ExUnit.Case, async: true

  alias TLA.Conformance.Counter.{Mutants, Refinement, Spec}
  alias TLA.Refinement, as: R

  @constants %{max_val: 5}

  describe "the mapping that conforms" do
    test "is accepted, and says which rules it could not decide" do
      assert {:ok, deferred} = R.validate!(Refinement, Spec, @constants)

      # Not a shortfall to be embarrassed about: there is no concrete state at compile
      # time to map, so these are checked on every mapping instead. Saying so is the
      # difference between a validator with limits and one that overstates itself.
      assert length(deferred) == 2
      assert Enum.any?(deferred, &(&1 =~ "abstract/1"))
      assert Enum.any?(deferred, &(&1 =~ "permitted state term"))
    end

    test "maps a concrete state onto exactly the spec's variables" do
      concrete = %{value: 2, status: :ready, max: 5}

      assert R.abstract!(Refinement, compiled(), concrete) == %{count: 2, status: :ready}
    end

    test "resolves the spec's constants the way mix tla.check does when given none" do
      assert {:ok, _deferred} = R.validate!(Refinement, Spec)
    end
  end

  # The corpus's oracle. Every one of these must fail, and fail for the stated reason: a
  # validator that accepts a broken mapping is worse than no validator, because the
  # conformance report that follows carries its authority.
  describe "the mutants" do
    test "a mapping that forgets a variable is named, with the variable" do
      error =
        assert_raise R.Error, fn ->
          R.abstract!(Mutants.MissingVariable, compiled(), %{value: 1, status: :ready})
        end

      assert Exception.message(error) =~ "missing: [:status]"
      assert Exception.message(error) =~ "every predicate reading it fails"
    end

    test "a mapping that invents a variable is named, with the variable" do
      error =
        assert_raise R.Error, fn ->
          R.abstract!(Mutants.ExtraVariable, compiled(), %{value: 1, status: :ready})
        end

      assert Exception.message(error) =~ "extra:   [:max]"
      assert Exception.message(error) =~ "every step diverges"
    end

    test "a mapping with no catch-all is reported as not total, rather than crashing" do
      error = assert_raise R.Error, fn -> R.validate!(Mutants.NotTotal, Spec, @constants) end

      assert Exception.message(error) =~ "is not total"
      assert Exception.message(error) =~ "def abstract_action(_), do: :unmapped"
    end

    test "a mapping whose two directions disagree is caught by the round trip" do
      error =
        assert_raise R.Error, fn -> R.validate!(Mutants.WrongWayRound, Spec, @constants) end

      assert Exception.message(error) =~ "does not round-trip increment"
      assert Exception.message(error) =~ ":done"
    end

    test "an action no message can produce is named as dead in this implementation" do
      error =
        assert_raise R.Error, fn -> R.validate!(Mutants.ActionNeverNamed, Spec, @constants) end

      assert Exception.message(error) =~ "names no message for [:reset]"
      assert Exception.message(error) =~ "dead in this implementation"
    end

    test "a module that is not a refinement mapping at all is refused" do
      error =
        assert_raise R.Error, fn -> R.validate!(Mutants.NoAbstractAction, Spec, @constants) end

      assert Exception.message(error) =~ "does not define abstract_action/1"
      assert Exception.message(error) =~ "invariant checking on a projection"
    end
  end

  describe "the spec side of the entry" do
    # The corpus is only worth having if the specification half is right, so the entry
    # carries the same assertion `mix tla.check` would make about it.
    test "the specification itself verifies, liveness included" do
      result =
        TLA.ModelChecker.run(Spec, %{constants: @constants, check_liveness: true})

      assert result.status == :ok
      assert result.distinct_states == 11
    end
  end

  defp compiled, do: TLA.Spec.Compiled.from_module(Spec)
end
