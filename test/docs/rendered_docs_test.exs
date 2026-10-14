defmodule ExTLA.RenderedDocsTest do
  @moduledoc """
  The documentation a user reads is about the library, not about how the library was built
  (#408, for #399).

  ## What was wrong

  The module and function docs ship in HexDocs, and about half the published modules carried
  maintainer narrative: which issue found a bug and how, which test pins a behaviour, what the
  differential corpus or the mutation harness measured, what a sibling project does. A user
  looking up an option met the project's history instead. Some docs still named modules from
  before the rename to `ExTLA`, and many sent the reader to specification files that are no
  longer published.

  ## What this holds

  The rendered text — every `@moduledoc`, `@doc` and `@typedoc` of a module the docs publish,
  read back with `Code.fetch_docs/1`, and `usage-rules.md` — against the marks that narrative
  leaves: an issue number, a pre-rename `TLA.` module, a path into `test/`, CI, the goldens, the
  corpus, mutation testing, and a reference to a `spec/` file the docs do not publish.

  Code comments are not read: they do not render, and the reasoning that lives there is for
  whoever edits the code.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # Each mark, and why a reader cannot use it. `spec/02` and `spec/07` are published (the DSL
  # reference and the examples), so only the other spec files are unreachable.
  @marks [
    {~r/(?<![\w\/])#\d{2,4}\b/, "an issue number"},
    {~r/(?<![\w.])TLA\.[A-Z]/, "a module name from before the rename to ExTLA"},
    {~r/(?<![\w])test\/[\w\/.]*/, "a path into this repository's tests"},
    {~r/\bCI\b/, "this repository's CI"},
    {~r/golden/i, "this repository's generated goldens"},
    {~r/\bcorpus\b/i, "this repository's differential corpus"},
    {~r/\bmutation (test|sweep|harness|catalogue|score)|\bmutants?\b/i,
     "this repository's mutation testing"},
    # By name, so a tutorial page (`00-introduction.md`) is not mistaken for one, and not
    # inside a link to the file on GitHub, which is where a maintainer page is meant to be read.
    {~r/(?<!blob\/main\/spec\/)\b0[0134568]-(prior-art|foundation|layer1-invariants|layer2-model-checker|layer3-conformance|architecture|decisions)\.md\b/,
     "a specification file the docs do not publish"},
    {~r/\bD-\d+\b/, "a decision-log number; the log is not published"}
  ]

  defp published_modules do
    {:ok, modules} = :application.get_key(:extla, :modules)

    for module <- modules,
        source = to_string(module.module_info(:compile)[:source]),
        String.starts_with?(source, Path.join(@root, "lib") <> "/"),
        {:docs_v1, _, _, _, moduledoc, _, _} = Code.fetch_docs(module),
        moduledoc != :hidden,
        do: module
  end

  # `{where, text}` for every rendered doc of a module: its moduledoc, and the docs of each
  # function, macro, type and callback that is not hidden.
  defp docs(module) do
    {:docs_v1, _, _, _, moduledoc, _, entries} = Code.fetch_docs(module)

    own = for %{"en" => text} <- [moduledoc], do: {inspect(module), text}

    entries =
      for {{kind, name, arity}, _, _, %{"en" => text}, _} <- entries,
          do: {"#{inspect(module)} #{kind} #{name}/#{arity}", text}

    own ++ entries
  end

  defp findings(where, text) do
    for {pattern, why} <- @marks,
        [match | _] <- Regex.scan(pattern, text),
        do: "#{where}: #{inspect(match)} — #{why}"
  end

  test "no published doc carries maintainer narrative" do
    found =
      for module <- published_modules(),
          {where, text} <- docs(module),
          finding <- findings(where, text),
          do: finding

    assert found == [], """
    #{length(found)} mark(s) of maintainer narrative in the published docs:

      #{Enum.join(Enum.uniq(found), "\n  ")}

    Say what the code does and why it behaves that way; leave how it was found and fixed to
    the commit history and code comments, which do not render.
    """
  end

  test "and neither does usage-rules.md" do
    text = @root |> Path.join("usage-rules.md") |> File.read!()
    found = findings("usage-rules.md", text)

    assert found == [], "usage-rules.md:\n  " <> Enum.join(found, "\n  ")
  end

  # The guides ship too, and #398 found the same narrative in them (#410). Two marks are left
  # out, because the guides teach putting a specification in the reader's own project: `CI`
  # is the reader's pipeline and `test/test_helper.exs` the reader's file, not this
  # repository's.
  test "and neither do the guides" do
    marks =
      Enum.reject(@marks, fn {_pattern, why} ->
        why in ["this repository's CI", "a path into this repository's tests"]
      end)

    # A bare ``` block is the tool's own output, held to what the tool prints by the guide
    # harness (#409); what it says is the tool's to fix, so it is not the prose's mark.
    #
    # Every fence is matched, language or not, so fences pair up in order; only the bare ones
    # are dropped. Matching bare fences alone paired a language block's closing fence with the
    # next opener.
    prose = fn path ->
      Regex.replace(~r/^```(\w*)\n.*?^```$/ms, File.read!(path), fn whole, lang ->
        if lang == "", do: "", else: whole
      end)
    end

    found =
      for path <- Path.wildcard(Path.join(@root, "guides/**/*.md")),
          relative = Path.relative_to(path, @root),
          {pattern, why} <- marks,
          [match | _] <- Regex.scan(pattern, prose.(path)),
          do: "#{relative}: #{inspect(match)} — #{why}"

    assert found == [], "the guides carry maintainer narrative:\n  " <> Enum.join(found, "\n  ")
  end

  # Anti-vacuity: the modules and their docs are really read, and each mark fires on what it
  # is for and not on what a user legitimately meets.
  test "the guard reads real docs with marks that fire" do
    assert length(published_modules()) > 40
    assert Enum.any?(docs(ExTLA.ModelChecker), fn {where, _} -> where =~ "run/2" end)

    assert findings("x", "fixed in #316") != []
    assert findings("x", "see TLA.Spec") != []
    assert findings("x", "pinned by test/ex_tla/foo_test.exs") != []
    assert findings("x", "`04-layer2-model-checker.md` §Symmetry") != []
    assert findings("x", "use ExTLA.Spec; see 02-dsl-semantics.md, TLA+ and spec_version") == []
    assert findings("x", "`x = x + 1` is not a mutation") == []
    assert findings("x", "the mutation sweep killed it") != []
  end
end
