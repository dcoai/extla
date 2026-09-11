defmodule TLA.Spec.PredicateResultTest do
  @moduledoc """
  A predicate that evaluates to something other than `true` or `false` is refused,
  wherever it is evaluated (#192).

  Elixir's `and`/`or` return their last operand, so `n >= 0 and status` is `status`. Every
  consumer of a predicate tested its result for truthiness, so that invariant counted as
  holding whenever `status` was anything but `nil` or `false` — a run in which `status`
  never took the value the author meant reported `:ok`. Four declaration kinds compile a
  predicate, and the wrapper is applied where each is compiled, so each is exercised here
  against the checker rather than by calling the function directly: the point is that the
  *run* refuses, not that a helper does.
  """
  use ExUnit.Case, async: true

  alias TLA.ModelChecker
  alias TLA.Spec.PredicateError

  # `status` is `:idle` in every reachable state. Read as a truthy value the invariant
  # holds everywhere; as the author's evident intent (`status == :done`) it fails at once.
  defmodule TruthyInvariant do
    use TLA.Spec

    variable :n, type: 0..2
    variable :status, type: [:idle, :done]

    init do
      n = 0
      status = :idle
    end

    action :bump do
      require n < 2
      n = n + 1
    end

    invariant :done_when_bumped do
      n >= 0 and status
    end
  end

  defmodule TruthyTerminal do
    use TLA.Spec

    variable :n, type: 0..1
    variable :status, type: [:idle, :done]

    init do
      n = 0
      status = :idle
    end

    action :bump do
      require n < 1
      n = n + 1
    end

    terminal :finished do
      n == 1 and status
    end
  end

  defmodule TruthyActionProperty do
    use TLA.Spec

    variable :n, type: 0..2
    variable :status, type: [:idle, :done]

    init do
      n = 0
      status = :idle
    end

    action :bump do
      require n < 2
      n = n + 1
    end

    action_property :monotone do
      new.n >= old.n and new.status
    end
  end

  defmodule TruthyTemporal do
    use TLA.Spec

    variable :n, type: 0..2
    variable :status, type: [:idle, :done]

    init do
      n = 0
      status = :idle
    end

    action :bump do
      require n < 2
      n = n + 1
    end

    temporal :eventually_done do
      eventually(n == 2 and status)
    end

    fairness(:weak, [:bump])
  end

  test "an invariant returning a non-boolean is refused, naming the declaration and value" do
    error =
      assert_raise PredicateError, fn ->
        ModelChecker.run(TruthyInvariant, %{})
      end

    assert error.declaration == "invariant :done_when_bumped"
    assert error.value == :idle
    assert Exception.message(error) =~ "invariant :done_when_bumped"
    assert Exception.message(error) =~ ":idle"
    assert Exception.message(error) =~ "not a boolean"
  end

  test "a terminal returning a non-boolean is refused" do
    error =
      assert_raise PredicateError, fn ->
        ModelChecker.run(TruthyTerminal, %{})
      end

    assert error.declaration == "terminal :finished"
  end

  test "an action property returning a non-boolean is refused" do
    error =
      assert_raise PredicateError, fn ->
        ModelChecker.run(TruthyActionProperty, %{})
      end

    assert error.declaration == "action_property :monotone"
  end

  test "a temporal's state predicate returning a non-boolean is refused" do
    error =
      assert_raise PredicateError, fn ->
        ModelChecker.run(TruthyTemporal, %{check_liveness: true})
      end

    assert error.declaration == "temporal :eventually_done"
  end

  # The wrapper is on the compiled function, so it is not the checker's alone: a consumer
  # that calls the predicate directly — trace replay, coverage, the ledger — gets the same
  # refusal. One call proves the wrapper is on the function and not in the checker.
  test "the compiled predicate function itself refuses" do
    assert_raise PredicateError, fn ->
      TruthyInvariant.__tla_invariant_done_when_bumped__(%{}, %{n: 0, status: :idle})
    end

    assert TruthyInvariant.__tla_invariant_done_when_bumped__(%{}, %{n: 0, status: false}) ==
             false
  end
end
