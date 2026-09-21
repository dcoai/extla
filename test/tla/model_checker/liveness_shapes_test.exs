defmodule TLA.ModelChecker.LivenessShapesTest do
  @moduledoc """
  Every shape in the supported temporal fragment has a spec that **refutes** it (#174).

  Three of the six had none. Replacing the refutation clauses for a bare predicate, for
  `always(eventually(P))` and for `eventually(always(P))` with `nil` — so the checker answers
  "holds" to all three — left the entire suite green. `eventually(always(P))` appeared in no
  spec anywhere in the project; `always(eventually(P))` appeared once and was only ever
  verified.

  The liveness test file next door is titled for "the failure mode this whole slice is
  measured against: a checker that answers 'holds' to everything." Half the fragment was
  exactly that mutant, and the fixtures could not tell.

  ## These are not corpus entries, deliberately

  They carry no TLC oracle. The differential corpus is D-9's acceptance gate and adding to it
  means writing a `.tla` module and regenerating `expected.json` — worth doing, and a bigger
  step than closing a mutation gap. What these assert is that the *refutation path* for each
  shape executes and produces a violation; whether ExTLA's answer matches TLC's is the
  corpus's question. Each model is small enough that its verdict is checkable by reading it.
  """
  use ExUnit.Case, async: true

  alias TLA.ModelChecker

  # `n` starts at 1, so a bare `n == 0` is false in the initial state. A bare predicate is
  # a claim about every initial state, so that refutes it.
  defmodule BarePredicate do
    use TLA.Spec

    variable :n, type: 0..1

    init do
      n = 1
    end

    action :flip do
      n = 1 - n
    end

    temporal :starts_at_zero do
      n == 0
    end
  end

  # 0 → 1 → 2, then 2 loops forever. `n == 0` holds once and never again, so it is reached
  # finitely often and `always(eventually(n == 0))` is refuted.
  defmodule InfinitelyOften do
    use TLA.Spec

    variable :n, type: 0..2

    init do
      n = 0
    end

    action :up do
      require n < 2
      n = n + 1
    end

    action :spin do
      require n == 2
      n = 2
    end

    temporal :always_eventually_zero do
      always(eventually(n == 0))
    end
  end

  # The only cycle is 0 ↔ 1, so `n == 1` keeps coming back and no suffix stays in `n == 0`.
  # That refutes `eventually(always(n == 0))`.
  defmodule EventuallyAlways do
    use TLA.Spec

    variable :n, type: 0..1

    init do
      n = 0
    end

    action :flip do
      n = 1 - n
    end

    temporal :eventually_always_zero do
      eventually(always(n == 0))
    end
  end

  # The Emerson-Lei strong split, which `liveness.ex`'s own moduledoc calls "the reason this
  # is not just Tarjan, then filter". Replacing the `{:strong, index}` branch with `[]` left
  # the whole suite green, because the only strong-fairness fixture is ever verified and `[]`
  # also yields `:ok`.
  #
  # This model needs the split to find its refutation:
  #
  #     tick:  0 -> 1,  1 -> 0,  2 -> 0
  #     stay:  0 -> 0            (a self-loop where `a` is DISABLED)
  #     a:     1 -> 2            (enabled only at 1)
  #
  # The SCC {0, 1} is unfair under SF(a): it visits 1, where `a` is enabled, infinitely often
  # and never takes it. So an unsplit search discards it and reports the property as holding.
  # Restricting to the states where `a` is disabled leaves {0}, whose self-loop is a genuine
  # SF-fair cycle that never reaches 2 — and that refutes the property.
  defmodule StrongSplit do
    use TLA.Spec

    variable :phase, type: 0..2

    init do
      phase = 0
    end

    action :tick do
      require phase == 0 or phase == 1 or phase == 2
      phase = if phase == 0, do: 1, else: 0
    end

    action :stay do
      require phase == 0
      phase = 0
    end

    action :a do
      require phase == 1
      phase = 2
    end

    temporal :always_eventually_two do
      always(eventually(phase == 2))
    end

    fairness(:strong, [:a])
  end

  defp verdict(module) do
    ModelChecker.run(module, %{check_liveness: true})
  end

  test "a bare predicate false in the initial state is refuted" do
    result = verdict(BarePredicate)

    assert result.status == :violation,
           "a bare temporal predicate that is false initially must be refuted"
  end

  test "always(eventually(P)) is refuted when P is reached only finitely often" do
    result = verdict(InfinitelyOften)

    assert result.status == :violation
    # The refuting cycle spins at n == 2, where P (`n == 0`) never holds again.
    assert result.violation.cycle.actions == [:spin]
    assert %{prefix: _, cycle: _} = result.violation
  end

  test "eventually(always(P)) is refuted when not-P keeps coming back" do
    result = verdict(EventuallyAlways)

    assert result.status == :violation
    # The refuting cycle flips between n == 0 and n == 1, so not-P recurs forever.
    assert result.violation.cycle.actions == [:flip, :flip]
    assert %{prefix: _, cycle: _} = result.violation
  end

  test "strong fairness refutes only after the split restricts to disabled states" do
    result = verdict(StrongSplit)

    assert result.status == :violation,
           "the SF-fair self-loop at phase 0 refutes the property, and only the strong " <>
             "split finds it — an unsplit search discards the whole component as unfair"

    # Pinned to the post-split component (#209): the unfair cycle `tick` runs through phase 1,
    # where `a` is enabled and strong fairness forbids staying; the fair one is `stay` at
    # phase 0 alone, where `a` is disabled. A regression that ignored fairness would report
    # the unfair cycle and still be a violation.
    assert %{prefix: _, cycle: cycle} = result.violation
    assert cycle.actions == [:stay]
    assert Enum.all?(cycle.states, &(&1.phase == 0))
  end

  # Without this the three above could pass because the specs are broken in some other way —
  # a deadlock, an unreachable state — rather than because the property was refuted.
  test "each model is otherwise sound, so the refutations are about the properties" do
    for module <- [BarePredicate, InfinitelyOften, EventuallyAlways, StrongSplit] do
      safety = ModelChecker.run(module, %{})

      assert safety.status == :ok,
             "#{inspect(module)} fails without liveness checking, so its liveness verdict " <>
               "is not evidence about the property"
    end
  end
end
