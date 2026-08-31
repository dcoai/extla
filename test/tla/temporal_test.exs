defmodule TLA.TemporalTest do
  use ExUnit.Case, async: true

  alias TLA.{ModelChecker, Spec, Temporal}
  alias TLA.TestSpecs.{Counter, PerBinding}

  defp start(module, constants) do
    spec = Spec.Compiled.from_module(module)
    {spec, spec.init |> hd() |> apply([constants])}
  end

  defp step(spec, constants, state, name, params) do
    {_action, _params, next} =
      spec
      |> ModelChecker.successors(constants, state)
      |> Enum.find(fn {action, bound, _} -> action == name and bound == params end)

    next
  end

  describe "enabled?/4" do
    test "is the action's guard over its bindings, and nothing else" do
      constants = %{max: 2}
      {spec, state} = start(Counter, constants)

      assert Temporal.enabled?(state, Spec.Compiled.action(spec, :increment), constants)
      refute Temporal.enabled?(state, Spec.Compiled.action(spec, :finish), constants)
      refute Temporal.enabled?(state, Spec.Compiled.action(spec, :reset), constants)
    end

    # §5.2's distinction, in one state: `p2` is idle and has not requested, so
    # ENABLED Acquire(p2) is false — while ENABLED \E p : Acquire(p) is true,
    # because p1 has. A fairness constraint reading the second where it meant
    # the first is how `no_starvation` becomes unprovable.
    test "a binding asks about one process; no binding asks about any" do
      constants = %{processes: MapSet.new([:p1, :p2])}
      {spec, state} = start(PerBinding, constants)
      acquire = Spec.Compiled.action(spec, :acquire)

      refute Temporal.enabled?(state, acquire, constants)

      waiting = step(spec, constants, state, :request, %{p: :p1})

      assert Temporal.enabled?(state, Spec.Compiled.action(spec, :request), constants, %{p: :p1})
      assert Temporal.enabled?(waiting, acquire, constants)
      assert Temporal.enabled?(waiting, acquire, constants, %{p: :p1})
      refute Temporal.enabled?(waiting, acquire, constants, %{p: :p2})
    end

    test "an action whose generator is empty here is disabled here" do
      constants = %{processes: MapSet.new([])}
      {spec, state} = start(PerBinding, constants)

      refute Temporal.enabled?(state, Spec.Compiled.action(spec, :request), constants)
    end
  end

  describe "enabled_among?/2" do
    test "agrees with enabled?/4 on the bindings it was given" do
      constants = %{processes: MapSet.new([:p1, :p2])}
      {spec, state} = start(PerBinding, constants)
      request = Spec.Compiled.action(spec, :request)

      bindings = ModelChecker.enabled_bindings(request, constants, state)

      assert Temporal.enabled_among?(bindings, %{})
      assert Temporal.enabled_among?(bindings, %{p: :p1})
      refute Temporal.enabled_among?(bindings, %{p: :nobody})
    end

    test "no enabled binding means enabled by nothing, restricted or not" do
      refute Temporal.enabled_among?([], %{})
      refute Temporal.enabled_among?([], %{p: :p1})
    end
  end
end
