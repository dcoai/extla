defmodule ExTLA.PrimerFramingTest do
  @moduledoc """
  The TLA+ primer says which parts of TLA+ this library implements (#293, for #181).

  ## What it was

  1321 published lines with **zero** occurrences of "ExTLA", shipping in the package and
  rendering in the sidebar, with chapters on PlusCal, TLAPS and TLC's distributed mode. A
  reader arriving there got TLA+ with nothing indicating which parts this tool implements,
  which it deliberately does not, and which are translated into Elixir syntax.

  ## Why this is a test and not just prose

  #181 says "no test for the primer header; it is prose", and the header is. But it makes
  two claims that are **not** prose: that ExTLA is not a theorem prover, and that this is a
  stated non-goal rather than an omission. Those live in `spec/06-architecture.md`
  §Non-goals, published for users as `guides/reference.md` §What ExTLA is not, and a page asserting them should fail when they stop being true — a non-goal
  becoming a goal would otherwise leave this page contradicting the architecture with
  nothing to notice.

  The links are already gated: #281 brought `spec/` and `README.md` under the guide harness
  and `ExTLA.GuideCheck.Links` resolves every relative link on a page it checks.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp primer, do: @root |> Path.join("research/tla-plus-primer.md") |> File.read!()

  defp squeeze(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  describe "the primer" do
    test "names the library it ships with" do
      assert primer() =~ "ExTLA",
             "the primer never mentions ExTLA, so a reader cannot tell which parts of TLA+ " <>
               "this tool implements"
    end

    test "and says so in its first screen, not somewhere in the middle" do
      opening = primer() |> String.split("\n") |> Enum.take(30) |> Enum.join("\n")

      assert opening =~ "ExTLA implements the specification and model-checking parts"
      assert opening =~ "does not implement PlusCal or TLAPS"
    end

    test "and points at the Elixir mapping" do
      assert primer() =~ "guides/tutorial/00-introduction.md"
      assert primer() =~ "usage-rules.md"
    end
  end

  describe "the claims it makes about scope" do
    # The header asserts that not being a theorem prover is a STATED non-goal rather than an
    # omission. That is a fact about another document, so it is checked against it.
    test "agree with spec/06's non-goals" do
      non_goals =
        @root
        |> Path.join("spec/06-architecture.md")
        |> File.read!()
        |> then(&Regex.run(~r/## Non-goals\n(.*?)\n---/s, &1))
        |> Enum.at(1)
        |> squeeze()

      assert non_goals =~ "ExTLA is not a theorem prover"
      assert non_goals =~ "TLAPS proves; ExTLA checks"

      # The primer's header cites the published statement of them by anchor, so the claim is
      # followable from HexDocs, where spec/06 is not published (#404, for #397).
      assert squeeze(primer()) =~ "guides/reference.md#what-extla-is-not"
    end

    # The published statement is a user's copy of spec/06's, so it is held to the same claim.
    test "and the reference page states the same one" do
      not_list =
        @root
        |> Path.join("guides/reference.md")
        |> File.read!()
        |> then(&Regex.run(~r/## What ExTLA is not\n(.*?)\n## /s, &1))
        |> Enum.at(1)
        |> squeeze()

      assert not_list =~ "Not a theorem prover"
      assert not_list =~ "TLAPS proves; ExTLA checks"
    end

    # Anti-vacuity: every assertion above is a substring match on a file read from disk, so
    # a wrong path yields `""` and `"" =~ x` is false — but a *truncated* read would pass
    # some and fail others confusingly. The size check makes the corpus explicit.
    test "and the page being checked is the whole primer" do
      assert String.length(primer()) > 30_000
      assert primer() =~ "## PlusCal"
      assert primer() =~ "## Fairness"
    end
  end
end
