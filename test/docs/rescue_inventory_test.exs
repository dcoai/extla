defmodule ExTLA.RescueInventoryTest do
  @moduledoc """
  Every `rescue` in `lib/` is named here, with the reason it is one (#182, #315).

  CLAUDE.md forbids `try/catch/rescue` outright, and the reason is not stylistic: a rescue
  scoped to a *function* rather than to a *call* reports any failure underneath it as the
  one failure it was written for. That is not a swallowed error, which a reviewer looks for
  — it is a **confident wrong diagnosis**, which a reviewer believes. #315 found one:
  `ExTLA.Refinement`'s totality probe reported a partial *helper* as a missing catch-all
  clause, and advised adding the clause the mapping already had.

  So the answer is not a count. Each of the four sites was reviewed on its own and two were
  kept, because for them the exception genuinely is *data about the user's input* rather
  than about the library — a blanket removal would have made `mix extla.explore` worse than
  it was. What a gate can hold is the part judgment cannot: that the list does not grow
  without someone writing down why.

  ## What is checked

  - The set of `{file, function/arity}` pairs in `lib/` carrying a `rescue` is **exactly**
    `@permitted`. A new one reddens the build; so does deleting one without deleting its
    entry here, which is what keeps this list from decaying into a list of ghosts.
  - Each is preceded by a `# PERMITTED RESCUE` comment, so the justification lives beside
    the code and not only here.
  - Each one's enclosing function body is **one call**. That is the property #315 was
    about: the private `check/2` in `Mix.Tasks.Extla.Check` and the private `total!/1` in
    `ExTLA.Refinement` both rescued over several calls, and both were split so the rescue
    covers only the call that can raise.

  The AST, not a `grep`: this project's source discusses `rescue` in prose in four modules
  that do not use one, and a textual scan would fail them for saying so.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # file => "function/arity" => why it is permitted.
  @permitted %{
    "lib/ex_tla/trace/explore.ex" => %{
      "evaluate_at/2" =>
        "the exception is data about the user's own expression: preserved whole, " <>
          "attributed to the state it happened at, and shown as a marked cell"
    },
    "lib/mix/tasks/extla.explore.ex" => %{
      "attempt/2" =>
        "hands the exception back as data so the caller can sort a deterministic " <>
          "failure from a state-dependent one; it decides nothing itself"
    },
    "lib/mix/tasks/extla.check.ex" => %{
      "run/2" =>
        "converts the one exception --verify-symmetry reports by into the one exit " <>
          "status the task reports by; the message travels with it"
    },
    "lib/ex_tla/refinement.ex" => %{
      "probe/1" =>
        "reads one stack frame to tell the probed call's own FunctionClauseError from " <>
          "any other, and re-raises every other one untouched"
    }
  }

  describe "the rescue inventory" do
    test "lib/ carries exactly the rescues that are written down here" do
      found = for site <- lib_rescues(), do: {site.file, signature(site)}

      permitted =
        for {file, functions} <- @permitted, {signature, _why} <- functions, do: {file, signature}

      assert Enum.sort(found) == Enum.sort(permitted), """
      the set of `rescue` sites in lib/ is not the set recorded in this test.

        only in lib/:      #{inspect(Enum.sort(found -- permitted))}
        only in this list: #{inspect(Enum.sort(permitted -- found))}

      A new one: CLAUDE.md forbids `try/catch/rescue`, and the four that survive did so one
      at a time, each for a reason written beside it. If a fifth is genuinely of that kind —
      the exception is data about the user's input, and the rescue covers exactly the call
      that produces it — add it to `@permitted` with the reason, and put a
      `# PERMITTED RESCUE` comment above it. Otherwise surface the failure instead of
      catching it.

      One that is gone: delete its entry. A list naming sites that no longer exist stops
      being a review and becomes decoration.
      """
    end

    test "each one says beside itself why it is one" do
      unexplained =
        for site <- lib_rescues(),
            not explained?(site),
            do: "#{site.file}:#{site.line} — #{signature(site)}"

      assert unexplained == [], """
      #{length(unexplained)} permitted rescue(s) carry no `# PERMITTED RESCUE` comment:

        #{Enum.join(unexplained, "\n  ")}

      The entry in this test is the inventory; the comment is the justification, and it has
      to be where the next reader is — at the code.
      """
    end

    test "each one is scoped to a single call" do
      wide =
        for site <- lib_rescues(),
            calls = calls(site.body),
            length(calls) > 1,
            do: "#{site.file} — #{signature(site)} wraps #{inspect(calls)}"

      assert wide == [], """
      #{length(wide)} permitted rescue(s) cover more than one call:

        #{Enum.join(wide, "\n  ")}

      This is the #315 defect itself. A rescue over several calls reports whichever of them
      failed as the one it was written for — `ExTLA.Refinement`'s probe reported a partial
      helper as a missing catch-all clause, and `mix extla.check` would have reported a second
      future raise site as an unsound symmetry declaration. Extract the one call that raises
      into its own function and rescue there.
      """
    end
  end

  describe "the gate itself" do
    # Anti-vacuity. Each of these fails the point of the three tests above if it is not
    # true: an empty list, a walk that reads nothing, or a detector blind to the shape it is
    # looking for all make those assertions pass by reading no code at all.
    test "the permitted list is not empty, and names files that exist" do
      assert map_size(@permitted) == 4

      for {file, functions} <- @permitted do
        assert File.exists?(Path.join(@root, file)), "#{file} is named here and does not exist"
        assert map_size(functions) >= 1
        for {_signature, why} <- functions, do: assert(String.length(why) > 40)
      end
    end

    test "it reads a real tree" do
      assert length(lib_files()) > 40
    end

    test "it finds both shapes of rescue" do
      function_scoped = """
      defmodule S do
        defp f(x) do
          g(x)
        rescue
          e -> e
        end
      end
      """

      inline = """
      defmodule S do
        defp f(x) do
          try do
            g(x)
          rescue
            e -> e
          end
        end
      end
      """

      assert [{:f, 1, _line, _body}] = defs_with_rescue(function_scoped)
      assert [{:f, 1, _line, _body}] = defs_with_rescue(inline)
    end

    test "it does not see a rescue that is only talked about" do
      prose = """
      defmodule S do
        # This deliberately does not rescue, and @keywords lists :rescue as a token.
        @keywords [:do, :rescue, :after]
        defp f(x), do: {x, @keywords}
      end
      """

      assert defs_with_rescue(prose) == []
    end

    test "and the single-call detector counts more than one when there is more than one" do
      two = """
      defmodule S do
        defp f(x) do
          y = g(x)
          h(y)
        rescue
          e -> e
        end
      end
      """

      assert [{:f, 1, _line, body}] = defs_with_rescue(two)
      assert calls(body) == [:g, :h]
    end
  end

  # ── Reading the tree ────────────────────────────────────────────────────────

  defp lib_files, do: @root |> Path.join("lib/**/*.ex") |> Path.wildcard()

  defp relative(path), do: Path.relative_to(path, @root)

  defp signature(%{function: function, arity: arity}), do: "#{function}/#{arity}"

  defp lib_rescues do
    for path <- lib_files(),
        {function, arity, line, body} <- defs_with_rescue(File.read!(path)),
        do: %{
          file: relative(path),
          function: function,
          arity: arity,
          line: line,
          body: body,
          source: File.read!(path)
        }
  end

  defp defs_with_rescue(code) do
    ast = Code.string_to_quoted!(code)

    sites =
      for {name, arity, body} <- defs(ast),
          line <- rescue_lines(body),
          do: {name, arity, line, body}

    # Nothing may escape attribution: a rescue outside every `def` would be invisible to the
    # inventory, so the two counts are held to each other rather than assumed equal.
    assert length(sites) == length(rescue_lines(ast)),
           "a `rescue` in this source sits outside every def; the inventory cannot name it"

    sites
  end

  defp defs(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {op, _meta, [head, body]} = node, acc when op in [:def, :defp] and is_list(body) ->
          {name, arity} = name_and_arity(head)
          {node, [{name, arity, body} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp name_and_arity({:when, _meta, [head | _guards]}), do: name_and_arity(head)

  defp name_and_arity({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp name_and_arity({name, _meta, nil}) when is_atom(name), do: {name, 0}

  # A `def unquote(name)(unquote_splicing(args))` inside a `quote`. It has no name until the
  # macro runs, so it cannot be named here — but it is still counted, so one carrying a
  # rescue reddens the inventory rather than slipping past it unnamed.
  defp name_and_arity(_generated), do: {:"def-in-quote", -1}

  defp rescue_lines(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:rescue, [{:->, meta, _clause} | _rest]} = node, acc ->
          {node, [Keyword.get(meta, :line, 0) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  # ── How wide is the rescue ──────────────────────────────────────────────────

  # Never invocations: the `.` of a qualified call (counted at the call node itself), an
  # attribute read, the literal constructors, and a block.
  @not_calls [:., :@, :{}, :%{}, :%, :<<>>, :__aliases__, :__block__, :__MODULE__]

  # The calls in the `do` block, ignoring the rescue clauses — the question is how much the
  # rescue covers, not what it does once it fires.
  defp calls(body) do
    {_ast, found} =
      body
      |> Keyword.fetch!(:do)
      |> Macro.prewalk([], fn node, acc -> {node, record(node, acc)} end)

    Enum.reverse(found)
  end

  # `Mod.fun(...)` or `var.fun(...)`.
  defp record({{:., _dot, [_target, function]}, _call, args}, acc)
       when is_atom(function) and is_list(args),
       do: [function | acc]

  # `fun.(...)`, over a lambda the caller supplied.
  defp record({{:., _dot, [_fun]}, _call, args}, acc) when is_list(args), do: [:"fn." | acc]

  defp record({name, _meta, args}, acc) when is_atom(name) and is_list(args) do
    cond do
      name in @not_calls -> acc
      Macro.operator?(name, length(args)) -> acc
      true -> [name | acc]
    end
  end

  defp record(_node, acc), do: acc

  # A `# PERMITTED RESCUE` comment in the forty lines above the rescue clause — far enough
  # to sit above the function's own head, close enough that it is about this rescue.
  defp explained?(%{source: source, line: line}) do
    source
    |> String.split("\n")
    |> Enum.slice(max(line - 41, 0)..(line - 1)//1)
    |> Enum.any?(&(&1 =~ ~r/^\s*#\s*PERMITTED RESCUE/))
  end
end
