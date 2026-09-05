defmodule TLA.Trace.Explore do
  @moduledoc """
  The body of `TLA.Trace.explore/3`: named expressions evaluated at every state of a
  counterexample, rendered as a table.

  A separate module for the reason `TLA.StateGraph.Export` is one — `TLA.Trace` is about
  *regenerating* a counterexample and checking it against the spec, and this is a rendering
  over the finished result. What the two share is deliberately small and lives on `TLA.Trace`
  as `join/1`, `call/2`, `banner/1` and `loop_note/2`, so the table and `format/1` cannot
  disagree about how a lasso flattens or how an action call is written.

  ## The layout, and why it is not the obvious one

  The obvious layout puts each step's binding in its column header. It does not survive
  contact with a real trace: `begin_transfer(from: :alice, to: :bob, amount: 3)` is 44
  characters, and one such column consumes most of a terminal on its own. So the header
  carries the state number and the bare action name, and the bindings are listed under the
  table, where their length costs nothing:

      ═══ EXPLORE: mutual_exclusion ══════════════════════════════════

                        1        2        3        4        5
                     init  request  request  acquire  release
        ──────────────────────────────────────────────────────
        waiting          0        1        2        1        1
        holder         nil      nil      nil   :alice      nil
        quorum?      false    false    false    false    false

        Bindings:
          2  request(client: :alice)
          3  request(client: :bob)
          4  acquire(client: :alice)
          5  release(client: :alice)
      ════════════════════════════════════════════════════════════════

  ## Chunking is not a nicety

  `raft_election`'s counterexample — the trace the whole feature is for — is nineteen states.
  At eight characters a column that is 152 characters against the 68 `format/1` rules to, so
  a renderer that emits one column per state cannot render its own motivating example. States
  are therefore chunked into groups that fit the budget, each group repeating the name column
  and labelled with the states it covers.

  `changed_only: true` narrows a wide trace but cannot be relied on to: an expression that
  moves at every step is exactly the one worth watching, and it is never hidden.
  """

  alias TLA.Trace

  # Two spaces of indent, and two between columns. Both are counted against `:width`, so the
  # budget is a promise about the rendered line rather than about the table inside it.
  @indent "  "
  @gutter 2

  @doc """
  `TLA.Trace.explore/3`. See its documentation for the options and the output.
  """
  def explore(trace_or_lasso, expressions, opts \\ [])

  def explore(_trace_or_lasso, [], _opts) do
    raise ArgumentError,
          "explore/3 was given no expressions. A table of no rows answers no question — " <>
            "pass at least one, as `name: fn state -> ... end`."
  end

  def explore(trace_or_lasso, expressions, opts) when is_list(expressions) do
    opts = Keyword.validate!(opts, changed_only: false, width: 68)
    {trace, loop} = Trace.join(trace_or_lasso)

    if trace.states == [] do
      raise ArgumentError,
            "the trace has no states, so there is nowhere to evaluate the expressions."
    end

    {rows, warnings} = evaluate(expressions, trace.states)
    shown = if opts[:changed_only], do: Enum.filter(rows, &changing?/1), else: rows

    Trace.banner(title(trace)) <>
      "\n\n" <>
      body(trace, shown, loop, opts) <>
      bindings(trace) <>
      warnings(warnings) <>
      loop_note(loop) <>
      String.duplicate("═", 68) <> "\n"
  end

  def explore(_trace_or_lasso, expressions, _opts) do
    raise ArgumentError,
          "expressions must be a keyword list, got: #{inspect(expressions)}. It is a list " <>
            "rather than a map because the rows are rendered in the order given, and the " <>
            "order a reader asked for their questions in is information."
  end

  defp title(%Trace{property: nil}), do: "EXPLORE"
  defp title(%Trace{property: property}), do: "EXPLORE: #{property}"

  # ── Evaluation ──────────────────────────────────────────────────────────────

  # One row per expression, one cell per state, and the failures collected beside them
  # rather than raised: the expression that blew up is usually the one asserting the very
  # invariant this counterexample violates.
  defp evaluate(expressions, states) do
    {rows, warnings} =
      Enum.map_reduce(expressions, [], fn {name, fun}, warnings ->
        {cells, warnings} =
          states
          |> Enum.with_index(1)
          |> Enum.map_reduce(warnings, fn {state, index}, warnings ->
            case evaluate_at(fun, state) do
              {:ok, value} -> {inspect(value), warnings}
              {:error, message} -> {"⚠", [{index, name, message} | warnings]}
            end
          end)

        {{name, cells}, warnings}
      end)

    {rows, Enum.reverse(warnings)}
  end

  # The rescue is scoped to this one call and turns the exception into an attributed
  # message, which is the same shape the three other rescues in the project take
  # (`mix/tasks/tla.check.ex`, `refinement.ex`, `spec/dsl.ex`). A `throw` or an `exit` is
  # left alone: neither is something a predicate over a state does on purpose.
  defp evaluate_at(fun, state) do
    {:ok, fun.(state)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp changing?({_name, cells}), do: length(Enum.uniq(cells)) > 1

  # ── The table ───────────────────────────────────────────────────────────────

  defp body(_trace, [], _loop, _opts) do
    @indent <>
      "Every expression holds the same value at every state, and `changed_only: true` " <>
      "hid them all.\n"
  end

  defp body(trace, rows, loop, opts) do
    columns = columns(trace, rows, loop)
    name_width = rows |> Enum.map(&String.length(to_string(elem(&1, 0)))) |> Enum.max()
    groups = chunk(columns, name_width, opts[:width])
    labelled? = length(groups) > 1

    Enum.map_join(groups, "\n", &group(&1, rows, name_width, labelled?))
  end

  defp columns(trace, rows, loop) do
    cells = Enum.map(rows, fn {_name, cells} -> cells end)

    Enum.map(0..(length(trace.states) - 1), fn index ->
      %{
        number: index + 1,
        label: Integer.to_string(index + 1),
        # Written the way `format/1` writes it, including for a trace whose `actions` are
        # short of its `states` — that is a corrupt trace, and `validate/3` is what says so.
        action: if(index == 0, do: "init", else: "#{Enum.at(trace.actions, index - 1)}"),
        marker: if(repeating?(loop, index + 1), do: "↺", else: ""),
        cells: Enum.map(cells, &Enum.at(&1, index))
      }
    end)
  end

  defp repeating?(nil, _number), do: false
  defp repeating?({back_to, _cycle}, number), do: number >= back_to

  defp width(column) do
    [column.label, column.action, column.marker | column.cells]
    |> Enum.map(&String.length/1)
    |> Enum.max()
  end

  # Greedy, and always takes at least one column: a single value wider than the whole budget
  # still has to be printed somewhere, and an empty group would loop forever.
  defp chunk(columns, name_width, budget) do
    start = String.length(@indent) + name_width

    {done, current, _used} =
      Enum.reduce(columns, {[], [], start}, fn column, {done, current, used} ->
        used = used + width(column) + @gutter

        cond do
          current == [] -> {done, [column], used}
          used <= budget -> {done, [column | current], used}
          true -> {[Enum.reverse(current) | done], [column], start + width(column) + @gutter}
        end
      end)

    Enum.reverse([Enum.reverse(current) | done])
  end

  defp group(columns, rows, name_width, labelled?) do
    header =
      case {labelled?, hd(columns).number, List.last(columns).number} do
        {false, _first, _last} -> ""
        {true, only, only} -> @indent <> "State #{only}\n"
        {true, first, last} -> @indent <> "States #{first}-#{last}\n"
      end

    marker =
      if Enum.any?(columns, &(&1.marker != "")) do
        line("", columns, & &1.marker, name_width) <> "\n"
      else
        ""
      end

    rule =
      @indent <>
        String.duplicate("─", name_width + Enum.sum(Enum.map(columns, &(width(&1) + @gutter))))

    cells =
      rows
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {{name, _cells}, row} ->
        line(name, columns, &Enum.at(&1.cells, row), name_width)
      end)

    header <>
      marker <>
      line("", columns, & &1.label, name_width) <>
      "\n" <>
      line("", columns, & &1.action, name_width) <>
      "\n" <> rule <> "\n" <> cells <> "\n"
  end

  # Names left, values right: a column of right-aligned numbers is the one a reader can
  # scan for the step where it moved. Trimmed, because padding an empty marker or a short
  # final column would otherwise leave trailing whitespace on every header line.
  defp line(name, columns, cell, name_width) do
    (@indent <>
       String.pad_trailing(to_string(name), name_width) <>
       Enum.map_join(columns, "", fn column ->
         String.pad_leading(cell.(column), width(column) + @gutter)
       end))
    |> String.trim_trailing()
  end

  # ── What goes under the table ───────────────────────────────────────────────

  # Step `n` produces state `n + 1`, so a binding is listed against the state it explains.
  # Actions taking no parameters are left out: `call/2` renders those as the bare name, which
  # the header already carries.
  defp bindings(trace) do
    notes =
      trace.bindings
      |> Enum.with_index(2)
      |> Enum.reject(fn {binding, _state} -> binding in [nil, %{}] end)
      |> Enum.map_join("\n", fn {binding, state} ->
        @indent <>
          @indent <> "#{state}  " <> Trace.call(Enum.at(trace.actions, state - 2), binding)
      end)

    if notes == "", do: "", else: "\n" <> @indent <> "Bindings:\n" <> notes <> "\n"
  end

  defp warnings([]), do: ""

  defp warnings(warnings) do
    "\n" <>
      Enum.map_join(warnings, "\n", fn {state, name, message} ->
        @indent <> "⚠ state #{state}, #{name}: #{message}"
      end) <> "\n"
  end

  defp loop_note(nil), do: ""
  defp loop_note({back_to, cycle}), do: Trace.loop_note(cycle, back_to)
end
