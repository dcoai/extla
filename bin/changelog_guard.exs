#!/usr/bin/env elixir

# A change to `lib/` must say what it did, or say why it has nothing to say.
#
#     elixir bin/changelog_guard.exs [BASE [HEAD]]
#
# Exit 0 when the range is fine, 1 when it is not. BASE defaults to the merge request's
# target branch under CI, then to `origin/main`; HEAD defaults to `HEAD`.
#
# ## Why this exists as a gate rather than as a convention
#
# #124 read the history as a habit that broke: eighteen consecutive work items wrote a
# CHANGELOG entry, then `fe0799d` reset the section and three merges passed without one.
# Investigating for #142 found something else, and it is worth recording because it changes
# what this script is for.
#
# **There was never a `lib/`-linked practice.** The eighteen were the "Teaching the thing",
# "Teaching the idea" and "Teaching the practice" milestones — documentation work, and
# fourteen of them touched no `lib/` at all. They wrote entries because writing prose *was*
# the work. In the same era, `issue-91-dependency-sets` changed three files under `lib/` and
# wrote nothing. No issue in either era mentions the CHANGELOG; neither does any skill, nor
# `CLAUDE.md`.
#
# So nothing carried the habit and nothing broke. The run ended because the work moved from
# documentation back to code, and the section reset merely happened to sit at the boundary.
# This script therefore **establishes** a rule rather than restoring one, which is the honest
# framing and also the reason the escape hatch below had to be designed rather than assumed:
# there is no prior practice to appeal to about what deserves an entry.
#
# ## The escape hatch
#
# A pure refactor genuinely has nothing to say, so the check has to be answerable and not
# only obeyable — a gate everyone learns to bypass is worse than no gate. The requirement is
# that answering it costs the same visibility as obeying it: a `Changelog-none:` trailer
# lands in the commit message, where a reviewer reads it beside the diff. A label or a
# `[skip changelog]` token would not, and afterwards nothing would distinguish a considered
# no-op from a bypass.
#
# The knob's holder is the AUTHOR and its value is INTENT — "does this affect anyone outside
# the repository" is not derivable from a diff, which is `RELEASING.md`'s own point. Set
# wrong it fails loudly, at the gate, rather than degrading into a release nobody can
# describe.

defmodule ChangelogGuard do
  @entry "CHANGELOG.md"
  @watched "lib/"
  @trailer "Changelog-none:"

  def main(argv) do
    {base, head} = range(argv)

    case verdict(base, head) do
      :ok ->
        IO.puts("changelog-guard: ok (#{base}..#{head})")
        System.halt(0)

      {:ok, reason} ->
        IO.puts("changelog-guard: ok — #{@trailer} #{reason}")
        System.halt(0)

      {:error, files} ->
        IO.puts(:stderr, failure_message(files))
        System.halt(1)
    end
  end

  defp verdict(base, head) do
    files = changed_files(base, head)
    touched = Enum.filter(files, &String.starts_with?(&1, @watched))

    cond do
      touched == [] -> :ok
      @entry in files -> :ok
      true -> exempted(base, head, touched)
    end
  end

  defp exempted(base, head, touched) do
    case trailer_reason(base, head) do
      nil -> {:error, touched}
      reason -> {:ok, reason}
    end
  end

  # Read from the commit messages in the range rather than from a file, so the answer travels
  # with the change and cannot be edited afterwards without rewriting history.
  #
  # The trailer has to BEGIN a line, as a git trailer does. Matching it anywhere would let
  # prose about the check satisfy the check — "I considered Changelog-none: but the API did
  # move" would pass, saying the opposite of what it means.
  defp trailer_reason(base, head) do
    git!(["log", "--format=%B", "#{base}..#{head}"])
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, @trailer))
    |> Enum.find_value(fn line ->
      line
      |> String.replace_prefix(@trailer, "")
      |> String.trim()
      |> presence()
    end)
  end

  defp presence(""), do: nil
  defp presence(reason), do: reason

  # Three dots: the diff against the MERGE BASE, so a `main` that moved on underneath the
  # branch does not make unrelated files look like this change's.
  defp changed_files(base, head) do
    git!(["diff", "--name-only", "#{base}...#{head}"])
    |> String.split("\n", trim: true)
  end

  defp range([base, head]), do: {base, head}
  defp range([base]), do: {base, "HEAD"}
  defp range([]), do: {default_base(), "HEAD"}

  defp default_base do
    case System.get_env("CI_MERGE_REQUEST_TARGET_BRANCH_NAME") do
      nil -> "origin/main"
      "" -> "origin/main"
      branch -> "origin/#{branch}"
    end
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} ->
        out

      {out, code} ->
        # A shallow clone has no merge base, and the diff then fails rather than returning
        # nothing — which would read as "no lib/ change" and pass. Say so instead: the job
        # needs GIT_DEPTH: 0.
        IO.puts(:stderr, "changelog-guard: git #{Enum.join(args, " ")} failed (#{code})\n#{out}")
        System.halt(2)
    end
  end

  defp failure_message(files) do
    listed = files |> Enum.take(10) |> Enum.map_join("\n", &"    #{&1}")

    more =
      case length(files) - 10 do
        n when n > 0 -> "\n    … and #{n} more"
        _ -> ""
      end

    """
    changelog-guard: #{length(files)} file(s) under #{@watched} changed, and #{@entry} did not.

    #{listed}#{more}

    What changed and why it matters is not derivable from the diff (RELEASING.md), which is
    why the entry is written now rather than reconstructed at release time.

    Add an entry to the [Unreleased] section of #{@entry}.

    If this change genuinely has nothing to say to anyone outside the repository — a pure
    refactor, an internal rename — say so in a commit message trailer:

        #{@trailer} internal rename, no behaviour or API change

    The reason is required, and it lands in the history where a reviewer reads it. That is
    the point: answering the check has to cost the same visibility as obeying it.
    """
  end
end

ChangelogGuard.main(System.argv())
