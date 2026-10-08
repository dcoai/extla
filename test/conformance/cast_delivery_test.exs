defmodule ExTLA.CastDeliveryTest do
  @moduledoc """
  An action the server takes by cast is drivable, not merely checkable (#306, closes #172).

  ## The gap this closes

  `ExTLA.GenServer.Driver` sent `{:"$gen_call", …}` unconditionally, and it is the sole
  delivery path for both Layer 3 drivers. **`spec/05-layer3-conformance.md`'s own canonical
  refinement maps `:complete_transfer` and `:reset` to `handle_cast/2` clauses.** Delivered
  as a call those reach `handle_call/3`, which has no matching clause: the server dies and
  replay reports `:not_followed` — "the spec permits a behaviour the implementation does not
  take" — about a server that is correct.

  Nothing in spec/05 restricted `concrete_message/2` to calls, and the runtime wrapper
  already instruments casts and infos. So the gap was exactly *checked but not drivable*.

  ## Why the corpus entry is the point and not a nicety

  It went unseen because **every entry in the conformance corpus was `handle_call`-only**.
  A corpus that cannot express a case cannot find a bug in it, so a fix without an entry
  that takes an action by cast would leave the gap able to reopen in the way it opened.
  `Impl.HandlesACast` is that entry, and it is exercised here by both Layer 3 drivers,
  because both share one delivery path and a fix tested through one proves nothing about
  the other.

  D-36 has the contract and the reasoning, including why a cast's completion is a
  `:get_state` system message rather than a clock.
  """

  use ExUnit.Case, async: true

  alias ExTLA.Conformance.Counter.{CastRefinement, Impl, Refinement, Spec}
  alias ExTLA.GenServer.Driver
  alias ExTLA.{ModelChecker, Replay, Simulation, Trace}

  defp start(module) do
    {:ok, pid} = module.start_link()
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  # ── The mapping says the route ──────────────────────────────────────────────

  describe "the delivery the mapping names" do
    test "is what the driver sends" do
      server = start(Impl.HandlesACast)

      # `:increment` from a bare term — a call, and it answers.
      assert {:ok, :ok} = Driver.deliver(server, CastRefinement.concrete_message(:increment, %{}))

      # `:done` from `{:cast, :done}`. A cast has no reply, and the completion is what the
      # driver reports instead.
      assert {:ok, :no_reply} =
               Driver.deliver(server, CastRefinement.concrete_message(:done, %{}))

      # `:reset` from `{:info, :reset}`.
      assert {:ok, :no_reply} =
               Driver.deliver(server, CastRefinement.concrete_message(:reset, %{}))

      assert :sys.get_state(server) == %{value: 0, status: :ready}
    end

    # The ordering guarantee D-36 rests on, observed rather than reasoned about: if the
    # driver returned before the cast was handled, this would be the pre-cast state.
    test "and a cast has been handled by the time the driver returns" do
      server = start(Impl.HandlesACast)

      {:ok, :ok} = Driver.deliver(server, :increment)
      assert :sys.get_state(server).status == :incrementing

      {:ok, :no_reply} = Driver.deliver(server, {:cast, :done})
      assert :sys.get_state(server).status == :ready
    end

    # The backward-compatibility claim, asserted rather than assumed: a mapping written
    # before D-36 returns bare terms and every one of them is still a call.
    test "and a bare term is still a call" do
      server = start(Impl.Conforming)

      for action <- [:increment, :done, :reset] do
        assert {:ok, :ok} = Driver.deliver(server, Refinement.concrete_message(action, %{}))
      end
    end

    test "and an explicit {:call, msg} is the same as the bare term" do
      server = start(Impl.Conforming)

      assert {:ok, :ok} = Driver.deliver(server, {:call, :increment})
      assert {:ok, :ok} = Driver.call(server, :done)
    end
  end

  # ── Both drivers, because both share the one path ───────────────────────────

  describe "a cast-handled action under replay" do
    test "drives, where it used to report :not_followed" do
      {_result, graph} =
        ModelChecker.explore(Spec, %{
          constants: %{max_val: 5},
          liveness_graph: true,
          check_deadlock: false
        })

      # `increment` is a call, `done` a cast, `reset` an info: one trace over all three
      # routes, so a driver that handled one and not another cannot pass.
      trace =
        Trace.replay(graph, 0, [{:increment, %{}}, {:done, %{}}, {:reset, %{}}])

      assert %{status: :ok, steps_checked: 3, violation: nil} =
               Replay.counterexample(Impl.HandlesACast, trace)
    end
  end

  describe "a cast-handled action under simulation" do
    test "drives, and the run covers every action" do
      {result, behaviour} =
        Simulation.run_trace(Impl.HandlesACast, %{max_steps: 30, seed: 11})

      assert result.status == :ok, inspect(result.detail)
      assert length(behaviour) > 1

      # Anti-vacuity, and it is the assertion that matters: a run that only ever drew
      # `increment` would pass without ever sending a cast. `actions_hit` is the census
      # `ExTLA.Coverage` keeps of what actually ran.
      assert Map.has_key?(result.coverage.actions_hit, :done),
             "seed 11 never drew `done`, so this asserts nothing about the cast path: " <>
               inspect(result.coverage.actions_hit)
    end
  end

  # ── The failure modes stay distinguishable ──────────────────────────────────

  describe "a cast that does not complete" do
    # The half that makes the design sound rather than merely working. A driver that moved
    # on after a cast without confirming it would compare the next action against a stale
    # state -- #168's defect class. So a cast that never completes must be a NAMED finding.
    test "is a named {:timeout, ms}, never a silent completion" do
      # A process that answers nothing — not the `:get_state` either — so the completion
      # signal never arrives. A driver that assumed a cast was done because it had been
      # SENT would report success here.
      inert = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(inert, :kill) end)

      # deadline: the timeout IS the outcome asserted. A silent server is given 200 ms, and
      # load can only make it more silent, never less, so a short bound cannot flake.
      assert {:timeout, 200} = Driver.deliver(inert, {:cast, :done}, 200)
      # deadline: as above, the timeout is the asserted outcome.
      assert {:timeout, 200} = Driver.deliver(inert, {:info, :reset}, 200)
    end

    test "and a server that dies on the message is reported by the monitor" do
      server = start(Impl.HandlesACast)

      # `handle_info/2` has only `:reset`, so the server dies rather than answering, and
      # the monitor carries that back as a value instead of raising here.
      #
      # The death is the outcome, so the bound only stops a hang: a passing run returns at the
      # `:DOWN`. It was 1_000 until #366, and a run on an oversubscribed host missed it, because a
      # crashing server writes its crash report before it exits, and under log pressure that
      # takes two to three orders of magnitude longer than idle (measured: median 0.3 ms idle,
      # 51 ms and up to 188 ms under CPU load and a log flood, more on a host short of CPU).
      assert {:stopped, _reason} =
               Driver.deliver(server, {:info, :nothing_matches_this}, :timer.seconds(30))
    end

    test "and a dead server is reported rather than raising" do
      server = start(Impl.HandlesACast)
      ref = Process.monitor(server)
      Process.exit(server, :kill)
      assert_receive {:DOWN, ^ref, :process, ^server, _}

      assert {:stopped, :noproc} = Driver.deliver(server, {:cast, :done})
    end
  end

  # ── The validator ───────────────────────────────────────────────────────────

  describe "the compile-time round-trip" do
    # The first thing that broke when the corpus entry was written, and the reason it is
    # worth a test: `abstract_action/1` receives the MESSAGE, not the envelope the driver
    # puts it in. Without the unwrap, a mapping that correctly says `{:cast, :done}` is
    # reported as naming no message for `:done` -- a false finding about a correct mapping.
    test "sees through the delivery tag" do
      # `validate!/3` raises on a finding and returns the rules it could not decide, so
      # "did not raise" is the assertion — and the deferred list is asserted too, since a
      # rule quietly moving into it would be the same defect wearing a different coat.
      assert {:ok, deferred} = ExTLA.Refinement.validate!(CastRefinement, Spec, %{max_val: 5})

      # Exactly the two every mapping defers — both need a concrete state, which a compile
      # does not have. Nothing about naming an action is among them.
      assert Keyword.keys(deferred) == [:always, :always]
      refute Enum.any?(deferred, fn {_scope, rule} -> rule =~ "names" end)
    end

    test "and the tagged mapping is the one the corpus entry compiles against" do
      assert Impl.HandlesACast.__tla_refinement__() == CastRefinement
    end
  end
end
