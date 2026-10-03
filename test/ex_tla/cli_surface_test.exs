defmodule ExTLA.CliSurfaceTest do
  @moduledoc """
  `CLI_SURFACE.md`'s scanner and the properties its drift gate rests on (#270, #272).

  The scanner is asserted against fixture task sources in a `tmp_dir`, not against the real
  tree, because the interesting cases are the ones the real tree does not have: a task with no
  spec section, a task whose moduledoc is interpolated, an exit-code table that runs on over
  several lines. The real tree is then checked for the two facts that must hold of it — the
  golden is current, and every shipped task is specified — and `spec_options_test.exs` walks
  the same rows this golden renders.
  """
  use ExUnit.Case, async: true

  alias ExTLA.CliSurface

  @moduletag :tmp_dir

  # A task whose help text is computed, like `mix tla.visualize`'s default `--max-states`. Its
  # moduledoc is a `<<>>` AST node rather than a binary, and an earlier draft's `is_binary`
  # guard read it as absent — silently emptying the exit-code table of the one task whose help
  # is computed. The fixture exists so that class cannot return.
  @interpolated ~S'''
  defmodule Mix.Tasks.Tla.Fixture do
    @shortdoc "a fixture"
    @moduledoc """
    Usage:

        --max-states   Refuse past this many states (default #{1 + 1}).

    ## Exit codes

        0  the thing was done
        1  the thing was not done, and this is why: a reason that
           runs onto a second line

    Prose after the table, which is not an exit code.
    """
    use Mix.Task

    @switches [max_states: :integer, dry_run: :boolean]

    @impl Mix.Task
    def run(argv), do: argv
  end
  '''

  @plain ~S'''
  defmodule Mix.Tasks.Tla.Plain do
    @moduledoc "No table here."
    use Mix.Task

    @switches [only: :string]

    @impl Mix.Task
    def run(argv), do: argv
  end
  '''

  defp tree(tmp, sources, specs \\ []) do
    File.mkdir_p!(Path.join(tmp, "lib/mix/tasks"))
    File.mkdir_p!(Path.join(tmp, "spec"))

    for {name, source} <- sources do
      File.write!(Path.join([tmp, "lib/mix/tasks", name]), source)
    end

    for {name, contents} <- specs do
      File.write!(Path.join([tmp, "spec", name]), contents)
    end

    CliSurface.run(tmp)
  end

  defp task(tasks, name) do
    Enum.find(tasks, &(&1.task == name)) ||
      flunk("#{name} not scanned; got #{inspect(Enum.map(tasks, & &1.task))}")
  end

  describe "what the scanner reads" do
    setup %{tmp_dir: tmp} do
      %{tasks: tree(tmp, [{"tla.fixture.ex", @interpolated}, {"tla.plain.ex", @plain}])}
    end

    test "every task under a mix/tasks directory, by the name a user types", %{tasks: tasks} do
      assert Enum.map(tasks, & &1.task) == ["tla.fixture", "tla.plain"]
    end

    test "the switches, sorted, with the type OptionParser is given", %{tasks: tasks} do
      assert task(tasks, "tla.fixture").switches == [dry_run: :boolean, max_states: :integer]
      assert task(tasks, "tla.plain").switches == [only: :string]
    end

    test "an exit-code table, including a meaning that runs onto a second line",
         %{tasks: tasks} do
      assert task(tasks, "tla.fixture").exit_codes == [
               {"0", "the thing was done"},
               {"1",
                "the thing was not done, and this is why: a reason that runs onto a second line"}
             ]
    end

    test "prose after the table is not an exit code", %{tasks: tasks} do
      refute Enum.any?(task(tasks, "tla.fixture").exit_codes, fn {_, meaning} ->
               meaning =~ "Prose after"
             end)
    end

    test "a task with no table has no exit rows, which is a finding and not a blank",
         %{tasks: tasks} do
      assert task(tasks, "tla.plain").exit_codes == []
      assert CliSurface.render(tasks) =~ "`mix tla.plain`"
      assert CliSurface.render(tasks) =~ "NO EXIT-CODE TABLE"
    end
  end

  describe "the spec section is derived, not listed" do
    test "a task whose defmodule line appears in a spec file is paired with it", %{tmp_dir: tmp} do
      tasks =
        tree(
          tmp,
          [{"tla.plain.ex", @plain}],
          [{"07-tasks.md", "```elixir\ndefmodule Mix.Tasks.Tla.Plain do\n  --only  a flag\n```"}]
        )

      assert task(tasks, "tla.plain").spec ==
               {"spec/07-tasks.md", "defmodule Mix.Tasks.Tla.Plain do"}
    end

    test "a shipped task with no section is listed and says so — the case @documented could not",
         %{tmp_dir: tmp} do
      tasks = tree(tmp, [{"tla.plain.ex", @plain}])
      plain = task(tasks, "tla.plain")

      assert plain.shipped?
      assert plain.spec == nil
      assert CliSurface.render(tasks) =~ "SHIPPED AND NOT SPECIFIED"
    end
  end

  describe "the golden is a stable function of source" do
    setup %{tmp_dir: tmp} do
      %{tasks: tree(tmp, [{"tla.fixture.ex", @interpolated}, {"tla.plain.ex", @plain}])}
    end

    test "rendering twice produces identical bytes", %{tasks: tasks} do
      assert CliSurface.render(tasks) == CliSurface.render(tasks)
    end

    test "a blank line above a task's switches leaves its version unchanged", %{tmp_dir: tmp} do
      moved = String.replace(@plain, "  @switches", "\n  # moved down\n  @switches")
      before = tree(tmp, [{"tla.plain.ex", @plain}]) |> task("tla.plain")
      after_move = tree(tmp, [{"tla.plain.ex", moved}]) |> task("tla.plain")

      assert before.version == after_move.version
    end

    test "adding a switch moves the version", %{tmp_dir: tmp} do
      changed = String.replace(@plain, "[only: :string]", "[only: :string, all: :boolean]")
      before = tree(tmp, [{"tla.plain.ex", @plain}]) |> task("tla.plain")
      after_change = tree(tmp, [{"tla.plain.ex", changed}]) |> task("tla.plain")

      refute before.version == after_change.version
    end

    test "no date or clock time reaches the output" do
      rendered = CliSurface.run() |> CliSurface.render()
      refute rendered =~ ~r/\d{4}-\d{2}-\d{2}/
      refute rendered =~ ~r/\d{2}:\d{2}:\d{2}/
    end
  end

  describe "against the real tree" do
    test "every scanned task is a real mix task with the switches it declares" do
      for task <- CliSurface.run() do
        assert Code.ensure_loaded?(task.module), "#{inspect(task.module)} does not compile"
        assert function_exported?(task.module, :run, 1)

        if function_exported?(task.module, :switches, 0) do
          assert Enum.sort(task.module.switches()) == task.switches,
                 "mix #{task.task}: CLI_SURFACE.md and switches/0 disagree"
        end
      end
    end

    test "the committed golden is current — the same equality the surface-drift job asserts" do
      path = Path.expand("../../CLI_SURFACE.md", __DIR__)
      assert File.read!(path) == CliSurface.run() |> CliSurface.render()
    end
  end
end
