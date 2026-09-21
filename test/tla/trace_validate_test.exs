defmodule TLA.TraceValidateTest do
  @moduledoc """
  `TLA.Trace.validate/3` — a counterexample checked against the spec rather than against a
  fixture recording what some other tool once said (#47).

  Almost every test here **corrupts** a real counterexample, because a validator that only
  ever sees valid input is a function that returns `:ok`. The corruptions are chosen to be
  the ones a broken checker would actually produce: real states, real actions, and a
  pairing between them that nothing computed.
  """

  use ExUnit.Case, async: true

  alias TLA.{ModelChecker, Spec, TestSpecs, Trace}

  defp safety_trace do
    result = ModelChecker.run(TestSpecs.Broken, %{})
    {result.violation, Spec.Compiled.from_module(TestSpecs.Broken), %{}}
  end

  defp lasso do
    result = ModelChecker.run(TestSpecs.Stalls, %{check_liveness: true})
    {result.violation, Spec.Compiled.from_module(TestSpecs.Stalls), %{}}
  end

  describe "a counterexample the checker really produced" do
    test "validates" do
      {trace, spec, constants} = safety_trace()

      assert trace.length == 4
      assert Trace.validate(trace, spec, constants) == :ok
    end

    test "and so does a lasso, cycle and all" do
      {violation, spec, constants} = lasso()

      assert %{prefix: _, cycle: _} = violation
      assert Trace.validate(violation, spec, constants) == :ok
    end

    test "and it takes a module as readily as a compiled spec" do
      {trace, _spec, constants} = safety_trace()

      assert Trace.validate(trace, TestSpecs.Broken, constants) == :ok
    end
  end

  describe "a step that is not legal" do
    test "an action that is not enabled in its predecessor" do
      {trace, spec, constants} = safety_trace()

      # `Broken` has one action, so the corruption is to name one the spec does not
      # enable there — `tick` requires `n < 5`, and this claims it fired past that.
      corrupt = %{trace | states: List.replace_at(trace.states, 0, %{n: 9})}

      assert {:error, message} = Trace.validate(corrupt, spec, constants)
      assert message =~ "no `init` block produces"
    end

    test "a post-state that is not what the transition produces" do
      {trace, spec, constants} = safety_trace()

      # The states are all reachable and the actions are all real. Only the PAIRING is
      # wrong — the second state is one the spec can reach, just not by this step. This
      # is the corruption nothing in the project could detect before.
      corrupt = %{trace | states: List.replace_at(trace.states, 1, %{n: 3})}

      assert {:error, message} = Trace.validate(corrupt, spec, constants)
      assert message =~ "step 1"
      assert message =~ "paired by something that did not compute them"
    end

    test "a binding the action does not admit there" do
      constants = %{accounts: MapSet.new([:alice, :bob]), max_balance: 2}
      spec = Spec.Compiled.from_module(TestSpecs.Transfer)

      {result, _graph} =
        ModelChecker.explore(TestSpecs.Transfer, %{
          constants: constants,
          state_constraint: fn state -> length(state.log) <= 1 end,
          check_deadlock: false,
          invariants: []
        })

      # Not every configuration of Transfer violates; this test is about the binding
      # check, so it needs a trace with a bound action in it.
      trace = %Trace{
        states: Enum.take(replayable_states(spec, constants), 2),
        actions: [:begin_transfer],
        bindings: [%{from: :alice, to: :alice, amount: 99}],
        length: 2
      }

      assert result.status in [:ok, :constrained, :violation]
      assert {:error, message} = Trace.validate(trace, spec, constants)
      assert message =~ "is not enabled in"
      assert message =~ "What is enabled there"
    end
  end

  describe "a trace that does not start where the spec starts" do
    test "is rejected, whatever else is true of it" do
      {trace, spec, constants} = safety_trace()

      # Every step below is legal; only the beginning is wrong. A trace that starts in
      # the middle describes a suffix of a behaviour, not a behaviour.
      corrupt = %{
        trace
        | states: tl(trace.states),
          actions: tl(trace.actions),
          bindings: tl(trace.bindings),
          length: trace.length - 1
      }

      assert {:error, message} = Trace.validate(corrupt, spec, constants)
      assert message =~ "no `init` block produces"
      assert message =~ "not a behaviour of the spec"
    end
  end

  describe "a lasso whose cycle is wrong" do
    # Built rather than corrupted, and deliberately. Truncating a real cycle fails the
    # step checks before it reaches the closure check, and `Stalls`'s cycle ends in a
    # stuttering terminal with nothing enabled, so it cannot be extended either. This
    # lasso has entirely legal steps and simply does not return to where it started —
    # which is the one thing a cycle is for.
    test "a cycle that does not close cannot be repeated forever" do
      spec = Spec.Compiled.from_module(TestSpecs.Broken)

      walk_away = %{
        prefix: %Trace{states: [%{n: 0}], actions: [], bindings: [], length: 1},
        cycle: %Trace{
          states: [%{n: 0}, %{n: 1}],
          actions: [:tick],
          bindings: [%{}],
          length: 2
        }
      }

      assert {:error, message} = Trace.validate(walk_away, spec, %{})
      assert message =~ "does not close"
      assert message =~ "repeated forever"
    end

    test "a cycle that starts somewhere other than where the prefix ends" do
      {%{prefix: prefix, cycle: cycle}, spec, constants} = lasso()

      detached = %{cycle | states: List.replace_at(cycle.states, 0, %{n: 0})}

      assert {:error, message} =
               Trace.validate(%{prefix: prefix, cycle: detached}, spec, constants)

      assert message =~ "two behaviours rather than one"
    end
  end

  # #203. `validate/3` is the oracle `generated_models_test.exs` rests on, and it accepted a
  # stutter anywhere: a one-state, no-action cycle validated at a state with enabled steps
  # and `format/1` rendered it "has no successors". §5.3 puts a stutter in exactly one place.
  describe "a stutter where a step is enabled" do
    test "a lasso stuttering at a live state is rejected, naming the enabled step" do
      spec = Spec.Compiled.from_module(TestSpecs.Broken)

      stuck_early = %{
        prefix: %Trace{
          type: :liveness,
          states: [%{n: 0}, %{n: 1}],
          actions: [:tick],
          bindings: [%{}],
          length: 2
        },
        cycle: %Trace{type: :liveness, states: [%{n: 1}], actions: [], bindings: [], length: 1}
      }

      assert {:error, message} = Trace.validate(stuck_early, spec, %{})
      assert message =~ "claimed to stutter forever"
      assert message =~ ":tick"
      assert message =~ "§5.3"
    end

    test "a lasso stuttering at a successor-less state still validates" do
      {violation, spec, constants} = lasso()

      assert violation.cycle.actions == []
      assert Trace.validate(violation, spec, constants) == :ok
    end

    test "a deadlock trace ending at a live state is rejected" do
      spec = Spec.Compiled.from_module(TestSpecs.Broken)

      not_stuck = %Trace{
        type: :deadlock,
        states: [%{n: 0}, %{n: 1}],
        actions: [:tick],
        bindings: [%{}],
        length: 1
      }

      assert {:error, message} = Trace.validate(not_stuck, spec, %{})
      assert message =~ "the deadlock's last state"
      assert message =~ ":tick"
    end

    test "a deadlock trace the checker produced still validates" do
      result = ModelChecker.run(TestSpecs.Deadlocking, %{constants: %{max: 2}})

      assert result.violation.type == :deadlock
      assert Trace.validate(result.violation, TestSpecs.Deadlocking, %{max: 2}) == :ok
    end
  end

  describe "a lasso with nothing to repeat" do
    test "an empty cycle is named rather than crashing the validator" do
      {%{prefix: prefix, cycle: cycle}, spec, constants} = lasso()

      empty = %{cycle | states: [], actions: [], bindings: []}

      assert {:error, message} = Trace.validate(%{prefix: prefix, cycle: empty}, spec, constants)
      assert message =~ "nothing to repeat"
    end
  end

  describe "a trace whose parts do not describe one behaviour" do
    test "more actions than steps is a shape error, not a shorter check" do
      {trace, spec, constants} = safety_trace()

      corrupt = %{trace | actions: trace.actions ++ [:tick]}

      assert {:error, message} = Trace.validate(corrupt, spec, constants)
      assert message =~ "cannot describe one behaviour"
    end

    # #204. `format/1` zipped the three lists and stopped at the shortest: one action short —
    # the shape the simulation's restart branch produced — it printed three states of four
    # and marked the wrong one `[VIOLATION]`. The state that actually violated was never
    # shown, and `Trace.Explore`, which renders every column, disagreed with it.
    test "format/1 refuses a misaligned trace rather than marking the wrong state" do
      {trace, _spec, _constants} = safety_trace()
      assert length(trace.states) == 4

      one_short = %{trace | actions: tl(trace.actions), bindings: tl(trace.bindings)}

      error = assert_raise ArgumentError, fn -> Trace.format(one_short) end
      assert error.message =~ "4 states, 2 actions and 2 bindings"
      assert error.message =~ "mark the wrong state"

      # The well-formed trace renders as before, its last state marked.
      assert Trace.format(trace) =~ "State 4 [VIOLATION]"
    end

    test "a JSON trace with no bindings is refused, not rendered as one state" do
      {trace, _spec, _constants} = safety_trace()
      no_bindings = trace |> Trace.to_json() |> Map.delete("bindings") |> Trace.from_json!()

      assert no_bindings.bindings == []

      assert_raise ArgumentError, ~r/4 states, 3 actions and 0 bindings/, fn ->
        Trace.format(no_bindings)
      end
    end
  end

  describe "validate!/3" do
    test "raises with the same message" do
      {trace, spec, constants} = safety_trace()
      corrupt = %{trace | states: List.replace_at(trace.states, 1, %{n: 3})}

      assert_raise ArgumentError, ~r/did not compute them/, fn ->
        Trace.validate!(corrupt, spec, constants)
      end
    end

    test "and returns :ok on a real one" do
      {trace, spec, constants} = safety_trace()
      assert Trace.validate!(trace, spec, constants) == :ok
    end
  end

  # The first two states of a real behaviour, for a fixture that needs a starting point
  # rather than a whole counterexample.
  defp replayable_states(spec, constants) do
    initial = hd(spec.init).(constants)
    [{action, binding} | _] = ModelChecker.enabled_steps(spec, constants, initial)
    next = Spec.Compiled.action(spec, action).transition.(constants, initial, binding)
    [initial, next]
  end
end
