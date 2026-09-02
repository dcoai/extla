defmodule Mix.Tasks.Tla.ReplayTest do
  @moduledoc """
  The pipeline `05-layer3-conformance.md` §Full verification pipeline describes, run end
  to end: `mix tla.check --format json` writes a counterexample, and `mix tla.replay`
  drives the real server through it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Tla.{Check, Replay}

  @server "TLA.Conformance.Counter.Impl.FaithfulToABuggySpec"

  setup do
    Mix.shell(Mix.Shell.IO)
    tmp = Path.join(System.tmp_dir!(), "tla-replay-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  # Both tasks report their verdict by exiting, so each runs in a monitored process and
  # the exit arrives as a message.
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
    {json, 1} = task(Check, ["TLA.Conformance.Counter.BuggySpec", "--format", "json"])
    path = Path.join(tmp, "counterexample.json")
    File.write!(path, json)
    path
  end

  describe "the pipeline, end to end" do
    test "a counterexample mix tla.check wrote is replayed against the real server", %{tmp: tmp} do
      path = counterexample_file(tmp)

      {output, code} = task(Replay, [@server, "--trace", path])

      assert code == 1
      assert output =~ "CONFORMANCE: invariant"
      assert output =~ "invariant :at_most_two"
      assert output =~ "steps checked"
    end

    # The reason the JSON encoding changed: `inspect/1` writes something a person can read
    # and a machine cannot parse back, and this is the parse.
    test "the states in that file are terms again, not strings", %{tmp: tmp} do
      trace =
        tmp
        |> counterexample_file()
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("specs")
        |> Enum.find(&(&1["spec"] == "TLA.Conformance.Counter.BuggySpec"))
        |> Map.fetch!("violation")
        |> TLA.Trace.from_json!()

      assert %TLA.Trace{} = trace
      assert hd(trace.states) == %{count: 0, status: :ready}
      assert List.last(trace.states).count == 3
      assert Enum.all?(trace.actions, &is_atom/1)
    end
  end

  describe "--captured" do
    test "a capture the spec permits exits 0", %{tmp: tmp} do
      path = Path.join(tmp, "good.json")

      File.write!(
        path,
        Jason.encode!(capture([{:init, 0, :ready}, {:increment, 1, :incrementing}]))
      )

      {output, 0} = task(Replay, ["TLA.Conformance.Counter.Impl.Conforming", "--captured", path])

      assert output =~ "REPRODUCED"
      assert output =~ "1 steps checked"
    end

    test "a capture with Example 4's bug in it exits 1, naming the step", %{tmp: tmp} do
      path = Path.join(tmp, "bad.json")
      File.write!(path, Jason.encode!(capture([{:init, 0, :ready}, {:increment, 1, :ready}])))

      {output, 1} = task(Replay, ["TLA.Conformance.Counter.Impl.Conforming", "--captured", path])

      assert output =~ "CONFORMANCE: diverged"
      assert output =~ "step 1"
      assert output =~ "status:"
    end
  end

  describe "what it refuses" do
    test "a file that is not there" do
      assert_raise Mix.Error, ~r/does not exist/, fn ->
        Replay.run([@server, "--trace", "/nonexistent/trace.json"])
      end
    end

    test "a file that is not JSON", %{tmp: tmp} do
      path = Path.join(tmp, "not.json")
      File.write!(path, "{not json")

      assert_raise Mix.Error, ~r/is not JSON/, fn -> Replay.run([@server, "--trace", path]) end
    end

    test "a results file with no entry for this server's spec", %{tmp: tmp} do
      path = Path.join(tmp, "other.json")

      File.write!(
        path,
        Jason.encode!(%{
          "schema_version" => Mix.Tasks.Tla.Check.schema_version(),
          "specs" => [%{"spec" => "Some.Other.Spec", "violation" => nil}]
        })
      )

      assert_raise Mix.Error, ~r/has no result for/, fn ->
        Replay.run([@server, "--trace", path])
      end
    end

    test "a results file whose spec was verified", %{tmp: tmp} do
      path = Path.join(tmp, "clean.json")

      File.write!(
        path,
        Jason.encode!(%{
          "schema_version" => Mix.Tasks.Tla.Check.schema_version(),
          "specs" => [%{"spec" => "TLA.Conformance.Counter.BuggySpec", "violation" => nil}]
        })
      )

      assert_raise Mix.Error, ~r/records no counterexample/, fn ->
        Replay.run([@server, "--trace", path])
      end
    end

    test "a results file written by a schema version this ExTLA does not read", %{tmp: tmp} do
      path = Path.join(tmp, "future.json")

      File.write!(
        path,
        Jason.encode!(%{
          "schema_version" => Mix.Tasks.Tla.Check.schema_version() + 1,
          "specs" => [%{"spec" => "TLA.Conformance.Counter.BuggySpec", "violation" => nil}]
        })
      )

      assert_raise Mix.Error, ~r/schema version/, fn ->
        Replay.run([@server, "--trace", path])
      end
    end

    test "neither --trace nor --captured" do
      assert_raise Mix.Error, ~r/pass --trace <file> or --captured <file>/, fn ->
        Replay.run([@server])
      end
    end

    test "a module that is not instrumented" do
      assert_raise Mix.Error, ~r/does not `use TLA.GenServer`/, fn ->
        Replay.run(["TLA.Conformance.Counter.Spec", "--trace", "x.json"])
      end
    end
  end

  defp capture(steps) do
    Enum.map(steps, fn {message, value, status} ->
      %{
        "message" => TLA.State.Json.encode(message),
        "state" => TLA.State.Json.encode(%{value: value, status: status})
      }
    end)
  end
end
