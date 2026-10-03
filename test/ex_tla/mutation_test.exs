defmodule ExTLA.MutationTest do
  @moduledoc """
  `ExTLA.Mutation` — the harness that measures what the gates catch (#46).

  The patching tests are pure and run in the normal suite: they are what keeps the
  catalogue honest as the checker moves, and a stale anchor has to be caught cheaply and
  often. Everything that copies the project, compiles it and runs a gate is tagged
  `:mutation` and excluded by default — one corpus gate is 45 seconds, and #46 requires
  `mix test` to stay near its current runtime.

      mix test --include mutation
  """

  use ExUnit.Case, async: true

  alias ExTLA.Mutation
  alias ExTLA.Mutation.Catalogue
  alias ExTLA.Mutation.Mutant

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
      assert message =~ "lib/ex_tla/thing.ex"
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

      mutant = %{anchored("x", "y") | name: :gone, file: "lib/ex_tla/deleted.ex"}

      error = assert_raise ArgumentError, fn -> Mutation.run_one(dir, mutant) end
      assert Exception.message(error) =~ "The catalogue is stale"
    end
  end

  describe "the catalogue" do
    # Cheap, and in the normal suite for that reason: it is the check that fails the day
    # someone edits `expand/3`, rather than three weeks later when a sweep is next run and
    # quietly measures less. Every mutant, not just the ones this file uses.
    test "every anchor resolves exactly once in the file its mutant names" do
      for mutant <- Catalogue.all() do
        assert File.exists?(mutant.file),
               "#{mutant.name} names #{mutant.file}, which does not exist"

        source = File.read!(mutant.file)
        count = length(String.split(source, mutant.anchor)) - 1

        assert count == 1,
               "#{mutant.name}: anchor appears #{count} times in #{mutant.file}, expected 1"
      end
    end

    test "every mutant says what it models, so the catalogue can be read" do
      for mutant <- Catalogue.all() do
        assert is_binary(mutant.models) and String.length(mutant.models) > 20,
               "#{mutant.name} has no usable `models:` line"
      end
    end

    test "names are unique — they are the keys in survivors.json" do
      names = Enum.map(Catalogue.all(), & &1.name)
      assert names == Enum.uniq(names)
    end

    test "fetch!/1 names what is available when asked for something that is not" do
      error = assert_raise ArgumentError, fn -> Catalogue.fetch!(:no_such_mutant) end

      assert Exception.message(error) =~ ":no_such_mutant"
      assert Exception.message(error) =~ ":drops_an_action"
    end
  end

  describe "the artifact" do
    # Real catalogue names, because `encode/1` looks each row's `models:` up there — the
    # artifact carries what the mutant models, so a name with no mutant behind it is not a
    # row the artifact could ever hold.
    @results [
      %{name: :weakens_a_type_domain, outcome: :survived, gate: :corpus, expected: :nothing},
      %{name: :drops_an_action, outcome: :killed, gate: :corpus, expected: :corpus}
    ]

    test "is sorted by name, so two runs of the same code produce the same bytes" do
      first = Mix.Tasks.Tla.Mutants.encode(@results)
      again = Mix.Tasks.Tla.Mutants.encode(Enum.reverse(@results))

      assert first == again

      names = Jason.decode!(first)["mutants"] |> Enum.map(& &1["name"])
      assert names == Enum.sort(names)
      assert names == ["drops_an_action", "weakens_a_type_domain"]
    end

    # Anything that varies between two runs of the same code makes the drift gate cry
    # wolf, and a gate that cries wolf gets disabled.
    test "carries nothing that varies between identical runs" do
      encoded = Mix.Tasks.Tla.Mutants.encode(@results)

      refute encoded =~ ~r/\d{4}-\d{2}-\d{2}/, "a date leaked into the artifact"
      refute encoded =~ "ms"
      refute encoded =~ "duration"
      refute encoded =~ "output"
    end

    test "counts every outcome, including the two that are not kills" do
      summary =
        Mix.Tasks.Tla.Mutants.encode(@results)
        |> Jason.decode!()
        |> Map.fetch!("summary")

      assert summary == %{"killed" => 1, "survived" => 1, "build_error" => 0, "timeout" => 0}
    end
  end

  describe "drift" do
    # The two directions mean opposite things, and a diff alone does not say which
    # happened — so the message names them rather than leaving a reader to work it out.
    test "a gate that got weaker is reported as a regression" do
      was = %{"mutants" => [%{"name" => "a", "outcome" => "killed"}]}
      now = %{"mutants" => [%{"name" => "a", "outcome" => "survived"}]}

      message = Mix.Tasks.Tla.Mutants.drift_message(was, now)

      assert message =~ "REGRESSION"
      assert message =~ "a — now survived"
      refute message =~ "PROGRESS"
    end

    test "a gate that got stronger is reported as progress, and still fails" do
      was = %{"mutants" => [%{"name" => "a", "outcome" => "survived"}]}
      now = %{"mutants" => [%{"name" => "a", "outcome" => "killed"}]}

      message = Mix.Tasks.Tla.Mutants.drift_message(was, now)

      assert message =~ "PROGRESS"
      refute message =~ "REGRESSION"
      assert message =~ "has to be recorded or it can be"
    end

    test "a mutant added to or removed from the catalogue is named" do
      was = %{"mutants" => [%{"name" => "gone", "outcome" => "killed"}]}
      now = %{"mutants" => [%{"name" => "fresh", "outcome" => "killed"}]}

      message = Mix.Tasks.Tla.Mutants.drift_message(was, now)

      assert message =~ "new to the catalogue"
      assert message =~ "fresh"
      assert message =~ "gone from the catalogue"
      assert message =~ "gone"
    end
  end

  defp anchored(anchor, replacement) do
    %Mutant{
      name: :t,
      models: "a fixture",
      file: "lib/ex_tla/thing.ex",
      anchor: anchor,
      replacement: replacement,
      kills: :corpus
    }
  end
end

defmodule ExTLA.MutationGateTest do
  @moduledoc """
  `ExTLA.Mutation` against a real gate: copy the project, compile it, run the corpus.

  Its own module because `setup_all` is module-wide — one workspace is prepared and
  compiled once and the tests share it, which is the same reason the sweep shares one.

  Tagged `:mutation` and excluded by default (`test/test_helper.exs`). One corpus gate is
  45 seconds and #46 requires `mix test` to stay near its current runtime, so these belong
  to the sweep's CI job.
  """

  use ExUnit.Case, async: false

  alias ExTLA.Mutation
  alias ExTLA.Mutation.Catalogue
  alias ExTLA.Mutation.Mutant

  @moduletag :mutation
  @moduletag timeout: 900_000

  @drops_an_action %Mutant{
    name: :drops_an_action,
    models: "successor generation that silently omits an action",
    file: "lib/ex_tla/model_checker.ex",
    anchor: "    run.spec.actions\n    |> Enum.reduce_while(",
    replacement: "    Enum.drop(run.spec.actions, 1)\n    |> Enum.reduce_while(",
    kills: :corpus
  }

  @does_not_compile %Mutant{
    name: :does_not_compile,
    models: "a mutant whose patch does not parse — not a defect, and not a kill",
    file: "lib/ex_tla/model_checker.ex",
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
