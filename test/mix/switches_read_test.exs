defmodule Mix.Tasks.Extla.SwitchesReadTest do
  @moduledoc """
  Every switch a task declares is read somewhere in that task (#165).

  `mix extla.replay` declared `init_arg: :string`, so `OptionParser` accepted `--init-arg`,
  and nothing ever read it: a user passed it, got no error and no effect. `strict_argv_test`
  holds every task to *parsing* strictly, which refuses a switch nobody declared. This is the
  other half, a switch declared that nobody reads.

  The check is deliberately cheap: every key of `@switches` has to appear as an atom
  somewhere else in the task's source, whether in `Keyword.get(opts, :key)`, `opts[:key]` or
  a `{:key, value}` pattern. A task that reads its options generically (say, passing the
  whole keyword list on) would satisfy this without using every key. None does today, and
  that blind spot is the trade for a check that reads source and needs no knowledge of
  each task. Read from source, so the dev-only ledger tasks and the test-support task are
  held too.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @trees ["lib/mix/tasks", "ledger/mix/tasks", "test/support/mix/tasks"]

  @doc false
  def unread(source) do
    ast = Code.string_to_quoted!(source)

    {declared, rest} =
      Macro.prewalk(ast, nil, fn
        {:@, _, [{:switches, _, [switches]}]}, nil when is_list(switches) ->
          {:__switches_removed__, Keyword.keys(switches)}

        node, acc ->
          {node, acc}
      end)

    used = atoms(declared)
    Enum.reject(rest || [], &MapSet.member?(used, &1))
  end

  defp atoms(ast) do
    {_, found} =
      Macro.prewalk(ast, MapSet.new(), fn
        atom, acc when is_atom(atom) -> {atom, MapSet.put(acc, atom)}
        node, acc -> {node, acc}
      end)

    found
  end

  defp tasks do
    for tree <- @trees, path <- Path.wildcard(Path.join([@root, tree, "*.ex"])), do: path
  end

  test "every task reads every switch it declares" do
    offenders =
      for path <- tasks(),
          key <- unread(File.read!(path)),
          do: "#{Path.relative_to(path, @root)}: --#{String.replace(to_string(key), "_", "-")}"

    assert offenders == [], """
    #{length(offenders)} switch(es) declared in @switches and read nowhere in the task:

      #{Enum.join(offenders, "\n  ")}

    OptionParser accepts a declared switch, so a user who passes it gets no error and no
    effect (#165). Read it, or remove it from @switches so it is refused by name.
    """
  end

  describe "the reader itself" do
    test "finds a declared switch that nothing reads, and not one that is read" do
      source = """
      defmodule Mix.Tasks.Fixture do
        @switches [trace: :string, init_arg: :string]
        def run(args) do
          {opts, _} = OptionParser.parse!(args, strict: @switches)
          Keyword.get(opts, :trace)
        end
      end
      """

      assert unread(source) == [:init_arg]
    end

    test "counts a key read through a pattern or an access" do
      source = """
      defmodule Mix.Tasks.Fixture do
        @switches [server: :string, timeout: :integer]
        def run(opts), do: Enum.map(opts, fn {:server, s} -> s; _ -> opts[:timeout] end)
      end
      """

      assert unread(source) == []
    end

    # Anti-vacuity: the walk must reach the tasks, or an empty offender list passes above.
    test "and the walk reads every tree's tasks, including the one #165 was found in" do
      paths = Enum.map(tasks(), &Path.relative_to(&1, @root))

      assert "lib/mix/tasks/extla.replay.ex" in paths
      assert Enum.any?(paths, &String.starts_with?(&1, "ledger/"))
      assert Enum.any?(paths, &String.starts_with?(&1, "test/support/"))
    end
  end
end
