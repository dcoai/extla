defmodule TLA.SpecOptionsTest do
  @moduledoc """
  The specification's list of a task's options, and the task's own `@switches`, held to each
  other (#132, #134).

  `spec/04-layer2-model-checker.md` reproduces `Mix.Tasks.Tla.Check`'s moduledoc as prose, and
  nothing compared the copy to the original. What that cost: the spec asserted `--workers` was
  **not** a flag of the task, nine hundred lines after the same file documented `workers:` as a
  config option — so it disagreed with the code and with itself, from Phase 4 until #132. Four
  more switches were undocumented, and the Usage block demonstrated `--graph`/`--output`, which
  the task refuses.

  Scoped to option **lists** and nothing wider, deliberately. Evaluation swept all of `spec/` for
  the claim class that produced the bug — an assertion that something is not built or waits on a
  phase — and found exactly one occurrence, the one being fixed. Prose does not drift here often
  enough to gate; flag lists change whenever a flag does, which is every few work items.
  """
  use ExUnit.Case, async: true

  @spec_file Path.expand("../../spec/04-layer2-model-checker.md", __DIR__)

  # One entry per task whose options the specification lists. `mix tla.explore` is deliberately
  # absent: its section shows flags in a usage example rather than in an option list, and there
  # is nothing to compare. Adding a task here is one line once its section grows a list.
  @documented [{Mix.Tasks.Tla.Check, "defmodule Mix.Tasks.Tla.Check do"}]

  describe "every task whose options the spec lists" do
    for {task, anchor} <- @documented do
      test "#{inspect(task)} declares exactly the switches #{Path.basename(@spec_file)} documents" do
        documented = documented_options(unquote(anchor))
        declared = declared_switches(unquote(task))

        assert MapSet.equal?(documented, declared), """
        #{inspect(unquote(task))} and spec/04-layer2-model-checker.md disagree about its options.

          in @switches, undocumented:  #{inspect(Enum.sort(MapSet.difference(declared, documented)))}
          documented, not a switch:    #{inspect(Enum.sort(MapSet.difference(documented, declared)))}

        The first list is a flag a user cannot discover from the specification. The second is one
        the specification invites them to pass and `OptionParser` will refuse — which is worse,
        because it fails only when someone trusts the document.

        Update the option list in the task's section of the spec, or the task.
        """
      end
    end
  end

  describe "the parser itself" do
    # A parser that silently matches nothing turns this gate into `assert true`, and a gate that
    # cannot fail is the failure mode this whole proposal is about. So it raises rather than
    # returning an empty set, and that behaviour is asserted rather than assumed.
    test "raises when the anchor is absent rather than comparing against nothing" do
      assert_raise RuntimeError, ~r/no section anchored at/, fn ->
        documented_options("defmodule Mix.Tasks.Tla.NoSuchTask do")
      end
    end

    test "raises when a section carries no option list at all" do
      assert_raise RuntimeError, ~r/no option lines/, fn ->
        # A real anchor whose section is prose and code, with no `--flag` definitions in it.
        documented_options("defmodule TLA.Spec.Compiled do")
      end
    end

    test "reads option definitions and not usage examples" do
      # `mix tla.check Specs.X --max-states 100000` is a usage line, and `--max-states` is also a
      # definition further down. The distinction matters: if usage lines counted, the `--graph`
      # example that started #132 would have read as documentation of a flag that does not exist.
      options = documented_options("defmodule Mix.Tasks.Tla.Check do")

      assert "--max-states" in options
      refute "--graph" in options
      refute "--output" in options
    end
  end

  # ── The two sides ───────────────────────────────────────────────────────────

  defp declared_switches(task) do
    MapSet.new(task.switches(), fn {name, _type} ->
      "--" <> String.replace(Atom.to_string(name), "_", "-")
    end)
  end

  # An option DEFINITION is a line whose first non-space characters are the flag, followed by the
  # description. A usage example begins with the command, so `^\s+--` separates them without
  # needing to know anything else about the layout.
  defp documented_options(anchor) do
    section = section(anchor)

    options =
      ~r/^\s+(--[a-z][a-z-]*)\s/m
      |> Regex.scan(section)
      |> MapSet.new(fn [_line, flag] -> flag end)

    if MapSet.size(options) == 0 do
      raise "no option lines in the section anchored at #{inspect(anchor)}. Either the task " <>
              "documents none — in which case remove it from @documented — or the layout " <>
              "changed and this parser now reads nothing, which would make the test vacuous."
    end

    options
  end

  # From the anchor to the end of the fenced block that contains it, so a neighbouring task's
  # options cannot leak in.
  defp section(anchor) do
    contents = File.read!(@spec_file)

    case String.split(contents, anchor, parts: 2) do
      [_before, after_anchor] ->
        after_anchor |> String.split("\n```", parts: 2) |> hd()

      _absent ->
        raise "no section anchored at #{inspect(anchor)} in #{@spec_file}. The specification " <>
                "no longer reproduces this task, or the anchor changed."
    end
  end
end
