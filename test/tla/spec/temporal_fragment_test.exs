defmodule TLA.Spec.TemporalFragmentTest do
  @moduledoc """
  The one gate holding the four copies of §5.1's fragment to each other (#277).

  ## Why four

  A temporal formula is enumerated, shape by shape, in four places:

  | Where | What it does with a shape it does not know |
  |---|---|
  | `TLA.Spec.Temporal`'s `@nesting` | refuses it, at compile time — since #277 |
  | `TLA.ModelChecker.Liveness.shape/4` | raised `ArgumentError`, under `check_liveness: true` |
  | `TLA.GenServer.Runtime.verdict/3` | had no clause: `FunctionClauseError` under `mix tla.simulate` |
  | `TLA.Coverage.walk/3` | had no clause: `FunctionClauseError`, under the DEFAULT config |

  That is this project's recurring defect — a hand-kept enumeration that stops being true
  without saying so — in its most expensive form, because each copy was reached by a
  different door and none of them agreed with `02-dsl-semantics.md` §5.1's grammar, which
  was recursive and admitted formulas no copy could evaluate.

  ## What holds them together

  The shapes are **derived from the bound itself** — `TLA.Spec.Temporal.nesting/0`, the
  table the parser enforces — rather than listed again here. A second list would be the
  same defect one level up: widen the fragment, and a hand-written gate would go on
  asserting the old seven shapes while the file whose job is to notice says nothing.

  So the shapes are the paths through that table, each needing a property below, and every
  one is driven through all four consumers. Widening the fragment in one place fails this.
  """
  use ExUnit.Case, async: true

  alias TLA.{Coverage, ModelChecker, Spec}

  # One temporal per shape of the fragment, on a spec whose whole state space is three
  # states, so every property below is settled rather than merely evaluated.
  defmodule EveryShape do
    @moduledoc false
    use TLA.Spec

    constant :procs, default: [:p1, :p2]

    variable :n, type: 0..2

    init do
      n = 0
    end

    action :tick do
      require n < 2
      n = n + 1
    end

    terminal :done do
      n == 2
    end

    temporal :pred do
      n == 0
    end

    temporal :always_pred do
      always(n <= 2)
    end

    temporal :eventually_pred do
      eventually(n == 2)
    end

    temporal :always_eventually do
      always(eventually(n == 2))
    end

    temporal :eventually_always do
      eventually(always(n == 2))
    end

    temporal :leads_to do
      (n == 0) ~> (n == 2)
    end

    temporal :always_leads_to do
      always((n == 1) ~> (n == 2))
    end

    # The quantifier, at the formula position, wrapping one of the shapes above.
    temporal :quantified do
      Enum.all?(^procs, fn _p -> eventually(n == 2) end)
    end

    # And the quantifier as a PREDICATE, under a temporal operator — `always(pred)`, which
    # is what made this a fix rather than a stricter grammar.
    temporal :always_quantified_pred do
      always(Enum.all?(^procs, fn p -> is_atom(p) end))
    end
  end

  @properties [
    :pred,
    :always_pred,
    :eventually_pred,
    :always_eventually,
    :eventually_always,
    :leads_to,
    :always_leads_to,
    :quantified,
    :always_quantified_pred
  ]

  describe "every shape of the fragment" do
    test "compiles" do
      names = Spec.Compiled.from_module(EveryShape).temporals |> Enum.map(& &1.name)

      assert Enum.sort(names) == Enum.sort(@properties)
    end

    # `Liveness.shape/4` is reached only with `check_liveness: true`, which is why its raise
    # was invisible for so long: the default configuration never looked at the formula.
    test "is evaluated by the model checker, and reaches a verdict" do
      result =
        ModelChecker.run(EveryShape, %{
          constants: %{procs: [:p1, :p2]},
          check_liveness: true,
          temporals: @properties
        })

      assert result.status in [:ok, :violation]
    end

    # The door `mix tla.simulate` and Layer 3 come through. A behaviour, not a state graph.
    test "is evaluated by the runtime checker, over a behaviour" do
      # `dropped: 0` is a claim about this list, and it is true: it was written here, not
      # kept in a bounded buffer (#278).
      behavior = %{states: [%{n: 0}, %{n: 1}, %{n: 2}], dropped: 0}

      verdicts = TLA.GenServer.Runtime.check_temporal_properties(EveryShape, behavior)

      assert Enum.sort(Map.keys(verdicts)) == Enum.sort(@properties)

      for {name, verdict} <- verdicts do
        assert verdict in [:holds, :violated, :inconclusive],
               "#{name} returned #{inspect(verdict)}"
      end
    end

    # The door that opens by default: coverage builds a probe per predicate position on
    # every run, whether or not liveness was asked for.
    test "is walked by the coverage probes" do
      spec = Spec.Compiled.from_module(EveryShape)
      coverage = Coverage.init(spec, %{procs: [:p1, :p2]}, spec.invariants)

      # One probe per predicate position, so a `~>` contributes two and the rest one each;
      # what matters is that `walk/3` reached every property rather than raising on one.
      properties = coverage.probes |> Map.keys() |> Enum.map(fn {name, _bound, _role} -> name end)

      assert Enum.sort(Enum.uniq(properties)) == Enum.sort(@properties)
    end

    # And by the door that opens without anyone asking: a default run builds the probes
    # above before the search starts, which is where `always(Enum.all?(…))` used to die.
    test "does not raise on a default run, which asks for no liveness at all" do
      result = ModelChecker.run(EveryShape, %{constants: %{procs: [:p1, :p2]}})

      assert result.status == :ok
      assert Enum.any?(result.warnings, &(&1 =~ "declared and not checked"))
    end
  end

  describe "the fragment's bound" do
    # The assertion that keeps this file honest. `nesting/0` is what the parser enforces;
    # the shapes are the paths through it, and every path needs a property above. Widen the
    # table without widening this file and the two disagree, here, at test time — rather
    # than in a consumer, at run time, on someone's specification.
    test "has a property above for every shape it admits" do
      derived = paths(Spec.Temporal.nesting())

      assert length(derived) == 7, """
      the fragment's table admits #{length(derived)} shapes, not the seven this gate was
      written for:

        #{Enum.map_join(derived, "\n  ", &inspect/1)}

      The fragment was widened (or narrowed) in `TLA.Spec.Temporal`. Add the shape to
      `EveryShape` and to `@properties` here, to §5.1's grammar, and to the three consumers
      — `Liveness.shape/4`, `GenServer.Runtime.verdict/3` and `Coverage.walk/3` — or this
      is exactly the drift this file exists to catch.
      """

      # Named, so the failure above is legible rather than a bare count.
      assert Enum.sort(derived) ==
               Enum.sort([
                 :pred,
                 {:always, :pred},
                 {:always, :eventually},
                 {:always, :~>},
                 {:eventually, :pred},
                 {:eventually, :always},
                 {:~>, :pred}
               ])
    end

    # Anti-vacuity, in the shape #164 taught: `paths/1` builds its list from the table's
    # `:formula` entries, so a table those stopped matching would yield the bare predicate
    # and nothing else — and every assertion above would compare a list of one against a
    # list of one and report green.
    test "is a table the parser reads, not a list this file keeps" do
      operators = for {{op, :formula}, _inner} <- Spec.Temporal.nesting(), do: op

      assert Enum.sort(operators) == [:always, :eventually, :~>]
    end
  end

  # A shape is a path through the nesting table: a bare predicate, an operator applied to a
  # predicate, or an operator applied to an operator applied to a predicate. `~>` takes
  # predicates, so it never extends.
  defp paths(nesting) do
    tops = for {{op, :formula}, inner} <- nesting, do: {op, inner}

    [:pred] ++
      Enum.flat_map(tops, fn {op, inner} ->
        [{op, :pred} | for({{nested, ^inner}, _} <- nesting, do: {op, nested})]
      end)
  end
end
