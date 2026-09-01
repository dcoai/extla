defmodule TLA.MutationTest do
  @moduledoc """
  `TLA.Mutation` — the harness that measures what the gates catch (#46).

  The patching tests are pure and run in the normal suite: they are what keeps the
  catalogue honest as the checker moves, and a stale anchor has to be caught cheaply and
  often. Everything that copies the project, compiles it and runs a gate is tagged
  `:mutation` and excluded by default — one corpus gate is 45 seconds, and #46 requires
  `mix test` to stay near its current runtime.

      mix test --include mutation
  """

  use ExUnit.Case, async: true

  alias TLA.Mutation
  alias TLA.Mutation.Mutant

  # Real, and aimed at the search itself: `expand/3` folds over every action, so dropping
  # one removes states the corpus counted with TLC.
  @drops_an_action %Mutant{
    name: :drops_an_action,
    models: "successor generation that silently omits an action",
    file: "lib/tla/model_checker.ex",
    anchor: "    run.spec.actions\n    |> Enum.reduce_while(",
    replacement: "    Enum.drop(run.spec.actions, 1)\n    |> Enum.reduce_while(",
    kills: :corpus
  }

  @does_not_compile %Mutant{
    name: :does_not_compile,
    models: "a mutant whose patch does not parse — not a defect, and not a kill",
    file: "lib/tla/model_checker.ex",
    anchor: "  defp expand(run, id, state) do",
    replacement: "  defp expand(run, id, state) do <<< not elixir",
    kills: :corpus
  }

  describe "patch/2" do
    test "replaces the anchor and nothing else" do
      mutant = anchored("ANCHOR", "PATCHED")

      assert Mutation.patch("before\nANCHOR\nafter\n", mutant) == "before\nPATCHED\nafter\n"
    end

    # The way this harness rots: the checker's source moves, the mutant stops applying,
    # and a sweep that skipped it stays green while measuring less. So it is the loudest
    # failure the runner has.
    test "a missing anchor raises, naming the mutant and the file" do
      mutant = %{anchored("THE ANCHOR", "x") | name: :moved_away}

      error = assert_raise ArgumentError, fn -> Mutation.patch("nothing here\n", mutant) end
      message = Exception.message(error)

      assert message =~ ":moved_away"
      assert message =~ "lib/tla/thing.ex"
      assert message =~ "no longer models what it claims"
      assert message =~ "rather than a skip"
    end

    test "an anchor that appears twice raises rather than guessing" do
      mutant = %{anchored("X", "Y") | name: :ambiguous}

      error = assert_raise ArgumentError, fn -> Mutation.patch("X\nmiddle\nX\n", mutant) end

      assert Exception.message(error) =~ "appears 2 times"
      assert Exception.message(error) =~ "Lengthen the anchor"
    end

    test "a file the mutant names but the tree does not have raises" do
      dir = Path.join(System.tmp_dir!(), "mutation-missing-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      mutant = %{anchored("x", "y") | name: :gone, file: "lib/tla/deleted.ex"}

      error = assert_raise ArgumentError, fn -> Mutation.run_one(dir, mutant) end
      assert Exception.message(error) =~ "The catalogue is stale"
    end
  end

  describe "the catalogue's anchors still apply" do
    # Cheap, and it runs in the normal suite for that reason: it is the check that fails
    # the day someone edits `expand/3`, rather than three weeks later when a sweep is next
    # run and quietly measures less.
    test "every anchor used in this file is present exactly once in the real source" do
      for mutant <- [@drops_an_action, @does_not_compile] do
        source = File.read!(mutant.file)
        count = length(String.split(source, mutant.anchor)) - 1

        assert count == 1,
               "#{mutant.name}: anchor appears #{count} times in #{mutant.file}, expected 1"
      end
    end
  end

  defp anchored(anchor, replacement) do
    %Mutant{
      name: :t,
      models: "a fixture",
      file: "lib/tla/thing.ex",
      anchor: anchor,
      replacement: replacement,
      kills: :corpus
    }
  end
end

defmodule TLA.MutationGateTest do
  @moduledoc """
  `TLA.Mutation` against a real gate: copy the project, compile it, run the corpus.

  Its own module because `setup_all` is module-wide — one workspace is prepared and
  compiled once and the tests share it, which is the same reason the sweep shares one.

  Tagged `:mutation` and excluded by default (`test/test_helper.exs`). One corpus gate is
  45 seconds and #46 requires `mix test` to stay near its current runtime, so these belong
  to the sweep's CI job.
  """

  use ExUnit.Case, async: false

  alias TLA.Mutation
  alias TLA.Mutation.Mutant

  @moduletag :mutation
  @moduletag timeout: 900_000

  @drops_an_action %Mutant{
    name: :drops_an_action,
    models: "successor generation that silently omits an action",
    file: "lib/tla/model_checker.ex",
    anchor: "    run.spec.actions\n    |> Enum.reduce_while(",
    replacement: "    Enum.drop(run.spec.actions, 1)\n    |> Enum.reduce_while(",
    kills: :corpus
  }

  @does_not_compile %Mutant{
    name: :does_not_compile,
    models: "a mutant whose patch does not parse — not a defect, and not a kill",
    file: "lib/tla/model_checker.ex",
    anchor: "  defp expand(run, id, state) do",
    replacement: "  defp expand(run, id, state) do <<< not elixir",
    kills: :corpus
  }

  setup_all do
    assert Mutation.timeout_available?(), "this suite needs timeout(1)"
    {:ok, workspace} = Mutation.prepare()
    on_exit(fn -> Mutation.cleanup(workspace) end)
    %{workspace: workspace}
  end

  test "a defect the corpus catches is killed, and the workspace is left pristine",
       %{workspace: workspace} do
    result = Mutation.run_one(workspace, @drops_an_action)

    assert result.outcome == :killed
    assert result.name == :drops_an_action
    assert result.gate == :corpus

    # Asserted here rather than in a test of its own: a separate test would depend on this
    # one having run first, and ExUnit orders a module's tests by seed.
    source = File.read!(Path.join(workspace, @drops_an_action.file))
    assert source =~ @drops_an_action.anchor
    refute source =~ "Enum.drop(run.spec.actions, 1)"
  end

  # The distinction #46 turns on: a mutant that never ran says nothing about the gates,
  # and counting it as caught is how a harness reports a kill rate it has not earned.
  test "a patch that does not compile is a build_error, not a kill", %{workspace: workspace} do
    result = Mutation.run_one(workspace, @does_not_compile)

    assert result.outcome == :build_error
  end

  # A generous compile budget and a one-second gate, so it is the GATE that runs out —
  # the path a genuinely hanging checker would take.
  test "a gate that runs out of time is a timeout, not a kill", %{workspace: workspace} do
    result = Mutation.run_one(workspace, @drops_an_action, timeout: 1, compile_timeout: 300)

    assert result.outcome == :timeout
  end

  test "sweep/2 runs a catalogue and leaves no workspace behind" do
    # Compared against a snapshot rather than against the empty set: `setup_all`'s own
    # workspace is alive for the whole module, so an absolute assertion would fail on a
    # directory this test did not create.
    before = workspaces()

    {:ok, [result]} = Mutation.sweep([@drops_an_action])

    assert result.outcome == :killed

    leftovers = MapSet.difference(workspaces(), before)
    assert MapSet.size(leftovers) == 0, "left behind: #{inspect(MapSet.to_list(leftovers))}"
  end

  defp workspaces do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "tla-mutation-"))
    |> MapSet.new()
  end
end
