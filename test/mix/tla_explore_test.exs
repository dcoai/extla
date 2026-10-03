defmodule Mix.Tasks.Tla.ExploreTest do
  @moduledoc """
  `mix tla.explore` — a saved counterexample explored without the checker running again
  (#115, #121).

  The round trip is the point of most of these: `mix tla.check --format json` writes the file
  and `mix tla.explore` reads it, so the two tasks are held to one format rather than to two
  descriptions of one.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Tla.{Check, Explore}

  @spec_module "ExTLA.Conformance.Counter.BuggySpec"

  setup do
    Mix.shell(Mix.Shell.IO)
    tmp = Path.join(System.tmp_dir!(), "tla-explore-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  # Both tasks report by exiting, so each runs in a monitored process and the exit arrives as
  # a message — the same harness `Mix.Tasks.Tla.ReplayTest` uses.
  defp task(module, args) do
    parent = self()

    output =
      capture_io(fn ->
        {pid, ref} = spawn_monitor(fn -> module.run(args) end)

        receive do
          {:DOWN, ^ref, :process, ^pid, :normal} -> send(parent, {:code, 0})
          {:DOWN, ^ref, :process, ^pid, {:shutdown, code}} -> send(parent, {:code, code})
          {:DOWN, ^ref, :process, ^pid, reason} -> send(parent, {:code, {:error, reason}})
        after
          60_000 -> send(parent, {:code, :timeout})
        end
      end)

    receive do
      {:code, code} -> {output, code}
    after
      0 -> flunk("the task neither exited nor returned")
    end
  end

  defp counterexample_file(tmp) do
    {json, 1} = task(Check, [@spec_module, "--format", "json"])
    path = Path.join(tmp, "counterexample.json")
    File.write!(path, json)
    path
  end

  # `Mix.raise` exits with an ExitError the harness above reports as {:error, reason}.
  defp message({:error, {%Mix.Error{message: message}, _stacktrace}}), do: message
  defp message(other), do: flunk("expected a Mix.raise, got: #{inspect(other)}")

  defp occurrences(text, needle), do: length(String.split(text, needle)) - 1

  describe "the round trip" do
    test "explores what mix tla.check --format json wrote, without re-running the checker",
         %{tmp: tmp} do
      path = counterexample_file(tmp)

      {output, code} =
        task(Explore, [@spec_module, "--trace", path, "--expr", "count: state.count"])

      assert code == 0
      assert output =~ "═══ EXPLORE"
      assert output =~ ~r/\n\s+count\s+0/
      # The checker's own report is absent: nothing searched anything.
      refute output =~ "distinct states"
    end

    test "a single trace object lifted out of that document is accepted too", %{tmp: tmp} do
      lifted =
        tmp
        |> counterexample_file()
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("specs")
        |> Enum.find(&(&1["spec"] == @spec_module))
        |> Map.fetch!("violation")

      path = Path.join(tmp, "lifted.json")
      File.write!(path, Jason.encode!(lifted))

      {output, code} = task(Explore, [@spec_module, "--trace", path, "--expr", "state.count"])

      assert code == 0
      assert output =~ "state.count"
    end

    test "the states really are terms again, so an expression can do arithmetic on them",
         %{tmp: tmp} do
      path = counterexample_file(tmp)

      {output, 0} =
        task(Explore, [@spec_module, "--trace", path, "--expr", "doubled: state.count * 2"])

      assert output =~ ~r/\n\s+doubled\s+0/
    end
  end

  describe "--expr" do
    setup %{tmp: tmp}, do: %{path: counterexample_file(tmp)}

    test "binds each variable by its own name as well as `state`", %{path: path} do
      {named, 0} = task(Explore, [@spec_module, "--trace", path, "--expr", "v: count"])

      {through_map, 0} =
        task(Explore, [@spec_module, "--trace", path, "--expr", "v: state.count"])

      assert named == through_map
    end

    test "an unlabelled expression is labelled with its own text", %{path: path} do
      {output, 0} = task(Explore, [@spec_module, "--trace", path, "--expr", "count * 2"])

      assert output =~ "count * 2"
    end

    test "the label is found by parsing, so a colon inside the expression is not one",
         %{path: path} do
      {output, 0} = task(Explore, [@spec_module, "--trace", path, "--expr", "[:a, :b]"])

      # Had it split on the first colon, the row would be called `[` and the expression `a, :b]`.
      assert output =~ "[:a, :b]"
      refute output =~ ~r/\n\s+\[\s/
    end

    test "is repeatable, and the rows keep the order the flags were given in", %{path: path} do
      {output, 0} =
        task(Explore, [
          @spec_module,
          "--trace",
          path,
          "--expr",
          "zebra: count",
          "--expr",
          "alpha: count"
        ])

      [zebra, alpha] =
        output
        |> String.split("\n")
        |> Enum.with_index()
        |> Enum.filter(fn {line, _} -> line =~ ~r/^\s+(zebra|alpha)\s/ end)
        |> Enum.map(fn {_, index} -> index end)

      assert zebra < alpha
    end

    test "one that does not parse names its own text and the reason", %{path: path} do
      {_output, code} = task(Explore, [@spec_module, "--trace", path, "--expr", "count *"])

      assert message(code) =~ ~s(--expr "count *" does not parse)
    end

    test "one that raises is reported at its state rather than killing the run", %{path: path} do
      {output, code} =
        task(Explore, [@spec_module, "--trace", path, "--expr", "bad: count.missing"])

      assert code == 0
      assert output =~ "⚠"
      assert output =~ "⚠ state 1, bad:"
    end

    # A misspelled variable does not depend on the state, so it is one error rather than one
    # cell per state reading `cannot compile file (errors have been logged)`.
    test "a name that is not in scope is refused once, naming what is", %{path: path} do
      {_output, code} = task(Explore, [@spec_module, "--trace", path, "--expr", "vlaue"])

      message = message(code)
      assert message =~ ~s(--expr "vlaue" does not compile)
      assert message =~ "undefined variable"
      assert message =~ "In scope: count, status"
    end

    # An undefined REMOTE call is a runtime error, not a compile error, so it used to slip
    # past the probe above and be reported once per state — the very outcome the probe's own
    # comment says it exists to prevent (#315). "Once" is the claim, so it is counted.
    test "a call to a function that does not exist is refused once, not once per state",
         %{path: path} do
      expression = "boom: Enum.no_such_thing(count)"
      {output, code} = task(Explore, [@spec_module, "--trace", path, "--expr", expression])

      message = message(code)
      assert message =~ ~s(--expr #{inspect(expression)} calls a function that does not exist)
      assert message =~ "Enum.no_such_thing/1 is undefined or private"
      assert message =~ "In scope: count, status"

      assert occurrences(output <> message, "is undefined or private") == 1
      refute output =~ "⚠"
    end

    # And the narrowing did not swallow the case the per-state table exists for: an error
    # that depends on the state still fills cells rather than ending the run.
    test "an error that depends on the state still fills cells after the narrowing",
         %{path: path} do
      {output, code} =
        task(Explore, [@spec_module, "--trace", path, "--expr", "bad: count.missing"])

      assert code == 0
      assert occurrences(output, "expected a map") > 1
    end

    test "several expressions in one flag are refused", %{path: path} do
      {_output, code} = task(Explore, [@spec_module, "--trace", path, "--expr", "a: 1, b: 2"])

      assert message(code) =~ "holds 2 expressions"
    end

    test "none at all says what to pass", %{path: path} do
      {_output, code} = task(Explore, [@spec_module, "--trace", path])

      assert message(code) =~ "pass at least one --expr"
    end
  end

  describe "--changed-only" do
    test "reaches the option on ExTLA.Trace.explore/3", %{tmp: tmp} do
      path = counterexample_file(tmp)
      args = [@spec_module, "--trace", path, "--expr", "steady: 1", "--expr", "moving: count"]

      {with_all, 0} = task(Explore, args)
      {changed, 0} = task(Explore, args ++ ["--changed-only"])

      assert with_all =~ "steady"
      refute changed =~ "steady"
      assert changed =~ "moving"
    end
  end

  describe "what it refuses" do
    test "no module", %{tmp: tmp} do
      path = counterexample_file(tmp)
      {_output, code} = task(Explore, ["--trace", path, "--expr", "count"])

      assert message(code) =~ "name the ExTLA.Spec module"
    end

    test "a module that is not a spec", %{tmp: tmp} do
      path = counterexample_file(tmp)
      {_output, code} = task(Explore, ["Enum", "--trace", path, "--expr", "count"])

      assert message(code) =~ "does not `use ExTLA.Spec`"
    end

    test "no --trace" do
      {_output, code} = task(Explore, [@spec_module, "--expr", "count"])

      assert message(code) =~ "pass --trace"
    end

    test "a file that is not there" do
      {_output, code} =
        task(Explore, [@spec_module, "--trace", "/nonexistent.json", "--expr", "count"])

      assert message(code) =~ "does not exist"
    end

    test "a file that is not JSON", %{tmp: tmp} do
      path = Path.join(tmp, "not.json")
      File.write!(path, "certainly not json")

      {_output, code} = task(Explore, [@spec_module, "--trace", path, "--expr", "count"])

      assert message(code) =~ "is not JSON"
    end

    test "a document carrying no result for this spec", %{tmp: tmp} do
      path = counterexample_file(tmp)

      {_output, code} =
        task(Explore, ["ExTLA.Conformance.Counter.Spec", "--trace", path, "--expr", "count"])

      assert message(code) =~ "has no result for ExTLA.Conformance.Counter.Spec"
    end
  end
end
