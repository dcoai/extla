defmodule Mix.Tasks.Tla.CoverageTest do
  @moduledoc """
  `mix tla.coverage --check` is the HARD gate on `TLA_COVERAGE.md` (#1, open question 2).

  These tests exist because **its failure paths had never executed** (#75, #84). No test
  invoked the task, and in CI the `tla-coverage-drift` job sits in `verify`, which never starts
  when `ledger_test.exs`'s own drift assertion fails first in `check`. The job therefore proved
  only that the task *succeeds*; that it correctly *fails* was unverified — a gate whose red
  path nobody had run.

  `check!/2` is called directly rather than through `Mix.Tasks.Tla.Coverage.run/1`, because the
  task recomputes the whole ledger first — a model check of all 31 specs, about 53 seconds — and
  none of that is what is under test here. The real golden is never touched: every path below is
  a `tmp_dir`.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Mix.Tasks.Tla.Coverage

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  describe "check!/2" do
    test "passes when the file matches what was rendered", %{tmp_dir: tmp} do
      path = Path.join(tmp, "TLA_COVERAGE.md")
      File.write!(path, "identical")

      Coverage.check!(path, "identical")

      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "is current"
    end

    test "raises when the file has drifted, naming how to regenerate", %{tmp_dir: tmp} do
      path = Path.join(tmp, "TLA_COVERAGE.md")
      File.write!(path, "what is committed")

      error = assert_raise Mix.Error, fn -> Coverage.check!(path, "what the specs produce") end

      assert error.message =~ "has drifted"
      # The message has to carry the remedy: a gate that fails without saying what to run is
      # one somebody works around rather than satisfies.
      assert error.message =~ "mix tla.coverage --write"
    end

    test "raises when the file is missing, rather than treating absence as agreement",
         %{tmp_dir: tmp} do
      path = Path.join(tmp, "TLA_COVERAGE.md")
      refute File.exists?(path)

      error = assert_raise Mix.Error, fn -> Coverage.check!(path, "anything") end

      assert error.message =~ "is missing"
      assert error.message =~ "mix tla.coverage --write"
    end
  end
end
