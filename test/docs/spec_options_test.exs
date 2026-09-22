defmodule TLA.SpecOptionsTest do
  @moduledoc """
  The specification's list of a task's options, and the task's own `@switches`, held to each
  other (#132, #134) — over the set of tasks `CLI_SURFACE.md` derives (#272).

  `spec/04-layer2-model-checker.md` reproduces `Mix.Tasks.Tla.Check`'s moduledoc as prose, and
  nothing compared the copy to the original. What that cost: the spec asserted `--workers` was
  **not** a flag of the task, nine hundred lines after the same file documented `workers:` as a
  config option — so it disagreed with the code and with itself, from Phase 4 until #132. Four
  more switches were undocumented, and the Usage block demonstrated `--graph`/`--output`, which
  the task refuses.

  ## Why the list of tasks is no longer written here

  Until #272 this file carried `@documented`: six `{task, spec file, anchor}` tuples, correct
  because #163 had written them eleven days earlier. A seventh task would not have been in it,
  and nothing would have said so — a task absent from the list reads exactly like a task that
  passes, which is the vacuity this project keeps finding in its own gates.

  The set now comes from `TLA.CliSurface`, which finds the tasks by walking `mix/tasks/` and
  finds each one's spec section by searching `spec/*.md` for its `defmodule` line. So this test
  iterates what the directory holds, a task with no section fails the "every shipped task is
  specified" assertion below rather than going unchecked, and the golden a reader opens lists
  the same set this gate walks — by construction, not by two hand lists agreeing.

  Scoped to option **lists** and nothing wider, deliberately. Evaluation swept all of `spec/`
  for the claim class that produced the bug — an assertion that something is not built or waits
  on a phase — and found exactly one occurrence, the one being fixed. Prose does not drift here
  often enough to gate; flag lists change whenever a flag does, which is every few work items.
  """
  use ExUnit.Case, async: true

  alias TLA.CliSurface

  @layer2 Path.expand("../../spec/04-layer2-model-checker.md", __DIR__)
  @root Path.expand("../..", __DIR__)

  setup_all do
    %{tasks: CliSurface.run(@root)}
  end

  describe "every task the specification documents" do
    test "declares exactly the switches its spec section lists", %{tasks: tasks} do
      documented = Enum.filter(tasks, &(&1.spec != nil))

      assert documented != [], "no task has a spec section; the anchor search reads nothing"

      for task <- documented do
        {path, anchor} = task.spec
        from_spec = documented_options(Path.join(@root, path), anchor)
        declared = MapSet.new(task.switches, fn {name, _type} -> CliSurface.flag(name) end)

        assert MapSet.equal?(from_spec, declared), """
        mix #{task.task} and #{path} disagree about its options.

          in @switches, undocumented:  #{inspect(Enum.sort(MapSet.difference(declared, from_spec)))}
          documented, not a switch:    #{inspect(Enum.sort(MapSet.difference(from_spec, declared)))}

        The first list is a flag a user cannot discover from the specification. The second is one
        the specification invites them to pass and `OptionParser` will refuse — which is worse,
        because it fails only when someone trusts the document.

        Update the option list in the task's section of the spec, or the task.
        """
      end
    end

    # The half `@documented` could not state: a task nobody listed was a task nobody checked.
    test "and every shipped task HAS a section", %{tasks: tasks} do
      unspecified = for t <- tasks, t.shipped?, t.spec == nil, do: t.task

      assert unspecified == [], """
      #{inspect(unspecified)} ship from lib/ and no spec/*.md file reproduces them.

      A shipped task is part of the published surface: `spec/04` or `spec/05` carries its
      section, and CLI_SURFACE.md's heading for it says which. Add the section, or — if the
      task is tooling rather than surface — move it out of `lib/`.
      """
    end

    test "and a task outside lib/ is listed without one, rather than unlisted", %{tasks: tasks} do
      tooling = Enum.reject(tasks, & &1.shipped?)

      assert tooling != [], "the ledger's own tasks are not being scanned"
      assert Enum.all?(tooling, &(&1.spec == nil))
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

  # ── The spec side ───────────────────────────────────────────────────────────

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
              "documents none — in which case its section is not an option list, and " <>
              "CLI_SURFACE.md should not pair it with one — or the layout changed and this " <>
              "parser now reads nothing, which would make the test vacuous."
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
