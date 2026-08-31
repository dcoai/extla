defmodule TLA.ModelCheckerTest do
  use ExUnit.Case, async: true

  alias TLA.Temporal.Fairness
  alias TLA.{ModelChecker, Spec, StateGraph, Temporal, Trace}

  alias TLA.TestSpecs.{
    Broken,
    Counter,
    Deadlocking,
    OutsideDomain,
    PerBinding,
    Swap,
    Terminating,
    Transfer,
    Unbounded
  }

  describe "exhaustive search" do
    test "finds every reachable state and no more" do
      result = ModelChecker.run(Counter, %{constants: %{max: 2}})

      # (n, done): (0,f) (1,f) (2,f) (2,t) — `finish` needs n == max, and `reset`
      # returns to (0,f), which is already known.
      assert result.status == :ok
      assert result.distinct_states == 4
      assert result.diameter == 4
    end

    test "counts generated states separately from distinct ones" do
      result = ModelChecker.run(Counter, %{constants: %{max: 2}})

      assert result.states_found > result.distinct_states
      assert result.transitions == result.states_found - 1
    end

    test "scales with the constants it is given" do
      for max <- 1..5 do
        result = ModelChecker.run(Counter, %{constants: %{max: max}})
        assert result.distinct_states == max + 2
      end
    end

    # The §8 worked example appends to `log` on every completed transfer and
    # `reset`s back to :idle, so its state space is infinite. That is what state
    # constraints are for, and the status says the run was bounded.
    test "explores a spec with params, under a constraint that bounds its log" do
      result =
        ModelChecker.run(Transfer, %{
          constants: %{accounts: MapSet.new([:alice, :bob]), max_balance: 2},
          invariants: [],
          check_deadlock: false,
          state_constraint: fn state -> length(state.log) <= 1 end
        })

      assert result.status == :constrained
      assert result.distinct_states > 10
    end

    test "reports the fingerprint width and the soundness margin it implies" do
      result = ModelChecker.run(Counter, %{constants: %{max: 2}})

      assert result.fingerprint_bits == 64
      assert result.collision_estimate < 1.0e-15

      wide = ModelChecker.run(Counter, %{constants: %{max: 2}, fingerprint_bits: 128})
      assert wide.fingerprint_bits == 128
      assert wide.distinct_states == result.distinct_states
    end
  end

  describe "invariant violations" do
    test "report the shortest counterexample" do
      result = ModelChecker.run(Broken, %{})

      assert result.status == :violation
      assert result.violation.property == :below_three
      assert result.violation.type == :safety

      # n = 0, 1, 2, 3 — four states, three steps. Breadth-first search is what
      # makes this the shortest rather than merely a counterexample.
      assert result.violation.length == 4
      assert result.violation.states == [%{n: 0}, %{n: 1}, %{n: 2}, %{n: 3}]
      assert result.violation.actions == [:tick, :tick, :tick]
    end

    test "stop the search at the violation" do
      result = ModelChecker.run(Broken, %{})

      # The spec can reach n = 5; the search stops at 3.
      assert result.distinct_states == 4
    end

    test "can be restricted to named invariants, as a TLC .cfg selects them" do
      # `Broken` stops at n = 5, which is a deadlock — so with no invariants
      # selected the run still fails, on the other check.
      assert ModelChecker.run(Broken, %{invariants: [], check_deadlock: false}).status == :ok
      assert ModelChecker.run(Broken, %{invariants: [:below_three]}).status == :violation
    end
  end

  describe "action properties" do
    test "are checked over every transition" do
      defmodule Decreasing do
        use TLA.Spec
        variable :n

        init do
          n = 1
        end

        action :drop do
          require n > 0
          n = n - 1
        end

        action_property :never_decreases do
          new.n >= old.n
        end
      end

      result = ModelChecker.run(Decreasing, %{})

      assert result.status == :violation
      assert result.violation.property == :never_decreases
      assert result.violation.states == [%{n: 1}, %{n: 0}]
    end
  end

  describe "deadlock and terminal states" do
    test "a successor-less state is a deadlock by default" do
      result = ModelChecker.run(Deadlocking, %{constants: %{max: 2}})

      assert result.status == :violation
      assert result.deadlock
      assert result.violation.type == :deadlock
      assert List.last(result.violation.states) == %{produced: 2}
    end

    test "the deadlock message points at `terminal` rather than at a flag" do
      result = ModelChecker.run(Deadlocking, %{constants: %{max: 2}})

      assert result.violation.message =~ "terminal :name do"
    end

    # `check_deadlock: false` is the blunt instrument: it silences the check for
    # every other state in the spec at the same time.
    test "check_deadlock: false silences it" do
      result = ModelChecker.run(Deadlocking, %{constants: %{max: 2}, check_deadlock: false})

      assert result.status == :ok
      assert result.deadlock
    end

    test "a declared terminal state is not a deadlock" do
      result = ModelChecker.run(Terminating, %{constants: %{max: 3}})

      assert result.status == :ok
      refute result.deadlock
      assert result.distinct_states == 4
    end

    test "declaring the end state keeps deadlock detection on everywhere else" do
      {_result, graph} = ModelChecker.explore(Terminating, %{constants: %{max: 3}})

      assert MapSet.size(graph.terminal) == 1
      assert MapSet.size(graph.deadlocked) == 0
    end
  end

  describe "bounded runs" do
    test "a state constraint bounds an unbounded spec and says so" do
      result =
        ModelChecker.run(Unbounded, %{state_constraint: fn s -> s.n <= 10 end})

      assert result.status == :constrained
      assert result.distinct_states == 12
      assert Enum.any?(result.warnings, &(&1 =~ "not an exhaustive search"))
    end

    test "max_states stops the search and reports that it did" do
      result = ModelChecker.run(Unbounded, %{max_states: 25})

      assert result.status == :max_states_reached
      assert result.distinct_states >= 25
    end

    # A run that stopped early and a run that finished must never look alike.
    test "a bounded run never reports plain :ok" do
      for config <- [%{state_constraint: fn s -> s.n <= 3 end}, %{max_states: 10}] do
        refute ModelChecker.run(Unbounded, config).status == :ok
      end
    end
  end

  describe "phase boundaries" do
    # Reporting temporal properties as holding without the liveness graph would
    # be exactly the silent unsoundness the project exists to avoid.
    test "liveness raises rather than checking something weaker" do
      assert_raise ArgumentError, ~r/liveness arrives in Phase 2|not implemented yet/, fn ->
        ModelChecker.run(Counter, %{constants: %{max: 2}, check_liveness: true})
      end
    end

    # The graph is built; nothing checks a temporal property with it. A run that
    # returned :ok here would be claiming an answer it does not have.
    test "having the liveness graph is not having a liveness answer" do
      assert_raise ArgumentError, ~r/not implemented yet/, fn ->
        ModelChecker.run(Counter, %{
          constants: %{max: 2},
          check_liveness: true,
          liveness_graph: true
        })
      end
    end

    test "symmetry raises" do
      assert_raise ArgumentError, ~r/symmetry reduction is not implemented/, fn ->
        ModelChecker.run(Counter, %{constants: %{max: 2}, symmetry: [:accounts]})
      end
    end

    test "a spec with unchecked temporal properties says so in the warnings" do
      result = ModelChecker.run(Counter, %{constants: %{max: 2}})

      assert Enum.any?(result.warnings, &(&1 =~ "temporal"))
      assert Enum.any?(result.warnings, &(&1 =~ "Phase 2"))
    end

    test "a spec with no temporal properties warns about nothing" do
      assert ModelChecker.run(Unbounded, %{max_states: 5}).warnings == []
    end
  end

  describe "reading outside a domain" do
    # D-20. Under `Access.get/2` this run reported success over a state space
    # the spec does not describe: the guard `balances[:carol] >= 1` was
    # `nil >= 1`, which is true, so `pay_carol` fired and its post-states were
    # explored. Raising is the only outcome that does not hide that.
    test "a guard that applies a function outside its domain raises, naming it" do
      constants = %{accounts: MapSet.new([:alice, :bob])}

      error =
        assert_raise TLA.Spec.DomainError, fn ->
          ModelChecker.run(OutsideDomain, %{constants: constants})
        end

      message = Exception.message(error)

      assert message =~ "balances[:carol]"
      assert message =~ "not in the domain [:alice, :bob]"
    end
  end

  describe "successors/3" do
    test "one per action per binding whose guard holds" do
      spec = TLA.Spec.Compiled.from_module(Transfer)
      constants = %{accounts: MapSet.new([:alice, :bob]), max_balance: 2}
      state = hd(spec.init).(constants)

      successors = ModelChecker.successors(spec, %{constants: constants}, state)

      # Only begin_transfer is enabled at :idle: 2 ordered pairs of distinct
      # accounts x 2 amounts, each bounded by the sender's balance.
      assert Enum.map(successors, fn {action, _, _} -> action end) |> Enum.uniq() ==
               [:begin_transfer]

      assert length(successors) == 4
    end

    test "a generator that returns nothing disables the action" do
      spec = TLA.Spec.Compiled.from_module(Transfer)
      constants = %{accounts: MapSet.new([:alice, :bob]), max_balance: 2}

      state = %{
        balances: %{alice: 2, bob: 2},
        status: :transferring,
        pending: MapSet.new(),
        log: []
      }

      actions =
        spec
        |> ModelChecker.successors(%{constants: constants}, state)
        |> Enum.map(fn {action, _, _} -> action end)
        |> Enum.uniq()

      refute :complete_transfer in actions
      assert :fail_transfer in actions
    end
  end

  describe "the state graph" do
    test "deduplicates by fingerprint" do
      {result, graph} = ModelChecker.explore(Counter, %{constants: %{max: 2}})

      assert graph.state_count == result.distinct_states
      assert MapSet.size(graph.initial_states) == 1
    end

    test "does not retain the states it explored" do
      {_result, graph} = ModelChecker.explore(Counter, %{constants: %{max: 2}})

      records = graph.nodes |> :ets.tab2list() |> Enum.map(fn {_id, record} -> record end)
      keys = records |> Enum.map(&(&1 |> Map.keys() |> Enum.sort())) |> Enum.uniq()

      assert keys == [[:action, :depth, :init_index, :params, :parent]]
      assert length(records) == 4
    end

    test "path_to/2 recovers the actions, and the init block that started them" do
      {result, graph} = ModelChecker.explore(Broken, %{})
      violating = graph.fingerprints |> :ets.tab2list() |> length()

      assert violating == result.distinct_states
      assert {0, steps} = StateGraph.path_to(graph, result.distinct_states - 1)
      assert Enum.map(steps, fn {action, _} -> action end) == [:tick, :tick, :tick]
    end

    # Parent pointers form a spanning tree, which has no cycles, so deriving
    # successors from them would report every liveness property as holding.
    test "successors/2 raises without a liveness graph rather than guessing" do
      {_result, graph} = ModelChecker.explore(Counter, %{constants: %{max: 2}})

      assert_raise ArgumentError, ~r/no liveness graph/, fn ->
        StateGraph.successors(graph, 0)
      end
    end
  end

  describe "traces" do
    setup do
      %{trace: ModelChecker.run(Broken, %{}).violation}
    end

    test "regenerate the states by replay", %{trace: trace} do
      assert trace.states == [%{n: 0}, %{n: 1}, %{n: 2}, %{n: 3}]
      assert trace.length == length(trace.states)
      assert length(trace.actions) == trace.length - 1
      assert length(trace.bindings) == trace.length - 1
    end

    test "carry the parameter binding of each step" do
      trace =
        ModelChecker.run(Transfer, %{
          constants: %{accounts: MapSet.new([:alice, :bob]), max_balance: 2}
        }).violation

      assert trace.property == :conservation_of_money
      assert Enum.any?(trace.bindings, &(map_size(&1) > 0))
    end

    test "format/1 marks what each step changed", %{trace: trace} do
      output = Trace.format(trace)

      assert output =~ "VIOLATION: below_three"
      assert output =~ "State 1 (Init)"
      assert output =~ "State 4 [VIOLATION]"
      assert output =~ "← changed"
      assert output =~ "── tick"
    end

    test "format/1 shows a binding as a call" do
      trace =
        ModelChecker.run(Transfer, %{
          constants: %{accounts: MapSet.new([:alice, :bob]), max_balance: 2}
        }).violation

      assert Trace.format(trace) =~ ~r/begin_transfer\(amount: \d, from: :\w+, to: :\w+\)/
    end

    test "to_diffs/1 gives one entry per state, changed variables first", %{trace: trace} do
      diffs = Trace.to_diffs(trace)

      assert length(diffs) == trace.length
      assert hd(diffs).action == nil
      assert Enum.at(diffs, 1) == %{action: :tick, params: %{}, changed: %{n: 1}, state: %{n: 1}}
    end
  end

  describe "the liveness graph" do
    @processes %{processes: MapSet.new([:p1, :p2])}

    test "is absent unless asked for, and says so rather than guessing" do
      {_result, graph} = ModelChecker.explore(Counter, %{constants: %{max: 2}})

      refute StateGraph.liveness?(graph)
      assert graph.edges == nil
      assert graph.fairness_index == nil

      assert_raise ArgumentError, ~r/spanning tree/, fn -> StateGraph.successors(graph, 0) end
      assert_raise ArgumentError, ~r/spanning tree/, fn -> StateGraph.enabled_bits(graph, 0) end
    end

    test "is built when it is asked for, indexed by the expanded fairness constraints" do
      {_result, graph} = explore_live(PerBinding, @processes)
      spec = Spec.Compiled.from_module(PerBinding)
      state = spec.init |> hd() |> apply([@processes])

      assert StateGraph.liveness?(graph)
      assert graph.fairness_index == Fairness.expand(spec, @processes, state)
      assert length(graph.fairness_index) == 6
    end

    # The failure this design already caught once. A spanning tree over n nodes
    # has n-1 edges and no cycles at all, so an SCC search over the parent
    # pointers would find only trivial components and report every liveness
    # property as holding.
    test "is not a spanning tree: it has the back edges the parent pointers lose" do
      {_result, graph} = explore_live(Counter, %{max: 2})

      edges = graph.edges |> Map.values() |> List.flatten()

      assert length(edges) > graph.state_count - 1

      # (0,false) → (1,false) → (2,false) → (2,true), and `reset` closes the loop.
      assert {:reset, %{}, 0} in StateGraph.successors(graph, 3)
      assert StateGraph.node_record(graph, 3).parent == 2
    end

    test "records every edge the checker would generate, in the same order" do
      {_result, graph} = explore_live(PerBinding, @processes)
      spec = Spec.Compiled.from_module(PerBinding)

      for {id, edges} <- graph.edges do
        expected =
          spec
          |> ModelChecker.successors(@processes, state_at(graph, id))
          |> Enum.map(fn {action, params, _next} -> {action, params} end)

        assert Enum.map(edges, fn {action, params, _id} -> {action, params} end) == expected
      end
    end

    test "the successor ids are the states those successors actually are" do
      {_result, graph} = explore_live(PerBinding, @processes)
      spec = Spec.Compiled.from_module(PerBinding)

      for {id, edges} <- graph.edges, {action, params, next_id} <- edges do
        stepped =
          Spec.Compiled.action(spec, action).transition.(
            @processes,
            state_at(graph, id),
            params
          )

        assert stepped == state_at(graph, next_id)
      end
    end

    # The bits are read off bindings the search already had, so this is the test
    # that they were read off the right ones: recomputed from the state, one
    # constraint at a time, against the same ENABLED the fairness rules will use.
    test "every bit is ENABLED for its constraint in that state" do
      {_result, graph} = explore_live(PerBinding, @processes)
      spec = Spec.Compiled.from_module(PerBinding)

      for {id, _edges} <- graph.edges,
          {{fairness, binding}, index} <- Enum.with_index(graph.fairness_index) do
        action = Spec.Compiled.action(spec, fairness.action)

        assert StateGraph.enabled?(graph, id, index) ==
                 Temporal.enabled?(state_at(graph, id), action, @processes, binding),
               "bit #{index} (#{Fairness.describe({fairness, binding})}) disagrees with " <>
                 "ENABLED in state #{id}"
      end
    end

    test "the bits are as wide as the fairness index, in every state" do
      {_result, graph} = explore_live(PerBinding, @processes)

      for {id, _} <- graph.edges do
        assert bit_size(StateGraph.enabled_bits(graph, id)) == 6
      end
    end

    test "a spec with no fairness still gets an edge table, and zero-width bits" do
      {_result, graph} = explore_live(Swap, %{})

      assert StateGraph.liveness?(graph)
      assert graph.fairness_index == []
      assert StateGraph.enabled_bits(graph, 0) == <<>>
    end

    # §5.3: for liveness a terminal state stutters forever, so the checker of
    # slice 3 has to find it with no out-edges rather than not find it at all.
    test "a state that ends the spec is recorded with no out-edges" do
      {_result, graph} = explore_live(Terminating, %{max: 3})

      assert MapSet.size(graph.terminal) > 0

      for id <- graph.terminal do
        assert StateGraph.successors(graph, id) == []
      end
    end

    # `complete_transfer` draws its param from the pre-state (§3), so its bindings
    # change from state to state. §5.2 forbids quantifying fairness over such a
    # param, and this spec does not — but the edges and the whole-action bits still
    # have to be right where one exists.
    test "handles an action whose params are drawn from the state" do
      constants = %{accounts: MapSet.new([:alice, :bob]), max_balance: 2}
      spec = Spec.Compiled.from_module(Transfer)

      {_result, graph} =
        ModelChecker.explore(Transfer, %{
          constants: constants,
          invariants: [],
          check_deadlock: false,
          state_constraint: fn state -> length(state.log) <= 1 end,
          liveness_graph: true
        })

      assert length(graph.fairness_index) == 3
      assert Enum.all?(graph.fairness_index, fn {_f, binding} -> binding == %{} end)

      for {id, edges} <- graph.edges,
          {{fairness, binding}, index} <- Enum.with_index(graph.fairness_index) do
        state = state_at(graph, id)
        action = Spec.Compiled.action(spec, fairness.action)

        assert StateGraph.enabled?(graph, id, index) ==
                 Temporal.enabled?(state, action, constants, binding)

        assert Enum.map(edges, fn {a, p, _} -> {a, p} end) ==
                 spec
                 |> ModelChecker.successors(constants, state)
                 |> Enum.map(&{elem(&1, 0), elem(&1, 1)})
      end
    end

    test "changes nothing about the safety answer" do
      config = %{constants: @processes}

      safety = ModelChecker.run(PerBinding, config)
      live = ModelChecker.run(PerBinding, Map.put(config, :liveness_graph, true))

      assert live.status == safety.status
      assert live.distinct_states == safety.distinct_states
      assert live.diameter == safety.diameter
      assert live.transitions == safety.transitions
      assert live.deadlock == safety.deadlock
    end

    defp explore_live(module, constants),
      do: ModelChecker.explore(module, %{constants: constants, liveness_graph: true})

    # The state a node stands for, regenerated by replaying the path to it —
    # which is the only way to get it back, since the graph does not keep states.
    defp state_at(graph, id),
      do: graph |> Trace.generate(id) |> Map.fetch!(:states) |> List.last()
  end
end
