defmodule Mix.Tasks.Extla.ApiSurfaceTest do
  @moduledoc """
  `mix extla.api_surface --check` is a HARD gate on `API_SURFACE.md` (#270, #271), and its red
  paths are exercised here for the reason `tla_coverage_test.exs` gives: a gate whose failure
  branches no test has run is one that has only ever been seen succeeding.

  The check is `ExTLA.Surface.check!/4`, shared with `extla.coverage` so there is one definition
  of "drifted" (#270); its three outcomes are asserted once, here, against a `tmp_dir`. The
  real golden is never touched.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  describe "ExTLA.Surface.check!/4" do
    # This asserts that a match does not raise, and nothing about what is printed.
    #
    # `Mix.shell/1` is VM-global. `tla_coverage_test.exs` sets it to `Mix.Shell.Process` for
    # its own assertions, so anything this file claims about output is a race with it: swap
    # the global here and that file reads an empty mailbox; capture stdout here and the
    # message goes to *its* mailbox instead and the capture is blank. Both were tried, and
    # both failed only under the full suite, which is the worst way to learn it.
    #
    # The success message has one owner — `tla_coverage_test.exs`, over the same shared
    # `ExTLA.Surface.check!/4` — and one owner is what a global permits.
    test "passes when the file matches what was rendered", %{tmp_dir: tmp} do
      path = Path.join(tmp, "API_SURFACE.md")
      File.write!(path, "identical")

      assert ExTLA.Surface.check!("API_SURFACE.md", "extla.api_surface", path, "identical") == :ok
    end

    test "raises on drift, naming the golden and how to regenerate it", %{tmp_dir: tmp} do
      path = Path.join(tmp, "API_SURFACE.md")
      File.write!(path, "what is committed")

      error =
        assert_raise Mix.Error, fn ->
          ExTLA.Surface.check!(
            "API_SURFACE.md",
            "extla.api_surface",
            path,
            "what the source says"
          )
        end

      assert error.message =~ "API_SURFACE.md has drifted"
      assert error.message =~ "mix extla.api_surface --write"
    end

    test "raises when the file is missing, rather than reading absence as agreement",
         %{tmp_dir: tmp} do
      path = Path.join(tmp, "API_SURFACE.md")

      error =
        assert_raise Mix.Error, fn ->
          ExTLA.Surface.check!("API_SURFACE.md", "extla.api_surface", path, "anything")
        end

      assert error.message =~ "API_SURFACE.md is missing"
      assert error.message =~ "mix extla.api_surface --write"
    end
  end

  describe "the surface-drift job" do
    # Every golden's header names its gate. That is a claim about the pipeline, and a golden
    # whose gate does not run it is worse than an ungated one: it carries a HARD marker nothing
    # enforces. So the job is read here, and the list it must run is derived from the tasks
    # that HAVE a `--check` rather than named a second time.
    #
    # The gate is read from each golden's own header, not assumed to be `surface-drift`.
    # Six goldens are gated there; `EXERCISE.md` is gated in `test`, because it is that job's
    # own coverage run and checking it anywhere else would mean carrying the data between jobs
    # or running the suite twice (#370). The rule is the same either way: the job a header
    # names runs that golden's --check.
    test "runs every golden's --check from the job its header names" do
      ci = File.read!(Path.expand("../../.gitlab-ci.yml", __DIR__))

      # A golden's task is the one that can both render and compare: `--write` regenerates,
      # `--check` refuses a difference. `mix extla.mutants` has a `--check` of its own and no
      # `--write`, and it is not a golden — the pair is what identifies one.
      checkers =
        for task <- ExTLA.CliSurface.run(),
            {:check, :boolean} in task.switches,
            {:write, :boolean} in task.switches,
            do: task.task

      assert checkers != [], "no task renders a golden; this assertion would be vacuous"

      gates = golden_gates()

      for name <- checkers do
        # `mix extla.examples` writes spec/07's corpus sources, which carry no markdown header;
        # a golden without one is gated where all of them were before #370, in surface-drift.
        gate = Map.get(gates, name, "surface-drift")

        [job] =
          Regex.run(~r/^#{Regex.escape(gate)}:\n(?:  .*\n|\s*\n)+/m, ci) ||
            flunk("no `#{gate}:` job")

        assert job =~ "- mix " <> name <> " --check",
               "the `#{gate}` job, which #{name}'s golden names as its gate, does not run `mix #{name} --check`"
      end

      # Anti-vacuity: the headers were read. Five header-bearing goldens gate in surface-drift
      # (the corpus sources `extla.examples` writes have none), and EXERCISE.md in test.
      assert Enum.count(gates, fn {_task, gate} -> gate == "surface-drift" end) == 5
      assert gates["extla.exercise"] == "test"
    end

    # The other direction, for every golden in the repository rather than only extla's own:
    # a header naming a gate is a claim that the job exists and runs that golden's task.
    # RELATIONS.md is surfex's, its header names `relation-status-drift` and surfex fixes that
    # name (#354), so the loop above, which starts from extla's tasks, never reads it.
    test "every golden's header names a job that exists and runs its task" do
      ci = File.read!(Path.expand("../../.gitlab-ci.yml", __DIR__))
      gates = golden_gates()

      assert gates["surfex.goldens"] == "relation-status-drift",
             "RELATIONS.md's header was not read; this assertion would be vacuous"

      for {task, gate} <- gates do
        [job] =
          Regex.run(~r/^#{Regex.escape(gate)}:\n(?:  .*\n|\s*\n)+/m, ci) ||
            flunk("#{task}'s golden names `#{gate}` as its gate, and there is no such job")

        assert job =~ ~r/^    - mix #{Regex.escape(task)}( --check)?$/m,
               "the `#{gate}` job does not run `mix #{task}`, though its golden names it as the gate"
      end
    end

    test "and the golden's header names that job" do
      header =
        Path.expand("../../API_SURFACE.md", __DIR__) |> File.read!() |> String.slice(0, 400)

      assert header =~ "gate `surface-drift` (HARD)"
      assert header =~ "mix extla.api_surface --write"
    end
  end

  # task => gate, from the attribution line every golden carries:
  # Generated by `mix <task> --write` · gate `<gate>` (HARD|ADVISORY) …
  defp golden_gates do
    root = Path.expand("../..", __DIR__)

    for path <- Path.wildcard(Path.join(root, "*.md")),
        [_, task, gate] <-
          [Regex.run(~r/Generated by `mix (\S+) --write` · gate `([^`]+)`/, File.read!(path))],
        into: %{},
        do: {task, gate}
  end
end
