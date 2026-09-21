defmodule TLA.CoverageTest do
  @moduledoc """
  A green check mark is only as good as what was behind it. These tests are about
  the three ways a run reports success having verified almost nothing.
  """
  use ExUnit.Case, async: true

  alias TLA.{Coverage, ModelChecker}

  defmodule Typo do
    @moduledoc "An action whose guard can never hold — the routine failure this report exists to find."
    use TLA.Spec

    constant :modes

    variable :n, type: 0..4
    variable :mode

    init do
      n = 0
      mode = :a
    end

    action :tick, params: [step: [1, 2]] do
      require n + step <= 4
      n = n + step
    end

    action :switch, params: [m: ^modes] do
      require m != mode
      require n == 99
      mode = m
    end

    invariant :small_or_even do
      n < 3 or rem(n, 2) == 0
    end
  end

  defmodule Properties do
    @moduledoc "Three leads-to properties: one never triggered, one trivially satisfied, one real."
    use TLA.Spec

    variable :n, type: 0..3

    init do
      n = 0
    end

    action :tick do
      require n < 3
      n = n + 1
    end

    terminal :done do
      n == 3
    end

    temporal :never_triggered do
      (n == 99) ~> (n == 0)
    end

    temporal :always_satisfied do
      (n >= 0) ~> (n < 100)
    end

    temporal :real do
      (n == 1) ~> (n == 3)
    end
  end

  defp coverage(module, config), do: ModelChecker.run(module, config).coverage

  describe "actions" do
    setup do
      %{coverage: coverage(Typo, %{constants: %{modes: MapSet.new([:a, :b])}, invariants: []})}
    end

    # A typo in a guard turns an action off entirely. The spec still model-checks
    # — it is simply a weaker spec now, and a weaker spec passes more easily.
    test "an action that was never enabled is named", %{coverage: coverage} do
      assert coverage.never_enabled == [:switch]

      assert coverage.actions[:switch] == %{
               enabled_in: 0,
               states_generated: 0,
               distinct_generated: 0
             }
    end

    test "an enabled action carries what it generated", %{coverage: coverage} do
      assert coverage.actions[:tick].enabled_in > 0

      assert coverage.actions[:tick].states_generated >=
               coverage.actions[:tick].distinct_generated
    end

    # #212. `unreached_params` was computed and surfaced nowhere. A binding an enabled action
    # never drew is a finding of the never-enabled kind, one value at a time; a never-enabled
    # action's whole universe is not repeated under it.
    test "an enabled action's never-drawn bindings are warned about, once each", %{
      coverage: coverage
    } do
      # `switch` is never enabled and has its own line; `tick` draws both of its steps.
      refute Enum.any?(Coverage.warnings(coverage), &(&1 =~ "never drawn"))
      assert Enum.any?(Coverage.warnings(coverage), &(&1 =~ "switch"))

      defmodule PartlyDrawn do
        use TLA.Spec
        variable :n, type: 0..4

        init do
          n = 0
        end

        # `step: 5` can never satisfy the guard from any reachable `n`.
        action :tick, params: [step: [1, 2, 5]] do
          require n + step <= 4
          n = n + step
        end
      end

      partly = ModelChecker.run(PartlyDrawn, %{}).coverage
      assert partly.unreached_params == %{tick: [%{step: 5}]}

      assert Enum.any?(
               Coverage.warnings(partly),
               &(&1 =~
                   "action :tick was enabled, but 1 of its binding was never drawn: %{step: 5}")
             )

      # Surfaced as a warning, not a strict-coverage failure: the action ran.
      assert Coverage.clean?(partly)
    end

    test "under symmetry the universe is unknown, so nothing is called unreached" do
      coverage =
        coverage(TLA.TestSpecs.PerBinding, %{
          constants: %{processes: MapSet.new([:p1, :p2])},
          symmetry: [:processes]
        })

      assert coverage.unreached_params == %{}
    end

    test "a never-enabled action's unexercised bindings are enumerated", %{coverage: coverage} do
      assert coverage.unreached_params[:switch] == [%{m: :a}, %{m: :b}]
    end

    test "an action whose bindings were all exercised has no entry", %{coverage: coverage} do
      refute Map.has_key?(coverage.unreached_params, :tick)
    end

    # The set a state function returns changes from state to state, so there is
    # no fixed universe to subtract from.
    test "a state-drawn param has no universe to compare against" do
      coverage =
        coverage(TLA.TestSpecs.Transfer, %{
          constants: %{accounts: MapSet.new([:alice, :bob]), max_balance: 2}
        })

      refute Map.has_key?(coverage.unreached_params, :complete_transfer)
    end
  end

  defmodule HaltsOnItsOnlyEnablement do
    @moduledoc """
    `reset` is enabled in exactly one state, and taking it is what violates the property. That
    combination is the whole of #128: an action whose enablement is lost when the expansion halts
    reports `enabled_in: 0`, and zero is not an undercount but a false claim.

    Every corpus entry before `audit_log` was too big to show it — `die_hard`'s actions are
    enabled in eleven or twelve states, so losing one leaves eleven and nothing looks wrong.
    """
    use TLA.Spec

    variable :n, type: 0..3

    init do
      n = 0
    end

    action :step do
      require n < 3

      n = n + 1
    end

    action :reset do
      require n == 3

      n = 0
    end

    action_property :never_decreases do
      new.n >= old.n
    end
  end

  describe "an action whose expansion halted" do
    setup do
      %{result: ModelChecker.run(HaltsOnItsOnlyEnablement, %{})}
    end

    test "is not reported as never enabled", %{result: result} do
      assert result.status == :violation
      assert result.violation.actions |> List.last() == :reset

      # Before #135 this was `[:reset]` — the run named `reset` in its counterexample and told
      # the user in the same breath that its guard never held.
      assert result.coverage.never_enabled == []
      assert result.coverage.actions[:reset].enabled_in == 1
    end

    test "and no warning accuses it", %{result: result} do
      refute Enum.any?(Coverage.warnings(result.coverage), &(&1 =~ "reset"))
    end

    test "the actions a counterexample names and never_enabled are disjoint", %{result: result} do
      # The property stated directly, because it is the one worth carrying into the corpus: it is
      # about the result object alone, so it costs nothing to assert wherever a violation exists.
      named = MapSet.new(result.violation.actions)
      claimed = MapSet.new(result.coverage.never_enabled)

      assert MapSet.disjoint?(named, claimed)
    end

    # The counts the split moved apart must still both be recorded. `reset` generated one state
    # before the property refused it; `step` generated three.
    test "enablement and what it generated are both still counted", %{result: result} do
      assert result.coverage.actions[:step].enabled_in == 3
      assert result.coverage.actions[:step].states_generated == 3
      assert result.coverage.actions[:reset].enabled_in == 1
    end
  end

  describe "a bounded run may not accuse" do
    # A truncated search cannot tell an action whose guard is never true from one whose states it
    # never reached, so `never_enabled` stays in the report as data and stops being a finding.
    setup do
      %{
        coverage:
          coverage(Typo, %{
            constants: %{modes: MapSet.new([:a, :b])},
            invariants: [],
            max_states: 2
          })
      }
    end

    test "the list is still reported, because it is data", %{coverage: coverage} do
      assert coverage.bounded_by == :max_states
      assert coverage.never_enabled == [:switch]
    end

    test "but the warning says the run was bounded rather than blaming the spec", %{
      coverage: coverage
    } do
      [line] = Enum.filter(Coverage.warnings(coverage), &(&1 =~ "switch"))

      assert line =~ "not enabled in any state this run reached"
      assert line =~ "bounded by :max_states"
      refute line =~ "was never enabled"
    end

    test "and --strict-coverage does not fail a build on it", %{coverage: coverage} do
      assert Coverage.clean?(coverage)
    end

    # The fix must not buy its correctness by going quiet: a COMPLETE run still accuses.
    #
    # `Typo` deadlocks once `tick` runs out, and until #136 that read as `bounded_by: :violation`
    # even though the search had finished — so this test had to pass `check_deadlock: false` to
    # get a run it could make the point with. It does not any more: a completed search reports
    # `:none` whatever it found, which is what the field was always supposed to mean.
    test "whereas a complete run still does both" do
      coverage = coverage(Typo, %{constants: %{modes: MapSet.new([:a, :b])}, invariants: []})

      assert coverage.bounded_by == :none
      refute Coverage.clean?(coverage)
      assert Enum.any?(Coverage.warnings(coverage), &(&1 =~ "action :switch was never enabled"))
    end

    # Same spec, deadlock check off. The verdict changes and the coverage judgement does not,
    # which is the point: `--strict-coverage` is about what the search covered, not about what
    # it concluded.
    test "and a deadlocking spec is caught with or without the deadlock check" do
      coverage =
        coverage(Typo, %{
          constants: %{modes: MapSet.new([:a, :b])},
          invariants: [],
          check_deadlock: false
        })

      assert coverage.bounded_by == :none
      refute Coverage.clean?(coverage)
    end
  end

  describe "invariants" do
    test "record how many states each was evaluated in" do
      coverage = coverage(Properties, %{})

      assert coverage.invariants[:type_ok].evaluated_in == 4
    end

    # A near miss is a state in which the invariant held only through its
    # non-trivial branch: the left disjunct was false, so the right had to carry
    # it. `n = 3` is the only such state here.
    test "count near misses for an invariant with a top-level or" do
      coverage =
        coverage(Typo, %{
          constants: %{modes: MapSet.new([:a])},
          invariants: [:small_or_even]
        })

      assert coverage.invariants[:small_or_even].near_misses == 1
    end

    # Zero near misses is a finding; "we did not look" is not, and the two must
    # not render as the same number.
    test "report nil, not zero, for an invariant with no measurable branch" do
      coverage = coverage(Properties, %{})

      assert coverage.invariants[:type_ok].near_misses == nil
      assert Coverage.format(coverage) =~ ~r/type_ok\s+\d+\s+-/
    end

    test "an invariant that was never at risk is a warning" do
      defmodule NeverAtRisk do
        use TLA.Spec
        variable :n

        init do
          n = 0
        end

        action :tick do
          require n < 2
          n = n + 1
        end

        invariant :trivial do
          n >= 0 or n < 0
        end
      end

      coverage = coverage(NeverAtRisk, %{check_deadlock: false})

      assert coverage.invariants[:trivial].near_misses == 0
      assert Enum.any?(Coverage.warnings(coverage), &(&1 =~ "never at risk"))
      refute Coverage.clean?(coverage)
    end
  end

  describe "vacuity" do
    setup do
      %{coverage: coverage(Properties, %{})}
    end

    test "a leads-to whose antecedent never held is vacuous", %{coverage: coverage} do
      assert %{property: :never_triggered, reason: :antecedent_never_held} =
               Enum.find(coverage.vacuous, &(&1.property == :never_triggered))
    end

    test "a leads-to whose consequent always held is vacuous", %{coverage: coverage} do
      assert %{property: :always_satisfied, reason: :consequent_always_held} =
               Enum.find(coverage.vacuous, &(&1.property == :always_satisfied))
    end

    test "a leads-to that says something is not flagged", %{coverage: coverage} do
      refute Enum.any?(coverage.vacuous, &(&1.property == :real))
    end

    # Flagging `always(P)` for holding everywhere would train people to ignore
    # the report, which is the one thing a coverage report cannot survive.
    test "a property that holds everywhere is not vacuous unless it is a leads-to" do
      coverage = coverage(TLA.TestSpecs.Counter, %{constants: %{max: 3}})

      assert coverage.vacuous == []
    end

    test "vacuity is reported per binding under a quantifier" do
      defmodule PerProcess do
        use TLA.Spec
        constant :procs

        variable :pc, type: [^procs ~> [:idle, :busy]]

        init do
          pc = for_each(^procs, fn _ -> :idle end)
        end

        action :start, params: [p: ^procs] do
          require pc[p] == :idle
          require p == :p1
          pc = update(pc, p, fn _ -> :busy end)
        end

        temporal :all_get_going do
          Enum.all?(^procs, fn p ->
            (pc[p] == :idle) ~> (pc[p] == :busy)
          end)
        end
      end

      coverage =
        coverage(PerProcess, %{
          constants: %{procs: MapSet.new([:p1, :p2])},
          check_deadlock: false
        })

      # p1 does get going, so its instance says something. p2 never does, but its
      # antecedent DID hold — so it is a real (unchecked) property, not a vacuous
      # one. Nothing should be flagged here.
      assert coverage.vacuous == []
    end

    # #200. Probes were keyed by the innermost binding alone, so under a nested quantifier
    # every outer instance landed on one key and only the last survived. Here `sender == :b`
    # never holds, so both `[:b, _]` instances are vacuous — and were reported by nothing,
    # while the liveness checker, expanding correctly, checked each as its own property.
    defmodule Nested do
      use TLA.Spec
      constant :procs

      variable :sent, type: [^procs ~> [^procs ~> [false, true]]]
      variable :got, type: [^procs ~> [^procs ~> [false, true]]]

      init do
        sent = for_each(^procs, fn _ -> for_each(^procs, fn _ -> false end) end)
        got = for_each(^procs, fn _ -> for_each(^procs, fn _ -> false end) end)
      end

      action :send, params: [from: ^procs, to: ^procs] do
        require from == :a
        require not sent[from][to]
        sent = update(sent, from, fn row -> update(row, to, fn _ -> true end) end)
      end

      action :deliver, params: [from: ^procs, to: ^procs] do
        require sent[from][to] and not got[from][to]
        got = update(got, from, fn row -> update(row, to, fn _ -> true end) end)
      end

      temporal :every_send_delivered do
        Enum.all?(^procs, fn from ->
          Enum.all?(^procs, fn to ->
            sent[from][to] ~> got[from][to]
          end)
        end)
      end
    end

    test "under a nested quantifier every outer instance is its own probe" do
      coverage =
        coverage(Nested, %{constants: %{procs: MapSet.new([:a, :b])}, check_deadlock: false})

      assert Enum.map(coverage.vacuous, &{&1.binding, &1.reason}) == [
               {[:b, :a], :antecedent_never_held},
               {[:b, :b], :antecedent_never_held}
             ]

      assert Enum.any?(Coverage.warnings(coverage), &(&1 =~ "VACUOUS for :b, :a"))
    end

    # The probes come from `Spec.Compiled.temporal_instances/2`, the expansion the liveness
    # checker uses. Asserted rather than assumed: the defect was two derivations of "what is
    # an instance" that disagreed, and the fix is that there is one.
    test "coverage's instances are the checker's instances" do
      constants = %{procs: MapSet.new([:a, :b])}
      spec = TLA.Spec.Compiled.from_module(Nested)
      [temporal] = spec.temporals

      checker =
        temporal
        |> TLA.Spec.Compiled.temporal_instances(constants)
        |> Enum.map(& &1.bound)
        |> Enum.sort()

      probes =
        coverage(Nested, %{constants: constants, check_deadlock: false})
        |> Map.fetch!(:vacuous)
        |> Enum.map(& &1.binding)

      # Every vacuous instance is a checker instance, and the checker has four.
      assert checker == [[:a, :a], [:a, :b], [:b, :a], [:b, :b]]
      assert Enum.all?(probes, &(&1 in checker))
    end
  end

  describe "terminal_but_live" do
    # Not an error — nothing is cut — but almost always a predicate broader than
    # the end state it was written for.
    test "names a terminal predicate that admitted a state with an enabled action" do
      defmodule TooBroad do
        use TLA.Spec
        variable :n, type: 0..2

        init do
          n = 0
        end

        action :tick do
          require n < 2
          n = n + 1
        end

        terminal :anywhere do
          n >= 0
        end
      end

      coverage = coverage(TooBroad, %{})

      assert coverage.terminal_but_live == [:anywhere]
      assert Enum.any?(Coverage.warnings(coverage), &(&1 =~ "admitted a live state"))
    end

    test "a predicate that matches only the end state is not flagged" do
      coverage = coverage(TLA.TestSpecs.Terminating, %{constants: %{max: 3}})

      assert coverage.terminal_but_live == []
    end
  end

  describe "bounded_by" do
    test "is :none for a complete run" do
      assert coverage(TLA.TestSpecs.Terminating, %{constants: %{max: 2}}).bounded_by == :none
    end

    test "names the state constraint" do
      coverage =
        coverage(TLA.TestSpecs.Unbounded, %{state_constraint: fn s -> s.n <= 5 end})

      assert coverage.bounded_by == :state_constraint
      assert Coverage.format(coverage) =~ "lower bound, not a census"
    end

    test "names the state limit" do
      assert coverage(TLA.TestSpecs.Unbounded, %{max_states: 10}).bounded_by == :max_states
    end

    # A run that stopped at a counterexample stopped mid-expansion, so its counts
    # are a lower bound for exactly the same reason a bounded run's are.
    test "names a violation" do
      assert coverage(TLA.TestSpecs.Broken, %{}).bounded_by == :violation
    end

    # The pair that separates the two runs one `:violation` used to cover (#136). They differ in
    # exactly this and in nothing else, which is what makes them a pair: `Deadlocking` empties
    # its frontier and only then reports a stuck state, so its counts are a census; `Broken`
    # stops mid-expansion on an invariant, so they are a floor. Only the second bounded
    # anything, and the field is about the counts rather than about the verdict.
    test "a completed search that found a deadlock bounded nothing" do
      result = ModelChecker.run(TLA.TestSpecs.Deadlocking, %{constants: %{max: 3}})

      assert result.status == :violation
      assert result.deadlock
      assert result.coverage.bounded_by == :none
    end

    test "whereas one that halted mid-expansion did" do
      result = ModelChecker.run(TLA.TestSpecs.Broken, %{})

      assert result.status == :violation
      refute result.deadlock
      assert result.coverage.bounded_by == :violation
    end
  end

  describe "format/2" do
    test "is quiet when everything was exercised" do
      coverage = coverage(TLA.TestSpecs.Terminating, %{constants: %{max: 3}})

      assert Coverage.clean?(coverage)
      refute Coverage.format(coverage) =~ "warning"
    end

    test "is loud about what it found" do
      output =
        Typo
        |> coverage(%{constants: %{modes: MapSet.new([:a, :b])}, invariants: []})
        |> Coverage.format(title: "COVERAGE: Typo")

      assert output =~ "COVERAGE: Typo"
      assert output =~ "NEVER ENABLED"
      assert output =~ "1 warning."
    end

    test "counts warnings in the plural correctly" do
      output = Properties |> coverage(%{}) |> Coverage.format()

      assert output =~ "2 warnings."
      assert output =~ "VACUOUS"
    end
  end
end
