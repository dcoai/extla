defmodule TLA.Spec.Version do
  @moduledoc """
  The **content version** of a spec item: 8 hex characters over its normalized definition
  (#1, scope item 3).

  A verification result is a claim about a specific version of a spec. `mix tla.check` passing
  on Monday says nothing about a spec whose guard was edited on Tuesday, and neither ExTLA nor
  TLC has any notion of "the spec changed since this result". A content version is what makes
  that staleness detectable — it is the whole basis of the ledger's `Fresh` column and of the
  `spec_version:` stamp.

  ## The algorithm is not ours to choose

  This delegates to `Surfex.SourceScan.definition_hash/1` — strip all AST metadata,
  `Macro.to_string`, sha256, first 8 hex — unchanged, deliberately. agentronic, extc and ExTLA
  all stamp rows with a "content version", and the value of that word depends on the three
  meaning the same thing by it. Two implementations that agree today diverge the first time
  one is improved.

  Metadata stripping is what makes the version a function of an item's STRUCTURE rather than
  its position: a blank line, a comment, or reindenting above an action leaves its version
  alone, while changing its body moves it. Without that, every item below an edit would
  restamp and the ledger would cry wolf until someone turned it off.

  ## Why this is a source scan and not a compile-time artifact

  #1's decision 1: no DSL change. The version is read from the spec's source, exactly as
  agentronic locates `§` sections and extc locates dispatch clauses — a spec that compiles
  today compiles unchanged, and nothing in the DSL has to carry a hash it cannot compute.

  Note what this is NOT built on. `TLA.Fingerprint` canonicalises *states* for the model
  checker's visited set — "are these two states the same". This asks "has this definition
  changed", which must be insensitive to formatting and position. Sharing an encoding between
  them would couple two questions that need opposite sensitivities.
  """

  # The DSL macros that declare an ITEM: something with a verdict of its own, and so a ledger
  # row. `variable`, `constant`, `init` and `fairness` are not items — but they are part of
  # the MODULE version `TLA.Spec.Hash.module_version/1` computes, because each changes what
  # the spec means (#194). An earlier comment here said there was "nothing for a verdict to
  # go stale against"; that was wrong for `init` and `constant … default:`, which change
  # the reachable set every invariant verdict is about.
  @kinds ~w(action invariant temporal action_property terminal)a

  @typedoc "A spec item's identity within its module."
  @type item :: {kind :: atom(), name :: atom()}

  @doc """
  Every versionable item declared by `module`, as `%{{kind, name} => version}`.

  Reads the module's source. Returns `%{}` when the source is not on disk — a released
  consumer, say — rather than raising: an absent source means "cannot version this", which the
  ledger renders as `—`, and that is a different fact from "this item has no version".
  """
  def versions(module) do
    case source(module) do
      nil -> %{}
      path -> path |> File.read!() |> scan()
    end
  end

  @doc """
  The version of one item, or `nil` when the module declares no such item.

      TLA.Spec.Version.version(Specs.Counter, :action, :increment)
  """
  def version(module, kind, name), do: module |> versions() |> Map.get({kind, name})

  @doc "Every versionable item in `source`, as `%{{kind, name} => version}`."
  def scan(source) do
    {_, items} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {kind, _meta, [name | _rest]} = node, acc when is_atom(name) ->
          if kind in @kinds and not reserved?(name),
            do: {node, [{{kind, name}, Surfex.SourceScan.definition_hash(node)} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Map.new(items)
  end

  @doc "The kinds of item that carry a version."
  def kinds, do: @kinds

  # `action` and friends take the item name first, but the same atom-headed shape appears in
  # ordinary code (`action(:foo)` calls, `@doc` bodies). An item name is a plain atom; a
  # leading `do:`/`else:` keyword is a block, not a name.
  defp reserved?(name), do: name in [:do, :else, :end, :catch, :rescue, :after]

  # The path the module was compiled from. Absent in a release, which `versions/1` treats as
  # "cannot version" rather than as an error.
  defp source(module) do
    with true <- Code.ensure_loaded?(module),
         info when is_list(info) <- module.module_info(:compile),
         path when is_list(path) <- info[:source],
         path = List.to_string(path),
         true <- File.exists?(path) do
      path
    else
      _ -> nil
    end
  end
end
