defmodule TLA.ReadmeEntryTest do
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

  Its command list named three of the six `mix tla.*` tasks that ship.

  ## What is gated, and what is not

  The command list is held to `CLI_SURFACE.md`, which is generated from the tasks that
  exist and gated by `surface-drift` — so "the README lists the tasks" is a fact about the
  code rather than a hand-kept set that goes stale the way the install pin did (#154).

  The **links** are not re-checked here: `TLA.GuideCheck.Links` already resolves every
  relative link on this page, and #281 brought `README.md` under that harness. What this
  adds is that the links a reader needs are *present*, which no link checker can tell you.

  The README's **proportions** are deliberately untouched — its Status section runs half
  the file, sits above the reasons to use the library, and "who is this for" is never
  stated. #155 left that for a separate decision on the grounds that bundling a rewrite
  with a navigation fix would stall the fix, and this file does not quietly adopt it.
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

    test "and lists guides/ in the repository layout" do
      [_match, table] = Regex.run(~r/## Repository layout\n(.*?)\n## /s, readme())

      assert table =~ "`guides/`",
             "the repository layout table omits guides/, which is where a reader starts"
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

      Every `mix tla.*` task that ships in the package should be discoverable from the
      front page; `mix tla.explore` and `mix tla.stamp` were both absent when #155 was
      filed. The list of packaged tasks is CLI_SURFACE.md's, which is generated.
      """
    end

    test "and mentions no task that does not ship" do
      # The ledger's own tooling — `mix tla.api_surface` and friends — is not packaged, so
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
      assert "mix tla.check" in packaged_tasks()
      assert "mix tla.api_surface" in all_tasks()
      refute "mix tla.api_surface" in packaged_tasks()
    end
  end

  # `## \`mix tla.check\` — specified in spec/04-…` versus
  # `## \`mix tla.api_surface\` — ledger tooling, not packaged`.
  defp all_tasks do
    @root
    |> Path.join("CLI_SURFACE.md")
    |> File.read!()
    |> then(&Regex.scan(~r/^## `(mix tla\.[\w.]+)`/m, &1))
    |> Enum.map(fn [_match, task] -> task end)
  end

  defp packaged_tasks do
    @root
    |> Path.join("CLI_SURFACE.md")
    |> File.read!()
    |> then(&Regex.scan(~r/^## `(mix tla\.[\w.]+)` — ([^\n]*)/m, &1))
    |> Enum.reject(fn [_match, _task, detail] ->
      String.contains?(detail, "not packaged")
    end)
    |> Enum.map(fn [_match, task, _detail] -> task end)
  end
end
