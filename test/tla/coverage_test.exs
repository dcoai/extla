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
    # `check_deadlock: false` because `Typo` deadlocks once `tick` runs out, and a deadlock is
    # reported as `bounded_by: :violation` even though the search finished (#136).
    test "whereas a complete run still does both" do
      coverage =
        coverage(Typo, %{
          constants: %{modes: MapSet.new([:a, :b])},
          invariants: [],
          check_deadlock: false
        })

      assert coverage.bounded_by == :none
      refute Coverage.clean?(coverage)
      assert Enum.any?(Coverage.warnings(coverage), &(&1 =~ "action :switch was never enabled"))
    end

    # And a run that halted on a violation is left alone, deliberately. `:violation` conflates a
    # truncated search with a completed one that found a deadlock (#136), so nothing here leans
    # on it — which means `--strict-coverage` is exactly as strong for a deadlocking spec as it
    # was before #135.
    test "a deadlocking spec is still caught by --strict-coverage" do
      coverage = coverage(Typo, %{constants: %{modes: MapSet.new([:a, :b])}, invariants: []})

      assert coverage.bounded_by == :violation
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
