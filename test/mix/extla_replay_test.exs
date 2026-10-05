defmodule Mix.Tasks.Extla.ReplayTest do
  @moduledoc """
  The pipeline `05-layer3-conformance.md` §Full verification pipeline describes, run end
  to end: `mix extla.check --format json` writes a counterexample, and `mix extla.replay`
  drives the real server through it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Extla.{Check, Replay}

  @server "ExTLA.Conformance.Counter.Impl.FaithfulToABuggySpec"

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
    {json, 1} = task(Check, ["ExTLA.Conformance.Counter.BuggySpec", "--format", "json"])
    path = Path.join(tmp, "counterexample.json")
    File.write!(path, json)
    path
  end

  describe "the pipeline, end to end" do
    test "a counterexample mix extla.check wrote is replayed against the real server", %{tmp: tmp} do
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
        |> Enum.find(&(&1["spec"] == "ExTLA.Conformance.Counter.BuggySpec"))
        |> Map.fetch!("violation")
        |> ExTLA.Trace.from_json!()

      assert %ExTLA.Trace{} = trace
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

      {output, 0} =
        task(Replay, ["ExTLA.Conformance.Counter.Impl.Conforming", "--captured", path])

      assert output =~ "REPRODUCED"
      assert output =~ "1 steps checked"
    end

    test "a capture with Example 4's bug in it exits 1, naming the step", %{tmp: tmp} do
      path = Path.join(tmp, "bad.json")
      File.write!(path, Jason.encode!(capture([{:init, 0, :ready}, {:increment, 1, :ready}])))

      {output, 1} =
        task(Replay, ["ExTLA.Conformance.Counter.Impl.Conforming", "--captured", path])

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
          "schema_version" => Mix.Tasks.Extla.Check.schema_version(),
          "specs" => [%{"spec" => "Some.Other.Spec", "violation" => nil}]
        })
      )

      assert_raise Mix.Error, ~r/has no result for/, fn ->
        Replay.run([@server, "--trace", path])
      end
    end

    test "a results file whose spec was verified", %{tmp: tmp} do
      path = Path.join(tmp, "clean.json")

      # `"status" => "ok"` is what makes this verified; the fixture used to omit the status,
      # and the reader used to say verified without it (#205).
      File.write!(
        path,
        Jason.encode!(%{
          "schema_version" => Mix.Tasks.Extla.Check.schema_version(),
          "specs" => [
            %{
              "spec" => "ExTLA.Conformance.Counter.BuggySpec",
              "status" => "ok",
              "violation" => nil
            }
          ]
        })
      )

      assert_raise Mix.Error, ~r/records no counterexample.*the spec was verified/, fn ->
        Replay.run([@server, "--trace", path])
      end
    end

    # #205. The reader matched `"violation" => nil` and said "verified" without reading the
    # `status` beside it, so a run the state limit stopped read as a proof.
    test "a results file whose run was bounded is not called verified", %{tmp: tmp} do
      for {status, expect} <- [
            {"max_states_reached", ~r/bounded at 20 states by the state limit/},
            {"constrained", ~r/state_constraint.*held states back after 20 states/},
            {"unsound_symmetry", ~r/status is "unsound_symmetry", which is not verified/}
          ] do
        path = Path.join(tmp, "#{status}.json")

        File.write!(
          path,
          Jason.encode!(%{
            "schema_version" => Mix.Tasks.Extla.Check.schema_version(),
            "specs" => [
              %{
                "spec" => "ExTLA.Conformance.Counter.BuggySpec",
                "status" => status,
                "distinct_states" => 20,
                "violation" => nil
              }
            ]
          })
        )

        error = assert_raise(Mix.Error, fn -> Replay.run([@server, "--trace", path]) end)

        assert error.message =~ expect, status
        refute error.message =~ "was verified", status
      end
    end

    # #211. An entry with no `violation` key was a `CaseClauseError` from inside the reader.
    test "a results entry with no violation key is refused by name", %{tmp: tmp} do
      path = Path.join(tmp, "keyless.json")

      File.write!(
        path,
        Jason.encode!(%{
          "schema_version" => Mix.Tasks.Extla.Check.schema_version(),
          "specs" => [%{"spec" => "ExTLA.Conformance.Counter.BuggySpec", "status" => "ok"}]
        })
      )

      assert_raise Mix.Error, ~r/has no "violation" key/, fn ->
        Replay.run([@server, "--trace", path])
      end
    end

    test "a results file written by a schema version this ExTLA does not read", %{tmp: tmp} do
      path = Path.join(tmp, "future.json")

      File.write!(
        path,
        Jason.encode!(%{
          "schema_version" => Mix.Tasks.Extla.Check.schema_version() + 1,
          "specs" => [%{"spec" => "ExTLA.Conformance.Counter.BuggySpec", "violation" => nil}]
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
      assert_raise Mix.Error, ~r/does not `use ExTLA.GenServer`/, fn ->
        Replay.run(["ExTLA.Conformance.Counter.Spec", "--trace", "x.json"])
      end
    end
  end

  # A server whose start depends on its init argument, so a test can tell whether
  # `--init-arg` reached it (#165). It refines `BuggySpec` exactly as
  # `FaithfulToABuggySpec` does when started with nothing: from 0, replying at once.
  # `start:` moves where it begins, and `delay:` makes every reply that slow, which is how
  # `--timeout` is observed.
  defmodule StartsFromItsInitArg do
    use GenServer

    use ExTLA.GenServer,
      spec: ExTLA.Conformance.Counter.BuggySpec,
      refinement: ExTLA.Conformance.Counter.Refinement

    @impl true
    def init(opts) do
      {:ok, %{value: Keyword.get(opts, :start, 0), status: :ready, delay: opts[:delay]}}
    end

    @impl true
    def handle_call(:increment, _from, state) do
      pause(state)
      {:reply, :ok, %{state | value: state.value + 1, status: :incrementing}}
    end

    def handle_call(:done, _from, state) do
      pause(state)
      {:reply, :ok, %{state | status: :ready}}
    end

    defp pause(%{delay: nil}), do: :ok
    defp pause(%{delay: ms}), do: Process.sleep(ms)
  end

  @starts "Mix.Tasks.Extla.ReplayTest.StartsFromItsInitArg"

  describe "--init-arg, --server and --timeout reach ExTLA.Replay (#165)" do
    test "with none of them, the server starts from its default and reproduces the trace",
         %{tmp: tmp} do
      {_output, code} = task(Replay, [@starts, "--trace", counterexample_file(tmp)])

      assert code == 1
    end

    test "--init-arg is the argument the server is started with", %{tmp: tmp} do
      path = counterexample_file(tmp)

      {_output, same} = task(Replay, [@starts, "--trace", path, "--init-arg", "[start: 0]"])
      {output, moved} = task(Replay, [@starts, "--trace", path, "--init-arg", "[start: 1]"])

      assert same == 1, "an explicit argument equal to the default changes nothing"
      assert moved == 2, "starting from 1, the server cannot follow a trace that starts at 0"
      assert output =~ "NOT FOLLOWED"
    end

    test "--timeout bounds each reply", %{tmp: tmp} do
      {output, code} =
        task(Replay, [
          @starts,
          "--trace",
          counterexample_file(tmp),
          "--init-arg",
          "[delay: 200]",
          "--timeout",
          "20"
        ])

      assert code == 2
      assert output =~ "no reply within 20ms"
    end

    # Handed a server started from 1, the replay cannot follow the trace (2, where a server
    # the task started itself reproduces it: 1). That is what shows it drove this process.
    # A replay that ends without the server's own invariant check firing leaves it running:
    # a server the task was handed is not the task's to stop.
    test "--server drives the named process, and leaves it running", %{tmp: tmp} do
      name = :"extla_replay_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start(StartsFromItsInitArg, [start: 1], name: name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      {output, code} =
        task(Replay, [@starts, "--trace", counterexample_file(tmp), "--server", ":#{name}"])

      assert code == 2
      assert output =~ "NOT FOLLOWED"
      assert Process.alive?(pid)
    end
  end

  describe "what the three refuse rather than ignore (#165)" do
    test "an --init-arg that is not a literal term" do
      assert_raise Mix.Error, ~r/--init-arg must be a literal term/, fn ->
        Replay.run([@starts, "--trace", "x.json", "--init-arg", "System.halt()"])
      end
    end

    test "an --init-arg that does not parse" do
      assert_raise Mix.Error, ~r/--init-arg .* does not parse/, fn ->
        Replay.run([@starts, "--trace", "x.json", "--init-arg", "[start:"])
      end
    end

    test "a --server name nothing is registered under" do
      assert_raise Mix.Error, ~r/no process is registered as :nobody_here/, fn ->
        Replay.run([@starts, "--trace", "x.json", "--server", ":nobody_here"])
      end
    end

    test "a --server pid, which means nothing in this VM" do
      assert_raise Mix.Error, ~r/--server takes a registered name/, fn ->
        Replay.run([@starts, "--trace", "x.json", "--server", "#PID<0.42.0>"])
      end
    end

    test "a --timeout that is not a positive number of milliseconds" do
      assert_raise Mix.Error, ~r/--timeout must be a positive number of milliseconds/, fn ->
        Replay.run([@starts, "--trace", "x.json", "--timeout", "0"])
      end
    end

    test "--init-arg with --server, where it would start nothing" do
      assert_raise Mix.Error, ~r/--init-arg starts a server; --server names one/, fn ->
        Replay.run([@starts, "--trace", "x.json", "--server", ":x", "--init-arg", "[]"])
      end
    end

    test "any of them with --captured, which starts and drives nothing" do
      for flags <- [["--init-arg", "[]"], ["--server", ":x"], ["--timeout", "10"]] do
        assert_raise Mix.Error, ~r/--captured checks a recording and drives no server/, fn ->
          Replay.run([@starts, "--captured", "x.json" | flags])
        end
      end
    end
  end

  defp capture(steps) do
    Enum.map(steps, fn {message, value, status} ->
      %{
        "message" => ExTLA.State.Json.encode(message),
        "state" => ExTLA.State.Json.encode(%{value: value, status: status})
      }
    end)
  end
end
