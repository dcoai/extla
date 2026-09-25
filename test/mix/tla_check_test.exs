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

    # #170. The first fix for the bounded comparison appended "could not be verified" to
    # `warnings` and left `status: :ok` — so this printed `— verified` and exited 0, with the
    # refusal as a trailing line. A CI consumer reading the exit code saw a verified run. The
    # test that pinned the API behaviour asserted only the warning text, so nothing here saw
    # the exit code; this does.
    test "--verify-symmetry that could not verify does not exit 0 or say verified" do
      Application.put_env(:extla, TLA.TestSpecs.PerBinding,
        constants: %{processes: MapSet.new([:p1, :p2])},
        symmetry: [:processes]
      )

      on_exit(fn -> Application.delete_env(:extla, TLA.TestSpecs.PerBinding) end)

      # `PerBinding` reduces 8 states to 5, so 6 truncates only the unreduced run.
      {output, code} =
        check(["TLA.TestSpecs.PerBinding", "--verify-symmetry", "--max-states", "6"])

      assert code == 2, "an inconclusive verification is a bounded run, exit 2; got #{code}"
      refute output =~ "— verified"
      assert output =~ "could not be verified"
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

    # #208. The budget skip was the one unnamed liveness skip, and this flag is where it bit:
    # exit 0, and a temporal property nobody checked went unmentioned. `Idling` declares two
    # and is stopped at two states here.
    test "--allow-incomplete still says which temporal properties were not checked" do
      {output, code} =
        check(["TLA.TestSpecs.Idling", "--max-states", "2", "--allow-incomplete"])

      assert code == 0
      assert output =~ "2 temporal properties were not checked"
      assert output =~ "max_states"
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

      # #66: results now arrive in a versioned envelope, as a sorted list of self-describing
      # entries rather than a map keyed by module name.
      decoded = Jason.decode!(output)

      assert decoded["schema_version"] == Check.schema_version()
      entry = Enum.find(decoded["specs"], &(&1["spec"] == "TLA.TestSpecs.Broken"))

      assert entry["status"] == "violation"
      assert entry["violation"]["property"] == "below_three"
      assert entry["violation"]["length"] == 4
      assert entry["coverage"]["bounded_by"] == "violation"
      assert is_number(entry["collision_estimate"])
    end

    # #198. `<<255, 0>>` is a term §6 permits and a JSON string cannot carry. The search found
    # the violation, then `Jason.encode!/1` raised `invalid byte 0xFF` from the report writer
    # and the task exited with a stack trace and no document. A found counterexample must
    # never be lost to its own serialisation.
    test "--format json carries a counterexample whose state is not valid UTF-8" do
      {output, 1} = check(["TLA.TestSpecs.RawBytes", "--format", "json"])

      entry = output |> Jason.decode!() |> Map.fetch!("specs") |> hd()

      assert entry["status"] == "violation"
      assert entry["violation"]["property"] == "payload_is_text"

      last = entry["violation"]["states"] |> List.last() |> TLA.State.Json.decode!()
      assert last == %{payload: <<255, 0>>}
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

  # ── flags that take a number ────────────────────────────────────────────────

  describe "a numeric flag with a value the checker cannot use" do
    # `--fingerprint-bits 7` used to be passed straight through and raise an `ArgumentError`
    # from inside `TLA.Fingerprint`, MID-SEARCH, with a stack trace through the checker — a
    # typo in a flag reported as though the library had failed, after the run had begun
    # (#180). `--workers` was already refused at the flag; this is the same treatment.
    test "is refused at the flag, not from inside the search" do
      assert_raise Mix.Error, ~r/--fingerprint-bits must be one of 64, 128, got: 7/, fn ->
        check(["TLA.TestSpecs.WithDefaults", "--fingerprint-bits", "7"])
      end
    end

    test "and --workers is refused the same way" do
      assert_raise Mix.Error, ~r/--workers must be a positive integer, got: 0/, fn ->
        check(["TLA.TestSpecs.WithDefaults", "--workers", "0"])
      end
    end

    # Anti-vacuity: the permitted widths still work, so the guard is refusing the wrong
    # values rather than all of them.
    test "but a permitted width runs" do
      for bits <- TLA.Fingerprint.permitted_bits() do
        {output, code} =
          check(["TLA.TestSpecs.WithDefaults", "--fingerprint-bits", to_string(bits)])

        assert code == 0
        assert output =~ "— verified"
      end
    end

    # The list is asked for rather than restated, so a width added to `TLA.Fingerprint`
    # cannot leave the flag refusing it.
    test "and the flag's list is the one the fingerprint enforces" do
      source =
        Path.expand("../..", __DIR__)
        |> Path.join("lib/mix/tasks/tla.check.ex")
        |> File.read!()

      assert source =~ "TLA.Fingerprint.permitted_bits()"
      refute source =~ "@fingerprint_widths"
    end
  end
end
