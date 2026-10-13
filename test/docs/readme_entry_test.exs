defmodule ExTLA.ReadmeEntryTest do
  @moduledoc """
  The README is the way in, and it has to lead somewhere (#289, for #155).

  ## What was wrong

  `README.md` contained **zero** occurrences of `guides/`, `getting-started` or `tutorial`,
  while linking into `spec/` eleven times, and its repository-layout table listed `spec/`,
  `pm/`, `research/` and `test/differential/` — so the offline proposal tracker was more
  discoverable than the tutorial.

  `mix.exs` sets `main: "readme"`, so this is the first page every hexdocs reader lands on
  and the first a GitLab visitor sees. It routed them into the normative specification,
  which `mix.exs` itself describes as "the authority" that the guides link *to*.

  Its command list named three of the six `mix extla.*` tasks that ship.

  ## What is gated, and what is not

  The command list is held to `CLI_SURFACE.md`, which is generated from the tasks that
  exist and gated by `surface-drift` — so "the README lists the tasks" is a fact about the
  code rather than a hand-kept set that goes stale the way the install pin did (#154).

  The **links** are not re-checked here: `ExTLA.GuideCheck.Links` already resolves every
  relative link on this page, and #281 brought `README.md` under that harness. What this
  adds is that the links a reader needs are *present*, which no link checker can tell you.

  #155 left the README's proportions for a separate decision, and #403 made it: the README is
  a front door (description, install, one example, resources), and the measurements its
  Status section held moved beside the corpus they measure, `test/differential/README.md`.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp readme, do: @root |> Path.join("README.md") |> File.read!()

  describe "the front page" do
    test "leads to the guides" do
      readme = readme()

      assert readme =~ "guides/getting-started.md",
             "the README does not link the getting-started guide"

      assert readme =~ "guides/tutorial/00-introduction.md",
             "the README does not link the tutorial"
    end

    test "and lists the guides first among its resources" do
      [_match, resources] = Regex.run(~r/## Resources\n(.*)\z/s, readme())
      [first, second | _] = Regex.scan(~r/^- \[[^\]]+\]\(([^)]+)\)/m, resources)

      assert Enum.map([first, second], &List.last/1) ==
               ["guides/getting-started.md", "guides/tutorial/00-introduction.md"],
             "the resources list should start where a reader starts: getting started, then the tutorial"
    end
  end

  describe "the command list" do
    # Held to the generated golden rather than to a list in this test: `CLI_SURFACE.md` is
    # rendered from the tasks that exist and gated by `surface-drift`, so a task added or
    # removed moves this assertion without anyone maintaining it.
    test "names every mix task that ships" do
      readme = readme()

      missing = for task <- packaged_tasks(), not String.contains?(readme, task), do: task

      assert missing == [], """
      the README does not mention #{Enum.join(missing, ", ")}.

      Every `mix extla.*` task that ships in the package should be discoverable from the
      front page; `mix extla.explore` and `mix extla.stamp` were both absent when #155 was
      filed. The list of packaged tasks is CLI_SURFACE.md's, which is generated.
      """
    end

    test "and mentions no task that does not ship" do
      # The ledger's own tooling — `mix extla.api_surface` and friends — is not packaged, so
      # a reader following the README could not run it.
      internal =
        for task <- all_tasks(),
            task not in packaged_tasks(),
            String.contains?(readme(), task),
            do: task

      assert internal == [],
             "the README mentions #{Enum.join(internal, ", ")}, which is not in the package"
    end

    # Anti-vacuity: both assertions above iterate a list parsed out of a golden, and an
    # empty list passes either way.
    test "and the task list it is checked against is the real one" do
      assert length(packaged_tasks()) >= 6
      assert "mix extla.check" in packaged_tasks()
      assert "mix extla.api_surface" in all_tasks()
      refute "mix extla.api_surface" in packaged_tasks()
    end
  end

  # `## \`mix extla.check\` — specified in spec/04-…` versus
  # `## \`mix extla.api_surface\` — ledger tooling, not packaged`.
  defp all_tasks do
    @root
    |> Path.join("CLI_SURFACE.md")
    |> File.read!()
    |> then(&Regex.scan(~r/^## `(mix extla\.[\w.]+)`/m, &1))
    |> Enum.map(fn [_match, task] -> task end)
  end

  defp packaged_tasks do
    @root
    |> Path.join("CLI_SURFACE.md")
    |> File.read!()
    |> then(&Regex.scan(~r/^## `(mix extla\.[\w.]+)` — ([^\n]*)/m, &1))
    |> Enum.reject(fn [_match, _task, detail] ->
      String.contains?(detail, "not packaged")
    end)
    |> Enum.map(fn [_match, task, _detail] -> task end)
  end
end
