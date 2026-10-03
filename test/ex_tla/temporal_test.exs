defmodule ExTLA.TemporalTest do
  use ExUnit.Case, async: true

  alias ExTLA.{ModelChecker, Spec, Temporal, Trace}
  alias ExTLA.Temporal.Fairness
  alias ExTLA.TestSpecs.{Counter, PerBinding, WeaklyFair}

  @processes %{processes: MapSet.new([:p1, :p2])}

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

  # ── Operators over one behaviour ────────────────────────────────────────────

  # 0 -> 1 -> 2, with the cycle (where there is one) starting at n = 1.
  @counting [%{n: 0}, %{n: 1}, %{n: 2}]

  describe "always/3" do
    test "one false state refutes it, lasso or no lasso" do
      assert Temporal.always(@counting, &(&1.n < 2)) == :violated
      assert Temporal.always(@counting, &(&1.n < 2), 1) == :violated
    end

    # The honesty rule: a prefix where P held throughout says nothing about the state
    # after it, so it cannot establish `[]P`.
    test "holding throughout a prefix is inconclusive, and throughout a lasso is holding" do
      assert Temporal.always(@counting, &(&1.n < 5)) == :inconclusive
      assert Temporal.always(@counting, &(&1.n < 5), 1) == :holds
    end
  end

  describe "eventually/3" do
    test "one true state establishes it" do
      assert Temporal.eventually(@counting, &(&1.n == 2)) == :holds
    end

    test "never true is inconclusive on a prefix and refuted on a lasso" do
      assert Temporal.eventually(@counting, &(&1.n == 9)) == :inconclusive
      assert Temporal.eventually(@counting, &(&1.n == 9), 1) == :violated
    end
  end

  describe "eventually_always/3" do
    test "is decided by the cycle, because nothing outside it recurs" do
      assert Temporal.eventually_always(@counting, &(&1.n >= 1), 1) == :holds
      assert Temporal.eventually_always(@counting, &(&1.n >= 2), 1) == :violated
    end

    test "a prefix settles it neither way" do
      assert Temporal.eventually_always(@counting, &(&1.n >= 0)) == :inconclusive
    end
  end

  describe "always_eventually/3" do
    test "is whether the predicate occurs in the cycle" do
      assert Temporal.always_eventually(@counting, &(&1.n == 2), 1) == :holds
      assert Temporal.always_eventually(@counting, &(&1.n == 0), 1) == :violated
    end

    test "a prefix settles it neither way" do
      assert Temporal.always_eventually(@counting, &(&1.n == 2)) == :inconclusive
    end
  end

  describe "leads_to/4" do
    test "a consequent in the cycle answers every antecedent at once" do
      assert Temporal.leads_to(@counting, &(&1.n == 0), &(&1.n == 2), 2) == :holds
    end

    test "an antecedent with nothing after it is refuted" do
      behavior = [%{n: 0}, %{n: 1}]

      assert Temporal.leads_to(behavior, &(&1.n == 0), &(&1.n == 5), 1) == :violated
    end

    # Q never recurs, but it came once, after the only P — and no P recurs either.
    test "an antecedent answered before the cycle, with no antecedent inside it, holds" do
      behavior = [%{n: 0}, %{n: 5}, %{n: 1}]

      assert Temporal.leads_to(behavior, &(&1.n == 0), &(&1.n == 5), 2) == :holds
    end

    # Not a gap: a P with no Q yet may get one in the next state, and a trace where every
    # P was answered may fail at the first state past the end.
    test "a prefix settles it neither way" do
      assert Temporal.leads_to(@counting, &(&1.n == 0), &(&1.n == 2)) == :inconclusive
    end
  end

  defp increment, do: fn pre, post -> post.n == pre.n + 1 end

  describe "box_action/4" do
    test "a step that neither satisfies the action nor stutters refutes it" do
      assert Temporal.box_action([%{n: 0}, %{n: 5}], increment(), [:n]) == :violated
    end

    test "stuttering is always permitted — that is what the subscript is for" do
      behavior = [%{n: 0}, %{n: 1}, %{n: 1}]

      assert Temporal.box_action(behavior, increment(), [:n], 2) == :holds
    end

    test "legal throughout a prefix is inconclusive" do
      assert Temporal.box_action([%{n: 0}, %{n: 1}], increment(), [:n]) == :inconclusive
    end

    # The step from the last state back to `lasso_start` is a step of the behaviour, and
    # leaving it out would let an illegal one through.
    test "the step that closes the lasso is checked too" do
      behavior = [%{n: 0}, %{n: 1}]

      assert Temporal.box_action(behavior, increment(), [:n], 0) == :violated
    end
  end

  describe "diamond_action/4" do
    test "one action step that moves something establishes it" do
      assert Temporal.diamond_action([%{n: 0}, %{n: 1}], increment(), [:n]) == :holds
    end

    test "a stuttering step does not count, however the action reads it" do
      always_true = fn _pre, _post -> true end

      assert Temporal.diamond_action([%{n: 0}, %{n: 0}], always_true, [:n], 0) == :violated
    end

    test "never taken is inconclusive on a prefix" do
      assert Temporal.diamond_action([%{n: 0}, %{n: 0}], increment(), [:n]) == :inconclusive
    end
  end

  describe "steps/2 and cycle/2" do
    test "a lasso has one step per state, the last closing the loop" do
      assert Temporal.steps(@counting, 1) == [
               {%{n: 0}, %{n: 1}},
               {%{n: 1}, %{n: 2}},
               {%{n: 2}, %{n: 1}}
             ]
    end

    test "a prefix has one step fewer than it has states" do
      assert Temporal.steps(@counting) == [{%{n: 0}, %{n: 1}}, {%{n: 1}, %{n: 2}}]
    end

    # A `terminal` stuttering forever (§5.3). Without the closing step it would have no
    # steps at all, and every action property over it would be vacuous.
    test "a cycle of one state is a stuttering step" do
      assert Temporal.steps([%{n: 0}], 0) == [{%{n: 0}, %{n: 0}}]
    end

    test "the cycle is the tail from lasso_start, and nothing without one" do
      assert Temporal.cycle(@counting, 1) == [%{n: 1}, %{n: 2}]
      assert Temporal.cycle(@counting, nil) == nil
    end
  end

  describe "what it refuses" do
    test "an empty behaviour" do
      assert_raise ArgumentError, ~r/at least one state/, fn ->
        Temporal.always([], fn _ -> true end)
      end
    end

    test "a lasso_start past the end" do
      assert_raise ArgumentError, ~r/past the end/, fn ->
        Temporal.always(@counting, fn _ -> true end, 3)
      end
    end
  end

  describe "fairness over a behaviour" do
    # The distinction §5.2 exists for, on one concrete cycle: p starving while a
    # competitor takes the lock and gives it back satisfies WF(acquire, p) — acquiring is
    # disabled wherever the competitor holds it — and breaks SF(acquire, p), because it is
    # enabled elsewhere in the same cycle and never taken.
    test "the same cycle satisfies weak fairness and breaks strong fairness" do
      result =
        ModelChecker.run(WeaklyFair, %{
          constants: @processes,
          check_liveness: true,
          temporals: [:no_starvation]
        })

      {states, lasso_start} = Trace.to_behavior(result.violation)
      spec = Spec.Compiled.from_module(WeaklyFair)
      vars = Enum.map(spec.variables, & &1.name)

      # The prefix has both processes idle at first; it is the CYCLE that starves one.
      cycle = Temporal.cycle(states, lasso_start)
      starving = Enum.find([:p1, :p2], fn p -> Enum.all?(cycle, &(&1.pc[p] == :waiting)) end)

      constraint =
        spec
        |> Fairness.expand(@processes, hd(states))
        |> Enum.find(fn {f, b} -> f.action == :acquire and b == %{p: starving} end)

      {action, enabled} = Fairness.constraint_predicates(spec, @processes, constraint)

      assert Fairness.weak_fairness(states, action, enabled, vars, lasso_start) == :holds
      assert Fairness.strong_fairness(states, action, enabled, vars, lasso_start) == :violated
    end

    test "a prefix cannot establish that anything happens infinitely often" do
      spec = Spec.Compiled.from_module(PerBinding)
      state = spec.init |> hd() |> apply([@processes])

      constraint = spec |> Fairness.expand(@processes, state) |> hd()
      {action, enabled} = Fairness.constraint_predicates(spec, @processes, constraint)

      assert Fairness.weak_fairness([state], action, enabled, [:pc, :owner]) == :inconclusive
      assert Fairness.strong_fairness([state], action, enabled, [:pc, :owner]) == :inconclusive
    end
  end
end
