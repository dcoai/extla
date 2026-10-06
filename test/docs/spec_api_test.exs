defmodule ExTLA.SpecApiTest do
  @moduledoc """
  The specification's API blocks, against `API_SURFACE.md` (#164, from #153; gate design from
  #214's root-cause note, form from #270).

  `spec/01–05` sketch each module as a fenced `defmodule` — heads, `@type`s, and the prose
  that explains why. #153 found **seventeen signatures and seven type shapes the code does not
  have**, and nothing had compared them, because there was no side derived from the code to
  compare against. `API_SURFACE.md` is that side now, so this is a document-to-document check
  and it runs before the build.

  ## Why the golden and not `function_exported?/3`

  Both would work. The golden is the one a reader opens: when this gate fails, the row it
  names is in a file the reviewer can read in the merge request, next to the diff that moved
  it. Asking the runtime instead would make the failure a fact about a loaded module and leave
  the document that is supposed to record the surface out of the conversation entirely.

  ## Four layers, and why NOPARSE is the first

  0. **Parse.** Every `defmodule` fence must `Code.string_to_quoted`. Two blocks did not, and
     three of #153's findings lived in them — a gate that skipped what it cannot read would
     have exempted exactly the blocks that had been hand-edited most.
  1. **Names and arities**, against the golden's function rows.
  2. **Type shapes** — the type's name, and for a record type its key set — against the
     golden's type rows.
  3. **No `@spec` in a spec fence.** #68 removed all 244 `@spec` from `lib/` on the reasoning
     that a hand-maintained annotation which drifts reads as a checked claim; the
     specification's own `@spec` lines were the same class, kept for a year and wrong in
     seventeen places. They are gone, and this refuses their return.

  ## What is checked, and what belongs to another gate

  A block sketching a module **ExTLA provides** — `ExTLA.*` or `Mix.Tasks.Extla.*` — is this
  gate's business: it is the published surface, and a reader coding to it gets an
  `UndefinedFunctionError` when it is wrong. A block under any other name is an example of
  what a *consumer* writes (`defmodule BankAccount`, `defmodule MyApp.TransferServer`, the
  worked `Specs.TransferProtocol`), and demanding that those exist in `lib/` would be asking
  the library to contain its own documentation's examples. Those blocks are #178's: they are
  checked by being **compiled**, which is a stronger claim than the one made here and a
  different mechanism.

  A block marked `> **Status: deferred past v1**` describes something not built. Those are
  skipped by name — the marker is the decision, and a gate that ignored it would force either
  a false row in the golden or the deletion of a design the project deliberately recorded.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @golden Path.join(@root, "API_SURFACE.md")
  @specs Path.wildcard(Path.join(@root, "spec/0[1-5]*.md")) |> Enum.sort()

  setup_all do
    %{blocks: blocks(), surface: surface()}
  end

  describe "layer 0 — every spec fence parses" do
    test "so that no block can be skipped for being unreadable", %{blocks: blocks} do
      unparseable =
        for block <- blocks, {:error, {meta, message, token}} <- [parse(block)] do
          "#{block.file}:#{block.line + meta[:line] - 1} — #{message}#{token}"
        end

      assert unparseable == [], """
      #{length(unparseable)} `defmodule` blocks in spec/ do not parse:

        #{Enum.join(unparseable, "\n  ")}

      A block that cannot be parsed is a block this gate cannot check, and skipping it would
      exempt from scrutiny exactly the blocks that have been edited most by hand. Repair the
      fence — a block split across two fences by prose, or prose left inside one.
      """
    end

    test "and there are blocks to parse", %{blocks: blocks} do
      assert length(blocks) > 30, "the fence reader found #{length(blocks)}; it reads nothing"
    end
  end

  describe "layer 1 — every head the spec publishes, the code declares" do
    @describetag verifies: [
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Liveness`",
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Safety`",
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API",
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API/The CLI infers `check_liveness`; the API does not",
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/State Graph",
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Spec.Compiled`",
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Overview/DSL Macro Reference",
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Overview/Helper Functions Available in DSL Blocks"
                 ]
    test "with the arity the spec gives it", %{blocks: blocks, surface: surface} do
      missing =
        for block <- checkable(blocks),
            {name, arity} <- heads(block),
            not exported?(surface, block.module, name, arity) do
          "#{block.file}:#{block.line} — #{inspect(block.module)}.#{name}/#{arity}" <>
            real(surface, block.module, name)
        end

      assert missing == [], """
      #{length(missing)} signatures the specification publishes are not in API_SURFACE.md:

        #{Enum.join(missing, "\n  ")}

      A reader coding to the specification gets `UndefinedFunctionError` or a
      `FunctionClauseError` on the first call. Correct the block against the golden's rows, or
      — if the module is not built — mark the block `> **Status: deferred past v1**`.
      """
    end

    test "and every module it sketches exists", %{blocks: blocks, surface: surface} do
      absent =
        for block <- checkable(blocks),
            not Map.has_key?(surface.modules, block.module),
            do: "#{block.file}:#{block.line} — #{inspect(block.module)}"

      assert absent == [], """
      #{length(absent)} modules the specification sketches are in no source file:

        #{Enum.join(absent, "\n  ")}

      Either the module was renamed, or it is a design that is not built — in which case the
      block carries `> **Status: deferred past v1**` and says so to a reader, rather than
      reading as a module they can use.
      """
    end
  end

  describe "layer 2 — every type the spec publishes, the code declares" do
    @describetag verifies: [
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Liveness`",
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API",
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API/The CLI infers `check_liveness`; the API does not",
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/State Graph",
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Spec.Compiled`"
                 ]
    test "by name, and with the same keys where it is a record", %{
      blocks: blocks,
      surface: surface
    } do
      wrong =
        for block <- checkable(blocks),
            {name, keys} <- types(block),
            fault = type_fault(surface, block.module, name, keys),
            fault != nil do
          "#{block.file}:#{block.line} — #{inspect(block.module)}.#{name}(): #{fault}"
        end

      assert wrong == [], """
      #{length(wrong)} type shapes in the specification disagree with API_SURFACE.md:

        #{Enum.join(wrong, "\n  ")}

      A struct or map type is the shape a caller pattern-matches. A missing key is a field the
      specification does not mention and the code returns; an extra one is a field the
      specification promises and nothing produces.
      """
    end
  end

  describe "layer 3 — the specification carries no @spec" do
    # #68 removed all 244 `@spec` from `lib/`: "a `@spec` that has drifted from its function is
    # worse than none, because it reads as a checked claim." The specification's own were the
    # same class — hand-maintained, drifted, and read as checked — and they are what #153
    # found seventeen of. Return shapes are documented in prose beside the head, which is the
    # one part of this surface not mechanically gated, by decision rather than oversight.
    test "so the class #68 closed in lib/ cannot return through the document", %{blocks: blocks} do
      offending =
        for block <- blocks,
            String.contains?(block.source, "@spec "),
            do: "#{block.file}:#{block.line} — #{inspect(block.module)}"

      assert offending == [], """
      #{length(offending)} spec blocks carry `@spec` lines:

        #{Enum.join(offending, "\n  ")}

      The specification does not carry `@spec` (#68, #164). Keep the `def` head, which this
      gate checks, and put the return shape in the `@doc` prose beside it or in a `@type` the
      code also declares — which layer 2 checks.
      """
    end
  end

  describe "the readings themselves" do
    # Every layer above compares two documents. A reader that silently returns nothing turns
    # all four into `assert [] == []`, which is the vacuity this project keeps finding in its
    # own gates — so each side is asserted non-empty here rather than assumed.
    test "the golden yields functions and types", %{surface: surface} do
      assert map_size(surface.modules) > 40
      assert Enum.any?(surface.modules, fn {_m, entries} -> entries.functions != %{} end)
      assert Enum.any?(surface.modules, fn {_m, entries} -> entries.types != %{} end)
    end

    # Reading a row is not reading its SHAPE. An earlier row pattern matched every type row
    # and let the lazy shape capture swallow the Version cell, so every key set came back
    # `nil` and layer 2 compared nothing while reporting green — on all seven of the findings
    # it exists for. A count of rows would not have caught that; a count of PARSED key sets
    # does, which is why this assertion is about the parse and not about the match.
    test "and a record type's keys, not merely its row", %{surface: surface} do
      records =
        for {_module, entries} <- surface.modules,
            {_name, keys} <- entries.types,
            keys != nil,
            do: keys

      assert length(records) > 10,
             "only #{length(records)} type rows yielded a key set; the shape column is being " <>
               "read wrongly and layer 2 is comparing nothing"

      assert Enum.any?(records, &MapSet.member?(&1, :constants)),
             "ExTLA.ModelChecker.config()'s keys did not parse"
    end

    test "the spec yields heads and types", %{blocks: blocks} do
      checkable = checkable(blocks)

      assert Enum.flat_map(checkable, &heads/1) != []
      assert Enum.flat_map(checkable, &types/1) != []
    end

    test "and a deferred block is recognised rather than checked", %{blocks: blocks} do
      deferred = Enum.filter(blocks, & &1.deferred?)

      assert deferred != [], "no block carries the deferred marker; the exemption is untested"
      refute Enum.any?(checkable(blocks), & &1.deferred?)
    end
  end

  # ── The spec side ───────────────────────────────────────────────────────────

  # A fenced ```elixir block whose first line opens a module, with the marker that precedes it.
  # The marker is searched for inside the block, because `> **Status: deferred past v1**` is
  # written into the `@doc`/`@moduledoc` of the thing it defers rather than above the fence.
  defp blocks do
    for file <- @specs, block <- blocks_in(file), do: block
  end

  defp blocks_in(file) do
    contents = File.read!(file)
    relative = Path.relative_to(file, @root)

    ~r/^```elixir\n(defmodule ([A-Z][\w.]*) do\n.*?)^```/ms
    |> Regex.scan(contents, return: :index)
    |> Enum.map(fn [{whole_at, _}, {source_at, source_len}, {name_at, name_len}] ->
      source = binary_part(contents, source_at, source_len)
      name = binary_part(contents, name_at, name_len)

      %{
        file: relative,
        line: line_of(contents, whole_at),
        module: Module.concat([name]),
        source: source,
        # The marker is written either into the `@moduledoc` of the thing it defers or as a
        # blockquote introducing the section — `ExTLA.PropertyTest.generate_test_module/3` does
        # the first, `ExTLA.Supervisor.Spec` the second — so both the block and the prose
        # immediately above it are read. Reading only one of the two made a deliberately
        # recorded design look like a missing module.
        deferred?:
          String.contains?(source, "Status: deferred past v1") or
            String.contains?(preamble(contents, whole_at), "Status: deferred past v1")
      }
    end)
  end

  # The prose between the previous fence (or heading) and this one — where a section-level
  # deferral marker is written. Bounded at 1,500 bytes so a marker several sections up cannot
  # exempt a block it says nothing about.
  defp preamble(contents, offset) do
    start = max(offset - 1_500, 0)

    contents
    |> binary_part(start, offset - start)
    |> String.split("```")
    |> List.last()
  end

  defp line_of(contents, offset) do
    contents
    |> binary_part(0, offset)
    |> String.graphemes()
    |> Enum.count(&(&1 == "\n"))
    |> Kernel.+(1)
  end

  # ExTLA's own surface, and not deferred. See the moduledoc: a block under another namespace
  # is an example of consumer code, and #178 checks those by compiling them.
  defp checkable(blocks) do
    Enum.filter(blocks, fn block ->
      not block.deferred? and ours?(block.module)
    end)
  end

  defp ours?(module) do
    name = inspect(module)

    name == "ExTLA" or String.starts_with?(name, "ExTLA.") or
      String.starts_with?(name, "Mix.Tasks.Extla.")
  end

  defp parse(block), do: Code.string_to_quoted(block.source)

  # Heads, from the AST where it parses. Layer 0 is what guarantees it does; a block that does
  # not parse contributes nothing here and fails there, rather than silently contributing
  # nothing and passing.
  defp heads(block) do
    case parse(block) do
      {:ok, ast} -> walk(ast, &head/1)
      {:error, _} -> []
    end
  end

  # `defdelegate` reads as a head here for the same reason `API_SURFACE.md` scans one: it
  # declares a public function. #319 turned `ExTLA.Spec.Helpers` into a façade over
  # `ExTLA.Set`/`ExTLA.Function`, so most of that module's sketch in `04` is delegations — and
  # a reader that skipped them would exempt from this gate exactly the block that had just
  # been rewritten, which is layer 0's objection one kind of node further in.
  @head_kinds [:def, :defmacro, :defdelegate]

  defp head({kind, _, [{:when, _, [inner | _]} | _]}) when kind in @head_kinds,
    do: head({kind, [], [inner]})

  defp head({kind, _, [{name, _, args} | _]}) when kind in @head_kinds and is_atom(name),
    do: {name, length(args || [])}

  defp head(_node), do: nil

  # `{name, keys}` for each `@type`; `keys` is `nil` for a type that is not a record shape.
  defp types(block) do
    case parse(block) do
      {:ok, ast} -> walk(ast, &type/1)
      {:error, _} -> []
    end
  end

  defp type({:@, _, [{:type, _, [{:"::", _, [{name, _, _}, definition]}]}]}) when is_atom(name),
    do: {name, record_keys(definition)}

  defp type(_node), do: nil

  defp record_keys({:%{}, _, fields}), do: field_names(fields)
  defp record_keys({:%, _, [_struct, {:%{}, _, fields}]}), do: field_names(fields)
  defp record_keys(_other), do: nil

  defp field_names(fields) do
    names =
      for {key, _value} <- fields do
        case key do
          {qualifier, _, [name]} when qualifier in [:optional, :required] -> name
          name -> name
        end
      end

    if Enum.all?(names, &is_atom/1), do: MapSet.new(names)
  end

  defp walk(ast, matcher) do
    {_, found} =
      Macro.prewalk(ast, [], fn node, acc ->
        case matcher.(node) do
          nil -> {node, acc}
          match -> {node, [match | acc]}
        end
      end)

    Enum.uniq(found)
  end

  # ── The golden side ─────────────────────────────────────────────────────────

  # `API_SURFACE.md`, read back as `%{module => %{functions: %{name => arities},
  # types: %{name => keys}}}`. Parsed from the rendered rows rather than from
  # `ExTLA.ApiSurface.run/0`, so this gate reads the artifact the `surface-drift` job publishes
  # — if the golden is stale, that job fails; if it is current, this is what a reader sees.
  defp surface do
    rows =
      @golden
      |> File.read!()
      |> String.split("\n")
      |> Enum.reduce({nil, %{}}, &surface_line/2)
      |> elem(1)

    %{modules: rows}
  end

  @heading ~r/^## ([A-Za-z][\w.]*) — /
  @function_row ~r/^\| `([\w?!]+)\/(\d+)` \| `:(\w+)` \|/
  # Four columns, and the last two pinned: Item | Kind | Shape | Version | Locus. An earlier
  # pattern ended `… \| \`[^\`]+\` \|$` and let the lazy Shape capture swallow the Version
  # cell, so every shape ended in "… | `a1b2c3d4`", failed the key check, and read as "no keys
  # to compare" — layer 2 passed on all seven of the shape findings it exists for. The gate was
  # vacuous and looked green, which is the exact defect this file is about.
  @type_row ~r/^\| `(\w+)\(\)` \| `:(?:type|opaque)` \| (.*) \| `[0-9a-f]{8}` \| `[^`]+` \|$/

  defp surface_line(line, acc) do
    classify(
      Regex.run(@heading, line),
      Regex.run(@function_row, line),
      Regex.run(@type_row, line),
      acc
    )
  end

  defp classify([_, name], _fn_row, _type_row, {_module, acc}),
    do: {Module.concat([name]), acc}

  defp classify(nil, [_, name, arity, _kind], _type_row, {module, acc}) when module != nil,
    do: {module, add_function(acc, module, String.to_atom(name), String.to_integer(arity))}

  defp classify(nil, nil, [_, name, shape], {module, acc}) when module != nil,
    do: {module, add_type(acc, module, String.to_atom(name), shape_keys(shape))}

  defp classify(_heading, _fn_row, _type_row, acc), do: acc

  defp entries(acc, module), do: Map.get(acc, module, %{functions: %{}, types: %{}})

  defp add_function(acc, module, name, arity) do
    current = entries(acc, module)
    functions = Map.update(current.functions, name, MapSet.new([arity]), &MapSet.put(&1, arity))
    Map.put(acc, module, %{current | functions: functions})
  end

  defp add_type(acc, module, name, keys) do
    current = entries(acc, module)
    Map.put(acc, module, %{current | types: Map.put(current.types, name, keys)})
  end

  # The golden renders a record type's shape as `key: :a \| :b, other?, third` — the key set is
  # what layer 2 compares, so the atom unions and the optional marker are stripped here. A
  # shape that is not a key list (a union, a bare alias) yields `nil`, and layer 2 then checks
  # the type's existence only, which is all either document states about it.
  defp shape_keys(shape) do
    keys =
      shape
      |> String.split(",")
      |> Enum.map(fn part ->
        part |> String.split(":") |> hd() |> String.trim() |> String.trim_trailing("?")
      end)

    if keys != [] and Enum.all?(keys, &Regex.match?(~r/^[a-z_][\w]*$/, &1)) do
      MapSet.new(keys, &String.to_atom/1)
    end
  end

  defp exported?(surface, module, name, arity) do
    case surface.modules[module] do
      nil -> false
      entries -> MapSet.member?(Map.get(entries.functions, name, MapSet.new()), arity)
    end
  end

  defp real(surface, module, name) do
    case get_in(surface.modules, [module, Access.key(:functions)]) do
      nil ->
        " (module absent)"

      functions ->
        " (declared: #{functions |> Map.get(name, MapSet.new()) |> Enum.sort() |> inspect()})"
    end
  end

  defp type_fault(surface, module, name, keys) do
    with entries when entries != nil <- surface.modules[module],
         true <- Map.has_key?(entries.types, name) do
      case {keys, entries.types[name]} do
        {nil, _} -> nil
        {_, nil} -> nil
        {spec_keys, real_keys} when spec_keys != real_keys -> key_difference(spec_keys, real_keys)
        _same -> nil
      end
    else
      nil -> "module absent from API_SURFACE.md"
      false -> "not a type the code declares"
    end
  end

  defp key_difference(spec_keys, real_keys) do
    missing = MapSet.difference(real_keys, spec_keys)
    extra = MapSet.difference(spec_keys, real_keys)

    [
      if(MapSet.size(missing) > 0,
        do: "in the code, not in the spec: #{inspect(Enum.sort(missing))}"
      ),
      if(MapSet.size(extra) > 0, do: "in the spec, not in the code: #{inspect(Enum.sort(extra))}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end
end
