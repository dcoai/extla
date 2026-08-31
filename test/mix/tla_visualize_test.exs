defmodule Mix.Tasks.Tla.VisualizeTest do
  @moduledoc """
  `mix tla.visualize` — the Phase 4 entry `06-architecture.md` lists as "DOT only".

  The refusals carry most of the weight here, as they do for the export underneath: a
  visualization is a claim about a graph, and the ways it can quietly be a claim about a
  different graph are what the tests are for.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Tla.Visualize

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

  describe "rendering" do
    test "writes DOT to stdout, and exits 0" do
      {output, code} = visualize(["TLA.TestSpecs.WithDefaults"])

      assert code == 0
      assert output =~ ~s(digraph "TLA.TestSpecs.WithDefaults")
      assert output =~ "rankdir=LR"
      assert output =~ "->"
      assert output =~ "n = 0"
    end

    @tag :tmp_dir
    test "writes to --output instead, and says where", %{tmp_dir: dir} do
      path = Path.join(dir, "graph.dot")
      {output, code} = visualize(["TLA.TestSpecs.WithDefaults", "--output", path])

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
      {_output, 1} = visualize(["TLA.TestSpecs.Broken", "--output", path])

      dot = File.read!(path)
      refute dot =~ "refuted"
      assert String.starts_with?(dot, "digraph ")
    end
  end

  describe "a spec with a violation" do
    test "still writes the graph, emphasises the counterexample, and exits 1" do
      {output, code} = visualize(["TLA.TestSpecs.Broken"])

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
          visualize(["TLA.TestSpecs.WithDefaults", "--format", "html"])
        end

      message = Exception.message(error)
      assert message =~ "06-architecture.md §Phase 4"
      assert message =~ "maintenance sink"
      assert message =~ "dot -Tsvg"
    end

    test "--format mermaid, the same way" do
      assert_raise Mix.Error, ~r/§Deferred/, fn ->
        visualize(["TLA.TestSpecs.WithDefaults", "--format", "mermaid"])
      end
    end

    test "an unknown --format, the way mix tla.check does" do
      assert_raise Mix.Error, ~r/unknown --format "svg"; expected dot/, fn ->
        visualize(["TLA.TestSpecs.WithDefaults", "--format", "svg"])
      end
    end

    test "a graph past --max-states, naming the count it really has" do
      error =
        assert_raise Mix.Error, fn ->
          visualize(["TLA.TestSpecs.WithDefaults", "--max-states", "1"])
        end

      assert Exception.message(error) =~ "4 states"
      assert Exception.message(error) =~ "the limit is 1"
    end

    test "a module that is not a spec" do
      assert_raise Mix.Error, ~r/does not `use TLA.Spec`/, fn ->
        visualize(["Enum"])
      end
    end

    test "several specs at once, because a graph is one file" do
      error =
        assert_raise Mix.Error, fn ->
          visualize(["TLA.TestSpecs.WithDefaults", "TLA.TestSpecs.Broken"])
        end

      assert Exception.message(error) =~ "name one spec to visualize"
    end

    test "a spec whose constants are unassigned, with both places named" do
      error = assert_raise Mix.Error, fn -> visualize(["TLA.TestSpecs.Counter"]) end

      message = Exception.message(error)
      assert message =~ "no assignment for :max"
      assert message =~ "config :extla"
    end
  end
end
