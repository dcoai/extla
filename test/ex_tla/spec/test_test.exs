defmodule ExTLA.Spec.TestTest do
  @moduledoc """
  `assert_spec` exists to make one thing impossible: a green suite over a spec
  that was never verified.
  """
  use ExUnit.Case, async: true

  @moduletag verifies:
               "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Mix Integration/ExUnit Integration"

  import ExTLA.Spec.Test

  test "passes and returns the result for a verified spec" do
    result = assert_spec(ExTLA.TestSpecs.Terminating, %{constants: %{max: 3}})

    assert result.status == :ok
    assert result.distinct_states == 4
  end

  # spec/04 §The CLI infers `check_liveness`; the API does not: "`assert_spec/2` passes its
  # config straight through, so a property that `mix extla.check` checks is not checked by
  # the same spec under `assert_spec` unless the config says so" (#358). IdlingUnfair's
  # temporal property is refuted whenever it is checked (the task exits 1 on it).
  @tag verifies: [
         "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Mix Integration/ExUnit Integration",
         "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API/The CLI infers `check_liveness`; the API does not"
       ]
  test "passes a refutable temporal property it was not asked to check, and the result says so" do
    unchecked = assert_spec(ExTLA.TestSpecs.IdlingUnfair, %{})

    assert unchecked.status == :ok
    assert Enum.any?(unchecked.warnings, &(&1 =~ "declared and not checked"))

    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_spec(ExTLA.TestSpecs.IdlingUnfair, %{check_liveness: true})
      end

    assert error.message =~ "eventually_two"
  end

  test "flunks on a violation, printing the counterexample" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_spec(ExTLA.TestSpecs.Broken, %{})
      end

    assert error.message =~ "Model checking violation in ExTLA.TestSpecs.Broken"
    assert error.message =~ "VIOLATION: below_three"
  end

  # An earlier draft warned here and let the test proceed, which is how a suite
  # goes green on a spec that was never verified -- the single most misleading
  # thing this library could do.
  test "flunks on a bounded run rather than warning" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_spec(ExTLA.TestSpecs.Unbounded, %{max_states: 10})
      end

    assert error.message =~ "did NOT complete"
    assert error.message =~ "UNVERIFIED, not verified"
    assert error.message =~ "allow_incomplete: true"
  end

  test "allow_incomplete: true accepts a bounded run deliberately" do
    result = assert_spec(ExTLA.TestSpecs.Unbounded, %{max_states: 10, allow_incomplete: true})

    assert result.status == :max_states_reached
  end

  test "a state constraint is a bounded run too" do
    assert_raise ExUnit.AssertionError, ~r/did NOT complete/, fn ->
      assert_spec(ExTLA.TestSpecs.Unbounded, %{state_constraint: fn s -> s.n <= 3 end})
    end
  end

  test "strict_coverage: true fails on a never-enabled action" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_spec(ExTLA.TestSpecs.WithDefaults, %{
          constants: %{max: 3},
          strict_coverage: true
        })
      end

    assert error.message =~ "Coverage failure"
    assert error.message =~ "action :impossible was never enabled"
  end

  test "the same spec passes without strict_coverage" do
    result = assert_spec(ExTLA.TestSpecs.WithDefaults, %{constants: %{max: 3}})

    assert result.status == :ok
  end
end
