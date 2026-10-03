defmodule ExTLA.Conformance.TruncatedBehaviourTest do
  @moduledoc """
  A behaviour that lost its beginning cannot settle a claim about its beginning (#278).

  ## The defect

  `ExTLA.GenServer.Runtime`'s trace buffer keeps the newest states and drops the rest —
  correctly, since an unbounded per-process trace is a memory leak in any long-lived
  GenServer. It recorded nothing about having dropped them, and the bare-predicate verdict
  read `hd(behavior)` as "the behaviour's first state".

  For a server past the buffer those are different states, and the verdict was not merely
  over-confident — it was **wrong**. A server that had taken 1,200 transitions from
  `n = 0` reported the property `n == 0` **violated**, as a settled fact, about a
  behaviour that satisfies it. A false refutation is the worst answer a verification tool
  can give: it sends someone to fix a specification that is correct.

  ## Why only this shape

  Truncation drops a *prefix*, and every other shape of §5.1 survives that:

  - `always(P)` answers `:violated` from a retained state where P is false — which really
    did occur, so it refutes the whole behaviour too — and `:inconclusive` otherwise,
    because without a lasso it can never answer `:holds`.
  - `eventually(P)` answers `:holds` from a retained witness, for the same reason, and
    `:inconclusive` otherwise.
  - `<>[]P`, `[]<>P` and `P ~> Q` need a lasso, which a real trace never has.

  So `always` is **not** made `:inconclusive` by truncation, though the work item asked
  for it: that would discard a sound refutation, which is the honesty rule pointed the
  wrong way. Only the bare predicate names a position the buffer can take away.
  """
  use ExUnit.Case, async: true

  alias ExTLA.GenServer.Runtime

  defmodule Spec do
    @moduledoc false
    use ExTLA.Spec

    variable :n, type: 0..2000

    init do
      n = 0
    end

    action :tick do
      require n < 2000
      n = n + 1
    end

    # A claim about the FIRST state, and the only shape a dropped prefix can falsify.
    temporal :starts_at_zero do
      n == 0
    end

    temporal :never_negative do
      always(n >= 0)
    end

    temporal :reaches_two do
      eventually(n == 2)
    end
  end

  # The verdicts, on a behaviour handed over directly. The trace buffer's limit is
  # application config and therefore VM-global, so a test that set it would race every
  # other async test recording a transition; a behaviour built here needs no buffer at all.
  describe "a complete behaviour" do
    test "settles a bare predicate, either way" do
      assert verdicts(%{states: [%{n: 0}, %{n: 1}], dropped: 0}).starts_at_zero == :holds
      assert verdicts(%{states: [%{n: 7}, %{n: 8}], dropped: 0}).starts_at_zero == :violated
    end
  end

  describe "a truncated behaviour" do
    # The assertion this whole work item exists for. Revert the `dropped > 0` clause in
    # `Runtime.verdict/3` and this reports `:violated` — of a behaviour that started at
    # zero and satisfies the property.
    test "cannot settle a bare predicate, in either direction" do
      began_at_zero = %{states: [%{n: 202}, %{n: 203}], dropped: 202}

      assert verdicts(began_at_zero).starts_at_zero == :inconclusive
    end

    test "still refutes an always, from a state that really occurred" do
      assert verdicts(%{states: [%{n: 5}, %{n: -1}], dropped: 99}).never_negative ==
               :violated
    end

    test "and still satisfies an eventually, from a witness that really occurred" do
      assert verdicts(%{states: [%{n: 1}, %{n: 2}], dropped: 99}).reaches_two == :holds
    end

    # `always(P)` cannot answer `:holds` without a lasso whatever the buffer did, so
    # truncation costs nothing here — the verdict was already the honest one.
    test "leaves the lasso-dependent verdicts exactly as they were" do
      complete = verdicts(%{states: [%{n: 0}, %{n: 1}], dropped: 0})
      truncated = verdicts(%{states: [%{n: 0}, %{n: 1}], dropped: 7})

      assert complete.never_negative == :inconclusive
      assert truncated.never_negative == :inconclusive
    end
  end

  describe "the buffer itself" do
    # The behaviour the work item asked for and no test built: longer than the buffer.
    # 1,201 transitions through the process dictionary, which is milliseconds — and no
    # `Application.put_env`, so nothing here is visible to another test.
    test "reports what it threw away" do
      for i <- 0..1200, do: Runtime.record_transition!(Spec, :tick, %{n: i}, %{n: i + 1})

      trace = Runtime.trace()

      # Bounds rather than equalities: another async test may have set `trace_buffer`
      # smaller, which can only drop MORE. Both of these hold either way.
      assert trace.dropped > 0
      assert length(trace.states) <= 1000
      assert hd(trace.states) != %{n: 0}
    end

    test "and a behaviour inside it reports nothing thrown away" do
      Runtime.record_transition!(Spec, :tick, %{n: 0}, %{n: 1})

      # Two states, one transition — under any buffer this project would accept.
      assert Runtime.trace() == %{states: [%{n: 0}, %{n: 1}], dropped: 0}
    end
  end

  describe "the shape" do
    # A bare list is refused rather than read as complete. Defaulting `dropped` to 0 would
    # have left every existing caller compiling and the truncated one still lying — the
    # argument `ExTLA.Conformance` already makes about its own `status:`.
    test "is required, and the refusal says what to pass" do
      error =
        assert_raise ArgumentError, fn ->
          Runtime.check_temporal_properties(Spec, [%{n: 0}])
        end

      assert Exception.message(error) =~ "not a bare list"
      assert Exception.message(error) =~ "%{states: behaviour, dropped: 0}"
    end
  end

  defp verdicts(behavior), do: Runtime.check_temporal_properties(Spec, behavior)
end
