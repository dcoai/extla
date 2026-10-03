defmodule ExTLA.BoundedAccusationTest do
  @moduledoc """
  What a bounded run may claim, and what `--strict-coverage` may fail on (#307, closes #167).

  Three defects, one theme: **a run that did not see the whole state space may not make a
  negative existential claim, and `--strict-coverage` may not fail on a condition the
  specification does not give it.**

  ## The rule, applied once instead of four times

  A negative existential claim — *no reached state satisfied P* — is not supportable by a
  bounded run: it cannot tell a P nothing satisfies from a P whose states it never got to.
  #128 established that for one of four and it stopped there. The other three are the same
  claim in different words:

  * `:antecedent_never_held` — no reached state satisfied P;
  * `:consequent_always_held` — no reached state *failed* Q. The proposal did not name this
    one; it is the same claim with the quantifier turned around;
  * an invariant with zero near misses — no reached state came close to violating it.

  ## `:constrained` meant "configured", not "bound"

  An exhaustive run whose `state_constraint` never fired was reported as unverified, exited
  2, and flunked `assert_spec` — over a predicate that turned out to exclude nothing. It is
  now derived from `held_back`, counted where the constraint is applied.

  ## The specification's own worked example was the witness

  `spec/04-layer2-model-checker.md` renders `type_ok … <-- never at risk` and then counts
  **2 warnings** — the never-enabled action and the vacuous property. The code counted three
  and failed the build on all of them. That disagreement stood for as long as both existed,
  which is why the example is a gate here rather than prose.
  """

  use ExUnit.Case, async: true

  alias ExTLA.{Coverage, ModelChecker}

  @root Path.expand("../..", __DIR__)

  # ── A spec whose constraint can be made to bite or not ──────────────────────

  defmodule Climb do
    @moduledoc "`n` climbs to five. A constraint on `n` either excludes states or does not."
    use ExTLA.Spec

    variable :n, type: 0..5

    init do
      n = 0
    end

    action :step do
      require n < 5
      n = n + 1
    end

    invariant :in_range do
      n >= 0 and n <= 5
    end
  end

  defp run(config),
    do: ModelChecker.run(Climb, Map.merge(%{check_deadlock: false, constants: %{}}, config))

  describe "a state_constraint that held nothing back" do
    test "does not make the run constrained" do
      # True of every reachable state, so it excludes nothing.
      result = run(%{state_constraint: fn state -> state.n <= 5 end})

      assert result.coverage.held_back == 0
      assert result.status == :ok
      assert result.coverage.bounded_by == :none
    end

    # The other half, and the reason the first is not a rename: a constraint that DOES bite
    # is still reported. Without this, "always `:ok`" would pass the test above.
    test "whereas one that did is still reported" do
      result = run(%{state_constraint: fn state -> state.n <= 2 end})

      assert result.coverage.held_back > 0
      assert result.status == :constrained
      assert result.coverage.bounded_by == :state_constraint
    end

    test "and a run with no constraint at all is unchanged" do
      result = run(%{})

      assert result.coverage.held_back == 0
      assert result.status == :ok
      assert result.coverage.bounded_by == :none
    end
  end

  # ── The downgrade, applied to all four ──────────────────────────────────────

  describe "on a bounded run" do
    setup do
      bounded = %Coverage{
        never_enabled: [:switch],
        vacuous: [
          %{property: :recovers, binding: [], reason: :antecedent_never_held},
          %{property: :settles, binding: [], reason: :consequent_always_held}
        ],
        invariants: %{safe: %{evaluated_in: 10, near_misses: 0}},
        terminal_but_live: [:finished],
        bounded_by: :max_states
      }

      %{bounded: bounded, complete: %{bounded | bounded_by: :none}}
    end

    test "nothing accuses", %{bounded: bounded} do
      assert Coverage.strict_failures(bounded) == []
    end

    test "and every line says why it is not a finding about the spec", %{bounded: bounded} do
      lines = Coverage.warnings(bounded)

      for fragment <- ["switch", "recovers", "settles", "safe"] do
        [line] = Enum.filter(lines, &(&1 =~ fragment))

        assert line =~ "bounded by :max_states",
               "the line for #{fragment} accuses without saying the run was bounded: #{line}"

        assert line =~ "not a finding about the spec"
      end
    end

    # Anti-vacuity for the block above: the same coverage, unbounded, must accuse on three
    # of the four. Without this the downgrade could be a function that always returns `[]`.
    test "whereas a complete run accuses on exactly the two the spec names", %{
      complete: complete
    } do
      failures = Coverage.strict_failures(complete)

      assert {:never_enabled, :switch} in failures
      assert {:vacuous, :recovers} in failures
      assert {:vacuous, :settles} in failures
      assert length(failures) == 3
    end

    test "and the lines on a complete run carry no qualifier", %{complete: complete} do
      for line <- Coverage.warnings(complete) do
        refute line =~ "not a finding about the spec"
      end
    end
  end

  # ── What --strict-coverage is for ───────────────────────────────────────────

  describe "--strict-coverage" do
    # spec/04: "`terminal` predicates that admitted a state which still had an enabled
    # action. Not an error — nothing is cut".
    test "does not fail on a terminal that admitted a live state" do
      coverage = %Coverage{terminal_but_live: [:finished], bounded_by: :none}

      assert Coverage.strict_failures(coverage) == []

      # But it is still WORTH PRINTING, which is the distinction `clean?/1` keeps.
      refute Coverage.clean?(coverage)
      assert Coverage.warnings(coverage) != []
    end

    test "and does not fail on an invariant that was never at risk" do
      coverage = %Coverage{
        invariants: %{type_ok: %{evaluated_in: 8431, near_misses: 0}},
        bounded_by: :none
      }

      assert Coverage.strict_failures(coverage) == []
      refute Coverage.clean?(coverage)
    end

    test "and does fail on a never-enabled action" do
      coverage = %Coverage{never_enabled: [:cancel_transfer], bounded_by: :none}

      assert Coverage.strict_failures(coverage) == [{:never_enabled, :cancel_transfer}]
    end

    test "and does fail on a vacuous property" do
      coverage = %Coverage{
        vacuous: [%{property: :error_recovery, binding: [], reason: :antecedent_never_held}],
        bounded_by: :none
      }

      assert Coverage.strict_failures(coverage) == [{:vacuous, :error_recovery}]
    end
  end

  # ── The specification's own example, as a gate ──────────────────────────────

  describe "spec/04's worked coverage example" do
    # The example's shape, transcribed: five actions of which one was never enabled, three
    # invariants of which one has zero near misses, one property checked and one vacuous.
    defp worked_example do
      %Coverage{
        actions: %{
          begin_transfer: %{enabled_in: 1204, states_generated: 3612, distinct_generated: 3612},
          complete_transfer: %{
            enabled_in: 3612,
            states_generated: 3612,
            distinct_generated: 2408
          },
          fail_transfer: %{enabled_in: 3612, states_generated: 3612, distinct_generated: 802},
          reset: %{enabled_in: 1204, states_generated: 1204, distinct_generated: 1},
          cancel_transfer: %{enabled_in: 0, states_generated: 0, distinct_generated: 0}
        },
        never_enabled: [:cancel_transfer],
        invariants: %{
          type_ok: %{evaluated_in: 8431, near_misses: 0},
          conservation_of_money: %{evaluated_in: 8431, near_misses: 802},
          no_negative_balance: %{evaluated_in: 8431, near_misses: 119}
        },
        vacuous: [%{property: :error_recovery, binding: [], reason: :antecedent_never_held}],
        bounded_by: :none
      }
    end

    # The number the specification prints, read from the specification rather than restated
    # here — so an edit to the example moves this test rather than leaving it agreeing with
    # a version nobody has.
    defp documented_warning_count do
      @root
      |> Path.join("spec/04-layer2-model-checker.md")
      |> File.read!()
      |> then(&Regex.run(~r/^(\d+) warnings\. Re-run with --strict-coverage/m, &1))
      |> Enum.at(1)
      |> String.to_integer()
    end

    test "prints the number of warnings the code produces" do
      assert documented_warning_count() == 2

      assert length(Coverage.strict_failures(worked_example())) == documented_warning_count()

      assert Coverage.format(worked_example()) =~
               "#{documented_warning_count()} warnings. Re-run with --strict-coverage"
    end

    # The example shows the never-at-risk marker in the invariants table and does not count
    # it. Both halves matter: uncounted is not the same as unreported.
    test "and shows the never-at-risk invariant without counting it" do
      rendered = Coverage.format(worked_example())

      assert rendered =~ "never at risk"
      assert rendered =~ "NEVER ENABLED"
      refute rendered =~ "3 warnings"
    end

    # Anti-vacuity: the regex above must be reading a real line of a real document.
    test "and the example is the one in the specification" do
      spec = @root |> Path.join("spec/04-layer2-model-checker.md") |> File.read!()

      assert spec =~ "cancel_transfer"
      assert spec =~ "<-- NEVER ENABLED"
      assert spec =~ "<-- never at risk"
      assert spec =~ "VACUOUS: `status == :error` never held"
    end
  end
end
