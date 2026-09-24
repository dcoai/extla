defmodule TLA.UsageRulesTest do
  @moduledoc """
  `usage-rules.md` describes the DSL that exists (#292, for #181).

  ## Why it exists at all

  This project's own governing instructions require a `usage-rules.md`, and there was none —
  so it was non-compliant with its own rules. But the convention is the weaker half of the
  case. The stronger half is that **the DSL is written in Elixir syntax and is not Elixir**:
  assignment is a next-state relation, `^name` is a constant rather than a match pin,
  `require` is an enabling condition rather than `Kernel.SpecialForms.require/2`, and guard
  order decides between a disabled action and a raised `DomainError`. An agent writing what
  looks like ordinary Elixir gets each of those wrong, and each is a compile error or a
  silent misspecification.

  ## Why it is gated

  A usage-rules file is a hand-written enumeration of what the compiler refuses — the
  project's most familiar defect class. So the diagnostics it names are held to
  `DIAGNOSTICS.md`, which is generated from the `bad!/5` and `raise!/1` call sites and gated
  by `surface-drift`. A rule citing a kind the compiler cannot raise would be advice about a
  tool that does not exist.

  The decisions it cites are held to `spec/08-decisions.md` for the same reason: D-20's
  guard-order rule and D-22's refusal are the *reasons* the advice is what it is, and a
  citation that resolves to nothing is worse than none — it reads as checkable and is not.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp rules, do: @root |> Path.join("usage-rules.md") |> File.read!()

  defp cited(pattern),
    do: pattern |> Regex.scan(rules()) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()

  describe "the file" do
    test "exists and ships in the package" do
      assert File.regular?(Path.join(@root, "usage-rules.md"))

      # `Mix.Project.config()` rather than `PACKAGE_SURFACE.md`: that golden enumerates
      # modules and dependencies, not the `files:` entries, so it is silent about this one.
      # The project config is the thing `mix hex.publish` reads.
      files = Mix.Project.config() |> Keyword.fetch!(:package) |> Keyword.fetch!(:files)

      assert "usage-rules.md" in files,
             "usage-rules.md is not in `files:`, so `mix usage_rules.sync` cannot pull it " <>
               "into a consumer project: #{inspect(files)}"
    end

    test "and is not an empty gesture at the convention" do
      assert String.length(rules()) > 3_000
      assert rules() =~ "next-state relation"
      assert rules() =~ "enabling condition"
    end
  end

  describe "every diagnostic it names" do
    # The kinds are generated from the call sites, so this compares the advice against what
    # the compiler can actually raise rather than against a second hand-kept list.
    test "is a kind the compiler can raise" do
      known =
        @root
        |> Path.join("DIAGNOSTICS.md")
        |> File.read!()
        |> then(&Regex.scan(~r/^\| `:(\w+)`/m, &1))
        |> Enum.map(fn [_match, kind] -> kind end)
        |> MapSet.new()

      assert MapSet.size(known) > 40, "DIAGNOSTICS.md yielded #{MapSet.size(known)} kinds"

      named = cited(~r/`:(\w+)`/)
      diagnostics = Enum.filter(named, &MapSet.member?(known, &1))

      assert diagnostics != [],
             "usage-rules.md names no diagnostic at all, so this gate is reading nothing"

      unknown =
        for kind <- named,
            not MapSet.member?(known, kind),
            kind not in ~w(state old new type_ok disabled enabled verbose log_only holds
                           inconclusive violated ok duplicate_declaration),
            do: kind

      assert unknown == [], """
      usage-rules.md names #{length(unknown)} atom(s) that are not diagnostic kinds and not
      on the allowed list of DSL names:

        #{Enum.join(unknown, ", ")}

      If one is a diagnostic, the compiler cannot raise it and the advice is about a tool
      that does not exist. If it is a DSL name, add it to the list in this test.
      """
    end
  end

  describe "every decision it cites" do
    test "is a decision that exists" do
      log = @root |> Path.join("spec/08-decisions.md") |> File.read!()

      numbers =
        ~r/^## D-(\d+) —/m |> Regex.scan(log) |> Enum.map(&Enum.at(&1, 1)) |> MapSet.new()

      assert MapSet.size(numbers) > 25

      cited = cited(~r/\(D-(\d+)\)/)

      assert cited != [], "usage-rules.md cites no decision, so this gate is reading nothing"

      missing = for n <- cited, not MapSet.member?(numbers, n), do: "D-#{n}"

      assert missing == [], """
      usage-rules.md cites #{Enum.join(missing, ", ")}, which `spec/08-decisions.md` does not
      contain. A citation that resolves to nothing reads as checkable and is not.
      """
    end
  end

  describe "every mix task it lists" do
    # The same rule `readme_entry_test.exs` applies to the README: the task list is held to
    # the generated golden, so a task added or removed moves it with nobody maintaining it.
    test "ships in the package" do
      packaged =
        @root
        |> Path.join("CLI_SURFACE.md")
        |> File.read!()
        |> then(&Regex.scan(~r/^## `(mix tla\.[\w.]+)` — ([^\n]*)/m, &1))
        |> Enum.reject(fn [_m, _task, detail] -> String.contains?(detail, "not packaged") end)
        |> Enum.map(fn [_m, task, _detail] -> task end)

      listed = cited(~r/`(mix tla\.[\w.]+)`/)

      assert listed != [], "usage-rules.md lists no task"

      internal = for task <- listed, task not in packaged, do: task

      assert internal == [],
             "usage-rules.md tells a reader to run #{Enum.join(internal, ", ")}, which the " <>
               "package does not ship"
    end
  end
end
