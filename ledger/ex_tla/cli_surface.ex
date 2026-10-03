defmodule ExTLA.CliSurface do
  @moduledoc """
  What the `mix extla.*` tasks accept and what they return — every switch, every documented exit
  code, and the specification section that reproduces each task — as a surfex golden,
  `CLI_SURFACE.md` (#270, #272).

  ## What this replaces

  `spec_options_test.exs` held each task's `@switches` against the option list its spec section
  documents, over a **hand-written list of six tasks**. That list was correct because #163 wrote
  it eleven days ago; it is the shape that goes stale the moment a seventh task is added, and
  nothing would have said so — a task absent from the list is a task nobody checks, which reads
  exactly like a task that passes.

  Here the set is derived twice over. The tasks are every `extla.*.ex` under a `mix/tasks`
  directory, and each task's spec section is found by searching `spec/*.md` for the `defmodule`
  line that opens it. So a task added without a section is a row that says `not specified`, and
  the gate that reads these rows refuses it — the difference between a gap that is recorded and
  a gap that is invisible, which is the distinction `TLA_COVERAGE.md` exists for one layer down.

  ## What a row is

  One row per switch (name, the type `OptionParser` is given, and the flag as a user types it),
  and one per documented exit code. Both are read from **source**: the switches from the AST's
  `@switches`, the exit codes from the `## Exit codes` block of the moduledoc. A task with no
  exit-code table has no exit rows and says so in its heading rather than appearing complete —
  `mix extla.stamp` is that case today (#173), and it is a finding the golden reports rather than
  one a reader has to notice.

  ## Which tasks must be specified

  A task under `lib/` ships to a consumer and its section in `spec/04` or `spec/05` is part of
  the published surface. A task under `ledger/` or `test/` is this project's own tooling,
  excluded from the package (`mix.exs` `files:`), and has no spec section by design. All are
  listed; the heading says which kind each is, so "no section" is never read as an omission,
  and a SHIPPED task with no section is the one combination that shouts.
  """

  alias Surfex.SourceScan

  @type task :: %{
          module: module(),
          task: String.t(),
          switches: [{atom(), atom()}],
          exit_codes: [{String.t(), String.t()}],
          spec: {String.t(), String.t()} | nil,
          shipped?: boolean(),
          version: String.t(),
          path: String.t()
        }

  @doc """
  Every `mix extla.*` task, in name order, from the project root that holds `mix.exs`.
  """
  def run(root \\ SourceScan.project_root("mix.exs")) do
    specs = spec_sources(root)

    root
    |> task_sources()
    |> Enum.map(&scan_file(&1, root, specs))
    |> Enum.sort_by(& &1.task)
  end

  # The trees Mix compiles from, and nothing else. An `**/mix/tasks` glob from the root also
  # walks `_build/`, `deps/`, `doc/` and `tmp/` — and `tmp/` is where ExUnit puts a `:tmp_dir`,
  # so a test that wrote a fixture task changed what the golden listed for the rest of the run.
  # That is a golden that is not a function of source, which is the one property every drift
  # gate rests on; the test that found it is in `cli_surface_test.exs`.
  @source_roots ~w(lib ledger test)

  @doc "Every `mix/tasks/extla.*.ex` in a source tree under `root`."
  def task_sources(root) do
    @source_roots
    |> Enum.flat_map(&Path.wildcard(Path.join([root, &1, "**/mix/tasks/extla.*.ex"])))
    |> Enum.sort()
  end

  @doc "The spec files a task section can live in, as `{path, contents}`."
  def spec_sources(root) do
    Path.join(root, "spec/*.md")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&{Path.relative_to(&1, root), File.read!(&1)})
  end

  @doc "One task's row data, with `path` relative to `root`."
  def scan_file(path, root, specs) do
    relative = Path.relative_to(path, root)
    source = File.read!(path)
    ast = Code.string_to_quoted!(source, file: path)

    [module | _] =
      ast
      |> SourceScan.defmodules()
      |> Enum.map(fn {:defmodule, _, [{:__aliases__, _, segments}, _]} ->
        Module.concat(segments)
      end)

    %{
      module: module,
      task: task_name(module),
      switches: switches(ast),
      exit_codes: exit_codes(attribute(ast, :moduledoc)),
      spec: spec_section(module, specs),
      shipped?: String.starts_with?(relative, "lib/"),
      version: SourceScan.definition_hash(ast),
      path: relative
    }
  end

  # `Mix.Tasks.Extla.ApiSurface` → "extla.api_surface", the name a user types.
  defp task_name(module), do: Mix.Task.task_name(module)

  # ── Reading a task's source ─────────────────────────────────────────────────

  defp attribute(ast, name) do
    {_, found} =
      Macro.prewalk(ast, nil, fn
        {:@, _, [{^name, _, [value]}]} = node, nil -> {node, text(value)}
        node, acc -> {node, acc}
      end)

    found
  end

  # A moduledoc may be an interpolated heredoc — `mix extla.visualize` renders its default
  # `--max-states` into its own help — and that arrives as a `<<>>` node rather than a binary.
  # Its literal segments are read and each interpolation stands as `…`: this reads a document
  # for structure, and a value computed at compile time is not part of the structure. Returning
  # `nil` for those (an earlier draft's `is_binary` guard) silently emptied the exit-code table
  # of the one task whose help is computed, which is the failure this golden exists to catch.
  defp text(value) when is_binary(value), do: value

  defp text({:<<>>, _, parts}) do
    Enum.map_join(parts, fn
      part when is_binary(part) -> part
      _interpolation -> "…"
    end)
  end

  defp text(_other), do: nil

  # `@switches [a: :boolean, b: :string]`, as `OptionParser` is given them. Read from the AST
  # rather than from `switches/0`, because a task that forgot the accessor would otherwise be
  # invisible here — and one did: `mix extla.coverage` has never had one.
  defp switches(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{:switches, _, [list]}]} = node, [] when is_list(list) ->
          {node, Enum.map(list, fn {name, type} -> {name, type} end)}

        node, acc ->
          {node, acc}
      end)

    Enum.sort(found)
  end

  # The `## Exit codes` block of a moduledoc: indented `<n>  <meaning>` lines, the meaning
  # continuing on more-indented lines, up to the next `##` heading or a blank-line-separated
  # paragraph that is not a code row.
  defp exit_codes(nil), do: []

  defp exit_codes(moduledoc) do
    case String.split(moduledoc, "## Exit codes", parts: 2) do
      [_only] ->
        []

      [_before, after_heading] ->
        after_heading
        |> String.split("\n")
        |> Enum.reduce({[], nil}, &exit_line/2)
        |> then(fn {rows, current} -> Enum.reverse(prepend(current, rows)) end)
        |> Enum.map(fn {code, words} -> {code, words |> Enum.join(" ") |> squeeze()} end)
    end
  end

  @code_line ~r/^\s{4,}(\d)\s\s+(\S.*)$/
  @continuation ~r/^\s{6,}(\S.*)$/

  defp exit_line(line, acc) do
    classify(line, Regex.run(@code_line, line), Regex.run(@continuation, line), acc)
  end

  defp classify(_line, [_, code, text], _cont, {rows, current}),
    do: {prepend(current, rows), {code, [text]}}

  defp classify(_line, nil, [_, text], {rows, {code, words}}),
    do: {rows, {code, words ++ [text]}}

  # A blank line inside the block continues it; anything else ends it.
  defp classify(line, nil, _cont, {rows, current}) do
    if String.trim(line) == "",
      do: {rows, current},
      else: {prepend(current, rows), nil}
  end

  defp prepend(nil, rows), do: rows
  defp prepend(row, rows), do: [row | rows]

  defp squeeze(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  # ── The spec section, derived rather than listed ────────────────────────────

  @doc """
  The `{spec file, anchor}` whose fenced block reproduces this task, or `nil`.

  The anchor is the `defmodule` line `spec_options_test` splits on, so the golden and that
  gate agree about where a task's documented options live by construction rather than by two
  hand lists agreeing.
  """
  def spec_section(module, specs) do
    anchor = "defmodule #{inspect(module)} do"

    Enum.find_value(specs, fn {path, contents} ->
      if String.contains?(contents, anchor), do: {path, anchor}
    end)
  end

  # ── Rendering ───────────────────────────────────────────────────────────────

  @doc """
  The `Surfex.Golden` spec for `CLI_SURFACE.md` — data only. One group per task.
  """
  def golden_spec(tasks) do
    switches = Enum.flat_map(tasks, & &1.switches)

    %{
      name: "CLI_SURFACE.md",
      purpose:
        "Every mix extla.* task's switches and documented exit codes, and the specification " <>
          "section that reproduces it. Held against spec/04 and spec/05 by spec_options_test.",
      task: "extla.cli_surface",
      gate: "surface-drift",
      hardness: :hard,
      prose: prose(),
      stats: [
        Surfex.Golden.stat(
          "#{length(tasks)} tasks · #{length(switches)} switches",
          [
            {"shipped", Enum.count(tasks, & &1.shipped?)},
            {"specified", Enum.count(tasks, &(&1.spec != nil))},
            {"exit codes", tasks |> Enum.map(&length(&1.exit_codes)) |> Enum.sum()}
          ]
        )
      ],
      columns: ["Item", "Kind", "Detail", "Locus"],
      groups: Enum.map(tasks, &group/1)
    }
  end

  defp prose do
    """
    A `switch` row is one `@switches` entry, with the flag as a user types it and the type
    `OptionParser` is given. An `exit` row is one code from the task's `## Exit codes` table; a
    task with no table has none, which is a finding rather than a blank. The specification
    section is found by searching `spec/*.md` for the task's `defmodule` line, so a task with
    no section says so instead of going unlisted — the list of tasks is the directory, not a
    hand-kept set. Tasks outside `lib/` — this project's ledger tooling and its test-support
    tasks — are excluded from the package, so they have no specification section by design.\
    """
  end

  defp group(task) do
    %{heading: heading(task), rows: rows(task)}
  end

  defp heading(task) do
    [
      "`mix #{task.task}`",
      where(task),
      "#{length(task.switches)} switches",
      exit_note(task)
    ]
    |> Enum.join(" — ")
  end

  defp where(%{shipped?: true, spec: {path, _}}), do: "specified in #{path}"
  defp where(%{shipped?: true, spec: nil}), do: "SHIPPED AND NOT SPECIFIED"
  defp where(%{path: "ledger/" <> _}), do: "ledger tooling, not packaged"
  defp where(%{path: "test/" <> _}), do: "test support, not packaged"
  defp where(task), do: "not packaged (#{Path.dirname(task.path)})"

  defp exit_note(%{exit_codes: []}), do: "NO EXIT-CODE TABLE"
  defp exit_note(task), do: "#{length(task.exit_codes)} exit codes"

  defp rows(task) do
    switch_rows =
      for {name, type} <- task.switches do
        %{
          "Item" => {:code, flag(name)},
          "Kind" => {:atom, :switch},
          "Detail" => {:atom, type},
          "Locus" => {:locus, task.path, nil}
        }
      end

    exit_rows =
      for {code, meaning} <- task.exit_codes do
        %{
          "Item" => {:code, "exit #{code}"},
          "Kind" => {:atom, :exit},
          "Detail" => {:raw, meaning},
          "Locus" => {:locus, task.path, nil}
        }
      end

    switch_rows ++ exit_rows
  end

  @doc "The flag as a user types it: `:max_states` → `--max-states`."
  def flag(name), do: "--" <> String.replace(Atom.to_string(name), "_", "-")

  @doc "Render the golden."
  def render(tasks), do: tasks |> golden_spec() |> Surfex.Golden.render()
end
