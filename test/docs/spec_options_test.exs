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

  @layer2 Path.expand("../../spec/04-layer2-model-checker.md", __DIR__)
  @layer3 Path.expand("../../spec/05-layer3-conformance.md", __DIR__)

  # One entry per task whose options the specification lists: `{task, spec file, anchor}`.
  #
  # This covered ONE task until #163 — `mix tla.check`, gated at #134 — and that section was
  # consequently the only flag list in the whole specification that stayed correct. Six more
  # drifted in the meantime: `tla.simulate` documented none of its eight switches,
  # `tla.replay` and `tla.visualize` were each missing one, and `tla.stamp` had no section
  # anywhere. The blocker was never the parser; it was that `switches/0` existed on one task.
  @documented [
    {Mix.Tasks.Tla.Check, @layer2, "defmodule Mix.Tasks.Tla.Check do"},
    {Mix.Tasks.Tla.Explore, @layer2, "defmodule Mix.Tasks.Tla.Explore do"},
    {Mix.Tasks.Tla.Simulate, @layer3, "defmodule Mix.Tasks.Tla.Simulate do"},
    {Mix.Tasks.Tla.Replay, @layer3, "defmodule Mix.Tasks.Tla.Replay do"},
    {Mix.Tasks.Tla.Visualize, @layer3, "defmodule Mix.Tasks.Tla.Visualize do"},
    {Mix.Tasks.Tla.Stamp, @layer3, "defmodule Mix.Tasks.Tla.Stamp do"}
  ]

  describe "every task whose options the spec lists" do
    for {task, file, anchor} <- @documented do
      test "#{inspect(task)} declares exactly the switches #{Path.basename(file)} documents" do
        documented = documented_options(unquote(file), unquote(anchor))
        declared = declared_switches(unquote(task))

        assert MapSet.equal?(documented, declared), """
        #{inspect(unquote(task))} and #{Path.basename(unquote(file))} disagree about its options.

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
        documented_options(@layer2, "defmodule Mix.Tasks.Tla.NoSuchTask do")
      end
    end

    test "raises when a section carries no option list at all" do
      assert_raise RuntimeError, ~r/no option lines/, fn ->
        # A real anchor whose section is prose and code, with no `--flag` definitions in it.
        documented_options(@layer2, "defmodule TLA.Spec.Compiled do")
      end
    end

    test "reads option definitions and not usage examples" do
      # `mix tla.check Specs.X --max-states 100000` is a usage line, and `--max-states` is also a
      # definition further down. The distinction matters: if usage lines counted, the `--graph`
      # example that started #132 would have read as documentation of a flag that does not exist.
      options = documented_options(@layer2, "defmodule Mix.Tasks.Tla.Check do")

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
  defp documented_options(file, anchor) do
    section = section(file, anchor)

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
  defp section(file, anchor) do
    contents = File.read!(file)

    case String.split(contents, anchor, parts: 2) do
      [_before, after_anchor] ->
        after_anchor |> String.split("\n```", parts: 2) |> hd()

      _absent ->
        raise "no section anchored at #{inspect(anchor)} in #{file}. The specification " <>
                "no longer reproduces this task, or the anchor changed."
    end
  end
end
