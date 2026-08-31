defmodule TLA.Temporal.FairnessTest do
  use ExUnit.Case, async: true

  alias TLA.Spec
  alias TLA.Temporal.Fairness
  alias TLA.TestSpecs.{Counter, PerBinding, Swap}

  defp expand(module, constants) do
    spec = Spec.Compiled.from_module(module)
    Fairness.expand(spec, constants, spec.init |> hd() |> apply([constants]))
  end

  describe "expand/3" do
    test "a whole-action declaration is one constraint, with no binding" do
      assert expand(Counter, %{max: 2}) |> Enum.map(&Fairness.describe/1) ==
               ["WF(increment)", "WF(finish)"]
    end

    # §5.2: `\A p \in Procs : SF_vars(Acquire(p))`, not `SF_vars(\E p : Acquire(p))`.
    # Three declarations over two processes are six constraints, and it is the six
    # that make `no_starvation` provable.
    test "a per-binding declaration is one constraint per element" do
      index = expand(PerBinding, %{processes: MapSet.new([:p1, :p2])})

      assert length(index) == 6

      assert index |> Enum.map(&Fairness.describe/1) |> Enum.sort() == [
               "SF(acquire, p: :p1)",
               "SF(acquire, p: :p2)",
               "WF(release, p: :p1)",
               "WF(release, p: :p2)",
               "WF(request, p: :p1)",
               "WF(request, p: :p2)"
             ]
    end

    # The index is the bit order of the graph's enabled bitstrings, so it has to
    # be declaration order, then generator order — and the same on every run.
    test "is in declaration order, and the same every time" do
      constants = %{processes: MapSet.new([:p1, :p2])}
      index = expand(PerBinding, constants)

      assert Enum.map(index, fn {f, _} -> {f.kind, f.action} end) == [
               {:strong, :acquire},
               {:strong, :acquire},
               {:weak, :release},
               {:weak, :release},
               {:weak, :request},
               {:weak, :request}
             ]

      assert expand(PerBinding, constants) == index
    end

    test "scales with the set the quantified param draws from" do
      for n <- 1..4 do
        processes = MapSet.new(for i <- 1..n, do: :"p#{i}")

        # One SF(acquire, p) and two WF(_, p) per process.
        assert length(expand(PerBinding, %{processes: processes})) == 3 * n
      end
    end

    test "a spec that declares no fairness has no constraints" do
      assert expand(Swap, %{}) == []
    end
  end

  describe "describe/1" do
    test "names the kind, the action and the binding it is about" do
      [sf | _] = expand(PerBinding, %{processes: MapSet.new([:p1])})
      [wf | _] = expand(Counter, %{max: 1})

      assert Fairness.describe(sf) == "SF(acquire, p: :p1)"
      assert Fairness.describe(wf) == "WF(increment)"
    end
  end
end
