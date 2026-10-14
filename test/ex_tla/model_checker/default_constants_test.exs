defmodule ExTLA.ModelChecker.DefaultConstantsTest do
  @moduledoc """
  The API honours a constant's `default:`, as the CLI does (#417, for #415).

  ## What was wrong

  `constant :max, default: 3` is how a spec carries its own assignment. `mix extla.check`,
  `mix extla.simulate`, Layer 3 and `ExTLA.Refinement` resolve it through
  `ExTLA.Spec.Compiled.resolve_constants/1`; `ExTLA.ModelChecker.run/2` took `constants:` as
  given, `%{}` by default, so the same spec checked from the command line and raised from the
  API — "the type of :n refers to ^max, which this run did not assign" — about a spec that
  declares exactly that assignment.

  ## The rule

  Declared defaults fill what `constants:` leaves out; an explicit constant wins. Application
  config stays the command line's to read, the way `check_liveness:` is inferred by the task
  and never by the API.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias ExTLA.ModelChecker
  alias ExTLA.TestSpecs.WithDefaults

  test "a spec that declares its constants' defaults checks with no constants: given" do
    result = ModelChecker.run(WithDefaults, %{})

    assert result.status == :ok
    # n from 0 to the default max of 3.
    assert result.distinct_states == 4
  end

  test "an explicit constant overrides its default" do
    result = ModelChecker.run(WithDefaults, %{constants: %{max: 5}})

    assert result.status == :ok
    assert result.distinct_states == 6
  end

  test "a constant with no default and none given is still refused, naming it" do
    message =
      assert_raise ArgumentError, fn -> ModelChecker.run(ExTLA.TestSpecs.Counter, %{}) end

    assert Exception.message(message) =~ "did not assign"
  end

  # The guard against the two drifting apart again: one spec, three ways of checking it, one
  # answer.
  test "run/2, assert_spec/2 and mix extla.check agree on a spec that relies on default:" do
    api = ModelChecker.run(WithDefaults, %{})

    require ExTLA.Spec.Test
    ExTLA.Spec.Test.assert_spec(WithDefaults, %{})

    # `--format json` prints with `IO.puts`, so it is captured here whichever `Mix.shell/0` an
    # async neighbour has installed.
    {_result, json} =
      with_io(fn ->
        Mix.Tasks.Extla.Check.run(["ExTLA.TestSpecs.WithDefaults", "--format", "json"])
      end)

    [cli] = json |> Jason.decode!() |> Map.fetch!("specs")

    assert cli["status"] == "ok"
    assert cli["distinct_states"] == api.distinct_states
  end
end
