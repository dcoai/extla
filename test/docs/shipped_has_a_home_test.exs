defmodule ExTLA.ShippedHasAHomeTest do
  @moduledoc """
  What is built is recorded where something checks it (#282).

  ## The claim that was withdrawn

  `06-architecture.md` §Implementation Phases called itself "the single source of truth for
  what is built" for three weeks. The four phases were written as a *plan* and ended
  honestly on 2026-09-01 (`d61a1df`, "Record that Phase 4 is complete, and hand off"); the
  claim was added the next day, to a finished enumeration nobody was extending. Eight
  features shipped after it with no home there.

  The fix is not a Phase 5 — that would be a third hand-maintained list of shipped work
  standing beside a gated one. §Phases records the plan; `CHANGELOG.md` records what is
  built, and `bin/changelog_guard.exs` fails any commit touching `lib/` that adds no entry.

  ## What this file asserts

  That the withdrawal is real, and that the record it points at actually holds the eight
  items the withdrawal was about. The *ongoing* guarantee is the changelog guard, which
  runs per commit in the `check` stage; this is the one-time evidence that the eight
  orphans found a home, which is the criterion #179 set for withdrawing the claim.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # The eight #179 named, each by a string that would have to survive a rewording of the
  # entry but not a removal of it. A needle naming a module is written without the `Ex`:
  # CHANGELOG.md is a record, and entries written before the namespace moved under `ExTLA`
  # (#338) name `TLA.*`. "TLA.Profile" matches both spellings.
  @shipped [
    {"ExTLA.Profile and the --profile flag", "TLA.Profile"},
    {"ExTLA.Trace.explore/3 and mix tla.explore", "tla.explore"},
    {"mix tla.stamp and spec_version:", "spec_version"},
    {"the verification ledger", "TLA_COVERAGE.md"},
    {"ExTLA.Conformance.against_graph/3", "against_graph"},
    {"ExTLA.Spec.Deps", "Spec.Deps"},
    {"mix tla.mutants", "tla.mutants"},
    {"JSON schema version 2", "schema_version"}
  ]

  defp changelog, do: @root |> Path.join("CHANGELOG.md") |> File.read!()

  describe "the eight features that shipped after Phase 4" do
    test "each have an entry in the gated record" do
      homeless =
        for {what, needle} <- @shipped,
            not String.contains?(changelog(), needle),
            do: "#{what} (searched for #{inspect(needle)})"

      assert homeless == [], """
      #{length(homeless)} of the eight shipped features have no CHANGELOG entry:

        #{Enum.join(homeless, "\n  ")}

      §Implementation Phases was withdrawn as "the single source of truth for what is
      built" on the grounds that CHANGELOG.md is that record and is gated. A feature in
      neither is in no record at all, which is worse than the claim that was removed.
      """
    end
  end

  describe "the withdrawal itself" do
    test "§Phases no longer claims to be the single source of truth" do
      architecture = @root |> Path.join("spec/06-architecture.md") |> File.read!()

      # The CLAIM, not the words: the section explains what it withdrew and quotes the
      # sentence it withdrew, which is the right way to record a correction.
      refute architecture =~ "**This section is the single source of truth"
      assert architecture =~ "**This section is the record of a plan"
      assert architecture =~ "There is no Phase 5, deliberately"
    end

    test "and the README sends a reader to the gated record" do
      readme = @root |> Path.join("README.md") |> File.read!()

      assert readme =~ "**What is built** is [`CHANGELOG.md`](CHANGELOG.md)"
      assert readme =~ "changelog_guard"
    end

    # The guard is what makes the CHANGELOG a record rather than a habit, so the prose
    # above is only true while it exists. A rename would leave both documents pointing at
    # a file nobody runs.
    test "and the guard the withdrawal rests on exists" do
      assert File.exists?(Path.join(@root, "bin/changelog_guard.exs"))

      ci = @root |> Path.join(".gitlab-ci.yml") |> File.read!()
      assert ci =~ "elixir bin/changelog_guard.exs"
    end
  end
end
