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
