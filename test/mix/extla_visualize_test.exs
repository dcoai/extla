defmodule Mix.Tasks.Extla.VisualizeTest do
  @moduledoc """
  `mix extla.visualize` — the Phase 4 entry `06-architecture.md` lists as "DOT only".

  The refusals carry most of the weight here, as they do for the export underneath: a
  visualization is a claim about a graph, and the ways it can quietly be a claim about a
  different graph are what the tests are for.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Extla.Visualize

  setup do
    Mix.shell(Mix.Shell.IO)
    :ok
  end

  # The same shape `tla_check_test.exs` uses, and for the same reason: the task signals
  # through its exit, which is the thing under test, so it has to be run for real.
  defp visualize(args) do
    parent = self()

    output =
      capture_io(fn ->
        code =
          try do
            Visualize.run(args)
            0
          catch
            :exit, {:shutdown, code} -> code
          end

        send(parent, {:exit_code, code})
      end)

    receive do
      {:exit_code, code} -> {output, code}
    after
      0 -> flunk("the task neither exited nor returned")
    end
  end

  # The refusal goes to stderr, where an error belongs, so the stdout helper above cannot
  # see it. Returns what was written there, with the exit code.
  defp visualize_err(args) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        {_out, code} = visualize(args)
        send(parent, {:exit_code, code})
      end)

    receive do
      {:exit_code, code} -> {stderr, code}
    after
      0 -> flunk("the task neither exited nor returned")
    end
  end

  describe "rendering" do
    test "writes DOT to stdout, and exits 0" do
      {output, code} = visualize(["ExTLA.TestSpecs.WithDefaults"])

      assert code == 0
      assert output =~ ~s(digraph "ExTLA.TestSpecs.WithDefaults")
      assert output =~ "rankdir=LR"
      assert output =~ "->"
      assert output =~ "n = 0"
    end

    @tag :tmp_dir
    test "writes to --output instead, and says where", %{tmp_dir: dir} do
      path = Path.join(dir, "graph.dot")
      {output, code} = visualize(["ExTLA.TestSpecs.WithDefaults", "--output", path])

      assert code == 0
      assert output =~ "wrote #{path}"
      refute output =~ "digraph"

      dot = File.read!(path)
      assert String.starts_with?(dot, "digraph ")
      assert String.ends_with?(dot, "}\n")
    end

    @tag :tmp_dir
    test "the file is what Graphviz would read, whatever else the task printed", %{tmp_dir: dir} do
      # The violation note goes to the shell rather than into the DOT, so that redirecting
      # stdout still produces a file a layout engine accepts.
      path = Path.join(dir, "broken.dot")
      {_output, 1} = visualize(["ExTLA.TestSpecs.Broken", "--output", path])

      dot = File.read!(path)
      refute dot =~ "refuted"
      assert String.starts_with?(dot, "digraph ")
    end
  end

  describe "a spec with a violation" do
    test "still writes the graph, emphasises the counterexample, and exits 1" do
      {output, code} = visualize(["ExTLA.TestSpecs.Broken"])

      assert code == 1
      assert output =~ "digraph"
      assert output =~ "penwidth", "the counterexample should be emphasised"
      assert output =~ "invariant :below_three is refuted at depth 4"

      # The graph is of an interrupted search, and saying so is the point — a picture of
      # part of a state space that does not admit to being partial is the failure mode
      # this whole layer is built to avoid.
      assert output =~ "covers only what the search reached"
    end
  end

  describe "what it refuses" do
    test "--format html, naming the decision rather than the absence" do
      error =
        assert_raise Mix.Error, fn ->
          visualize(["ExTLA.TestSpecs.WithDefaults", "--format", "html"])
        end

      message = Exception.message(error)
      assert message =~ "06-architecture.md §Phase 4"
      assert message =~ "maintenance sink"
      assert message =~ "dot -Tsvg"
    end

    test "--format mermaid, the same way" do
      assert_raise Mix.Error, ~r/§Deferred/, fn ->
        visualize(["ExTLA.TestSpecs.WithDefaults", "--format", "mermaid"])
      end
    end

    test "an unknown --format, the way mix extla.check does" do
      assert_raise Mix.Error, ~r/unknown --format "svg"; expected dot/, fn ->
        visualize(["ExTLA.TestSpecs.WithDefaults", "--format", "svg"])
      end
    end

    # This asserted `"4 states"` until #312 — the count of the whole state space, which the
    # task could only know because it searched the whole thing in order to draw none of it.
    # `--max-states` bounds the search now, so the number in the message is where the search
    # stopped and the message says so instead of offering it as a census.
    test "a graph past --max-states, which says the count is not a census" do
      {stderr, code} = visualize_err(["ExTLA.TestSpecs.WithDefaults", "--max-states", "1"])

      assert code == 2, "a graph too big to draw is not exit 1; that means a violation"
      assert stderr =~ "the limit is 1"
      assert stderr =~ "MORE THAN 1"
      assert stderr =~ "not a census"
    end

    # The other side of it: a search that finished under the limit knows exactly how many
    # states there are, and the refusal cannot fire at all — so nothing is ever drawn from a
    # search that stopped early.
    test "and a spec that fits is drawn in full, with no note" do
      {output, code} = visualize(["ExTLA.TestSpecs.WithDefaults", "--max-states", "50"])

      assert code == 0
      assert output =~ "digraph"
      refute output =~ "MORE THAN"
    end

    test "a module that is not a spec" do
      assert_raise Mix.Error, ~r/does not `use ExTLA.Spec`/, fn ->
        visualize(["Enum"])
      end
    end

    test "several specs at once, because a graph is one file" do
      error =
        assert_raise Mix.Error, fn ->
          visualize(["ExTLA.TestSpecs.WithDefaults", "ExTLA.TestSpecs.Broken"])
        end

      assert Exception.message(error) =~ "name one spec to visualize"
    end

    test "a spec whose constants are unassigned, with both places named" do
      error = assert_raise Mix.Error, fn -> visualize(["ExTLA.TestSpecs.Counter"]) end

      message = Exception.message(error)
      assert message =~ "no assignment for :max"
      assert message =~ "config :extla"
    end
  end

  # ── the flag reaches the search ─────────────────────────────────────────────

  describe "--max-states bounds the search, not only the rendering" do
    # The defect, in the form that makes it measurable rather than inferred. `Cube` has 8
    # states; bounded at 3 the search must stop having seen fewer than all of them, which
    # `ExTLA.ModelChecker` reports as `:max_states_reached`. Before #312 the flag was read
    # AFTER `explore/2` and the search ran to the checker's million-state default.
    test "so a bounded run stops rather than exploring past the limit" do
      {result, graph} = bounded(ExTLA.TestSpecs.Cube, 3)

      assert result.status == :max_states_reached
      assert graph.state_count < 8
    end

    test "and an unbounded run over the same spec finds all eight" do
      {result, graph} = bounded(ExTLA.TestSpecs.Cube, 50)

      assert result.status == :ok
      assert graph.state_count == 8
    end

    # The two together are the whole claim: the flag changes what the SEARCH does, and the
    # count in the refusal is therefore a fact about the search rather than about the spec.
    # Asserted through the task, so it is the task's config that is under test.
    test "and the task refuses without ever drawing a truncated graph" do
      {stderr, code} = visualize_err(["ExTLA.TestSpecs.Cube", "--max-states", "3"])

      assert code == 2
      refute stderr =~ "digraph"
      assert stderr =~ "MORE THAN 3"
    end

    defp bounded(module, max_states) do
      ExTLA.ModelChecker.explore(module, %{
        constants: %{},
        liveness_graph: true,
        check_deadlock: false,
        max_states: max_states
      })
    end
  end
end
