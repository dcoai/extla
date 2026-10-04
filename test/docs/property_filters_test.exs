defmodule ExTLA.PropertyFiltersTest do
  @moduledoc """
  A generator that filters says why (#341).

  A filter clause in `check all`/`gen all` is a bare expression after a generator. When it
  is false, the generator before it draws again, and gives up after ten rejections in a row
  with `StreamData.FilterTooNarrowError`. `StreamData.filter/3` does the same, with a
  longer leash. A filter that rejects often enough fails on a rare seed, as an unrelated
  red on whichever merge request draws it. `helpers_test.exs`'s out-of-domain property did
  that for three weeks: one run in about 12,000, CI seed 796610.

  Usually the fix is to generate the wanted values instead of filtering for them, and then
  this test has nothing to say. When a filter is the right tool (`valid_states/3` filters
  because the invariant is the only definition of the type), it carries a
  `# filter: <reason>` comment on the line above, so the choice is a decision a reviewer
  reads rather than an accident.

  Read from source, not from compiled modules: a filter clause is a macro argument and is
  gone by the time anything is compiled.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @trees ["lib", "ledger", "test"]

  # A generator (`<-`), a binding (`=`) or the options keyword list. Anything else is a filter.
  defp filter_clause?({:<-, _, _}), do: false
  defp filter_clause?({:=, _, _}), do: false
  defp filter_clause?(clause) when is_list(clause), do: not Keyword.keyword?(clause)
  defp filter_clause?(_clause), do: true

  @doc false
  def filters(source) do
    {_, found} =
      source
      |> Code.string_to_quoted!(columns: true)
      |> Macro.prewalk([], fn
        {macro, _, [{:all, _, clauses} | _]} = node, acc
        when macro in [:check, :gen] and is_list(clauses) ->
          lines = for c <- clauses, filter_clause?(c), do: {"#{macro} all filter", line(c)}
          {node, lines ++ acc}

        {{:., _, [{:__aliases__, _, [:StreamData]}, :filter]}, meta, _} = node, acc ->
          {node, [{"StreamData.filter", meta[:line]} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  # A clause's first line: the AST carries `line:` on any node that has metadata.
  defp line({_, meta, _}) when is_list(meta), do: meta[:line]
  defp line(_), do: nil

  @doc false
  def unjustified(source) do
    lines = String.split(source, "\n")

    for {kind, n} <- filters(source),
        not justified?(lines, n),
        do: {kind, n}
  end

  # `# filter: <reason>` on one of the two lines above, with a reason after the colon.
  defp justified?(lines, n) when is_integer(n) do
    lines
    |> Enum.slice(max(n - 3, 0), min(2, n - 1))
    |> Enum.any?(&Regex.match?(~r/#\s*filter:\s*\S/, &1))
  end

  defp justified?(_lines, nil), do: false

  defp sources do
    for tree <- @trees,
        path <- Path.wildcard(Path.join([@root, tree, "**", "*.{ex,exs}"])),
        do: path
  end

  test "every generator filter in lib/, ledger/ and test/ says why" do
    offenders =
      for path <- sources(),
          {kind, n} <- unjustified(File.read!(path)),
          do: "#{Path.relative_to(path, @root)}:#{n} (#{kind})"

    assert offenders == [], """
    #{length(offenders)} generator filter(s) with no `# filter: <reason>` above them:

      #{Enum.join(offenders, "\n  ")}

    Generate the values you want instead of filtering for them. A filter rejects into the
    generator before it, which raises StreamData.FilterTooNarrowError after ten rejections
    in a row: a rare-seed failure (#341). If filtering is genuinely right, say why on the
    line above: `# filter: <reason>`.
    """
  end

  describe "the reader itself" do
    test "finds a bare filter clause in check all, and not a generator, binding or option" do
      source = """
      check all(s <- list_of(integer()), n = length(s), m <- integer(), m != n, max_runs: 50) do
        :ok
      end
      """

      assert filters(source) == [{"check all filter", 1}]
    end

    test "finds a filter clause in gen all and a StreamData.filter call" do
      source = """
      gen all(x <- integer(),
              x > 0) do
        x
      end

      StreamData.filter(integer(), &(&1 > 0))
      """

      assert filters(source) == [{"gen all filter", 2}, {"StreamData.filter", 6}]
    end

    test "accepts a filter whose reason is written on the line above" do
      source = """
      check all(x <- integer(),
                # filter: rejects one value in 2^32; the leash never comes close
                x != 7) do
        :ok
      end
      """

      assert filters(source) != []
      assert unjustified(source) == []
    end

    test "and refuses one with an empty reason" do
      source = """
      check all(x <- integer(),
                # filter:
                x != 7) do
        :ok
      end
      """

      assert unjustified(source) == [{"check all filter", 3}]
    end

    # Anti-vacuity: the walk must reach the trees, or an empty offender list passes above.
    test "and the walk reads the real trees, including the generator this guard was written for" do
      paths = Enum.map(sources(), &Path.relative_to(&1, @root))

      assert "test/ex_tla/spec/helpers_test.exs" in paths
      assert "lib/ex_tla/invariant/test.ex" in paths
      assert filters(File.read!(Path.join(@root, "lib/ex_tla/invariant/test.ex"))) != []
    end
  end
end
