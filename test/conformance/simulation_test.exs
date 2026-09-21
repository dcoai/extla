defmodule TLA.ConformanceSimulationTest do
  use ExUnit.Case, async: true

  alias TLA.Conformance.Counter.{Impl, Refinement, Spec}
  alias TLA.Simulation
  alias TLA.Simulation.Generator

  @constants %{max_val: 5}

  describe "the implementation that conforms" do
    test "survives a hundred random traces, and says what they covered" do
      result = Simulation.run(Impl.Conforming, %{traces: 100, max_steps: 20, seed: 7})

      assert result.status == :ok
      assert result.traces_run == 100
      assert result.total_steps > 0
      assert result.violation == nil

      # `reset` and `increment` are enabled from the initial state and `done` from the
      # state increment leads to, so a run this size must have reached all three.
      assert result.coverage.actions_covered == 1.0
      assert Map.keys(result.coverage.actions_hit) |> Enum.sort() == [:done, :increment, :reset]
      assert result.coverage.states_visited > 1
    end

    test "reports the seed it ran with, so a finding can be run again" do
      result = Simulation.run(Impl.Conforming, %{traces: 2, max_steps: 3})

      assert is_integer(result.seed)

      assert Simulation.run(Impl.Conforming, %{traces: 2, max_steps: 3, seed: result.seed}).seed ==
               result.seed
    end

    test "the same seed produces the same walk" do
      config = %{traces: 3, max_steps: 10, seed: 1234}

      {_result, first} = Simulation.run_trace(Impl.Conforming, config)
      {_result, again} = Simulation.run_trace(Impl.Conforming, config)

      assert first == again
    end

    test "run_trace/2 hands back the behaviour whether or not it found anything" do
      {result, behavior} = Simulation.run_trace(Impl.Conforming, %{max_steps: 5, seed: 3})

      assert result.status == :ok
      assert [%{count: 0, status: :ready} | _] = behavior
      assert length(behavior) > 1
    end
  end

  describe "an implementation that does not conform" do
    # Found by walking randomly rather than by being told where to look: the mutant's only
    # message is `:increment`, and every generator that sends one finds it.
    test "is caught, and the finding is a TLA.Trace" do
      result = Simulation.run(Impl.CollapsesTwoSteps, %{traces: 5, max_steps: 5, seed: 11})

      assert result.status == :violation
      assert %TLA.Trace{} = result.violation
      assert result.violation.message =~ "CONFORMANCE: DIVERGED"
      assert :increment in result.violation.actions

      # The counterexample the model checker produces has this shape too, which is what
      # lets it be replayed and printed by the same code.
      assert length(result.violation.states) == length(result.violation.actions) + 1
    end

    test "and the trace it reports can be replayed against the same server" do
      result = Simulation.run(Impl.CollapsesTwoSteps, %{traces: 5, max_steps: 5, seed: 11})

      report = TLA.Replay.counterexample(Impl.CollapsesTwoSteps, result.violation)

      assert report.status == :violation
      assert report.violation.kind == :diverged
    end
  end

  describe "explicit messages" do
    test "drive the server in order, and report the step that failed" do
      assert %{status: :ok, total_steps: 3} =
               Simulation.replay(Impl.Conforming, [:increment, :done, :reset])

      assert %{status: :violation} = Simulation.replay(Impl.CollapsesTwoSteps, [:increment])
    end
  end

  describe "the unrestricted generator, which is opt-in" do
    # It asks a different question: does the implementation REFUSE what the spec forbids
    # in this state. `Impl.Conforming` does not — its `handle_call(:done, …)` has no guard
    # of its own — and `:not_enabled` is the correct finding about that pair. It is also a
    # finding about nearly every server ever written, which is why it is not the default.
    test "catches the conforming server accepting a message the spec forbids there" do
      result =
        Simulation.run(Impl.Conforming, %{
          traces: 10,
          max_steps: 10,
          seed: 5,
          message_generator: Generator.from_spec(Spec, Refinement, @constants)
        })

      assert result.status == :violation
      assert result.violation.message =~ "NOT ENABLED"
    end
  end

  describe "failure injection" do
    # A crash is not a step of the specification — nothing in the DSL models one — so a
    # restart is not checked as a transition. Where recovery LANDS is checked.
    test "kills and restarts the server, and checks where recovery lands" do
      result =
        Simulation.run(Impl.Conforming, %{
          traces: 20,
          max_steps: 20,
          seed: 99,
          inject_failures: true
        })

      assert result.status == :ok
      assert result.restarts > 0
    end
  end

  # #206. Each server was started linked, unlinked at once, and stopped only on the normal
  # return — so a generator that raised once took the run down and left every started
  # server alive: eight `Impl.Conforming` processes after one failed run. The server is now
  # owned by the trace's process, linked for its whole life.
  describe "the server's lifetime is the trace's" do
    # A module of this test's own (#266): counting `Impl.Conforming` processes counted the
    # servers other async tests had running at the same moment, and reported them as leaks.
    # `Leaky` is the conforming implementation under a name nothing else starts.
    defmodule Leaky do
      use GenServer
      use TLA.GenServer, spec: Spec, refinement: Refinement

      def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(_opts), do: {:ok, %{value: 0, status: :ready}}

      @impl true
      def handle_call(:increment, _from, state),
        do: {:reply, :ok, %{state | value: state.value + 1, status: :incrementing}}

      def handle_call(:done, _from, state), do: {:reply, :ok, %{state | status: :ready}}
      def handle_call(:reset, _from, state), do: {:reply, :ok, %{state | value: 0}}
    end

    defp leaky_servers do
      for pid <- Process.list(),
          {:dictionary, dict} <- [Process.info(pid, :dictionary)],
          dict[:"$initial_call"] == {Leaky, :init, 1},
          do: pid
    end

    test "a generator that raises leaves no server alive" do
      assert leaky_servers() == []

      explode = fn _state -> raise "the generator is broken" end

      # The raise reaches the caller as the linked task's exit, as a crash always did; what
      # is different is what it leaves behind.
      Process.flag(:trap_exit, true)

      spawn_link(fn ->
        Simulation.run(Leaky, %{traces: 8, seed: 1, message_generator: explode})
      end)

      assert_receive {:EXIT, _, {%RuntimeError{message: "the generator is broken"}, _}}, 5_000

      # The links deliver the kill asynchronously, so wait for the count to settle rather
      # than for a fixed time -- and fail with the survivors named if it never does.
      assert settle(fn -> leaky_servers() end, 2_000) == []
    end

    defp settle(count, deadline_ms) do
      deadline = System.monotonic_time(:millisecond) + deadline_ms

      Stream.repeatedly(count)
      |> Enum.find(fn left -> left == [] or System.monotonic_time(:millisecond) > deadline end)
    end

    test "init/1 returning :ignore is an outcome, not a MatchError" do
      defmodule Declines do
        use GenServer
        use TLA.GenServer, spec: Spec, refinement: Refinement

        def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

        @impl true
        def init(_opts), do: :ignore
      end

      result = Simulation.run(Declines, %{traces: 2, seed: 1})

      assert result.status == :error
      assert result.detail =~ "init/1 returned :ignore"
      assert result.detail =~ "nothing was checked"
    end
  end

  # #213. Three things the module said or did that did not match each other.
  describe "what the doc says, the code does" do
    test "run/2 stops at the first finding, and traces_run counts what ran" do
      result = Simulation.run(Impl.CollapsesTwoSteps, %{traces: 50, max_steps: 5, seed: 11})

      assert result.status == :violation
      assert result.traces_run < 50
    end

    # `terminate/2` is the implementation's chance to clean up, and a bare `:kill` skipped it
    # for every server. A supervisor's `:shutdown` runs it for a server that traps exits.
    test "a stopped server that traps exits gets its terminate/2" do
      defmodule Tidy do
        use GenServer
        use TLA.GenServer, spec: Spec, refinement: Refinement

        def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

        @impl true
        def init(opts) do
          Process.flag(:trap_exit, true)
          {:ok, %{value: 0, status: :ready, notify: Keyword.fetch!(opts, :notify)}}
        end

        @impl true
        def handle_call(:increment, _from, state),
          do: {:reply, :ok, %{state | value: state.value + 1, status: :incrementing}}

        def handle_call(:done, _from, state), do: {:reply, :ok, %{state | status: :ready}}
        def handle_call(:reset, _from, state), do: {:reply, :ok, %{state | value: 0}}

        @impl true
        def terminate(reason, state), do: send(state.notify, {:terminated, reason})
      end

      assert %{status: :ok} =
               Simulation.replay(Tidy, [:increment, :done], %{init_arg: [notify: self()]})

      assert_receive {:terminated, :shutdown}, 5_000
    end

    # The server resolves its constants from application config; a generator on any other
    # assignment would drive it against a different specification.
    test "constants: is refused, naming where the constants come from" do
      error =
        assert_raise ArgumentError, fn ->
          Simulation.run(Impl.Conforming, %{traces: 1, constants: %{max_val: 99}})
        end

      assert error.message =~ "takes no `constants:`"
      assert error.message =~ "config :extla, TLA.Conformance.Counter.Spec"
    end
  end

  describe "the generator" do
    test "produces a message for an action the spec declares" do
      generate = Generator.from_spec(Spec, Refinement, @constants)

      assert {action, %{}, message} = generate.(%{count: 0, status: :ready})
      assert action in [:increment, :done, :reset]
      assert message in [:increment, :done, :reset]
    end

    # A simulation that only ever sends enabled messages cannot produce a `:not_enabled`
    # finding, which is worth knowing before choosing it.
    test "enabled_only/3 never offers an action the guard forbids" do
      generate = Generator.enabled_only(Spec, Refinement, @constants)

      for _ <- 1..50 do
        assert {action, _binding, _message} = generate.(%{count: 0, status: :incrementing})
        assert action == :done
      end
    end

    test "and from_spec/3 does offer one, which is how :not_enabled is ever found" do
      generate = Generator.from_spec(Spec, Refinement, @constants)

      offered =
        for _ <- 1..100, do: elem(generate.(%{count: 0, status: :incrementing}), 0)

      assert :increment in offered
    end

    test "answers nil where no action of the spec is enabled" do
      generate = Generator.enabled_only(Spec, Refinement, @constants)

      # Outside the declared type of `status`, which is the only way this counter has no
      # enabled action at all: every guard mentions it.
      assert generate.(%{count: 0, status: :wedged}) == nil
    end
  end
end
