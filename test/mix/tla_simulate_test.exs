defmodule Mix.Tasks.Tla.SimulateTest do
  @moduledoc """
  `mix tla.simulate MyServer` walks the real implementation against its spec, says what
  the walk covered, and reports its verdict in the exit code.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Tla.Simulate

  setup do
    Mix.shell(Mix.Shell.IO)
    :ok
  end

  # The task signals its verdict by exiting, which is part of what is under test. It runs
  # in a monitored process so the exit arrives as a message — the same reason
  # `ExTLA.GenServer.Driver` sends its own `:"$gen_call"`.
  defp simulate(args) do
    parent = self()

    output =
      capture_io(fn ->
        {pid, ref} = spawn_monitor(fn -> Simulate.run(args) end)

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

  describe "a conforming server" do
    test "exits 0, and says what the walk covered" do
      {output, code} =
        simulate(["ExTLA.Conformance.Counter.Impl.Conforming", "--traces", "20", "--steps", "10"])

      assert code == 0
      assert output =~ "NO FINDING"
      assert output =~ "20 traces"
      assert output =~ "seed "
      assert output =~ "covered 100% of the spec's actions"
      assert output =~ "increment x"
      assert output =~ "distinct abstract states"
    end

    test "runs the seed it is given, and reports it back" do
      {output, 0} =
        simulate([
          "ExTLA.Conformance.Counter.Impl.Conforming",
          "--traces",
          "2",
          "--steps",
          "3",
          "--seed",
          "4242"
        ])

      assert output =~ "seed 4242"
    end

    test "answers in json when asked" do
      {output, 0} =
        simulate([
          "ExTLA.Conformance.Counter.Impl.Conforming",
          "--traces",
          "2",
          "--steps",
          "3",
          "--format",
          "json"
        ])

      assert %{"status" => "ok", "traces_run" => 2, "coverage" => coverage, "violation" => nil} =
               Jason.decode!(output)

      assert coverage["actions_covered"] > 0
    end
  end

  describe "a server that does not conform" do
    test "exits 1 and prints the counterexample as a trace" do
      {output, code} =
        simulate([
          "ExTLA.Conformance.Counter.Impl.CollapsesTwoSteps",
          "--traces",
          "5",
          "--steps",
          "5",
          "--seed",
          "11"
        ])

      assert code == 1
      assert output =~ "CONFORMANCE VIOLATION"
      assert output =~ "DIVERGED"
    end
  end

  describe "--unrestricted" do
    # Off by default: it asks whether the implementation refuses what the spec forbids in
    # this state, which nearly no server is written to do.
    test "asks whether the server refuses what the spec forbids there" do
      {output, code} =
        simulate([
          "ExTLA.Conformance.Counter.Impl.Conforming",
          "--traces",
          "10",
          "--steps",
          "10",
          "--seed",
          "5",
          "--unrestricted"
        ])

      assert code == 1
      assert output =~ "NOT ENABLED"
    end
  end

  describe "what it refuses to run" do
    test "a module that is not instrumented, naming the reason" do
      assert_raise Mix.Error, ~r/does not `use ExTLA.GenServer`/, fn ->
        Simulate.run(["ExTLA.Conformance.Counter.Spec"])
      end
    end

    test "a module that does not exist" do
      assert_raise Mix.Error, ~r/is not a module in this project/, fn ->
        Simulate.run(["No.Such.Server"])
      end
    end

    test "no module at all" do
      assert_raise Mix.Error, ~r/name the ExTLA.GenServer module/, fn -> Simulate.run([]) end
    end

    test "an unknown --format" do
      assert_raise Mix.Error, ~r/unknown --format/, fn ->
        Simulate.run([
          "ExTLA.Conformance.Counter.Impl.Conforming",
          "--traces",
          "1",
          "--steps",
          "1",
          "--format",
          "yaml"
        ])
      end
    end
  end

  # ── --against-graph ─────────────────────────────────────────────────────────

  describe "--against-graph" do
    @conforming "ExTLA.Conformance.Counter.Impl.Conforming"

    test "runs the traces asked for and no others" do
      {output, code} =
        simulate([@conforming, "--traces", "4", "--steps", "6", "--seed", "9", "--against-graph"])

      assert code == 0

      # It used to run a SECOND suite of `--traces` simulations afterwards, so this said 4
      # while 8 had run. One suite reports what it did (#180).
      assert output =~ "4 traces"
    end

    # Defect 3's second half. `check_against_graph/2` wrote to the shell BEFORE the format
    # dispatch and could exit before reaching it at all -- an unparseable file plus a
    # discarded result. With the check inside the one suite there is no earlier writer.
    test "and --format json emits only JSON" do
      {output, code} =
        simulate([
          @conforming,
          "--traces",
          "3",
          "--steps",
          "6",
          "--seed",
          "9",
          "--against-graph",
          "--format",
          "json"
        ])

      assert code == 0
      assert {:ok, decoded} = Jason.decode(output)
      assert decoded["status"] == "ok"
      assert decoded["containment"] == nil

      refute output =~ "against-graph:",
             "the human line from the old second suite is back, before the JSON"
    end

    # The forwarding defect, at the CLI. `--unrestricted --against-graph` used to audit
    # containment with the RESTRICTED generator, because the second suite forwarded two of
    # the five options. There is one suite now, so the generator that runs is the one asked
    # for -- and on this server the unrestricted generator finds `:not_enabled`, which is
    # the evidence that it ran at all.
    test "and --unrestricted beside it uses the unrestricted generator" do
      {output, code} =
        simulate([
          @conforming,
          "--traces",
          "6",
          "--steps",
          "8",
          "--seed",
          "9",
          "--unrestricted",
          "--against-graph"
        ])

      assert code == 1
      assert output =~ "CONFORMANCE VIOLATION: not_enabled"
    end

    # The same flags without `--unrestricted`: the restricted generator never offers a
    # disabled action, so there is no finding. Without this pair, the test above would pass
    # for a run that ignored `--unrestricted` and happened to fail for another reason.
    test "and without it the restricted generator finds nothing" do
      {_output, code} =
        simulate([@conforming, "--traces", "6", "--steps", "8", "--seed", "9", "--against-graph"])

      assert code == 0
    end
  end

  # ── exit 2, and the path behind it ──────────────────────────────────────────

  describe "the server that does not answer" do
    @moduletag :capture_log

    # #180 called this path "entirely dead" and "produced by nothing". It is neither
    # unreachable nor produced by nothing — it was **untested**, which is a different fault
    # and the one fixed here. Measured before writing the test:
    #
    #     ExTLA.Simulation.run(SlowServer, %{timeout: 200})
    #     #=> {:error, "no reply within 200ms"}
    #
    # So the code was right and nothing held it to that. Both halves are gated now.
    defmodule Slow do
      use GenServer

      use ExTLA.GenServer,
        spec: ExTLA.Conformance.Counter.Spec,
        refinement: ExTLA.Conformance.Counter.Refinement

      def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(_opts), do: {:ok, %{value: 0, status: :ready}}

      # Never answers. Every other callback is the conforming one, so the only thing this
      # server does wrong is take too long.
      @impl true
      def handle_call(:increment, _from, state) do
        Process.sleep(:infinity)
        {:reply, :ok, state}
      end

      def handle_call(:done, _from, state), do: {:reply, :ok, %{state | status: :ready}}
      def handle_call(:reset, _from, state), do: {:reply, :ok, %{state | value: 0}}
    end

    defmodule Declines do
      use GenServer

      use ExTLA.GenServer,
        spec: ExTLA.Conformance.Counter.Spec,
        refinement: ExTLA.Conformance.Counter.Refinement

      def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(_opts), do: :ignore
    end

    test "reaches the timeout path, which says how long it waited" do
      result =
        ExTLA.Simulation.run(Slow, %{traces: 2, max_steps: 5, seed: 1, timeout: 200})

      assert result.status == :error
      assert result.detail == "no reply within 200ms"
    end

    # The documented exit code, produced. It is NOT 1: nothing about conformance was
    # decided after the server stopped answering, and reporting it as a violation would
    # name the implementation for a finding the run never made.
    #
    # Through `init/1` declining rather than through the timeout: the task has no
    # `--timeout` switch, so a task-level timeout test would wait the default five seconds
    # per step. Adding a flag to make a test convenient is surface this issue did not ask
    # for; the timeout path is gated above, where it can be driven in 200ms.
    test "and an init/1 that declines exits 2, which the moduledoc documents" do
      {output, code} = simulate([inspect(Declines), "--traces", "2", "--seed", "1"])

      assert code == 2
      assert output =~ "THE SERVER DID NOT ANSWER"
      assert output =~ "nothing was checked"
    end

    # Anti-vacuity: the same flags against a server that starts exit 0, so the test above
    # fails on the server rather than on the flags.
    test "whereas a server that starts exits 0" do
      {_output, code} =
        simulate([
          "ExTLA.Conformance.Counter.Impl.Conforming",
          "--traces",
          "2",
          "--steps",
          "5",
          "--seed",
          "1"
        ])

      assert code == 0
    end
  end
end
