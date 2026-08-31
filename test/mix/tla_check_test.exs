defmodule Mix.Tasks.Tla.CheckTest do
  @moduledoc """
  The Phase 1 deliverable: `mix tla.check MySpec` verifies safety, reports what it
  actually exercised, and says which of those two happened in its exit code.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Tla.Check

  setup do
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Application.delete_env(:extla, TLA.TestSpecs.Terminating) end)
    :ok
  end

  # The task signals its verdict by exiting, which is the thing under test, so the
  # helper has to run it for real and catch that rather than call an inner
  # function that returns a status.
  defp check(args) do
    parent = self()

    output =
      capture_io(fn ->
        code =
          try do
            Check.run(args)
            0
          catch
            :exit, {:shutdown, code} -> code
          end

        send(parent, {:exit_code, code})
      end)

    receive do
      {:exit_code, code} -> {output, code}
    after
      0 -> flunk("the task neither exited nor returned")
    end
  end

  describe "verdicts and exit codes" do
    test "a verified spec exits 0 and says so" do
      {output, code} = check(["TLA.TestSpecs.WithDefaults"])

      assert code == 0
      assert output =~ "TLA.TestSpecs.WithDefaults — verified"
      assert output =~ "4 distinct states"
    end

    test "a violation exits 1 and prints the counterexample" do
      {output, code} = check(["TLA.TestSpecs.Broken"])

      assert code == 1
      assert output =~ "VIOLATION: below_three"
      assert output =~ "State 4 [VIOLATION]"
    end

    # A spec that declares a `temporal` is asking for it to be checked, so the task
    # checks it — and prints a lasso rather than a trace when one is refuted.
    test "a refuted temporal property exits 1 and prints the lasso" do
      {output, code} = check(["TLA.TestSpecs.IdlingUnfair"])

      assert code == 1
      assert output =~ "LIVENESS: eventually_two"
      assert output =~ "↺ back to state 1"
    end

    test "--safety-only leaves the temporal properties unchecked, and says so" do
      {output, code} = check(["TLA.TestSpecs.IdlingUnfair", "--safety-only"])

      assert code == 0
      assert output =~ "verified"
      assert output =~ "declared and not checked"
    end

    test "--verify-symmetry catches a declaration the spec does not deserve" do
      Application.put_env(:extla, TLA.TestSpecs.Asymmetric,
        constants: %{processes: MapSet.new([:p1, :p2])},
        symmetry: [:processes]
      )

      on_exit(fn -> Application.delete_env(:extla, TLA.TestSpecs.Asymmetric) end)

      {output, code} = check(["TLA.TestSpecs.Asymmetric", "--verify-symmetry"])

      assert code == 1
      assert output =~ "UNSOUND SYMMETRY"
      assert output =~ "is not sound for this spec"
      assert output =~ "D-17"
    end

    test "a symmetry declaration without --verify-symmetry is taken at its word" do
      Application.put_env(:extla, TLA.TestSpecs.Asymmetric,
        constants: %{processes: MapSet.new([:p1, :p2])},
        symmetry: [:processes]
      )

      on_exit(fn -> Application.delete_env(:extla, TLA.TestSpecs.Asymmetric) end)

      {output, code} = check(["TLA.TestSpecs.Asymmetric"])

      assert code == 0
      assert output =~ "verified"
      assert output =~ "2 distinct states"
    end

    test "a deadlock is reported as one" do
      Application.put_env(:extla, TLA.TestSpecs.Deadlocking, constants: %{max: 2})
      on_exit(fn -> Application.delete_env(:extla, TLA.TestSpecs.Deadlocking) end)

      {output, code} = check(["TLA.TestSpecs.Deadlocking"])

      assert code == 1
      assert output =~ "DEADLOCK"
    end

    # "We ran out of budget" is not "it holds", and a tool that returns them as
    # the same number teaches its users to believe something false.
    test "a bounded run exits 2, not 0" do
      {output, code} = check(["TLA.TestSpecs.Unbounded", "--max-states", "20"])

      assert code == 2
      assert output =~ "INCOMPLETE (state limit)"
    end

    test "--allow-incomplete accepts a bounded run deliberately" do
      {_output, code} =
        check(["TLA.TestSpecs.Unbounded", "--max-states", "20", "--allow-incomplete"])

      assert code == 0
    end

    test "--strict-coverage exits 3 on a never-enabled action" do
      {output, code} = check(["TLA.TestSpecs.WithDefaults", "--strict-coverage"])

      assert code == 3
      assert output =~ "NEVER ENABLED"
    end

    test "the same spec without --strict-coverage exits 0, with a warning" do
      {output, code} = check(["TLA.TestSpecs.WithDefaults"])

      assert code == 0
      assert output =~ "1 warning."
    end
  end

  describe "constants" do
    test "come from `default:` beside the declaration" do
      {output, 0} = check(["TLA.TestSpecs.WithDefaults"])

      assert output =~ "4 distinct states"
    end

    test "can be supplied by application config" do
      Application.put_env(:extla, TLA.TestSpecs.Terminating, constants: %{max: 4})

      {output, 0} = check(["TLA.TestSpecs.Terminating"])

      assert output =~ "5 distinct states"
    end

    test "application config wins over a default" do
      Application.put_env(:extla, TLA.TestSpecs.WithDefaults, constants: %{max: 5})
      on_exit(fn -> Application.delete_env(:extla, TLA.TestSpecs.WithDefaults) end)

      {output, _} = check(["TLA.TestSpecs.WithDefaults"])

      assert output =~ "6 distinct states"
    end

    # A checker cannot start without them, so the error names both places one
    # could come from rather than saying "missing".
    test "a constant with neither is an error naming both ways to supply it" do
      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn -> Check.run(["TLA.TestSpecs.Terminating"]) end)
        end

      assert error.message =~ "has no assignment for :max"
      assert error.message =~ "constant :max, default:"
      assert error.message =~ "config :extla, TLA.TestSpecs.Terminating"
    end
  end

  describe "output" do
    test "always prints the coverage report" do
      {output, 0} = check(["TLA.TestSpecs.WithDefaults"])

      assert output =~ "COVERAGE: TLA.TestSpecs.WithDefaults"
      assert output =~ "Actions"
      assert output =~ "Invariants"
    end

    test "--format json carries the result, the coverage and the counterexample" do
      {output, 1} = check(["TLA.TestSpecs.Broken", "--format", "json"])

      entry = output |> Jason.decode!() |> Map.fetch!("TLA.TestSpecs.Broken")

      assert entry["status"] == "violation"
      assert entry["violation"]["property"] == "below_three"
      assert entry["violation"]["length"] == 4
      assert entry["coverage"]["bounded_by"] == "violation"
      assert is_number(entry["collision_estimate"])
    end

    test "an unknown format is refused" do
      assert_raise Mix.Error, ~r/unknown --format/, fn ->
        capture_io(fn -> Check.run(["TLA.TestSpecs.WithDefaults", "--format", "yaml"]) end)
      end
    end
  end

  describe "module resolution" do
    test "a module that is not a spec is refused by name" do
      assert_raise Mix.Error, ~r/is not a TLA spec/, fn ->
        capture_io(fn -> Check.run(["Enum"]) end)
      end
    end
  end
end
