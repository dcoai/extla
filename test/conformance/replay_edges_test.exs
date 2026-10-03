defmodule ExTLA.ReplayEdgesTest do
  @moduledoc """
  What `ExTLA.Replay` does with a lasso and with a step that names no spec action
  (#304, closes #168).

  ## The lasso

  `ModelChecker.Liveness` builds a cycle with
  `Trace.from(graph, List.last(prefix.states), cycle_steps, [])`, and `Trace.from/4`
  prepends the state it is handed — so the cycle's first state **is** the prefix's last.
  `Trace.to_behavior/1` compensates. `splice/2` adjusted `length` for it and not the list,
  so the spliced trace carried one state too many; `drive/5` zips actions against
  `Enum.drop(states, 1)`, and from the first cycle step onward compared every action
  against the state *before* it. **Every genuine liveness counterexample replayed as
  `:not_followed`** — a true finding, inverted.

  It survived because the only lasso in the suite was hand-written and
  `Trace.validate/3` rejects it: `length: 1` on a two-state prefix, a one-state cycle with
  an action, and a cycle head that is not the prefix's tail. The liveness checker cannot
  emit that shape, so the test exercised something the defect could not reach.

  `Stuck` below is a spec whose temporal property the checker genuinely refutes, and the
  lasso under test is **what the checker returned**, asserted to pass `Trace.validate/3`
  before anything is replayed with it.

  ## The steps that name no action

  A trace's `actions` are not all actions of the spec. `ExTLA.Simulation` writes `:unmapped`
  for a message the mapping does not model — its normal answer — and `:restart` for a crash
  injected by `--inject-failures`. `drive/5` called `concrete_message/2` on them regardless
  and died with a `FunctionClauseError`: the advertised simulation-to-replay handoff
  crashing on its ordinary input.
  """

  use ExUnit.Case, async: true

  alias ExTLA.Conformance.Counter.Impl
  alias ExTLA.{ModelChecker, Replay, Simulation, Trace}

  # ── A spec the checker refutes, so the lasso is real ────────────────────────

  defmodule Stuck do
    @moduledoc """
    `toggle` flips `n` forever and nothing ever sets `flag`, so `eventually(flag)` is
    refuted by the cycle `0 → 1 → 0`. No fairness is needed: a behaviour that never sets
    the flag is enough.
    """
    use ExTLA.Spec

    variable :n, type: 0..1
    variable :flag, type: [false, true]

    init do
      n = 0
      flag = false
    end

    action :toggle do
      n = 1 - n
    end

    temporal :eventually_flag do
      eventually(flag == true)
    end
  end

  defmodule StuckRefinement do
    use ExTLA.Refinement

    def abstract(%{n: n, flag: f}), do: %{n: n, flag: f}

    def abstract_action(:toggle), do: {:toggle, %{}}
    def abstract_action(_), do: :unmapped

    def concrete_message(:toggle, _params), do: :toggle
  end

  defmodule StuckServer do
    use GenServer

    use ExTLA.GenServer,
      spec: ExTLA.ReplayEdgesTest.Stuck,
      refinement: ExTLA.ReplayEdgesTest.StuckRefinement

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts), do: {:ok, %{n: 0, flag: false}}

    @impl true
    def handle_call(:toggle, _from, state), do: {:reply, :ok, %{state | n: 1 - state.n}}
  end

  defp refuted_lasso do
    result = ModelChecker.run(Stuck, %{check_liveness: true, check_deadlock: false})
    assert result.status == :violation
    result.violation
  end

  describe "a liveness counterexample the checker produced" do
    # The fixture's own credentials, asserted before it is used for anything. The lasso this
    # replaced failed exactly here, and nothing looked.
    test "is a lasso the spec admits" do
      lasso = refuted_lasso()

      assert %{prefix: %Trace{}, cycle: %Trace{}} = lasso
      assert Trace.validate(lasso, Stuck, %{}) == :ok
      assert Trace.well_formed(lasso) == :ok

      # The shape the splice has to account for: the cycle opens where the prefix ends.
      assert hd(lasso.cycle.states) == List.last(lasso.prefix.states)
    end

    test "replays cleanly against an implementation that refines the spec" do
      assert %{status: :ok, violation: nil, skipped: []} =
               Replay.counterexample(StuckServer, refuted_lasso())
    end

    # The arithmetic the defect got wrong, asserted on the trace rather than inferred from
    # the verdict: prefix states + cycle states - 1, and one action per step.
    test "and the spliced trace is one behaviour" do
      lasso = refuted_lasso()
      %{status: :ok, steps_checked: steps} = Replay.counterexample(StuckServer, lasso)

      assert steps == length(lasso.prefix.actions) + length(lasso.cycle.actions)
      assert steps == length(lasso.prefix.states) + length(lasso.cycle.states) - 2
    end
  end

  # ── A step that names no spec action ────────────────────────────────────────

  describe "an :unmapped step" do
    # `:unmapped` claims the message does not move the abstract state, so there is nothing
    # to send and the behaviour is unchanged by it. Hand-built rather than simulated: the
    # default generator only offers actions the spec enables, so it never draws the one
    # message `Impl.Conforming` leaves unmapped.
    defp with_unmapped do
      ready = %{count: 0, status: :ready}
      incrementing = %{count: 1, status: :incrementing}
      done = %{count: 1, status: :ready}

      %Trace{
        type: :safety,
        states: [ready, incrementing, incrementing, done],
        actions: [:increment, :unmapped, :done],
        bindings: [%{}, %{}, %{}],
        length: 4
      }
    end

    test "is skipped rather than crashing the replay" do
      assert %{status: :ok, steps_checked: 3} =
               Replay.counterexample(Impl.Conforming, with_unmapped())
    end

    test "and the skip is reported, not swallowed" do
      result = Replay.counterexample(Impl.Conforming, with_unmapped())

      assert result.skipped == [{2, :unmapped}]
      assert result.detail =~ "1 step(s) were not driven"
      assert result.detail =~ "2 (unmapped)"
      assert result.detail =~ "post-states were still checked"
    end

    # The half that makes skipping honest: the trace still says where the behaviour was
    # after that step, and a step claiming to stutter while the state moved is a finding.
    test "and its post-state is still checked" do
      moved = %{
        with_unmapped()
        | states: List.replace_at(with_unmapped().states, 2, %{count: 9, status: :ready})
      }

      assert %{status: :not_followed, steps_checked: 1} =
               Replay.counterexample(Impl.Conforming, moved)
    end
  end

  describe "a :restart step" do
    # End to end: a counterexample the simulation produced under `--inject-failures`, which
    # is the input the advertised handoff is for. Seeded, so the restart is deterministic
    # rather than a race; `restarts > 0` is the anti-vacuity guard.
    defp simulated_with_restart do
      {result, _behaviour} =
        Simulation.run_trace(Impl.CollapsesTwoSteps, %{
          max_steps: 60,
          seed: 2,
          inject_failures: true
        })

      assert result.restarts > 0, "seed 2 took no restart, so this test drives nothing new"
      assert :restart in result.violation.actions
      result.violation
    end

    test "is reproduced, and the replay reaches the step after it" do
      trace = simulated_with_restart()
      restart_at = Enum.find_index(trace.actions, &(&1 == :restart)) + 1

      result = Replay.counterexample(Impl.CollapsesTwoSteps, trace)

      # It used to raise `FunctionClauseError` here. Now it gets past the restart and finds
      # the defect the simulation found — which is what the trace is a counterexample to.
      assert result.status == :violation
      assert result.violation.step > restart_at
      assert result.steps_checked >= restart_at
    end

    # Reproducing means killing the server and starting it again, which is not something to
    # do to a server the caller handed over.
    test "is refused, naming the step, when the caller supplied the server" do
      trace = simulated_with_restart()
      {:ok, server} = GenServer.start_link(Impl.CollapsesTwoSteps, [])
      Process.unlink(server)
      on_exit(fn -> if Process.alive?(server), do: Process.exit(server, :kill) end)

      result = Replay.counterexample(Impl.CollapsesTwoSteps, trace, server: server)

      assert result.status == :not_replayable
      assert result.detail =~ "is a `:restart`"
      assert result.detail =~ "does not own"
      assert Process.alive?(server), "the replay killed a server it was told it does not own"
    end
  end
end
