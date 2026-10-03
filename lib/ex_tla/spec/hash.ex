defmodule ExTLA.Spec.Hash do
  @moduledoc """
  Content versions for spec items and for a spec as a whole (#67).

  A verification result, and a refinement mapping, are claims about a *specific version* of a
  spec. `Refinement.abstract/1` is written against a set of spec variables; rename one or
  change an action's post-state and `abstract_action/1` still compiles and still returns an
  action name. The mapping is now wrong, and the only symptom is `:diverged` at runtime, on a
  path that may not be exercised for months (#1, failure mode 2). A content version turns that
  into a compile error.

  ## Why the algorithm is implemented here rather than taken from surfex

  The algorithm is `Surfex.SourceScan.definition_hash/1`'s — agentronic, extc and ExTLA all
  stamp rows with a "content version", and the value of that word depends on the three meaning
  the same thing by it. But `use ExTLA.GenServer, spec_version: …` is written by a CONSUMER, so
  the check runs at their compile — and surfex is `only: [:dev, :test]`, which is not
  transitive. A check that called it would fail for exactly the people it protects.

  So the algorithm is implemented here and ships. It is written down rather than shared:
  **strip all AST metadata, `Macro.to_string`, sha256, first 8 hex.**

  **The agreement is tested, not assumed.** `ExTLA.Spec.HashTest` asserts this module and
  `Surfex.SourceScan.definition_hash/1` produce identical output for every item in the corpus.
  If that test is deleted or excluded from the default run, the decision recorded on #67 is
  void — two implementations that agree only because both were written from the same paragraph
  will drift, and the symptom is a stamp that is wrong for no visible reason.

  This is also the ledger's `Version` column. There used to be a second module for that,
  `ExTLA.Spec.Version` in `ledger/`, delegating to surfex and scanning the whole *file* — so
  every `tick` in `test/support/specs.ex` showed the last one's hash, seven rows sharing one
  cell (#201). One implementation, module-scoped, rather than a test proving two agree.

  ## Metadata stripping is the point

  A version is a function of an item's STRUCTURE, not its position. A blank line, a comment or
  reindenting above an action leaves its version alone; changing its body moves it. Without
  that, an edit near the top of a file would restamp everything below it and every stamp in
  the file would go stale at once — which teaches authors to restamp without reading, defeating
  the mechanism.
  """

  # The item kinds: declarations that carry a verdict of their own, so each is a ledger row
  # and each has a stated route to TLC in the differential corpus.
  @kinds ~w(action invariant temporal action_property terminal)a

  # The other declarations. None has a verdict, so none is a row — but every one of them
  # changes what the spec MEANS, and so every one is part of the module version (#194).
  # `init` and `constant … default:` change the reachable set every invariant verdict is
  # about; a `variable`'s `type:` changes what the type check admits; `fairness` changes
  # which behaviours count, and with them every liveness verdict.
  @named_declarations ~w(variable constant)a
  @anonymous_declarations ~w(init fairness)a
  @block_keywords [:do, :else, :end, :catch, :rescue, :after]

  @typedoc "A spec item's identity within its module."
  @type item :: {kind :: atom(), name :: atom()}

  @doc """
  The content version of a quoted node or a source binary: 8 lowercase hex characters.
  """
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
  def scan(source), do: source |> Code.string_to_quoted!() |> scan_ast()

  @doc """
  Every versionable item `module` declares within `source`.

  Scoped to that module's own `defmodule`, NOT the whole file. One file routinely holds several
  specs — `ExTLA.Conformance.Counter.Spec` and `.BuggySpec` are neighbours — and a file-wide scan
  gives them the same version, so editing one would mark every mapping stamped against the
  other stale. A stamp going stale for something that did not change is the same "cries wolf"
  failure position-insensitivity exists to prevent, arriving by a different route.
  """
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
  def item_versions(module) do
    case source(module) do
      nil -> %{}
      path -> path |> File.read!() |> scan(module)
    end
  end

  @doc """
  The version of `module` as a whole: 8 hex over every declaration it makes.

  This is what a refinement mapping stamps. A mapping is written against the spec's variables
  and actions *together*, so the question it must answer is "has anything I depended on
  moved", not "has this one action moved" — and a per-item stamp on a mapping would be a list
  nobody maintains.

  ## Every declaration, not only the items

  The first version hashed the item kinds alone, on the reasoning that `variable`, `constant`,
  `init` and `fairness` are "not independently verified, so there is nothing for a verdict to
  go stale against". That was wrong about what the number is for (#194). A stamp does not
  name a verdict; it names *the specification* somebody re-read a mapping against, and
  changing an `init` value, a `constant`'s default or a variable's `type:` produced the
  identical version — so a mapping stayed fresh across a new variable its `abstract/1` could
  not produce, which is the exact staleness the stamp exists to catch.

  `fairness` is in for the same reason, and it was the one worth arguing: it changes liveness
  verdicts and nothing a mapping reads. But the version is one number naming one
  specification, and a spec under strong fairness admits a different set of behaviours from
  the same spec under weak. Keeping fairness out would mean a "mapping-relevant" version
  distinct from a "liveness-relevant" one — two stamps, where the second would be maintained
  by nobody — and the ledger's `Fresh` column, which sits beside temporal rows, rests on this
  same number.

  What is *not* in: `@moduledoc`, `@doc`, `use ExTLA.Spec`, and any ordinary `def` in the
  module. A helper function called from an action body would change meaning without moving
  the version; no spec in the project has one, and hashing the whole module body instead
  would restamp every mapping on a documentation edit, which teaches authors to restamp
  without reading.

  Derived from declaration hashes rather than the file's bytes, so it inherits their
  position-insensitivity: reformatting a spec does not invalidate every mapping written against
  it. Returns `nil` when the spec's source is not on disk.
  """
  def module_version(module) do
    case source(module) do
      nil -> nil
      path -> path |> File.read!() |> module_version(module)
    end
  end

  @doc """
  The version of `module` as declared in `source`, or `nil` when `source` does not define it.

  `Mix.Tasks.Tla.Stamp` reads specs from disk by path rather than through the loaded module,
  and used to derive the version by its own copy of the formula. One formula, here, is what
  keeps the compile-time check and the stamp task from disagreeing about a spec's version.
  """
  def module_version(source, module) when is_binary(source) do
    case source |> Code.string_to_quoted!() |> module_body(Module.split(module), []) do
      nil ->
        nil

      body ->
        body
        |> declaration_lines()
        |> Enum.sort()
        |> Enum.join("\n")
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 8)
    end
  end

  # One line per declaration, sorted by the caller. Items and named declarations carry their
  # name; `init` and `fairness` have none, and a spec may declare `fairness(:weak, …)` more
  # than once, which is why this is a list of lines and not a map keyed by identity.
  defp declaration_lines(body) do
    {_, lines} =
      Macro.prewalk(body, [], fn
        {kind, _meta, [name | _]} = node, acc
        when kind in @kinds and is_atom(name) and name not in @block_keywords ->
          {node, ["#{kind} #{name} #{definition_hash(node)}" | acc]}

        {kind, _meta, [name | _]} = node, acc
        when kind in @named_declarations and is_atom(name) and name not in @block_keywords ->
          {node, ["#{kind} #{name} #{definition_hash(node)}" | acc]}

        {kind, _meta, args} = node, acc
        when kind in @anonymous_declarations and is_list(args) ->
          {node, ["#{kind} #{definition_hash(node)}" | acc]}

        node, acc ->
          {node, acc}
      end)

    lines
  end

  @doc "The kinds of item that carry a version of their own — the ledger's rows."
  def kinds, do: @kinds

  @doc """
  The declarations that carry no verdict but are part of the module version.

  Together with `kinds/0`, every declaration form the DSL has. A macro added to the DSL and
  to neither list would leave the module version blind to it, which is the defect #194
  closed; `ExTLA.Spec.HashTest` compares the union against the DSL's own macros.
  """
  def declarations, do: @named_declarations ++ @anonymous_declarations

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
  #
  # Only a LITERAL name can be matched from source. `defmodule __MODULE__.Spec` puts an
  # `{:__MODULE__, _, _}` node among the segments; that used to reach `Atom.to_string/1` and
  # crash the scanner from inside a consumer's compile (#210). A computed name is not a scan
  # failure, it is a module this scanner cannot version — `nil`, which `check_stamp!`
  # reports as unverifiable and says why.
  defp module_body({:defmodule, _, [{:__aliases__, _, alias_segs}, [do: body]]}, segments, prefix) do
    if Enum.all?(alias_segs, &is_atom/1) do
      here = prefix ++ Enum.map(alias_segs, &Atom.to_string/1)
      if here == segments, do: body, else: module_body(body, segments, here)
    else
      nil
    end
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
