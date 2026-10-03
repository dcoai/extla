defmodule ExTLA.ResourceLifetimeTest do
  @moduledoc """
  What a run allocates, a run releases (#316).

  Two leaks of the same kind, found by counting rather than by reading. An ETS table is
  owned by a *process*, not reachable from a term, so dropping the last reference to a
  `ExTLA.StateGraph` frees nothing: `ExTLA.ModelChecker.run/2` discarded the graph and left both
  tables holding one record per distinct state for the calling process's lifetime. Twenty
  runs left forty tables. `ExTLA.Replay` left a live `GenServer` behind per replay, where
  `ExTLA.Simulation` — the same shape, one door over — stops its own.

  ## Why it went unnoticed

  Under ExUnit every test is its own process, and a process's exit takes its tables with it.
  So the suite could not see this, however many runs it made. It accumulates where processes
  are long-lived: `mix extla.check A B C`, `ExTLA.Spec.Test`, `ExTLA.Ledger`'s corpus pass, and any
  application that model-checks more than once.

  ## What is counted, and why not `:ets.all/0` outright

  `:ets.all()` is VM-global, and a bare count of it would be a claim about everything else
  running in the VM. So the measurement is filtered to *the graph's own* tables by name —
  `:tla_nodes` and `:tla_fingerprints` — and compared to the set standing before. That is
  sharper than the raw count in both directions: it sees a table leaked into ANY process,
  including one this test does not own, and it cannot be reddened by a table this project
  did not create.

  `async: false`, because both measurements are VM-global and a concurrent test running a
  model check would be counted here (#285's rule).
  """
  use ExUnit.Case, async: false

  alias ExTLA.Conformance.Counter.{BuggySpec, Impl, Spec}
  alias ExTLA.{ModelChecker, Replay, Simulation, StateGraph, Trace}

  @constants %{max_val: 5}
  @graph_tables [:tla_nodes, :tla_fingerprints]

  # A float is not a permitted state term (§6), and `ExTLA.StateGraph.add_state/5` is where
  # that is checked — AFTER the tables exist. So this raises on the one exit path a `delete`
  # on the last line of `run/2` would not cover.
  defmodule Floating do
    use ExTLA.Spec
    variable :x

    init do
      x = 4
    end

    action :halve do
      require x > 1
      x = x / 2
    end
  end

  describe "ExTLA.ModelChecker.run/2" do
    test "twenty runs in one process leave no tables behind" do
      before = graph_tables()

      for _ <- 1..20 do
        result = ModelChecker.run(Spec, %{constants: @constants, check_liveness: false})
        assert result.status == :ok
      end

      leaked = MapSet.difference(graph_tables(), before)

      assert MapSet.size(leaked) == 0, """
      #{MapSet.size(leaked)} graph table(s) outlived the runs that made them. This is the
      measurement that found the leak: twenty runs, forty tables, held for the calling
      process's lifetime because an ETS table belongs to a process and not to the term that
      names it.
      """
    end

    test "a run that raises leaves none either — the path a delete at the end does not cover" do
      before = graph_tables()

      assert_raise ExTLA.State.InvalidTermError, fn ->
        ModelChecker.run(Floating, %{})
      end

      assert MapSet.difference(graph_tables(), before) |> MapSet.size() == 0
    end

    # Isolating the search must not turn a diagnosis into an opaque exit. The exception and
    # the stack it was raised on both have to cross back, which is what keeps
    # `mix extla.check`'s `rescue error in ExTLA.Symmetry.UnsoundError` matching.
    test "and a failure arrives as the exception it was, on the stack it was raised on" do
      error = assert_raise ExTLA.State.InvalidTermError, fn -> ModelChecker.run(Floating, %{}) end

      assert Exception.message(error) =~ "a float"

      # Observed rather than rescued: the reason a monitored process exits with carries the
      # stacktrace, so this reads the re-raise without catching it.
      assert {%ExTLA.State.InvalidTermError{}, stacktrace} =
               exit_reason(fn -> ModelChecker.run(Floating, %{}) end)

      assert Enum.any?(stacktrace, &match?({ExTLA.State, _function, _arity, _location}, &1)),
             "the re-raised stack does not name ExTLA.State: #{inspect(stacktrace)}"
    end
  end

  describe "ExTLA.ModelChecker.explore/2" do
    test "keeps the graph's tables, because the caller owns the graph" do
      before = graph_tables()

      {result, graph} =
        ModelChecker.explore(Spec, %{constants: @constants, check_liveness: false})

      assert result.status == :ok

      # Not released here, asserted — so the fix cannot be over-applied to the one place
      # where the tables ARE the return value.
      assert MapSet.size(MapSet.difference(graph_tables(), before)) == 2
      assert StateGraph.live_state_count(graph) > 0

      assert StateGraph.delete(graph) == :ok
      assert MapSet.difference(graph_tables(), before) |> MapSet.size() == 0

      # Releasing twice is not punished: a caller being careful is not a caller in error.
      assert StateGraph.delete(graph) == :ok
    end
  end

  describe "ExTLA.Replay" do
    setup do
      result = ModelChecker.run(BuggySpec, %{constants: @constants, check_liveness: false})

      assert result.status == :violation
      assert %Trace{} = result.violation

      %{trace: result.violation}
    end

    # Deliberately the CLEAN replays, not the violating ones. A violation is raised inside
    # the server, which kills it — so twenty violating replays tidy up after themselves by
    # accident and would have made this gate vacuous. The leak is on the path where nothing
    # goes wrong.
    test "twenty replays leave no servers behind", %{trace: trace} do
      module = Impl.FaithfulToABuggySpec
      step = first_step(trace)
      before = servers(module)

      for _ <- 1..20 do
        assert Replay.counterexample(module, step).status == :ok
      end

      assert servers(module) -- before == [], """
      #{length(servers(module) -- before)} server(s) outlived the replays that started them.
      `ExTLA.Replay` starts one with `GenServer.start_link/2` and unlinks it, so nothing else
      will take it down.
      """
    end

    test "and a replay that ends in a violation leaves none either", %{trace: trace} do
      module = Impl.FaithfulToABuggySpec
      before = servers(module)

      assert Replay.counterexample(module, trace).status == :violation
      assert servers(module) -- before == []
    end

    # The work item's claim is comparative — "the two are the same shape; one cleans up" —
    # so the comparison is the test. Both now measure zero.
    test "which is what ExTLA.Simulation already satisfied" do
      module = Impl.Conforming
      before = servers(module)

      for _ <- 1..20 do
        {summary, _states} = Simulation.run_trace(module, %{max_steps: 3})
        assert summary.status in [:ok, :violation]
      end

      assert servers(module) -- before == []
    end

    test "but a server the caller supplied is left alone — it is not ours to stop",
         %{trace: trace} do
      {:ok, server} = GenServer.start_link(Impl.FaithfulToABuggySpec, [])
      Process.unlink(server)
      on_exit(fn -> Process.exit(server, :kill) end)

      # The FIRST step only. The whole counterexample ends in a violation, which the
      # wrapper raises inside the server — so a server that died there would say nothing
      # about who stopped it.
      report = Replay.counterexample(Impl.FaithfulToABuggySpec, first_step(trace), server: server)

      assert report.status == :ok
      assert report.steps_checked == 1

      assert Process.alive?(server),
             "the replay stopped a server it was handed; ownership is what decides this"
    end
  end

  # ── Counting ────────────────────────────────────────────────────────────────

  defp graph_tables do
    for table <- :ets.all(),
        :ets.info(table, :name) in @graph_tables,
        into: MapSet.new(),
        do: table
  end

  # By `$initial_call` rather than by a raw `Process.list/0` count: an unrelated process
  # starting during the loop would redden a raw count, and this names exactly the servers
  # these two modules start.
  defp servers(module) do
    Enum.filter(Process.list(), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          Keyword.get(dictionary, :"$initial_call") == {module, :init, 1}

        nil ->
          false
      end
    end)
  end

  # A one-step prefix of a counterexample: two states, the action between them, and its
  # binding. Enough to drive a server and not enough to reach the violation.
  defp first_step(%Trace{} = trace) do
    %Trace{
      trace
      | states: Enum.take(trace.states, 2),
        actions: Enum.take(trace.actions, 1),
        bindings: Enum.take(trace.bindings, 1)
    }
  end

  defp exit_reason(fun) do
    {_pid, ref} = spawn_monitor(fun)

    receive do
      {:DOWN, ^ref, :process, _pid, reason} -> reason
    after
      30_000 -> flunk("the probe neither returned nor exited")
    end
  end
end
