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
  # `TLA.GenServer.Driver` sends its own `:"$gen_call"`.
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
        simulate(["TLA.Conformance.Counter.Impl.Conforming", "--traces", "20", "--steps", "10"])

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
          "TLA.Conformance.Counter.Impl.Conforming",
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
          "TLA.Conformance.Counter.Impl.Conforming",
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
          "TLA.Conformance.Counter.Impl.CollapsesTwoSteps",
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
          "TLA.Conformance.Counter.Impl.Conforming",
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
      assert_raise Mix.Error, ~r/does not `use TLA.GenServer`/, fn ->
        Simulate.run(["TLA.Conformance.Counter.Spec"])
      end
    end

    test "a module that does not exist" do
      assert_raise Mix.Error, ~r/is not a module in this project/, fn ->
        Simulate.run(["No.Such.Server"])
      end
    end

    test "no module at all" do
      assert_raise Mix.Error, ~r/name the TLA.GenServer module/, fn -> Simulate.run([]) end
    end

    test "an unknown --format" do
      assert_raise Mix.Error, ~r/unknown --format/, fn ->
        Simulate.run([
          "TLA.Conformance.Counter.Impl.Conforming",
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
end
