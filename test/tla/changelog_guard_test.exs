defmodule TLA.ChangelogGuardTest do
  @moduledoc """
  `bin/changelog_guard.exs` — a `lib/` change must say what it did, or say why it has nothing
  to say (#124, #142).

  Two kinds of test here, and the second is the one that matters. The synthetic repository
  below proves the *mechanism*: red when it should be red, green on each of the ways to be
  green. The history cases at the bottom prove the *rule* — run over eight real merges to
  `main`, the guard must flag exactly the four that shipped `lib/` changes with no entry. A
  gate that has only ever been shown a fixture is #75's defect one layer up.
  """
  use ExUnit.Case, async: true

  @guard Path.expand("../../bin/changelog_guard.exs", __DIR__)
  @project Path.expand("../..", __DIR__)

  defp guard(dir, base, head) do
    {_out, code} =
      System.cmd("elixir", [@guard, base, head], cd: dir, stderr_to_stdout: true)

    code
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  # A repository of its own rather than fixtures in this one: the guard reads `git diff` and
  # `git log`, so the only honest way to give it a range is to make one.
  defp repo(context) do
    dir = Path.join(System.tmp_dir!(), "changelog_guard_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    on_exit(fn -> File.rm_rf!(dir) end)

    git!(dir, ["init", "-q", "."])
    git!(dir, ["config", "user.email", "guard@test"])
    git!(dir, ["config", "user.name", "Guard Test"])

    File.write!(Path.join(dir, "lib/a.ex"), "initial\n")
    File.write!(Path.join(dir, "CHANGELOG.md"), "# Changelog\n")
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-qm", "base"])

    Map.put(context, :dir, dir)
  end

  defp commit(dir, message, changes) do
    Enum.each(changes, fn {path, contents} ->
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, contents)
    end)

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-qm", message])
  end

  describe "the mechanism" do
    setup :repo

    test "a lib/ change with no entry and no reason is refused", %{dir: dir} do
      commit(dir, "touch lib", [{"lib/a.ex", "changed\n"}])

      assert guard(dir, "HEAD~1", "HEAD") == 1
    end

    test "a lib/ change with an entry passes", %{dir: dir} do
      commit(dir, "touch lib", [{"lib/a.ex", "changed\n"}, {"CHANGELOG.md", "# Changelog\n- x\n"}])

      assert guard(dir, "HEAD~1", "HEAD") == 0
    end

    test "a lib/ change with a Changelog-none: reason passes", %{dir: dir} do
      commit(dir, "refactor\n\nChangelog-none: internal rename, no behaviour change", [
        {"lib/a.ex", "changed\n"}
      ])

      assert guard(dir, "HEAD~1", "HEAD") == 0
    end

    # The hatch has to cost something, or it is a `--force` with extra steps. An empty reason
    # is the cheapest possible bypass, so it is the one worth refusing explicitly.
    test "a Changelog-none: with no reason is not an answer", %{dir: dir} do
      commit(dir, "refactor\n\nChangelog-none:", [{"lib/a.ex", "changed\n"}])

      assert guard(dir, "HEAD~1", "HEAD") == 1
    end

    # A git trailer begins a line. Matching the token anywhere would let prose *about* the
    # check satisfy the check, and the sentence most likely to contain it is one saying the
    # entry is needed.
    test "the trailer must begin a line, not merely appear in one", %{dir: dir} do
      commit(
        dir,
        "refactor\n\nI considered Changelog-none: here but the public API did move",
        [{"lib/a.ex", "changed\n"}]
      )

      assert guard(dir, "HEAD~1", "HEAD") == 1
    end

    test "a change that does not touch lib/ is not asked for anything", %{dir: dir} do
      commit(dir, "tests and prose", [{"test/a_test.exs", "x\n"}, {"guides/g.md", "y\n"}])

      assert guard(dir, "HEAD~1", "HEAD") == 0
    end

    # The trailer is read from every commit in the range, not only the tip: a branch that
    # answers in its first commit and then adds a second must not be asked again.
    test "the reason may come from any commit in the range", %{dir: dir} do
      commit(dir, "refactor\n\nChangelog-none: pure rename", [{"lib/a.ex", "changed\n"}])
      commit(dir, "follow-up", [{"lib/b.ex", "more\n"}])

      assert guard(dir, "HEAD~2", "HEAD") == 0
    end
  end

  describe "the rule, against this repository's own history" do
    # The eight most recent merges to `main` that touched `lib/`, and what they did about the
    # CHANGELOG. Established by reading the merges, not by running the guard — otherwise this
    # asserts that the guard agrees with itself.
    @with_entry ~w(1942cd3 bf14e81 591063c c15b19b)
    @without_entry ~w(2698981 6805aa8 279afb4 01e1604)

    test "it flags every merge that changed lib/ without an entry" do
      for sha <- @without_entry do
        assert guard(@project, "#{sha}^1", sha) == 1,
               "#{sha} shipped a lib/ change with no CHANGELOG entry and was not flagged"
      end
    end

    test "it passes every merge that wrote one" do
      for sha <- @with_entry do
        assert guard(@project, "#{sha}^1", sha) == 0,
               "#{sha} wrote a CHANGELOG entry and was flagged anyway"
      end
    end
  end
end
