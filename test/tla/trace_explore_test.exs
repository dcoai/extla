defmodule TLA.TraceExploreTest do
  @moduledoc """
  `TLA.Trace.explore/3` — your own expressions evaluated at every state of a counterexample
  (#115).

  Most of these run against a hand-built `TLA.Trace.t()` rather than a checker run. That is
  not a shortcut: `explore/3` is a pure function of the struct, and a fixture is the only way
  to assert an exact table containing all three of the cases that matter at once — a `nil`, a
  value that never moves, and one that moves at every step. Two tests at the end run it over
  a counterexample the checker really produced, so the fixture cannot drift from the shape.
  """

  use ExUnit.Case, async: true

  alias TLA.{ModelChecker, Trace}

  defp trace do
    %Trace{
      type: :safety,
      property: :below_three,
      message: "",
      states: [
        %{n: 0, tag: nil},
        %{n: 1, tag: nil},
        %{n: 2, tag: :two},
        %{n: 3, tag: :two}
      ],
      actions: [:tick, :tick, :bump],
      bindings: [%{}, %{}, %{by: 1}],
      length: 4
    }
  end

  defp expressions do
    [n: & &1.n, tag: & &1.tag, steady: fn _state -> :same end]
  end

  describe "the table" do
    test "one row per expression, one column per state, with the action that produced it" do
      assert Trace.explore(trace(), expressions()) == """
             ═══ EXPLORE: below_three ═══════════════════════════════════════════

                           1      2      3      4
                        init   tick   tick   bump
               ──────────────────────────────────
               n           0      1      2      3
               tag       nil    nil   :two   :two
               steady  :same  :same  :same  :same

               Bindings:
                 4  bump(by: 1)
             ════════════════════════════════════════════════════════════════════
             """
    end

    test "rows are rendered in the order given, not sorted" do
      table = Trace.explore(trace(), zebra: & &1.n, alpha: & &1.tag)

      [zebra, alpha] =
        table
        |> String.split("\n")
        |> Enum.with_index()
        |> Enum.filter(fn {line, _} -> line =~ ~r/^\s+(zebra|alpha)\s/ end)
        |> Enum.map(fn {_, index} -> index end)

      assert zebra < alpha
    end

    test "a trace naming no property is still explorable" do
      table = Trace.explore(%{trace() | property: nil}, expressions())

      assert table =~ "═══ EXPLORE ══"
      refute table =~ "below_three"
    end

    test "an action taking no parameters gets no binding note" do
      table = Trace.explore(%{trace() | bindings: [%{}, %{}, %{}]}, n: & &1.n)

      refute table =~ "Bindings:"
    end
  end

  describe "an expression that raises" do
    test "is reported at the state it raised in, and the rest of the table still renders" do
      table =
        Trace.explore(trace(),
          n: & &1.n,
          doubled: fn state -> state.tag * 2 end
        )

      # The row is still there, with the two states where `tag` was an atom marked and the
      # message printed once per failing state.
      assert table =~ ~r/\n\s+doubled\s+⚠\s+⚠\s+⚠\s+⚠/
      assert table =~ "⚠ state 1, doubled: bad argument in arithmetic expression"
      assert table =~ "⚠ state 3, doubled: bad argument in arithmetic expression"

      # And the expression that did not raise is untouched.
      assert table =~ ~r/\n\s+n\s+0\s+1\s+2\s+3/
    end

    test "raising at only some states leaves the others carrying their values" do
      table =
        Trace.explore(trace(),
          risky: fn state -> if state.n > 1, do: raise(RuntimeError, "too big"), else: state.n end
        )

      assert table =~ ~r/\n\s+risky\s+0\s+1\s+⚠\s+⚠/
      assert table =~ "⚠ state 3, risky: too big"
      assert table =~ "⚠ state 4, risky: too big"
      refute table =~ "⚠ state 1"
    end
  end

  describe "changed_only" do
    test "hides a constant row and keeps a moving one" do
      table = Trace.explore(trace(), expressions(), changed_only: true)

      assert table =~ ~r/\n\s+n\s+0/
      assert table =~ ~r/\n\s+tag\s+nil/
      refute table =~ "steady"
    end

    test "a row that changes at every step is never hidden" do
      table = Trace.explore(trace(), [n: & &1.n], changed_only: true)

      assert table =~ ~r/\n\s+n\s+0\s+1\s+2\s+3/
    end

    test "when it hides everything, it says so rather than printing an empty table" do
      table = Trace.explore(trace(), [steady: fn _ -> :same end], changed_only: true)

      assert table =~ "Every expression holds the same value at every state"
      refute table =~ "───"
    end
  end

  describe "width" do
    # The motivating trace: `raft_election`'s counterexample is nineteen states, which is
    # what a renderer emitting one column per state cannot fit and this test pins.
    defp wide_trace(states) do
      %Trace{
        type: :safety,
        property: :below_three,
        states: Enum.map(0..(states - 1), &%{n: &1}),
        actions: List.duplicate(:tick, states - 1),
        bindings: List.duplicate(%{}, states - 1),
        length: states
      }
    end

    test "a trace too wide for the budget is chunked, and no line exceeds it" do
      table = Trace.explore(wide_trace(19), n: & &1.n)

      for line <- String.split(table, "\n"), not String.starts_with?(line, "═") do
        assert String.length(line) <= 68, "line over budget: #{inspect(line)}"
      end

      assert table =~ "States 1-"
      assert table =~ "-19"
    end

    test "every state appears exactly once across the chunks" do
      table = Trace.explore(wide_trace(19), n: & &1.n)

      values =
        table
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ ~r/^\s+n\s/))
        |> Enum.flat_map(&(String.split(&1) |> tl()))
        |> Enum.map(&String.to_integer/1)

      assert values == Enum.to_list(0..18)
    end

    test "each chunk repeats the name column" do
      chunks =
        wide_trace(19)
        |> Trace.explore(n: & &1.n)
        |> String.split("\n")
        |> Enum.count(&(&1 =~ ~r/^\s+n\s/))

      assert chunks > 1
    end

    test "a narrower budget makes more chunks, a wider one fewer" do
      narrow = Trace.explore(wide_trace(19), [n: & &1.n], width: 30)
      wide = Trace.explore(wide_trace(19), [n: & &1.n], width: 200)

      rows = fn table -> table |> String.split("\n") |> Enum.count(&(&1 =~ ~r/^\s+n\s/)) end

      assert rows.(narrow) > rows.(wide)
      assert rows.(wide) == 1
    end

    test "a single value wider than the whole budget is printed rather than truncated" do
      long = String.duplicate("x", 90)
      table = Trace.explore(wide_trace(3), long: fn _ -> long end)

      assert table =~ long
    end
  end

  describe "lassos" do
    defp lasso do
      %{
        prefix: %Trace{
          type: :liveness,
          property: :eventually_done,
          states: [%{n: 0}, %{n: 1}],
          actions: [:tick],
          bindings: [%{}],
          length: 2
        },
        cycle: %Trace{
          type: :liveness,
          states: [%{n: 1}, %{n: 2}, %{n: 1}],
          actions: [:up, :down],
          bindings: [%{}, %{}],
          length: 3
        }
      }
    end

    test "the repeating states are marked, and the loop is named under the table" do
      table = Trace.explore(lasso(), n: & &1.n)

      assert table =~ "↺"
      assert table =~ "↺ back to state 2 — states 2-3 repeat forever."
      # Prefix and cycle are one behaviour: four columns, the cycle's closing state included
      # exactly as `format/1` prints it.
      assert table =~ ~r/\n\s+n\s+0\s+1\s+2\s+1/
    end

    test "a cycle: nil lasso is not given a fabricated one" do
      table = Trace.explore(%{prefix: lasso().prefix, cycle: nil}, n: & &1.n)

      refute table =~ "↺"
      refute table =~ "repeat forever"
      assert table =~ ~r/\n\s+n\s+0\s+1/
    end

    test "a cycle with no actions is the terminal that stutters forever" do
      terminal = %{
        prefix: lasso().prefix,
        cycle: %Trace{states: [%{n: 1}], actions: [], bindings: [], length: 1}
      }

      table = Trace.explore(terminal, n: & &1.n)

      assert table =~ "State 2 has no successors: the behaviour stutters there forever"
    end
  end

  describe "what it refuses" do
    test "no expressions" do
      assert_raise ArgumentError, ~r/A table of no rows answers no question/, fn ->
        Trace.explore(trace(), [])
      end
    end

    # #212. A non-function expression failed at every state and was reported as N runtime
    # errors — under `changed_only`, N warnings beneath no row at all.
    test "an expression that is not a function is refused once, up front" do
      error = assert_raise(ArgumentError, fn -> Trace.explore(trace(), n: 42) end)
      assert error.message =~ "expression :n is 42, not a function of one argument"
    end

    test "a row that errors is shown under changed_only, since the error is the change" do
      output = Trace.explore(trace(), [boom: fn _ -> raise "no" end], changed_only: true)

      # The ROW, not only the warnings beneath: a name followed by an error cell in the table.
      assert output =~ ~r/^\s+boom\s+⚠/m
      refute output =~ "hid them all"
    end

    test "expressions as a map, because the order is information" do
      assert_raise ArgumentError, ~r/must be a keyword list/, fn ->
        Trace.explore(trace(), %{n: & &1.n})
      end
    end

    test "a trace with no states" do
      assert_raise ArgumentError, ~r/no states/, fn ->
        Trace.explore(%Trace{}, n: & &1.n)
      end
    end

    test "an option it does not have" do
      assert_raise ArgumentError, fn ->
        Trace.explore(trace(), [n: & &1.n], changed: true)
      end
    end
  end

  describe "over a counterexample the checker really produced" do
    test "a safety trace" do
      violation = ModelChecker.run(TLA.TestSpecs.Broken, %{}).violation

      table =
        Trace.explore(violation,
          n: & &1.n,
          over_two?: &(&1.n > 2)
        )

      assert table =~ "═══ EXPLORE: below_three ══"
      assert table =~ ~r/\n\s+n\s+0\s+1\s+2\s+3/
      assert table =~ ~r/\n\s+over_two\?\s+false\s+false\s+false\s+true/
    end

    test "a lasso, cycle marking and all" do
      violation =
        ModelChecker.run(TLA.TestSpecs.Stalls, %{check_liveness: true}).violation

      assert %{prefix: _, cycle: _} = violation

      table = Trace.explore(violation, phase: & &1.phase, done?: &(&1.phase == :done))

      assert table =~ "═══ EXPLORE: eventually_done ══"
      assert table =~ ":stuck"
      assert table =~ ~r/\n\s+done\?\s+false/
      assert table =~ "stutters there forever"
    end

    test "bindings appear under the table, written the way format/1 writes them" do
      violation =
        ModelChecker.run(TLA.TestSpecs.Transfer, %{
          constants: %{accounts: MapSet.new([:alice, :bob]), max_balance: 2}
        }).violation

      table = Trace.explore(violation, total: &(&1.balances |> Map.values() |> Enum.sum()))

      assert table =~ "Bindings:"
      assert table =~ ~r/begin_transfer\(amount: \d, from: :\w+, to: :\w+\)/
    end
  end
end
