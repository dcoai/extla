defmodule ExTLA.ActionPropertyTraceTest do
  @moduledoc """
  An `action_property` counterexample ends with the offending step, and a safety trace has to
  refute the property it names (#112, #113).

  The defect this pins: the trace was built from the **post-state's** graph id, so when that state
  had already been discovered by a shorter route the parent pointers described *that* route — the
  offending step was absent, and the step the trace marked could satisfy the property it was
  offered as a refutation of. `Trace.validate/3` passed it, because it *was* a legal path from an
  initial state and nothing checked the rest.
  """
  use ExUnit.Case, async: true

  @moduletag verifies:
               "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Trace`"

  alias ExTLA.{ModelChecker, Spec, Trace}
  alias ExTLA.ModelChecker.Safety

  defmodule Audited do
    @moduledoc """
    An audit log that must only grow, and a `compact` that truncates it.

    The shape matters: `compact`'s post-state is reachable in fewer steps by `acquire`, which is
    what made the old trace point somewhere innocent.
    """
    use ExTLA.Spec

    constant :clients, default: MapSet.new([:alice, :bob])

    variable :holder, type: ^clients | :none
    variable :log, type: seq(^clients)

    init do
      holder = :none
      log = seq()
    end

    action :acquire, params: [c: ^clients] do
      require holder == :none
      holder = c
      log = append(log, c)
    end

    action :release do
      require holder != :none
      holder = :none
    end

    action :compact do
      require len(log) > 1
      log = seq([head(log)])
    end

    action_property :log_only_grows do
      len(new.log) >= len(old.log)
    end
  end

  defmodule OnlyByTheStep do
    @moduledoc """
    The case that worked before the fix and must keep working: the offending step's post-state is
    reachable *only* by that step, so walking back from it happened to give the right answer.
    """
    use ExTLA.Spec

    variable :n, type: 0..2

    init do
      n = 0
    end

    action :up do
      require n < 2
      n = n + 1
    end

    action_property :never_decreases do
      new.n >= old.n
    end

    action :reset do
      require n == 2
      n = 0
    end

    invariant :within_range do
      n >= 0 and n <= 2
    end
  end

  defp constants(module) do
    {:ok, constants} = module |> Spec.Compiled.from_module() |> Spec.Compiled.resolve_constants()
    constants
  end

  describe "the counterexample contains the step that broke the property" do
    test "even when the post-state was already reachable by a shorter route" do
      spec = Spec.Compiled.from_module(Audited)
      constants = constants(Audited)

      result = ModelChecker.run(spec, %{constants: constants})

      assert result.status == :violation
      assert result.violation.property == :log_only_grows

      # The finding, stated as the property it is about: the LAST step must be the guilty one.
      [old_state, new_state] = Enum.take(result.violation.states, -2)

      assert Safety.check_action_properties(spec, constants, old_state, new_state) ==
               {:violation, :log_only_grows},
             "the trace's final step satisfies the property it is offered as a refutation of"

      assert List.last(result.violation.actions) == :compact
    end

    test "and the case that already worked still works" do
      spec = Spec.Compiled.from_module(OnlyByTheStep)
      result = ModelChecker.run(spec, %{constants: constants(OnlyByTheStep)})

      assert result.status == :violation
      assert result.violation.property == :never_decreases
      assert List.last(result.violation.actions) == :reset
    end

    test "and it validates as a counterexample, not merely as a legal path" do
      spec = Spec.Compiled.from_module(Audited)
      constants = constants(Audited)
      result = ModelChecker.run(spec, %{constants: constants})

      assert Trace.validate(result.violation, spec, constants) == :ok
    end
  end

  describe "a safety trace must refute the property it names" do
    test "an action property that holds over the final step is rejected" do
      spec = Spec.Compiled.from_module(Audited)
      constants = constants(Audited)

      # A legal path, and exactly the shape the old code produced: acquire from init.
      fabricated = %Trace{
        type: :safety,
        property: :log_only_grows,
        actions: [:acquire],
        bindings: [%{c: :alice}],
        states: [%{holder: :none, log: []}, %{holder: :alice, log: [:alice]}],
        length: 2
      }

      assert {:error, message} = Trace.validate(fabricated, spec, constants)
      assert message =~ "log_only_grows"
      assert message =~ "HOLDS"
      assert message =~ "final step"
    end

    test "an invariant that holds in the final state is rejected" do
      spec = Spec.Compiled.from_module(OnlyByTheStep)

      fabricated = %Trace{
        type: :safety,
        property: :within_range,
        actions: [:up],
        bindings: [%{}],
        states: [%{n: 0}, %{n: 1}],
        length: 2
      }

      assert {:error, message} = Trace.validate(fabricated, spec, %{})
      assert message =~ "within_range"
      assert message =~ "HOLDS"
    end

    test "an implicit type_ok is not checked, and that is stated rather than silent" do
      # `type_ok` is derived from the `type:` annotations rather than declared, so it is not in
      # `spec.invariants` and this check does not reach it. Harmless in practice — an invariant
      # trace is built from the violating state's own id, where any path is a fair counterexample
      # — and recorded here so the limit is visible rather than discovered.
      spec = Spec.Compiled.from_module(OnlyByTheStep)

      trace = %Trace{
        type: :safety,
        property: :type_ok,
        actions: [:up],
        bindings: [%{}],
        states: [%{n: 0}, %{n: 1}],
        length: 2
      }

      assert Trace.validate(trace, spec, %{}) == :ok
    end

    test "a trace naming no property claims nothing to refute" do
      spec = Spec.Compiled.from_module(OnlyByTheStep)

      trace = %Trace{
        type: :safety,
        property: nil,
        actions: [:up],
        bindings: [%{}],
        states: [%{n: 0}, %{n: 1}],
        length: 2
      }

      assert Trace.validate(trace, spec, %{}) == :ok
    end
  end
end
