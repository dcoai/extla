defmodule ExTLA.SpecDiagnosticsTest do
  @moduledoc """
  `02-dsl-semantics.md` §7's table, the diagnostics the DSL raises, and the ones the tests
  assert on — held to each other (#273, from #270).

  §7 sits under a preamble promising that a spec violating any rule does not compile, and
  tabulates the diagnostics that enforce it. Nothing held the table to the code and nothing
  could: a row's first column was a name its author gave it, and `ExTLA.Spec.CompileError`
  carried no identifier to match against. There was no join key. The table was twenty-eight
  kinds short, and one of its rows described §6's term check, which runs at runtime — so the
  preamble was false for exactly that row, which is the class this project keeps finding.

  `kind` is the join key. Three of the four sets below are derived from source, and the
  fourth is the document:

    * **raised** — every `kind` at a raise site, from `ExTLA.Diagnostics`' scan of the AST;
    * **rendered** — `DIAGNOSTICS.md`, the golden the `surface-drift` job gates;
    * **tabulated** — §7's first column;
    * **tested** — every kind `diagnostics_test.exs` asserts on.

  The first three must be equal. The fourth must be a subset, and the gap is named rather
  than tolerated silently: a diagnostic with no test is a message nobody has read back.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @spec_file Path.join(@root, "spec/02-dsl-semantics.md")
  @golden Path.join(@root, "DIAGNOSTICS.md")
  @diagnostics_test Path.join(@root, "test/ex_tla/spec/diagnostics_test.exs")

  setup_all do
    %{raised: ExTLA.Diagnostics.kinds(ExTLA.Diagnostics.run(@root))}
  end

  describe "the three derived sets" do
    test "every kind the DSL raises is in §7's table", %{raised: raised} do
      missing = raised -- tabulated()

      assert missing == [], """
      #{length(missing)} diagnostics the DSL raises are not in §7's table:

        #{Enum.map_join(missing, "\n  ", &inspect/1)}

      §7 promises that a spec violating any rule does not compile, and its table is what a
      reader checks that against. A diagnostic missing from it is a rule the document does
      not mention. Add a row, keyed by the kind.
      """
    end

    test "every row in §7's table is a kind the DSL raises", %{raised: raised} do
      extra = tabulated() -- raised

      assert extra == [], """
      #{length(extra)} rows in §7's table name a diagnostic nothing raises:

        #{Enum.map_join(extra, "\n  ", &inspect/1)}

      Either the kind was renamed and the row was not, or the row describes a check that is
      not a compile-time diagnostic — §6's term check was such a row until #273, under a
      preamble that made it a false claim.
      """
    end

    test "the golden lists exactly what the code raises", %{raised: raised} do
      assert golden_kinds() == raised
    end
  end

  describe "the tests" do
    # A subset, not an equality: a diagnostic may be reached by more than one input and a
    # test names the kind once. What must not happen is a diagnostic nobody ever read back.
    test "assert on kinds that exist", %{raised: raised} do
      unknown = tested() -- raised

      assert unknown == [],
             "diagnostics_test.exs asserts on #{inspect(unknown)}, which nothing raises"
    end

    test "and the diagnostics with no test are named here rather than merely absent",
         %{raised: raised} do
      untested = raised -- tested()

      # 17 when this gate was written (#273): 33 of the 50 kinds are pinned by a fixture.
      # The backlog is recorded rather than gated to zero, for the reason `mix tla.coverage`
      # gives about NOTHING entries — a gate that failed on gaps could only be satisfied by
      # deleting rows. What is gated is that it cannot GROW: a new diagnostic arrives with a
      # test, or this number goes up and someone has to say why.
      assert length(untested) <= 17, """
      #{length(untested)} diagnostics have no test asserting their kind, which is more than
      the 17 this gate was written with:

        #{Enum.map_join(untested, "\n  ", &inspect/1)}

      A diagnostic with no test is a message nobody has read back — and message quality is
      §7's stated deliverable, not a nicety. Add a fixture to diagnostics_test.exs, or lower
      this bound with the reason.
      """
    end
  end

  describe "the parsers themselves" do
    # Each of the three readings below is a `grep` over a document that people edit. A
    # reading that silently returns nothing turns every assertion above into `assert [] == []`,
    # which is the vacuity this project keeps finding in its own gates.
    test "§7's table yields rows" do
      assert length(tabulated()) > 40
    end

    test "the golden yields rows" do
      assert length(golden_kinds()) > 40
    end

    test "the diagnostics test yields kinds" do
      assert length(tested()) > 5
    end
  end

  # ── The four readings ───────────────────────────────────────────────────────

  # §7's first column, from the `## 7.` heading to the next `## ` heading, so a table
  # elsewhere in the file cannot leak in.
  defp tabulated do
    [_before, section] =
      String.split(File.read!(@spec_file), "## 7. Compile-time validation", parts: 2)

    [section, _after] = String.split(section, "\n## ", parts: 2)

    ~r/^\| `([a-z_]+)` \|/m
    |> Regex.scan(section)
    |> Enum.map(fn [_row, kind] -> String.to_atom(kind) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp golden_kinds do
    ~r/^\| `:([a-z_]+)` \|/m
    |> Regex.scan(File.read!(@golden))
    |> Enum.map(fn [_row, kind] -> String.to_atom(kind) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The kind each `refuse(body, :kind)` pins, from the AST rather than a regex: the calls
  # are multi-line, the kind sits on its own line, and a line-oriented reading of them found
  # three of forty-seven — a parser that silently under-reads is what makes a gate vacuous,
  # which is the failure this file exists to prevent, so it must not be one.
  defp tested do
    @diagnostics_test
    |> File.read!()
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {:refuse, _, [_body, kind]} = node, acc when is_atom(kind) -> {node, [kind | acc]}
      node, acc -> {node, acc}
    end)
    |> elem(1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
