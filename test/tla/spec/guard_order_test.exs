defmodule TLA.Spec.GuardOrderTest do
  @moduledoc """
  Guards and `let`s are evaluated in **source order**, so a `require` protects the bindings
  that follow it and not the ones above it (`02-dsl-semantics.md` §2.1, #151).

  This is the half of the rule that the specification denied. §2.1 said `require` "is not
  positional" and that guards "are always evaluated before any assignment", which describes
  hoisting — and `TLA.Spec.Block.guard_body/2` deliberately does not hoist, because §1.6 makes
  function application strict. `f[x]` outside `f`'s domain raises rather than returning `nil`,
  so a guard can only protect the `let` beneath it if the conjunction short-circuits over the
  binding.

  The difference is not stylistic. It decides whether an action is **disabled** in a state or
  **raises** in it, and a reader who trusted the document would have written the second while
  intending the first. Both halves are pinned here so the prose and the code cannot drift apart
  again without something going red.
  """
  use ExUnit.Case, async: true

  defmodule Protected do
    use TLA.Spec

    constant :clients
    variable :inbox, type: [^clients ~> :int]
    variable :seen, type: :int

    init do
      inbox = %{}
      seen = 0
    end

    # The guard comes FIRST, so it protects the binding: in a state where `inbox` has no
    # entry for the client, the action is not enabled and nothing raises.
    action :consume, params: [c: ^clients] do
      require Map.has_key?(inbox, c)
      let msg = inbox[c]
      require msg > 0
      seen = seen + msg
    end
  end

  defmodule Unprotected do
    use TLA.Spec

    constant :clients
    variable :inbox, type: [^clients ~> :int]
    variable :seen, type: :int

    init do
      inbox = %{}
      seen = 0
    end

    # The same guard, written AFTER the binding it should have protected. Source order means
    # the `let` is evaluated first, and strict application raises on exactly the states the
    # guard exists to exclude.
    action :consume, params: [c: ^clients] do
      let msg = inbox[c]
      require msg > 0
      require Map.has_key?(inbox, c)
      seen = seen + msg
    end
  end

  defmodule WithTemporal do
    use TLA.Spec

    variable :n, type: 0..2

    init do
      n = 0
    end

    action :bump do
      require n < 2
      n = n + 1
    end

    terminal :done do
      n == 2
    end

    # Unreachable: `n` is typed 0..2, so this property is refuted. That is what makes the
    # default observable -- a run that does not check liveness reports :ok over it.
    temporal :reaches_three do
      eventually(n == 3)
    end
  end

  @constants %{clients: MapSet.new([:a])}

  defp guard(module, state) do
    compiled = TLA.Spec.Compiled.from_module(module)
    action = Enum.find(compiled.actions, &(&1.name == :consume))
    action.guard.(@constants, state, %{c: :a})
  end

  test "a require before a let protects it: the action is disabled, not broken" do
    refute guard(Protected, %{inbox: %{}, seen: 0})
  end

  test "the same require after the let does not protect it: strict application raises" do
    assert_raise TLA.Spec.DomainError, fn ->
      guard(Unprotected, %{inbox: %{}, seen: 0})
    end
  end

  test "both forms agree wherever the guard would have held anyway" do
    state = %{inbox: %{a: 7}, seen: 0}

    assert guard(Protected, state)
    assert guard(Unprotected, state)
  end

  # #152. `spec/04:460` said `check_liveness` defaults to TRUE. It defaults to false, and the
  # direction matters: a reader who believed the document thought their temporal properties
  # were being checked by `TLA.ModelChecker.run/2` and by `assert_spec`, and they were not.
  #
  # The documented value now has an executable counterpart, so it cannot drift back silently.
  describe "the documented config defaults" do
    test "a refutable temporal property is not checked unless asked for" do
      result = TLA.ModelChecker.run(WithTemporal, %{})

      assert result.status == :ok
      assert result.violation == nil
    end

    test "and is refuted when it is" do
      result = TLA.ModelChecker.run(WithTemporal, %{check_liveness: true})

      # A liveness counterexample is a lasso -- a prefix plus the cycle it stutters in --
      # rather than the flat trace a safety violation carries.
      assert result.status == :violation
      assert %{prefix: _, cycle: _} = result.violation
    end
  end

  # #167. Four defects in the step that turns a completed search into a reported verdict.
  # Two rules settle them: a found violation is never discarded, and a check that did not
  # run is named.
  describe "the verdict says what was checked (#167)" do
    defmodule Deadlocks do
      use TLA.Spec

      variable :n, type: 0..2

      init do
        n = 0
      end

      action :bump do
        require n < 2
        n = n + 1
      end

      # No `terminal`, so n == 2 deadlocks. Unreachable property, so it is refutable.
      temporal :reaches_three do
        eventually(n == 3)
      end
    end

    defmodule Violates do
      use TLA.Spec

      variable :n, type: 0..3

      init do
        n = 0
      end

      action :bump do
        require n < 3
        n = n + 1
      end

      invariant :below_two do
        n < 2
      end

      temporal :reaches_three do
        eventually(n == 3)
      end
    end

    defmodule Constrainable do
      use TLA.Spec

      variable :n, type: 0..10

      init do
        n = 0
      end

      action :bump do
        require n < 10
        n = n + 1
      end

      terminal :done do
        n == 10
      end

      temporal :reaches_eleven do
        eventually(n == 11)
      end
    end

    test "a deadlock skips liveness and says so" do
      result = TLA.ModelChecker.run(Deadlocks, %{check_liveness: true})

      assert result.status == :violation
      assert result.violation.type == :deadlock

      assert Enum.any?(result.warnings, &(&1 =~ "temporal property was not checked")),
             "a skipped liveness pass must name itself; got #{inspect(result.warnings)}"

      assert Enum.any?(result.warnings, &(&1 =~ "check_deadlock: false"))
    end

    test "the same spec without deadlock checking reports the refutation" do
      result = TLA.ModelChecker.run(Deadlocks, %{check_liveness: true, check_deadlock: false})

      assert result.status == :violation
      assert %{prefix: _, cycle: _} = result.violation
    end

    # Previously `ArgumentError: the search did not expand every state`, raised AFTER the
    # search, discarding a safety result that was valid for what it covered.
    test "a constraint that holds states back declines liveness instead of crashing" do
      result =
        TLA.ModelChecker.run(Constrainable, %{
          check_liveness: true,
          state_constraint: fn s -> s.n <= 3 end
        })

      assert result.status == :constrained

      assert Enum.any?(result.warnings, &(&1 =~ "state_constraint")),
             "declining must say why; got #{inspect(result.warnings)}"
    end

    # A constraint that never fires leaves a complete graph, so the question IS answerable —
    # and the lasso used to be found and then dropped by the `:constrained` status.
    test "a vacuous constraint still reports a refutation it found" do
      result =
        TLA.ModelChecker.run(Constrainable, %{
          check_liveness: true,
          state_constraint: fn _ -> true end
        })

      assert result.status == :violation
      assert %{prefix: _, cycle: _} = result.violation
    end

    # #208. The deadlock skip and the constraint skip were named; the budget skip was not, and
    # that is the one `mix tla.check --allow-incomplete` turns into exit 0 — a temporal
    # property nobody checked, unmentioned in a green result.
    test "a run the state budget stopped skips liveness and says so" do
      result = TLA.ModelChecker.run(Constrainable, %{check_liveness: true, max_states: 2})

      assert result.status == :max_states_reached
      assert result.status == :max_states_reached

      assert Enum.any?(result.warnings, &(&1 =~ "temporal property was not checked")),
             "a budget-skipped liveness pass must name itself; got #{inspect(result.warnings)}"

      assert Enum.any?(result.warnings, &(&1 =~ "max_states"))
    end

    test "a safety counterexample that halted the search names the liveness skip too" do
      result = TLA.ModelChecker.run(Violates, %{check_liveness: true})

      assert result.status == :violation
      assert result.violation.property == :below_two
      assert Enum.any?(result.warnings, &(&1 =~ "safety counterexample halted the search"))
    end

    # Nothing to name when nothing was declared.
    test "a bounded run of a spec with no temporal property has no skip to report" do
      result =
        TLA.ModelChecker.run(TLA.TestSpecs.Unbounded, %{check_liveness: true, max_states: 5})

      assert result.status == :max_states_reached
      refute Enum.any?(result.warnings, &(&1 =~ "not checked"))
    end
  end

  # #166. A selection naming something the spec does not declare checked NOTHING and reported
  # `:ok`:
  #
  #     invariants: [:cap]         status=:violation
  #     invariants: [:capp] (typo) status=:ok  warnings=[]
  #
  # It matters beyond a hand-typed config. `TLA.DifferentialCase` drives the whole TLC corpus
  # through these selections using names read from `expected.json`, and D-9 makes agreement
  # with TLC the acceptance gate — so a misspelled name in a fixture made
  # `assert result.status == :ok` pass having compared nothing.
  describe "a selection that matched nothing (#166)" do
    defmodule Selectable do
      use TLA.Spec

      variable :n, type: 0..3

      init do
        n = 0
      end

      action :bump do
        require n < 3
        n = n + 1
      end

      terminal :done do
        n == 3
      end

      invariant :cap do
        n < 2
      end

      temporal :reaches_three do
        eventually(n == 3)
      end
    end

    test "an invariant name the spec does not declare is refused" do
      error =
        assert_raise ArgumentError, fn ->
          TLA.ModelChecker.run(Selectable, %{invariants: [:capp]})
        end

      assert error.message =~ ":capp"
      assert error.message =~ "which this spec does not declare"
      assert error.message =~ ":cap"
      assert error.message =~ "checks nothing"
    end

    test "a temporal name the spec does not declare is refused" do
      error =
        assert_raise ArgumentError, fn ->
          TLA.ModelChecker.run(Selectable, %{
            check_liveness: true,
            invariants: [],
            temporals: [:reaches_four]
          })
        end

      assert error.message =~ ":reaches_four"
      assert error.message =~ ":reaches_three"
    end

    test "a correct selection still selects" do
      assert TLA.ModelChecker.run(Selectable, %{invariants: [:cap]}).status == :violation
      assert TLA.ModelChecker.run(Selectable, %{invariants: []}).status == :ok
    end
  end
end
