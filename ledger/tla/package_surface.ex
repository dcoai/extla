defmodule TLA.PackageSurface do
  @moduledoc """
  What ExTLA depends on and what it ships, as a surfex golden, `PACKAGE_SURFACE.md`
  (#270, #274).

  ## Two sections, one question

  Both halves answer "what does a consumer of this library actually receive?", and both had
  the same defect: the answer existed in `mix.exs` and was *restated* somewhere else by hand.

  **Dependencies.** `06-architecture.md` §Dependencies is a fenced block whose first line is
  the comment `# mix.exs` — it announces itself as a copy, and it was never edited after the
  initial commit. It lists `dialyxir`, removed by #69; it omits `surfex`, added by #64; its
  `ex_doc` requirement is three minor versions behind. The prose under it is still true,
  because prose states properties and only contents drift (#179).

  **Modules.** The docs are built with `MIX_ENV=dev`, and `elixirc_paths(:dev)` includes
  `ledger/`, so the published documentation advertises `TLA.Ledger`, `TLA.Spec.Version` and
  `mix tla.coverage` to a consumer whose package contains `lib/` only. Nobody decided to
  document the ledger; the environment did (#181). The `consumer-compile` job proves the
  package is right and cannot see the docs; nothing compared the two.

  This lists both from `mix.exs` — the dependency list as declared, and every module under
  the dev compile paths with whether a directory in `files:` ships it. `mix.exs`'s own
  `docs: [filter_modules: …]` then keeps a module out of the published docs on the same
  rule, so the two cannot disagree, and `test/docs/package_docs_test.exs` checks the built
  pages against these rows.
  """

  alias Surfex.SourceScan

  @type dependency :: %{
          name: atom(),
          requirement: String.t(),
          only: String.t(),
          optional: boolean(),
          runtime: boolean()
        }

  @type module_row :: %{module: module(), path: String.t(), packaged?: boolean()}

  @doc "The dependency rows and the module rows, from the project root that holds `mix.exs`."
  def run(root \\ SourceScan.project_root("mix.exs")) do
    %{dependencies: dependencies(root), modules: modules(root)}
  end

  # ── Dependencies ────────────────────────────────────────────────────────────

  @doc """
  Every declared dependency, as `mix.exs` declares it.

  Read from the project's own configuration rather than from `mix.lock`: the lock records
  what a resolution chose, and the question here is what this library *asks for*, which is
  what a consumer inherits or does not.
  """
  def dependencies(root) do
    root
    |> project_config()
    |> Keyword.fetch!(:deps)
    |> Enum.map(&dependency/1)
    |> Enum.sort_by(& &1.name)
  end

  defp dependency({name, requirement}) when is_binary(requirement),
    do: dependency({name, requirement, []})

  defp dependency({name, options}) when is_list(options),
    do: dependency({name, source(options), options})

  defp dependency({name, requirement, options}) do
    %{
      name: name,
      requirement: requirement,
      only: only(options),
      optional: Keyword.get(options, :optional, false),
      runtime: Keyword.get(options, :runtime, true)
    }
  end

  # A git dependency has no version requirement; what it has is a source and a pin, and a
  # row that left them out would say less about it than `mix.exs` does.
  defp source(options) do
    cond do
      url = options[:git] -> "git: #{url}" <> pin(options)
      path = options[:path] -> "path: #{path}"
      true -> options[:version] || "—"
    end
  end

  defp pin(options) do
    case {options[:tag], options[:branch], options[:ref]} do
      {nil, nil, nil} -> ""
      {tag, nil, nil} -> " tag: #{tag}"
      {nil, branch, nil} -> " branch: #{branch}"
      {nil, nil, ref} -> " ref: #{ref}"
    end
  end

  defp only(options) do
    case Keyword.get(options, :only) do
      nil -> "all"
      envs when is_list(envs) -> Enum.map_join(envs, ", ", &to_string/1)
      env -> to_string(env)
    end
  end

  # ── Modules ─────────────────────────────────────────────────────────────────

  @doc """
  Every module the docs build can see, and whether the package ships it.

  The docs build uses `MIX_ENV=dev`, so the set is `elixirc_paths(:dev)` — and that is
  precisely why this row exists: the published documentation's module list is a function of
  an environment rather than of a decision.
  """
  def modules(root) do
    config = project_config(root)
    shipped = config |> Keyword.fetch!(:package) |> Keyword.fetch!(:files)

    for tree <- dev_paths(config),
        path <- Path.wildcard(Path.join([root, tree, "**/*.ex"])),
        module <- modules_in(path),
        relative = Path.relative_to(path, root) do
      %{module: module, path: relative, packaged?: packaged?(relative, shipped)}
    end
    |> Enum.uniq_by(& &1.module)
    |> Enum.sort_by(&inspect(&1.module))
  end

  @doc """
  Whether `path` is under one of the `files:` entries the package ships.

  This is the predicate `mix.exs` gives ExDoc as `filter_modules`, so the golden's
  `packaged?` column and the published module set are one rule rather than two.
  """
  def packaged?(path, files) do
    Enum.any?(files, fn entry ->
      path == entry or String.starts_with?(path, entry <> "/")
    end)
  end

  defp dev_paths(config) do
    case Keyword.get(config, :elixirc_paths) do
      paths when is_list(paths) -> paths
      _not_a_literal -> ["lib", "ledger"]
    end
  end

  # Nested modules carry their enclosing name: `defmodule Error` inside `defmodule
  # TLA.Refinement` is `TLA.Refinement.Error`, and listing it as `Error` would put a row in
  # the golden naming a module that does not exist — and, worse, one whose name collides
  # with every other nested `Error` in the tree.
  defp modules_in(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!(file: path)
    |> nested([])
  end

  defp nested({:defmodule, _, [{:__aliases__, _, segments}, [do: body]]}, prefix) do
    here = prefix ++ segments
    [Module.concat(here) | nested(body, here)]
  end

  defp nested({:__block__, _, nodes}, prefix), do: Enum.flat_map(nodes, &nested(&1, prefix))
  defp nested(nodes, prefix) when is_list(nodes), do: Enum.flat_map(nodes, &nested(&1, prefix))
  defp nested(_other, _prefix), do: []

  # Read from `mix.exs`'s AST, not from `Mix.Project.config/0`.
  #
  # Two reasons, and the second is the one that decided it. `Mix.Project.config/0` answers
  # for whichever project is *loaded*, so a fixture root would be read as this tree and every
  # assertion would be about `extla` rather than about the fixture. And evaluating the file
  # is worse than useless: Mix refuses a second definition of a project module that is
  # already loaded, which is exactly the situation any run from inside this project is in.
  #
  # So the three values are lifted out of the quoted file: the `deps/0` body, the `files:`
  # entry of `package:`, and the `elixirc_paths(:dev)` clause. All three are literals here —
  # a computed one would raise rather than be guessed at, because a golden that quietly read
  # something else would be worse than one that refuses.
  defp project_config(root) do
    ast = root |> Path.join("mix.exs") |> File.read!() |> Code.string_to_quoted!(file: "mix.exs")

    [
      deps:
        literal(ast, fn
          {:defp, _, [{:deps, _, _}, [do: list]]} -> list
          _node -> nil
        end),
      elixirc_paths:
        literal(ast, fn
          {:defp, _, [{:elixirc_paths, _, [:dev]}, [do: list]]} -> list
          _node -> nil
        end),
      package: [
        files:
          literal(ast, fn
            {:files, files} -> files
            _node -> nil
          end)
      ]
    ]
  end

  defp literal(ast, matcher) do
    {_, found} =
      Macro.prewalk(ast, nil, fn node, acc ->
        {node, acc || matcher.(node)}
      end)

    case found do
      nil ->
        raise "mix.exs does not declare that value as a literal this can read"

      # `files: packaged_files()` — the entry names a private helper rather than repeating
      # the list, because `docs: [filter_modules: …]` needs the same one and a second copy
      # would be the drift this golden exists to report. Follow the name to its body.
      {name, _, args} when is_atom(name) and args in [[], nil] ->
        literal(ast, fn
          {:defp, _, [{^name, _, _}, [do: body]]} -> body
          _node -> nil
        end)

      quoted ->
        {value, _bindings} = Code.eval_quoted(quoted)
        value
    end
  end

  # ── Rendering ───────────────────────────────────────────────────────────────

  @doc "The `Surfex.Golden` spec for `PACKAGE_SURFACE.md` — data only."
  def golden_spec(%{dependencies: dependencies, modules: modules}) do
    packaged = Enum.count(modules, & &1.packaged?)

    %{
      name: "PACKAGE_SURFACE.md",
      purpose:
        "What ExTLA depends on and what it ships. Linked from 06-architecture.md " <>
          "§Dependencies; the published docs are filtered on the same rule.",
      task: "tla.package_surface",
      gate: "surface-drift",
      hardness: :hard,
      prose: prose(),
      stats: [
        Surfex.Golden.stat(
          "#{length(dependencies)} dependencies · #{length(modules)} modules",
          [
            {"packaged", packaged},
            {"not packaged", length(modules) - packaged},
            {"required at runtime", Enum.count(dependencies, &required?/1)}
          ]
        )
      ],
      columns: ["Item", "Kind", "Detail", "Locus"],
      groups: [
        %{
          heading: "Dependencies — as `mix.exs` declares them",
          rows: Enum.map(dependencies, &dependency_row/1)
        },
        %{
          heading: "Modules — and whether `files:` ships them",
          rows: Enum.map(modules, &module_row/1)
        }
      ]
    }
  end

  defp required?(dependency), do: dependency.only == "all" and not dependency.optional

  defp prose do
    """
    A dependency row is one `deps` entry as declared — a requirement, or a source and its pin
    for a git dependency — with its `only:`, `optional:` and `runtime:`. A module row is every
    module the **dev** compile paths hold, which is the set the docs build sees, and whether a
    `files:` entry ships it. Those two facts belong side by side: the docs are built under dev
    and the package is `lib/` only, so a module can be documented to a consumer who cannot
    call it. `mix.exs` filters the published docs on this same rule, and
    `test/docs/package_docs_test.exs` holds the built pages to these rows.\
    """
  end

  defp dependency_row(dependency) do
    %{
      "Item" => {:code, to_string(dependency.name)},
      "Kind" => {:atom, kind(dependency)},
      "Detail" => {:raw, detail(dependency)},
      "Locus" => {:locus, "mix.exs", nil}
    }
  end

  defp kind(dependency) do
    cond do
      required?(dependency) and not dependency.optional -> :required
      dependency.optional -> :optional
      true -> :dev_test
    end
  end

  defp detail(dependency) do
    [
      dependency.requirement,
      "only: " <> dependency.only,
      if(dependency.optional, do: "optional"),
      if(not dependency.runtime, do: "runtime: false")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp module_row(row) do
    %{
      "Item" => {:code, inspect(row.module)},
      "Kind" => {:atom, if(row.packaged?, do: :packaged, else: :not_packaged)},
      "Detail" => {:raw, if(row.packaged?, do: "ships to a consumer", else: "this project only")},
      "Locus" => {:locus, row.path, nil}
    }
  end

  @doc "Render the golden."
  def render(surface), do: surface |> golden_spec() |> Surfex.Golden.render()
end
