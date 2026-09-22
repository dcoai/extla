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

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  describe "TLA.Surface.check!/4" do
    test "passes when the file matches what was rendered", %{tmp_dir: tmp} do
      path = Path.join(tmp, "API_SURFACE.md")
      File.write!(path, "identical")
      TLA.Surface.check!("API_SURFACE.md", "tla.api_surface", path, "identical")
      assert_received {:mix_shell, :info, [msg]}
      assert msg == "API_SURFACE.md is current"
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
