defmodule ExTLA.SpecDecisionsTest do
  @moduledoc """
  Every decision in `spec/08-decisions.md` names the test that would fail if it were
  reversed — or says, in as many words, that nothing would (#176).

  ## Why a decision needs a pin

  `08` is where this project records *why* it is shaped as it is, and the entries are cited
  from `lib/` in eight places as reasons. Nothing connected a decision to the code that
  honours it, and the cost showed up twice: D-18 said every declaration macro takes `desc:`
  while `dsl.ex` refused it on four of them — the same file citing the decision two hundred
  lines from where it contradicted it — and the log itself **stopped being written on
  2026-08-31**, while fifteen decisions were made in commit messages over the next three
  weeks.

  A `**Pinned by:**` line is the connection. Where a decision genuinely cannot be pinned —
  D-8 is about build order, D-13 is a list of non-goals — it says `nothing — <why>`, which
  is #156's rule: "unguarded by decision" and "unguarded by oversight" read identically in
  an empty space, and only one of them is acceptable.

  ## What this checks

  Every decision has a pin; every test a pin names exists; the numbering is contiguous and
  unique, so a backfill cannot silently collide with an entry someone else added. And the
  readings are asserted on **what parsed**, not on what matched — #164's layer 2 was green
  while comparing nothing, because its reader matched every row and extracted from none.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @decisions Path.join(@root, "spec/08-decisions.md")

  setup_all do
    %{entries: entries()}
  end

  describe "every decision" do
    test "carries a Pinned by: line", %{entries: entries} do
      unpinned = for e <- entries, e.pin == nil, do: "D-#{e.number} — #{e.title}"

      assert unpinned == [], """
      #{length(unpinned)} decisions carry no `**Pinned by:**` line:

        #{Enum.join(unpinned, "\n  ")}

      A decision nothing pins is one the code can quietly stop honouring — which is what
      happened to D-18, contradicted by the same file that cited it. If nothing can pin it,
      say `**Pinned by:** nothing — <why>`; that is a different claim from silence.
      """
    end

    test "and names a test that exists, where it names one", %{entries: entries} do
      known = test_files()

      missing =
        for e <- entries,
            e.pin != nil,
            path <- cited_paths(e.pin),
            path not in known,
            do: "D-#{e.number} cites #{path}"

      assert missing == [], """
      #{length(missing)} decisions cite a test file that is not in the tree:

        #{Enum.join(missing, "\n  ")}

      A pin naming a file nobody can open is worse than no pin: it reads as a check that
      exists. Cite the file that holds the assertion, or write `nothing — <why>`.
      """
    end

    test "and a quoted test name, where it quotes one, is a test that exists", %{entries: entries} do
      sources = test_sources()

      missing =
        for e <- entries,
            e.pin != nil,
            name <- quoted_names(e.pin),
            not Enum.any?(sources, &String.contains?(&1, name)),
            do: ~s(D-#{e.number} cites "#{name}")

      assert missing == [], """
      #{length(missing)} decisions quote a test name that no file contains:

        #{Enum.join(missing, "\n  ")}

      The name may have been reworded — in which case the pin follows it, because a pin is
      only worth having while it resolves.
      """
    end
  end

  describe "the numbering" do
    test "is contiguous from 1, so a backfill cannot collide", %{entries: entries} do
      numbers = Enum.map(entries, & &1.number)

      assert numbers == Enum.to_list(1..length(numbers)),
             "D-numbers are #{inspect(numbers)}; a gap or a repeat means two decisions share " <>
               "a name, and every citation of that name becomes ambiguous"
    end
  end

  describe "the reading itself" do
    # #164's layer 2 matched every row it was given and extracted a key set from none, so it
    # compared nothing and reported green — on exactly the findings it existed for. A count
    # of decisions found would not have caught that; a count of PINS PARSED does.
    test "finds decisions, and parses pins out of them", %{entries: entries} do
      assert length(entries) > 25, "only #{length(entries)} decisions parsed; the reader is wrong"

      pinned = Enum.count(entries, &(&1.pin != nil))
      assert pinned == length(entries)

      citing = Enum.count(entries, &(&1.pin != nil and cited_paths(&1.pin) != []))

      assert citing > 20,
             "only #{citing} pins yielded a file path; the pin parser is reading nothing and " <>
               "every assertion above is vacuous"
    end

    test "and the tree it checks against is non-empty" do
      assert length(test_files()) > 50
      assert length(test_sources()) > 50
    end
  end

  # ── The readings ────────────────────────────────────────────────────────────

  # One entry per `## D-N — title`, with everything up to the next `## D-` heading.
  defp entries do
    @decisions
    |> File.read!()
    |> String.split(~r/^## D-/m)
    |> Enum.drop(1)
    |> Enum.map(fn chunk ->
      [heading | _] = String.split(chunk, "\n", parts: 2)
      [number, title] = String.split(heading, " — ", parts: 2)

      %{
        number: String.to_integer(number),
        title: String.trim(title),
        pin: pin(chunk)
      }
    end)
  end

  defp pin(chunk) do
    case Regex.run(~r/\*\*Pinned by:\*\*(.+?)(?:\n\n|\n---)/s, chunk) do
      [_match, text] -> String.trim(text)
      nil -> nil
    end
  end

  # `test/…_test.exs` paths named in a pin. A pin that cites no file is one that says
  # `nothing — …`, and the assertion above lets that through deliberately.
  defp cited_paths(pin) do
    ~r/`(test\/[\w\/.]+\.exs)`/
    |> Regex.scan(pin)
    |> Enum.map(fn [_match, path] -> path end)
  end

  # A quoted test name, with its line wrapping undone. A pin is prose in a markdown file and
  # a long test name wraps across lines there, while the test declares it on one — so both
  # sides are normalised before they are compared. Comparing them raw found eight "missing"
  # tests that all exist, which is a gate failing on its own formatting.
  defp quoted_names(pin) do
    ~r/"([^"]{8,})"/
    |> Regex.scan(pin)
    |> Enum.map(fn [_match, name] -> squeeze(name) end)
  end

  defp squeeze(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp test_files do
    @root
    |> Path.join("test/**/*.exs")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @root))
  end

  defp test_sources do
    @root
    |> Path.join("test/**/*.exs")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> File.read!() |> squeeze()))
  end
end
