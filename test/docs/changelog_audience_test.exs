defmodule ExTLA.ChangelogAudienceTest do
  @moduledoc """
  The CHANGELOG is written for people who use ExTLA (#406, for #397).

  ## What was wrong

  The file ships and HexDocs renders it, and about a third of its 2,555 lines were about the
  repository rather than the library: CI jobs, the surface goldens, the relation log, the
  mutation harness, test helpers, decision-log pins. A user reading what changed in a release
  had to dig the changes they could observe out from among those.

  #406 condensed every release to the rule `RELEASING.md` states: an entry records what a user
  can observe, and work only the repository sees is left to the commit history. The full text
  is the CHANGELOG at `v0.5.0`.

  ## What this holds

  That the rule keeps holding. It names the repository's own tooling — the artifacts and
  harnesses no consumer ever runs — and fails when an entry mentions one. A term a user can
  legitimately meet (`CI` in their own pipeline, `DIAGNOSTICS.md` in an old fix) is not on the
  list, so this catches the common slide back rather than judging every sentence.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # The repository's own tooling: generated goldens, the relation log, the mutation harness,
  # decision-log pins, and this project's test files.
  @internal [
    ~r/surfex/i,
    ~r/relation log/i,
    ~r/\b(RELATIONS|EXERCISE|API_SURFACE|CLI_SURFACE|PACKAGE_SURFACE|TLA_COVERAGE)\.md\b/,
    ~r/mutant/i,
    ~r/golden/i,
    ~r/Pinned by/,
    ~r/changelog_guard/,
    ~r{\btest/[\w/]+_test\.exs\b}
  ]

  # The entries: everything from the first section heading on — `## [Unreleased]` between
  # releases, `## [X.Y.Z]` in a release commit, which has none. The preamble above it explains
  # the rule, and so has to name what the rule leaves out.
  defp entries do
    [_preamble, entries] =
      @root
      |> Path.join("CHANGELOG.md")
      |> File.read!()
      |> String.split(~r/^## \[/m, parts: 2)

    entries
  end

  test "no entry is about the repository's own tooling" do
    found =
      for {line, number} <- entries() |> String.split("\n") |> Enum.with_index(1),
          pattern <- @internal,
          Regex.match?(pattern, line),
          do: "  line #{number} of the entries: #{String.trim(line)}"

    assert found == [], """
    The CHANGELOG mentions this repository's own tooling:

    #{Enum.join(Enum.uniq(found), "\n")}

    An entry records what someone using ExTLA can observe (RELEASING.md). Work only the
    repository sees has no entry; a lib/ change of that kind answers the changelog guard with
    a `Changelog-none:` trailer instead.
    """
  end

  # Anti-vacuity: the split found the entries, and the patterns match what they are for.
  test "and the check reads the real entries with patterns that fire" do
    assert entries() =~ "## [0.1.0]"
    assert Enum.any?(@internal, &Regex.match?(&1, "regenerated API_SURFACE.md"))
    assert Enum.any?(@internal, &Regex.match?(&1, "the surfex relation log"))
    refute Enum.any?(@internal, &Regex.match?(&1, "in scripts, CI files, Makefiles and aliases"))
  end
end
