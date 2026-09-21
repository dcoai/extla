defmodule TLA.SpecTest do
  use ExUnit.Case, async: true

  alias TLA.Spec.Compiled
  alias TLA.TestSpecs.{Counter, LetScopes, PerBinding, Swap, Transfer}

  describe "from_module/1" do
    test "returns the compiled spec" do
      assert %Compiled{module: Counter} = Compiled.from_module(Counter)
    end

    test "says so, rather than failing three frames down, for a module that is not a spec" do
      assert_raise ArgumentError, ~r/is not a TLA spec/, fn ->
        Compiled.from_module(Enum)
      end
    end
  end

  describe "declarations" do
    test "keep declaration order" do
      spec = Compiled.from_module(Transfer)

      assert Compiled.constant_names(spec) == [:accounts, :max_balance]
      assert Compiled.variable_names(spec) == [:balances, :status, :pending, :log]

      assert Enum.map(spec.actions, & &1.name) == [
               :begin_transfer,
               :complete_transfer,
               :fail_transfer,
               :reset
             ]
    end

    # D-19: a type mentioning a constant has no value at compile time, so the
    # only honest representation is the expression itself.
    test "store types quoted, unevaluated" do
      spec = Compiled.from_module(Transfer)
      balances = Enum.find(spec.variables, &(&1.name == :balances))

      assert Macro.to_string(balances.type) == "[^accounts ~> :nat]"
    end

    test "leave a variable with no type: nil rather than inventing one" do
      spec = Compiled.from_module(Swap)
      assert Enum.all?(spec.variables, &is_nil(&1.type))
    end

    test "carry desc: through to the compiled invariant" do
      spec = Compiled.from_module(Counter)
      invariant = Enum.find(spec.invariants, &(&1.name == :within_bounds))

      assert invariant.description == "the counter never leaves its declared range"
    end
  end

  describe "init" do
    test "builds the initial state from constants" do
      spec = Compiled.from_module(Counter)
      assert [init] = spec.init
      assert init.(%{max: 3}) == %{n: 0, done: false}
    end

    test "resolves ^constants and helpers" do
      spec = Compiled.from_module(Transfer)
      constants = %{accounts: MapSet.new([:alice, :bob]), max_balance: 3}

      assert hd(spec.init).(constants) == %{
               balances: %{alice: 3, bob: 3},
               status: :idle,
               pending: MapSet.new(),
               log: []
             }
    end
  end

  describe "actions" do
    setup do
      %{spec: Compiled.from_module(Counter), constants: %{max: 2}}
    end

    test "guards read the pre-state", %{spec: spec, constants: constants} do
      increment = Compiled.action(spec, :increment)

      assert increment.guard.(constants, %{n: 0, done: false}, %{})
      assert increment.guard.(constants, %{n: 1, done: false}, %{})
      refute increment.guard.(constants, %{n: 2, done: false}, %{})
      refute increment.guard.(constants, %{n: 0, done: true}, %{})
    end

    test "transitions produce the post-state", %{spec: spec, constants: constants} do
      increment = Compiled.action(spec, :increment)

      assert increment.transition.(constants, %{n: 0, done: false}, %{}) == %{n: 1, done: false}
    end

    test "a variable the action does not assign is UNCHANGED", %{spec: spec, constants: c} do
      increment = Compiled.action(spec, :increment)

      assert %{done: :untouched} = increment.transition.(c, %{n: 0, done: :untouched}, %{})
    end

    # 02-dsl-semantics.md §2, the rule most likely to surprise an Elixir
    # programmer: `x = y; y = x` swaps. Every RHS reads the pre-state, so there
    # is no intermediate state for the second line to observe.
    test "an action body is a conjunction, not a sequence" do
      swap = Swap |> Compiled.from_module() |> Compiled.action(:swap)

      assert swap.transition.(%{}, %{x: 1, y: 2}, %{}) == %{x: 2, y: 1}
    end
  end

  describe "let" do
    setup do
      %{action: LetScopes |> Compiled.from_module() |> Compiled.action(:bump)}
    end

    # The guard reads `room` and the transition reads `entry`; neither reads the
    # other's. Both functions are compiled from the same block, so each has to
    # keep what it reads and drop what it does not -- a binding nothing reads is
    # dead code in a pure block, and emitting it costs a warning the spec author
    # cannot silence.
    test "a binding only the guard reads still guards", %{action: bump} do
      assert bump.guard.(%{}, %{n: 0, log: []}, %{})
      refute bump.guard.(%{}, %{n: 3, log: []}, %{})
    end

    test "a binding only an assignment reads is still available to it", %{action: bump} do
      assert bump.transition.(%{}, %{n: 1, log: []}, %{}) == %{n: 2, log: [%{was: 1}]}
    end
  end

  describe "params" do
    # #210. `params: [k: [1, 1, 2]]` yielded three bindings per state, two of them the same
    # successor, and inflated the action's coverage. Each distinct value is drawn once, and
    # the visible repeat is a compile warning naming it.
    test "a list draws each distinct value once, and a literal repeat warns" do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule TLA.SpecTest.Repeats do
            use TLA.Spec
            variable :n, type: 0..2
            init do
              n = 0
            end
            action :set, params: [k: [1, 1, 2]] do
              n = k
            end
          end
          """)
        end)

      assert warning =~ "lists 1 2 times"

      spec = Compiled.from_module(TLA.SpecTest.Repeats)

      assert TLA.ModelChecker.bindings(Compiled.action(spec, :set), %{}, %{n: 0}) == [
               %{k: 1},
               %{k: 2}
             ]

      result = TLA.ModelChecker.run(TLA.SpecTest.Repeats, %{})
      assert result.coverage.actions[:set].states_generated == 2 * result.distinct_states
    end

    setup do
      spec = Compiled.from_module(Transfer)
      constants = %{accounts: MapSet.new([:alice, :bob]), max_balance: 3}
      %{spec: spec, constants: constants, init: hd(spec.init).(constants)}
    end

    test "record where each one draws from", %{spec: spec} do
      assert Compiled.action(spec, :begin_transfer).param_sources == [
               from: :constant,
               to: :constant,
               amount: :literal
             ]

      assert Compiled.action(spec, :complete_transfer).param_sources == [t: :state]
      assert Compiled.action(spec, :fail_transfer).param_sources == []
    end

    test "generate from a constant and from a literal range", ctx do
      [{:from, from}, {:to, _}, {:amount, amount}] =
        Compiled.action(ctx.spec, :begin_transfer).params

      assert from.(ctx.constants, ctx.init, %{}) == MapSet.new([:alice, :bob])
      assert Enum.to_list(amount.(ctx.constants, ctx.init, %{})) == [1, 2, 3]
    end

    # The mechanism that replaced `choose`: `\E t \in pending` is a param drawn
    # from the pre-state, so the body stays a deterministic function of it.
    test "generate from the pre-state", ctx do
      [{:t, generator}] = Compiled.action(ctx.spec, :complete_transfer).params
      state = %{ctx.init | pending: MapSet.new([{:bob, 2}])}

      assert generator.(ctx.constants, state, %{}) == MapSet.new([{:bob, 2}])
    end

    test "bind as locals inside the block", ctx do
      begin = Compiled.action(ctx.spec, :begin_transfer)
      params = %{from: :alice, to: :bob, amount: 2}

      assert begin.guard.(ctx.constants, ctx.init, params)

      assert begin.transition.(ctx.constants, ctx.init, params) == %{
               balances: %{alice: 1, bob: 3},
               status: :transferring,
               pending: MapSet.new([{:bob, 2}]),
               log: []
             }
    end

    test "a guard that reads a param it was not given fails loudly", ctx do
      begin = Compiled.action(ctx.spec, :begin_transfer)

      assert_raise KeyError, fn -> begin.guard.(ctx.constants, ctx.init, %{from: :alice}) end
    end
  end

  describe "invariants and action properties" do
    test "an invariant reads constants as well as state" do
      spec = Compiled.from_module(Counter)
      within = Enum.find(spec.invariants, &(&1.name == :within_bounds))

      assert within.predicate.(%{max: 2}, %{n: 2, done: false})
      refute within.predicate.(%{max: 2}, %{n: 3, done: false})
    end

    test "an action property sees both states" do
      spec = Compiled.from_module(Counter)
      never_jumps = Enum.find(spec.action_properties, &(&1.name == :never_jumps))

      assert never_jumps.predicate.(%{max: 9}, %{n: 0, done: false}, %{n: 1, done: false})
      refute never_jumps.predicate.(%{max: 9}, %{n: 0, done: false}, %{n: 5, done: false})
    end

    # The §8 worked example's stated counterexample: fail_transfer discards
    # `pending` without refunding it, so conservation is reachable-false. If this
    # ever passes, either the example or the DSL has stopped meaning what it said.
    test "conservation_of_money is refuted by fail_transfer, as the worked example says" do
      spec = Compiled.from_module(Transfer)
      constants = %{accounts: MapSet.new([:alice, :bob]), max_balance: 3}
      conservation = Enum.find(spec.invariants, &(&1.name == :conservation_of_money))

      after_begin =
        Compiled.action(spec, :begin_transfer).transition.(
          constants,
          hd(spec.init).(constants),
          %{from: :alice, to: :bob, amount: 2}
        )

      assert conservation.predicate.(constants, after_begin)

      after_failure =
        Compiled.action(spec, :fail_transfer).transition.(constants, after_begin, %{})

      refute conservation.predicate.(constants, after_failure)
    end
  end

  describe "terminals" do
    test "compile to a state predicate" do
      spec = Compiled.from_module(Counter)
      assert [%{name: :nothing_left, predicate: predicate}] = spec.terminals

      refute predicate.(%{max: 2}, %{n: 0, done: true})
    end
  end

  describe "temporal formulas" do
    test "are built from the constants, and land in the bounded fragment" do
      spec = Compiled.from_module(Counter)
      assert [%{name: :eventually_done, formula: formula}] = spec.temporals

      assert {:eventually, {:predicate, predicate}} = formula.(%{max: 2})
      assert predicate.(%{n: 0, done: true})
      refute predicate.(%{n: 0, done: false})
    end

    test "leads-to keeps both operands as state predicates" do
      spec = Compiled.from_module(Transfer)
      [%{name: :no_stuck_pending, formula: formula}] = spec.temporals

      assert {:leads_to, p, q} = formula.(%{})
      assert p.(%{status: :transferring})
      refute p.(%{status: :idle})
      assert q.(%{status: :done})
    end

    # `always(P ~> Q)` means the same thing as `P ~> Q`, so it is collapsed
    # rather than rejected -- TLA+ users write it out of habit.
    test "always(P ~> Q) collapses to leads_to" do
      defmodule Collapse do
        use TLA.Spec
        variable :s

        init do
          s = :a
        end

        temporal :collapsed do
          always((s == :a) ~> (s == :b))
        end
      end

      [%{formula: formula}] = Compiled.from_module(Collapse).temporals
      assert {:leads_to, _, _} = formula.(%{})
    end

    test "quantifies over a constant with for_all" do
      spec = Compiled.from_module(PerBinding)
      [%{name: :no_starvation, formula: formula}] = spec.temporals
      constants = %{processes: MapSet.new([:p1, :p2])}

      assert {:for_all, set, instantiate} = formula.(constants)
      assert set.(constants) == MapSet.new([:p1, :p2])

      assert {:leads_to, waiting, holding} = instantiate.(:p1)
      assert waiting.(%{pc: %{p1: :waiting, p2: :idle}, owner: nil})
      refute holding.(%{pc: %{p1: :waiting, p2: :idle}, owner: nil})
      assert holding.(%{pc: %{p1: :holding, p2: :idle}, owner: :p1})
    end
  end

  describe "fairness" do
    test "whole-action form has no params" do
      spec = Compiled.from_module(Counter)

      assert spec.fairness == [
               %{kind: :weak, action: :increment, per: []},
               %{kind: :weak, action: :finish, per: []}
             ]
    end

    # Whole-action WF guarantees only that SOME binding fires, which is
    # consistent with one process starving while the others take turns.
    test "per-binding form records the quantified params" do
      spec = Compiled.from_module(PerBinding)

      assert %{kind: :strong, action: :acquire, per: [:p]} in spec.fairness
      assert %{kind: :weak, action: :release, per: [:p]} in spec.fairness
      assert %{kind: :weak, action: :request, per: [:p]} in spec.fairness
    end
  end
end
