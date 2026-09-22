defmodule TLA.ApiSurface do
  @moduledoc """
  What `lib/` declares — every public function head and every named type — as a surfex
  golden, `API_SURFACE.md` (#270, #271).

  ## Why it is scanned from source and not read from the compiled modules

  The specification's API blocks (`spec/01–05`) publish signatures the code does not have —
  seventeen of them, plus seven type shapes, on the day #153 was filed — and nothing compared
  the two. A comparison needs a side that is derived from the code and readable in a diff. This
  golden is that side: `Surfex.SourceScan` reads the uncompiled AST, so the gate runs before and
  independently of the build, and a signature change shows up as a changed row in the merge
  request rather than as a stale block in a document nobody reopened. #164 compares the spec's
  blocks to these rows; this module only says what the code declares.

  Scanning source also means the golden lists exactly what a reader of `lib/` would find: a
  `def` in a file. Functions a macro generates into the module — `__struct__/1`, the `__tla_*`
  accessors `use TLA.Spec` emits — are not declared here and are not rows.

  ## What a row is

  One row per `{module, name, arity}` and one per named type. A head with defaults is one
  declaration and several arities, so `at(f, key, default \\\\ nil)` is two rows sharing one
  version. The version is `definition_hash/1` over **every clause** of the item, so a body
  change moves the version and a blank line above it does not — the property the drift gate
  rests on, asserted in `api_surface_test.exs` rather than assumed.

  A map or struct type's row carries its key set and, for a key whose value is a union of
  atoms, that union — the two facts #153's shape findings were about (`result()` missing
  `diameter`, `status` naming `:error`), and the two an AST can state without a compiler.
  """

  alias Surfex.SourceScan

  @type item :: %{
          module: module(),
          kind: :def | :defmacro | :defguard | :defdelegate | :type | :opaque,
          name: atom(),
          arities: [non_neg_integer()],
          shape: String.t(),
          version: String.t(),
          path: String.t()
        }

  @doc """
  Every item `lib/` declares, grouped by module, from the project root that holds `mix.exs`.
  """
  def run(root \\ SourceScan.project_root("mix.exs")) do
    root
    |> SourceScan.lib_sources()
    |> Enum.filter(&String.starts_with?(&1, Path.join(root, "lib/")))
    |> Enum.flat_map(&scan_file(&1, root))
    |> Enum.group_by(& &1.module)
    |> Enum.sort_by(fn {module, _} -> inspect(module) end)
  end

  @doc "The items one source file declares, with `path` relative to `root`."
  def scan_file(path, root) do
    relative = Path.relative_to(path, root)
    ast = path |> File.read!() |> Code.string_to_quoted!(file: path)
    scan(ast, relative)
  end

  @doc false
  # Exposed for the fixture tests: scan a quoted module.
  def scan(ast, path), do: modules(ast, [], path)

  # ── Modules ─────────────────────────────────────────────────────────────────

  defp modules({:defmodule, _, [{:__aliases__, _, segments}, [do: body]]}, prefix, path) do
    here = prefix ++ segments
    module = Module.concat(here)
    own = body |> statements() |> items(module, path)
    own ++ modules(body, here, path)
  end

  defp modules({:__block__, _, nodes}, prefix, path),
    do: Enum.flat_map(nodes, &modules(&1, prefix, path))

  defp modules(nodes, prefix, path) when is_list(nodes),
    do: Enum.flat_map(nodes, &modules(&1, prefix, path))

  defp modules(_other, _prefix, _path), do: []

  defp statements({:__block__, _, nodes}), do: nodes
  defp statements(nil), do: []
  defp statements(node), do: [node]

  # ── Items ───────────────────────────────────────────────────────────────────

  # The module's OWN statements only: a nested module's are visited under its own name.
  defp items(statements, module, path) do
    functions =
      statements
      |> Enum.flat_map(&function_clause/1)
      |> Enum.group_by(fn {kind, name, _arities, _node} -> {kind, name} end)
      |> Enum.map(fn {{kind, name}, clauses} ->
        nodes = Enum.map(clauses, &elem(&1, 3))

        %{
          module: module,
          kind: kind,
          name: name,
          arities: clauses |> Enum.flat_map(&elem(&1, 2)) |> Enum.uniq() |> Enum.sort(),
          shape: signature(hd(nodes)),
          version: SourceScan.definition_hash(nodes),
          path: path
        }
      end)

    types =
      for {kind, name, node} <- Enum.flat_map(statements, &type_declaration/1) do
        %{
          module: module,
          kind: kind,
          name: name,
          arities: [],
          shape: type_shape(node),
          version: SourceScan.definition_hash(node),
          path: path
        }
      end

    functions ++ types
  end

  @public [:def, :defmacro, :defguard]

  defp function_clause({kind, _, [head | _]} = node) when kind in @public do
    {name, args} = head_name_args(head)
    [{kind, name, arities(args), node}]
  end

  defp function_clause({:defdelegate, _, [head | _]} = node) do
    {name, args} = head_name_args(head)
    [{:defdelegate, name, arities(args), node}]
  end

  defp function_clause(_other), do: []

  # `def f(a) when g`, `def f(a)`, and the bare `def f` (arity 0) all reach here.
  defp head_name_args({:when, _, [inner | _]}), do: head_name_args(inner)
  defp head_name_args({name, _, args}) when is_atom(name) and is_list(args), do: {name, args}
  defp head_name_args({name, _, _}) when is_atom(name), do: {name, []}

  # A head with n args of which d carry `\\` defaults declares arities n-d..n.
  defp arities(args) do
    n = length(args)
    d = Enum.count(args, &match?({:\\, _, _}, &1))
    Enum.to_list((n - d)..n//1)
  end

  # The argument names as the reader sees them, with a default marked. Patterns that are not a
  # plain variable are rendered as `_`: the golden lists what is declared, not how it matches.
  defp signature({_kind, _, [head | _]}) do
    {_name, args} = head_name_args(head)

    "(" <>
      Enum.map_join(args, ", ", fn
        {:\\, _, [arg, _default]} -> arg_name(arg) <> " \\\\ …"
        arg -> arg_name(arg)
      end) <> ")"
  end

  defp arg_name({:=, _, [_pattern, {name, _, ctx}]}) when is_atom(name) and is_atom(ctx),
    do: Atom.to_string(name)

  defp arg_name({:=, _, [{name, _, ctx}, _pattern]}) when is_atom(name) and is_atom(ctx),
    do: Atom.to_string(name)

  defp arg_name({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: Atom.to_string(name)
  defp arg_name(_pattern), do: "_"

  # ── Types ───────────────────────────────────────────────────────────────────

  defp type_declaration({:@, _, [{kind, _, [{:"::", _, [{name, _, _}, _]}]}]} = node)
       when kind in [:type, :opaque] and is_atom(name),
       do: [{kind, name, node}]

  defp type_declaration(_other), do: []

  # The key set of a map or struct type, and the atom alternatives of any key whose value is
  # a union of atoms. Anything else — a bare alias, a union of types, a tuple — is rendered as
  # its own text: the golden must not pretend to a structure it did not find.
  defp type_shape({:@, _, [{_kind, _, [{:"::", _, [_name, definition]}]}]}) do
    case map_fields(definition) do
      fields when is_list(fields) and fields != [] -> Enum.map_join(fields, ", ", &field_shape/1)
      _not_a_record -> Macro.to_string(definition)
    end
  end

  # A record-shaped map only: `%{name() => value()}` is a function type, and its "keys" are
  # types, so it is shown as written rather than as a key set.
  defp map_fields({:%{}, _, fields}), do: if(Enum.all?(fields, &atom_key?/1), do: fields)
  defp map_fields({:%, _, [_struct, {:%{}, _, fields}]}), do: map_fields({:%{}, [], fields})
  defp map_fields(_other), do: nil

  defp atom_key?({{qualifier, _, [key]}, _}) when qualifier in [:optional, :required],
    do: is_atom(key)

  defp atom_key?({key, _}), do: is_atom(key)

  defp field_shape({{qualifier, _, [key]}, value}) when qualifier in [:optional, :required],
    do: field_shape({key, value}, qualifier)

  defp field_shape({key, value}), do: field_shape({key, value}, :required)

  defp field_shape({key, value}, qualifier) do
    prefix = if qualifier == :optional, do: "#{key}?", else: to_string(key)

    case atom_union(value) do
      [] -> prefix
      atoms -> prefix <> ": " <> Enum.map_join(atoms, " | ", &inspect/1)
    end
  end

  # `:a | :b | :c` as a sorted list; a union with any non-atom alternative is not one, and a
  # key whose value is a single atom (`cycle: nil`) is a union of one.
  defp atom_union(value) do
    case alternatives(value) do
      {:ok, atoms} -> Enum.sort(atoms)
      :error -> []
    end
  end

  defp alternatives({:|, _, [left, right]}) do
    with {:ok, l} <- alternatives(left), {:ok, r} <- alternatives(right), do: {:ok, l ++ r}
  end

  defp alternatives(atom) when is_atom(atom), do: {:ok, [atom]}
  defp alternatives(_other), do: :error

  # ── Rendering ───────────────────────────────────────────────────────────────

  @doc """
  The `Surfex.Golden` spec for `API_SURFACE.md` — data only. One group per module.
  """
  def golden_spec(groups) do
    all = Enum.flat_map(groups, fn {_module, items} -> items end)
    functions = Enum.filter(all, &(&1.kind not in [:type, :opaque]))
    types = all -- functions

    %{
      name: "API_SURFACE.md",
      purpose:
        "Every public function head and every named type lib/ declares. Checked against " <>
          "spec/01–05's API blocks (#164).",
      task: "tla.api_surface",
      gate: "surface-drift",
      hardness: :hard,
      prose: prose(),
      stats: [
        Surfex.Golden.stat(
          "#{length(groups)} modules · #{length(all)} items",
          [
            {"functions", length(functions)},
            {"arities", functions |> Enum.map(&length(&1.arities)) |> Enum.sum()},
            {"types", length(types)}
          ]
        )
      ],
      columns: ["Item", "Kind", "Shape", "Version", "Locus"],
      groups: Enum.map(groups, &group/1)
    }
  end

  defp prose do
    """
    A row is one `{module, name, arity}` or one named type, as declared in source: a function
    a macro generates into a module is not declared there and is not listed. A head with
    defaults is one declaration and one row per arity. `Version` is the content hash over every
    clause of the item, so a changed body moves it and a moved definition does not. A map or
    struct type's `Shape` is its key set, `key?` marking an optional key, and `key: :a | :b` a
    key whose value is a union of atoms; any other type is shown as written.\
    """
  end

  defp group({module, items}) do
    %{
      heading: "#{inspect(module)} — #{length(items)} items",
      rows: Enum.flat_map(items, &rows/1)
    }
  end

  defp rows(%{kind: kind} = item) when kind in [:type, :opaque] do
    [
      %{
        "Item" => {:code, "#{item.name}()"},
        "Kind" => {:atom, kind},
        "Shape" => {:raw, cell_safe(item.shape)},
        "Version" => {:version, item.version},
        "Locus" => {:locus, item.path, nil}
      }
    ]
  end

  defp rows(item) do
    for arity <- item.arities do
      %{
        "Item" => {:code, "#{item.name}/#{arity}"},
        "Kind" => {:atom, item.kind},
        "Shape" => {:raw, cell_safe(item.shape)},
        "Version" => {:version, item.version},
        "Locus" => {:locus, item.path, nil}
      }
    end
  end

  # A `|` inside a table cell ends the cell; escaped, it renders as itself.
  defp cell_safe(text), do: String.replace(text, "|", "\\|")

  @doc "Render the golden."
  def render(groups), do: groups |> golden_spec() |> Surfex.Golden.render()
end
