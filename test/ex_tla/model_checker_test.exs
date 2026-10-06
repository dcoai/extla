defmodule ExTLA.ModelCheckerTest do
  use ExUnit.Case, async: true

  alias ExTLA.Temporal.Fairness
  alias ExTLA.{ModelChecker, Spec, StateGraph, Temporal, Trace}

  alias ExTLA.TestSpecs.{
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
    @describetag verifies:
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`"
    test "finds every reachable state and no more" do
      result = ModelChecker.run(Counter, %{constants: %{max: 2}})

      # (n, done): (0,f) (1,f) (2,f) (2,t) — `finish` needs n == max, and `reset`
      # returns to (0,f), which is already known.
      assert result.status == :ok
      assert result.distinct_states == 4
      assert result.diameter == 4
    end

    @tag verifies: [
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`",
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API"
         ]
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
    #
    # `invariants: [:type_ok]` rather than `[]`, which is what stood here and carried a
    # comment about the constraint and none about itself (#280). This spec is DELIBERATELY
    # refutable — `fail_transfer` discards `pending` without refunding it, which is the
    # counterexample `04-layer2-model-checker.md` prints as its worked example — so leaving
    # every invariant selected would halt the search at depth 3 and this test would be
    # measuring a violation rather than a bound. Deselecting all of them instead made the
    # run check nothing at all, and the documented violation was pinned by no test
    # anywhere. `:type_ok` holds over the whole constrained space, so the run reaches its
    # bound while still checking something, and the violation is pinned below.
    @tag verifies: [
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`",
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/State-space reduction/State constraints"
         ]
    test "explores a spec with params, under a constraint that bounds its log" do
      result =
        ModelChecker.run(Transfer, %{
          constants: %{accounts: MapSet.new([:alice, :bob]), max_balance: 2},
          invariants: [:type_ok],
          check_deadlock: false,
          state_constraint: fn state -> length(state.log) <= 1 end
        })

      assert result.status == :constrained
      assert result.distinct_states > 10
    end

    # `02-dsl-semantics.md` §8 says its example is refuted by `conservation_of_money`, and
    # `04-layer2-model-checker.md` §Example Trace Output prints the counterexample: three
    # states, ending with `pending` emptied and the money gone. Nothing asserted it. A
    # "fix" to `fail_transfer` — which is what #280 was originally scoped to do — would
    # have left that printed trace describing a run that no longer happens, silently.
    @tag verifies: [
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`",
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Trace`/Example Trace Output"
         ]
    test "and the worked example is refuted exactly as §04's trace output shows" do
      result =
        ModelChecker.run(Transfer, %{
          constants: %{accounts: MapSet.new([:alice, :bob]), max_balance: 2},
          check_deadlock: false,
          state_constraint: fn state -> length(state.log) <= 1 end
        })

      assert result.status == :violation
      assert result.violation.property == :conservation_of_money
      assert result.violation.length == 3

      [initial | _] = result.violation.states
      last = List.last(result.violation.states)

      assert result.violation.actions == [:begin_transfer, :fail_transfer]
      assert last.status == :error
      assert Enum.empty?(last.pending)

      # The money is gone: the total over balances and pending is less than it was.
      assert total(last) < total(initial)
    end

    @tag verifies: [
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`",
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API"
         ]
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
    @tag verifies: [
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Safety`",
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Trace`"
         ]
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

    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Safety`"
    test "stop the search at the violation" do
      result = ModelChecker.run(Broken, %{})

      # The spec can reach n = 5; the search stops at 3.
      assert result.distinct_states == 4
    end

    @tag verifies: [
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Safety`",
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API"
         ]
    test "can be restricted to named invariants, as a TLC .cfg selects them" do
      # `Broken` stops at n = 5, which is a deadlock — so with no invariants
      # selected the run still fails, on the other check.
      assert ModelChecker.run(Broken, %{invariants: [], check_deadlock: false}).status == :ok
      assert ModelChecker.run(Broken, %{invariants: [:below_three]}).status == :violation
    end
  end

  defp total(state) do
    Enum.sum(Map.values(state.balances)) + Enum.sum(Enum.map(state.pending, &elem(&1, 1)))
  end

  describe "action properties" do
    @describetag verifies:
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Safety`"
    test "are checked over every transition" do
      defmodule Decreasing do
        use ExTLA.Spec
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
    @tag verifies: [
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Safety`",
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API"
         ]
    test "a successor-less state is a deadlock by default" do
      result = ModelChecker.run(Deadlocking, %{constants: %{max: 2}})

      assert result.status == :violation
      assert result.deadlock
      assert result.violation.type == :deadlock
      assert List.last(result.violation.states) == %{produced: 2}
    end

    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API"
    test "the deadlock message points at `terminal` rather than at a flag" do
      result = ModelChecker.run(Deadlocking, %{constants: %{max: 2}})

      assert result.violation.message =~ "terminal :name do"
    end

    # `check_deadlock: false` is the blunt instrument: it silences the check for
    # every other state in the spec at the same time.
    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API"
    test "check_deadlock: false silences it" do
      result = ModelChecker.run(Deadlocking, %{constants: %{max: 2}, check_deadlock: false})

      assert result.status == :ok
      assert result.deadlock
    end

    @tag verifies: [
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Safety`",
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API",
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Overview/DSL Macro Reference"
         ]
    test "a declared terminal state is not a deadlock" do
      result = ModelChecker.run(Terminating, %{constants: %{max: 3}})

      assert result.status == :ok
      refute result.deadlock
      assert result.distinct_states == 4
    end

    @tag verifies: [
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API",
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Overview/DSL Macro Reference"
         ]
    test "declaring the end state keeps deadlock detection on everywhere else" do
      {_result, graph} = ModelChecker.explore(Terminating, %{constants: %{max: 3}})

      assert MapSet.size(graph.terminal) == 1
      assert MapSet.size(graph.deadlocked) == 0
    end
  end

  describe "bounded runs" do
    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/State-space reduction/State constraints"
    test "a state constraint bounds an unbounded spec and says so" do
      result =
        ModelChecker.run(Unbounded, %{state_constraint: fn s -> s.n <= 10 end})

      assert result.status == :constrained
      assert result.distinct_states == 12
      assert Enum.any?(result.warnings, &(&1 =~ "not an exhaustive search"))
    end

    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API"
    test "max_states stops the search and reports that it did" do
      result = ModelChecker.run(Unbounded, %{max_states: 25})

      assert result.status == :max_states_reached
      assert result.distinct_states >= 25
    end

    # A run that stopped early and a run that finished must never look alike.
    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API"
    test "a bounded run never reports plain :ok" do
      for config <- [%{state_constraint: fn s -> s.n <= 3 end}, %{max_states: 10}] do
        refute ModelChecker.run(Unbounded, config).status == :ok
      end
    end
  end

  describe "phase boundaries" do
    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API"
    test "asking for liveness now checks it, and builds the graph to do so" do
      {result, graph} =
        ModelChecker.explore(Counter, %{constants: %{max: 2}, check_liveness: true})

      assert result.status == :ok
      assert StateGraph.liveness?(graph)
    end

    # This test named parallel exploration and asserted something else entirely: that
    # `symmetry: [:accounts]` raises because the constant is unassigned. True, and about a
    # different boundary. It then asserted #29's refusal — `workers:` accepted, ignored,
    # and the single-threaded run reported as `:ok` was worse than raising.
    #
    # `ExTLA.ModelChecker.Parallel` exists now, so what this boundary asserts is the
    # remaining half: the option is honoured, and the combination that is still unsound
    # still raises. The rest of parallel exploration is
    # `test/ex_tla/model_checker/parallel_test.exs` and
    # `test/differential/parallel_agreement_test.exs`.
    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API"
    test "parallel exploration is honoured, and refused only alongside liveness" do
      result = ModelChecker.run(Counter, %{constants: %{max: 2}, workers: 4})
      assert result.status == :ok
      assert result.distinct_states == 4

      error =
        assert_raise ArgumentError, fn ->
          ModelChecker.run(Counter, %{constants: %{max: 2}, workers: 4, check_liveness: true})
        end

      message = Exception.message(error)
      assert message =~ "workers: 4"
      assert message =~ "liveness is refused"

      # A refusal that only says no is half a message: the run this caller can have is
      # named, on both sides of the pairing.
      assert message =~ "safety with `workers:`"
      assert message =~ "liveness on one process"
    end

    # Everything but `duration_ms`, which is a measurement of the run rather than a fact
    # about the model — comparing whole results made this test pass only when the two runs
    # landed in the same millisecond.
    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API"
    test "and one worker is what the checker does, so it is not refused" do
      config = %{constants: %{max: 2}}

      one = ModelChecker.run(Counter, Map.put(config, :workers, 1))
      none = ModelChecker.run(Counter, config)

      assert Map.delete(one, :duration_ms) == Map.delete(none, :duration_ms)
    end

    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API/The CLI infers `check_liveness`; the API does not"
    test "a spec with unchecked temporal properties says so in the warnings" do
      result = ModelChecker.run(Counter, %{constants: %{max: 2}})

      assert Enum.any?(result.warnings, &(&1 =~ "temporal"))
      assert Enum.any?(result.warnings, &(&1 =~ "check_liveness: true"))
    end

    @tag verifies:
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API/The CLI infers `check_liveness`; the API does not"
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
        assert_raise ExTLA.Spec.DomainError, fn ->
          ModelChecker.run(OutsideDomain, %{constants: constants})
        end

      message = Exception.message(error)

      assert message =~ "balances[:carol]"
      assert message =~ "not in the domain [:alice, :bob]"
    end
  end

  describe "successors/3" do
    test "one per action per binding whose guard holds" do
      spec = ExTLA.Spec.Compiled.from_module(Transfer)
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
      spec = ExTLA.Spec.Compiled.from_module(Transfer)
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

  describe "the state graph, as a thing a second process could write to" do
    @describetag verifies:
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/State Graph"
    # #31. Not parallel exploration — that is Phase 4 — but the three things that make it
    # impossible: a protected table a worker cannot write to at all, a lookup-then-insert
    # that two writers both win, and an id allocated from a field of an immutable struct.
    test "its tables are public, and deliberately not write_concurrency" do
      graph = StateGraph.new(ExTLA.Spec.Compiled.from_module(Counter), %{max: 2})

      for table <- [graph.nodes, graph.fingerprints] do
        # The impossibility: a non-owner cannot write to a `:protected` table at all.
        assert :ets.info(table, :protection) == :public
        assert :ets.info(table, :read_concurrency) == true

        # Not an oversight — a measurement. `write_concurrency` costs 1.39x on a
        # single-writer insert-and-lookup loop and buys nothing until there are concurrent
        # writers, while the profile puts ETS at 0.2% of the raft search. Which lock
        # granularity a coordinator wants depends on how it batches its writes, and there
        # is no coordinator yet to ask.
        assert :ets.info(table, :write_concurrency) == false
      end
    end

    test "the same state registered from many processes at once gets exactly one id" do
      graph = StateGraph.new(ExTLA.Spec.Compiled.from_module(Counter), %{max: 2})
      state = %{count: 0, status: :ready}
      me = self()

      # Every process holds its own copy of the struct — it is an immutable term — so what
      # is shared is exactly the ETS side, which is the side under test.
      for _ <- 1..24 do
        spawn(fn ->
          {_graph, id, status} = StateGraph.add_state(graph, state, nil, 0, nil)
          send(me, {:registered, id, status})
        end)
      end

      results = for _ <- 1..24, do: assert_receive({:registered, _id, _status})
      ids = results |> Enum.map(fn {:registered, id, _} -> id end) |> Enum.uniq()
      news = Enum.count(results, fn {:registered, _, status} -> status == :new end)

      assert length(ids) == 1, "the same state was given #{length(ids)} ids: #{inspect(ids)}"
      assert news == 1, "#{news} processes were told the state was new"
      assert :ets.info(graph.fingerprints, :size) == 1
    end

    test "distinct states registered concurrently get distinct ids, and none is reused" do
      graph = StateGraph.new(ExTLA.Spec.Compiled.from_module(Counter), %{max: 2})
      me = self()

      for n <- 1..24 do
        spawn(fn ->
          {_graph, id, status} =
            StateGraph.add_state(graph, %{count: n, status: :ready}, nil, 0, nil)

          send(me, {:registered, id, status})
        end)
      end

      results = for _ <- 1..24, do: assert_receive({:registered, _id, _status})
      ids = Enum.map(results, fn {:registered, id, _} -> id end)

      assert Enum.uniq(ids) == ids
      assert Enum.all?(results, fn {:registered, _, status} -> status == :new end)
      assert :ets.info(graph.fingerprints, :size) == 24
    end

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
    @describetag verifies:
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Trace`"
    setup do
      %{trace: ModelChecker.run(Broken, %{}).violation}
    end

    @tag verifies: [
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/State Graph",
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Trace`"
         ]
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

    @tag verifies: [
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Trace`",
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Trace`/Example Trace Output"
         ]
    test "format/1 marks what each step changed", %{trace: trace} do
      output = Trace.format(trace)

      assert output =~ "VIOLATION: below_three"
      assert output =~ "State 1 (Init)"
      assert output =~ "State 4 [VIOLATION]"
      assert output =~ "← changed"
      assert output =~ "── tick"
    end

    # The `message` every finding writes went to `to_json/1` and to nowhere a person looks:
    # `format/1` printed the banner, which is the property's NAME, and dropped the sentence
    # saying what about it failed (#176). `:type_ok` is the clearest case — its message names
    # the variable, its value and the type it was declared with, and the banner says `type_ok`.
    @tag verifies: [
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Trace`",
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Trace`/Example Trace Output"
         ]
    test "format/1 prints the message the finding wrote, not just the property's name" do
      trace = %ExTLA.Trace{
        type: :safety,
        property: :type_ok,
        message: "type_ok: n = 4 is not in 0..3",
        states: [%{n: 4}],
        length: 1
      }

      assert Trace.format(trace) =~ "type_ok: n = 4 is not in 0..3"
    end

    @tag verifies: [
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Trace`",
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.Trace`/Example Trace Output"
         ]
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
    @describetag verifies:
                   "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/State Graph"
    @processes %{processes: MapSet.new([:p1, :p2])}

    @tag verifies: [
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/API",
           "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker`/State Graph"
         ]
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

    # Specified on the graph rather than hidden in the checker (§State Graph): it is a
    # fact about the edge table, and the checker's question — can a behaviour cycle here
    # forever — is a further one about fairness.
    test "sccs/1 finds the components of the edge table" do
      {_result, graph} = explore_live(Counter, %{max: 2})

      # (0,f) → (1,f) → (2,f) → (2,t), and `reset` closes the loop, so all four states
      # are mutually reachable and the graph is one component.
      assert StateGraph.sccs(graph) == [MapSet.new([0, 1, 2, 3])]
    end

    # Tarjan pops a component when its root is done, so the order is reverse-topological
    # — sinks first. It is stated here because it is stable, and a counterexample read off
    # the first fair component must not move between runs.
    test "sccs/2 ignores the edges that leave the region it was given" do
      {_result, graph} = explore_live(Counter, %{max: 2})

      region = MapSet.new([0, 1])

      assert StateGraph.sccs(graph, region) == [MapSet.new([1]), MapSet.new([0])]
      assert StateGraph.sccs(graph, region) == StateGraph.sccs(graph, region)
    end

    test "a spec that ends has a component per state and no cycle" do
      {_result, graph} = explore_live(Terminating, %{max: 3})

      components = StateGraph.sccs(graph)

      assert length(components) == graph.state_count
      assert Enum.all?(components, &(MapSet.size(&1) == 1))
    end

    test "sccs raises on a graph that has no edge table" do
      {_result, graph} = ModelChecker.explore(Counter, %{constants: %{max: 2}})

      assert_raise ArgumentError, ~r/spanning tree/, fn -> StateGraph.sccs(graph) end
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
