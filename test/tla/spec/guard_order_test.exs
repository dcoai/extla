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
end
