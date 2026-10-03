defmodule ExTLA.Diagnostics do
  @moduledoc """
  Every compile-time diagnostic the DSL raises, as a surfex golden, `DIAGNOSTICS.md`
  (#270, #273).

  ## Why this needed a change to the code first

  `02-dsl-semantics.md` §7 tabulates these under a preamble promising that a spec violating
  any rule does not compile. The table was nineteen rows short and one row described a check
  that runs at runtime — and **nothing could have caught either**, because a row's first
  column was a name its author chose and the code carried no identifier to match it against.
  There was nothing to join on.

  `ExTLA.Spec.CompileError` now carries a `kind`, every raise site passes one, and this golden
  lists them. `test/docs/spec_diagnostics_test.exs` then holds four sets to each other: the
  kinds the code raises, the kinds this golden renders, the kinds §7 tabulates, and the kinds
  `diagnostics_test.exs` asserts on. Three of those four are derived from source; the fourth
  is the document, which is the one that was wrong.

  ## What a row is

  One row per raise site — not per kind. Two sites may share a kind where the same rule is
  broken in two syntactic positions (`let` without a binding, inside an action and inside a
  predicate), and a golden that collapsed them would hide the second site from a reader
  checking coverage. `Kind` is the identifier, `Problem` the first line of the message, and
  `Locus` the file the site is in.

  ## The two shapes a site takes

  A module with many diagnostics funnels them through a private `bad!/5` whose first argument
  is the kind; a module with a few calls `ExTLA.Spec.CompileError.raise!/1` with `kind:` among
  its options. Both are read here, from the AST, so neither shape can hide a site.
  """

  alias Surfex.SourceScan

  @type site :: %{
          kind: atom(),
          problem: String.t(),
          path: String.t(),
          line: pos_integer()
        }

  @doc "Every diagnostic site under `lib/ex_tla/spec`, in kind order then file order."
  def run(root \\ SourceScan.project_root("mix.exs")) do
    root
    |> sources()
    |> Enum.flat_map(&scan_file(&1, root))
    |> Enum.sort_by(&{&1.kind, &1.path, &1.line})
  end

  @doc "The sources a diagnostic can be raised from: the DSL's compile-time front end."
  def sources(root) do
    [
      Path.join(root, "lib/ex_tla/spec.ex")
      | Path.wildcard(Path.join(root, "lib/ex_tla/spec/*.ex"))
    ]
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  @doc "The diagnostic sites one source file holds, with `path` relative to `root`."
  def scan_file(path, root) do
    relative = Path.relative_to(path, root)

    path
    |> File.read!()
    |> Code.string_to_quoted!(file: path)
    |> sites(relative)
  end

  defp sites(ast, path) do
    {_, found} =
      Macro.prewalk(ast, [], fn node, acc ->
        case site(node, path) do
          nil -> {node, acc}
          site -> {node, [site | acc]}
        end
      end)

    Enum.reverse(found)
  end

  # `bad!(:kind, ctx, meta, "problem", …)` — the funnel shape.
  defp site({:bad!, meta, [kind | rest]}, path) when is_atom(kind) and is_list(rest) do
    %{kind: kind, problem: problem_of(Enum.at(rest, 2)), path: path, line: line(meta)}
  end

  # `ExTLA.Spec.CompileError.raise!(kind: :kind, …, problem: …)` — the direct shape.
  #
  # A `kind:` that is not a literal atom is the funnel itself forwarding its own parameter
  # (`kind: kind`), not a diagnostic: the sites it raises for are its callers, and they are
  # listed above. Counting it would put a row in the golden that no spec can ever produce.
  defp site({{:., _, [{:__aliases__, _, aliases}, :raise!]}, meta, [options]}, path) do
    with :CompileError <- List.last(aliases),
         true <- Keyword.keyword?(options),
         kind when is_atom(kind) <- Keyword.fetch!(options, :kind) do
      %{
        kind: kind,
        problem: problem_of(Keyword.get(options, :problem)),
        path: path,
        line: line(meta)
      }
    else
      _not_a_site -> nil
    end
  end

  defp site(_node, _path), do: nil

  defp line(meta), do: Keyword.get(meta, :line, 0)

  # The first line of the problem, with every interpolation and every concatenated
  # expression standing as `…`. A message's literal skeleton is what a reader matches a §7
  # row against; the values it splices in are per-spec and are not part of the diagnostic's
  # identity.
  defp problem_of(nil), do: ""
  defp problem_of(text) when is_binary(text), do: first_line(text)

  defp problem_of({:<<>>, _, parts}) do
    parts
    |> Enum.map_join(fn
      part when is_binary(part) -> part
      _interpolation -> "…"
    end)
    |> first_line()
  end

  defp problem_of({:<>, _, [left, _right]}), do: problem_of(left) <> "…"
  defp problem_of(_other), do: "…"

  defp first_line(text) do
    text |> String.split("\n", parts: 2) |> hd() |> String.trim()
  end

  # ── Rendering ───────────────────────────────────────────────────────────────

  @doc "The `Surfex.Golden` spec for `DIAGNOSTICS.md` — data only."
  def golden_spec(sites) do
    kinds = sites |> Enum.map(& &1.kind) |> Enum.uniq()

    %{
      name: "DIAGNOSTICS.md",
      purpose:
        "Every compile-time diagnostic the DSL raises, by kind. Held against " <>
          "02-dsl-semantics.md §7 by spec_diagnostics_test.",
      task: "tla.diagnostics",
      gate: "surface-drift",
      hardness: :hard,
      prose: prose(),
      stats: [
        Surfex.Golden.stat(
          "#{length(kinds)} kinds · #{length(sites)} sites",
          [{"files", sites |> Enum.map(& &1.path) |> Enum.uniq() |> length()}]
        )
      ],
      columns: ["Kind", "Problem", "Locus"],
      rows: Enum.map(sites, &row/1)
    }
  end

  defp prose do
    """
    A row is one raise site, not one kind: the same rule broken in two syntactic positions is
    two sites, and collapsing them would hide the second from a reader checking coverage.
    `Problem` is the first line of the message with each interpolated value shown as `…`,
    because a message's literal skeleton is its identity and the values it splices are
    per-spec. §7's table lists the same kinds; `spec_diagnostics_test.exs` holds the two to
    each other, and to the kinds the tests assert on.\
    """
  end

  defp row(site) do
    %{
      "Kind" => {:atom, site.kind},
      "Problem" => {:raw, escape(site.problem)},
      "Locus" => {:locus, site.path, site.line}
    }
  end

  defp escape(text), do: text |> String.replace("|", "\\|") |> String.replace("\"", "'")

  @doc "Render the golden."
  def render(sites), do: sites |> golden_spec() |> Surfex.Golden.render()

  @doc "Every kind the code raises — the set §7's table and the tests are held to."
  def kinds(sites \\ run()), do: sites |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()
end
