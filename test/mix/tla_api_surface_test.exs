defmodule Mix.Tasks.Tla.ApiSurfaceTest do
  @moduledoc """
  `mix tla.api_surface --check` is a HARD gate on `API_SURFACE.md` (#270, #271), and its red
  paths are exercised here for the reason `tla_coverage_test.exs` gives: a gate whose failure
  branches no test has run is one that has only ever been seen succeeding.

  The check is `TLA.Surface.check!/4`, shared with `tla.coverage` so there is one definition
  of "drifted" (#270); its three outcomes are asserted once, here, against a `tmp_dir`. The
  real golden is never touched.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  describe "TLA.Surface.check!/4" do
    # This asserts that a match does not raise, and nothing about what is printed.
    #
    # `Mix.shell/1` is VM-global. `tla_coverage_test.exs` sets it to `Mix.Shell.Process` for
    # its own assertions, so anything this file claims about output is a race with it: swap
    # the global here and that file reads an empty mailbox; capture stdout here and the
    # message goes to *its* mailbox instead and the capture is blank. Both were tried, and
    # both failed only under the full suite, which is the worst way to learn it.
    #
    # The success message has one owner — `tla_coverage_test.exs`, over the same shared
    # `TLA.Surface.check!/4` — and one owner is what a global permits.
    test "passes when the file matches what was rendered", %{tmp_dir: tmp} do
      path = Path.join(tmp, "API_SURFACE.md")
      File.write!(path, "identical")

      assert TLA.Surface.check!("API_SURFACE.md", "tla.api_surface", path, "identical") == :ok
    end

    test "raises on drift, naming the golden and how to regenerate it", %{tmp_dir: tmp} do
      path = Path.join(tmp, "API_SURFACE.md")
      File.write!(path, "what is committed")

      error =
        assert_raise Mix.Error, fn ->
          TLA.Surface.check!("API_SURFACE.md", "tla.api_surface", path, "what the source says")
        end

      assert error.message =~ "API_SURFACE.md has drifted"
      assert error.message =~ "mix tla.api_surface --write"
    end

    test "raises when the file is missing, rather than reading absence as agreement",
         %{tmp_dir: tmp} do
      path = Path.join(tmp, "API_SURFACE.md")

      error =
        assert_raise Mix.Error, fn ->
          TLA.Surface.check!("API_SURFACE.md", "tla.api_surface", path, "anything")
        end

      assert error.message =~ "API_SURFACE.md is missing"
      assert error.message =~ "mix tla.api_surface --write"
    end
  end

  describe "the surface-drift job" do
    # Every golden's header names `surface-drift` as its gate. That is a claim about the
    # pipeline, and a golden whose gate does not run it is worse than an ungated one: it
    # carries a HARD marker nothing enforces. So the job is read here, and the list it must
    # run is derived from the tasks that HAVE a `--check` rather than named a second time.
    test "runs every golden's --check from one job" do
      ci = File.read!(Path.expand("../../.gitlab-ci.yml", __DIR__))
      [job] = Regex.run(~r/^surface-drift:\n(?:  .*\n)+/m, ci)

      # A golden's task is the one that can both render and compare: `--write` regenerates,
      # `--check` refuses a difference. `mix tla.mutants` has a `--check` of its own and no
      # `--write`, and it is not a golden — the pair is what identifies one.
      checkers =
        for task <- TLA.CliSurface.run(),
            {:check, :boolean} in task.switches,
            {:write, :boolean} in task.switches,
            do: task.task

      assert checkers != [], "no task renders a golden; this assertion would be vacuous"

      for name <- checkers do
        assert job =~ "- mix " <> name <> " --check",
               "the surface-drift job does not run `mix #{name} --check`"
      end
    end

    test "and the golden's header names that job" do
      header =
        Path.expand("../../API_SURFACE.md", __DIR__) |> File.read!() |> String.slice(0, 400)

      assert header =~ "gate `surface-drift` (HARD)"
      assert header =~ "mix tla.api_surface --write"
    end
  end
end
