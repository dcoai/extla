defmodule TLA.Spec.Hash do
  @moduledoc """
  Content versions for spec items and for a spec as a whole (#67).

  A verification result, and a refinement mapping, are claims about a *specific version* of a
  spec. `Refinement.abstract/1` is written against a set of spec variables; rename one or
  change an action's post-state and `abstract_action/1` still compiles and still returns an
  action name. The mapping is now wrong, and the only symptom is `:diverged` at runtime, on a
  path that may not be exercised for months (#1, failure mode 2). A content version turns that
  into a compile error.

  ## Why this ships, when `TLA.Spec.Version` already exists

  `TLA.Spec.Version` lives in dev/test-only `ledger/` and delegates to
  `Surfex.SourceScan.definition_hash/1`. That is right for ExTLA's own tooling and **wrong for
  this**: `use TLA.GenServer, spec_version: …` is written by a CONSUMER, so the check runs at
  their compile — and surfex is `only: [:dev, :test]`, which is not transitive. A check that
  called it would fail for exactly the people it protects.

  So the algorithm is implemented here and ships. It is written down rather than shared:
  **strip all AST metadata, `Macro.to_string`, sha256, first 8 hex.**

  **The agreement is tested, not assumed.** `TLA.Spec.HashTest` asserts this module and
  `Surfex.SourceScan.definition_hash/1` produce identical output for every item in the corpus.
  If that test is deleted or excluded from the default run, the decision recorded on #67 is
  void — two implementations that agree only because both were written from the same paragraph
  will drift, and the symptom is a stamp that is wrong for no visible reason.

  ## Metadata stripping is the point

  A version is a function of an item's STRUCTURE, not its position. A blank line, a comment or
  reindenting above an action leaves its version alone; changing its body moves it. Without
  that, an edit near the top of a file would restamp everything below it and every stamp in
  the file would go stale at once — which teaches authors to restamp without reading, defeating
  the mechanism.
  """

  @kinds ~w(action invariant temporal action_property terminal)a
  @block_keywords [:do, :else, :end, :catch, :rescue, :after]

  @typedoc "A spec item's identity within its module."
  @type item :: {kind :: atom(), name :: atom()}

  @doc """
  The content version of a quoted node or a source binary: 8 lowercase hex characters.
  """
  @spec definition_hash(Macro.t() | String.t()) :: String.t()
  def definition_hash(source) when is_binary(source),
    do: source |> Code.string_to_quoted!() |> definition_hash()

  def definition_hash(ast) do
    ast
    |> strip_meta()
    |> Macro.to_string()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  # A `{form, meta, args}` node is a call; a 2-tuple is an AST literal pair; a list is an
  # argument list; anything else is a leaf carrying no metadata.
  defp strip_meta({form, _meta, args}), do: {strip_meta(form), [], strip_meta(args)}
  defp strip_meta(list) when is_list(list), do: Enum.map(list, &strip_meta/1)
  defp strip_meta({a, b}), do: {strip_meta(a), strip_meta(b)}
  defp strip_meta(leaf), do: leaf

  @doc "Every versionable item declared anywhere in `source`."
  @spec scan(String.t()) :: %{item() => String.t()}
  def scan(source), do: source |> Code.string_to_quoted!() |> scan_ast()

  @doc """
  Every versionable item `module` declares within `source`.

  Scoped to that module's own `defmodule`, NOT the whole file. One file routinely holds several
  specs — `TLA.Conformance.Counter.Spec` and `.BuggySpec` are neighbours — and a file-wide scan
  gives them the same version, so editing one would mark every mapping stamped against the
  other stale. A stamp going stale for something that did not change is the same "cries wolf"
  failure position-insensitivity exists to prevent, arriving by a different route.
  """
  @spec scan(String.t(), module()) :: %{item() => String.t()}
  def scan(source, module) do
    case source |> Code.string_to_quoted!() |> module_body(Module.split(module), []) do
      nil -> %{}
      body -> scan_ast(body)
    end
  end

  @doc """
  Every versionable item `module` declares, or `%{}` when its source is not on disk.

  An absent source means "cannot version this", a different fact from "this has no version": a
  spec that arrived inside a released package has a version nobody here can compute, and
  callers render that differently from an item with none.
  """
  @spec item_versions(module()) :: %{item() => String.t()}
  def item_versions(module) do
    case source(module) do
      nil -> %{}
      path -> path |> File.read!() |> scan(module)
    end
  end

  @doc """
  The version of `module` as a whole: 8 hex over its items' versions, in name order.

  This is what a refinement mapping stamps. A mapping is written against the spec's variables
  and actions *together*, so the question it must answer is "has anything I depended on
  moved", not "has this one action moved" — and a per-item stamp on a mapping would be a list
  nobody maintains.

  Derived from the item versions rather than the file's bytes, so it inherits their
  position-insensitivity: reformatting a spec does not invalidate every mapping written against
  it. Returns `nil` when the spec's source is not on disk.
  """
  @spec module_version(module()) :: String.t() | nil
  def module_version(module) do
    case item_versions(module) do
      empty when empty == %{} ->
        nil

      versions ->
        versions
        |> Enum.sort()
        |> Enum.map_join("\n", fn {{kind, name}, version} -> "#{kind} #{name} #{version}" end)
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 8)
    end
  end

  @doc "The kinds of item that carry a version."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  defp scan_ast(ast) do
    {_, items} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [name | _rest]} = node, acc when is_atom(name) ->
          if kind in @kinds and name not in @block_keywords,
            do: {node, [{{kind, name}, definition_hash(node)} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Map.new(items)
  end

  # The body of the `defmodule` naming `segments`, at any nesting depth. Elixir permits both
  # `defmodule A.B do` and `defmodule A do defmodule B do`, and both must resolve, so the walk
  # carries the enclosing prefix rather than matching an alias literally.
  defp module_body({:defmodule, _, [{:__aliases__, _, alias_segs}, [do: body]]}, segments, prefix) do
    here = prefix ++ Enum.map(alias_segs, &Atom.to_string/1)

    if here == segments, do: body, else: module_body(body, segments, here)
  end

  defp module_body({:__block__, _, nodes}, segments, prefix),
    do: Enum.find_value(nodes, &module_body(&1, segments, prefix))

  defp module_body(nodes, segments, prefix) when is_list(nodes),
    do: Enum.find_value(nodes, &module_body(&1, segments, prefix))

  defp module_body(_other, _segments, _prefix), do: nil

  defp source(module) do
    with true <- Code.ensure_loaded?(module),
         path when is_list(path) <- module.module_info(:compile)[:source],
         path = List.to_string(path),
         true <- File.exists?(path) do
      path
    else
      _ -> nil
    end
  end
end
