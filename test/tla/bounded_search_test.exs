defmodule TLA.BoundedSearchTest do
  @moduledoc """
  The second search (#47/#56).

  The test that matters is the one where it says **no**: a re-search that only ever agrees
  proves nothing about the search it is checking. So the central case here claims a
  counterexample is shorter than it is, and requires the independent search to contradict
  the claim.
  """

  use ExUnit.Case, async: true

  alias TLA.{BoundedSearch, ModelChecker, Spec, TestSpecs}

  defp broken do
    {Spec.Compiled.from_module(TestSpecs.Broken), %{}}
  end

  defp below_three(spec), do: Enum.find(spec.invariants, &(&1.name == :below_three))

  describe "nothing_violates_before?/4" do
    test "agrees that the checker's counterexample is the shortest" do
      {spec, constants} = broken()
      result = ModelChecker.run(TestSpecs.Broken, %{})
      predicate = &below_three(spec).predicate.(constants, &1)

      assert result.violation.length == 4

      assert BoundedSearch.nothing_violates_before?(spec, constants, predicate, 4)
    end

    # The one that gives the check its power. `Broken` violates at four states; a checker
    # claiming five would be handing back a longer explanation of the same bug, and
    # `expected.json`'s length column catches that only because TLC happened to say four.
    test "contradicts a claim that a longer counterexample was the shortest" do
      {spec, constants} = broken()
      predicate = &below_three(spec).predicate.(constants, &1)

      refute BoundedSearch.nothing_violates_before?(spec, constants, predicate, 5),
             "a violation exists at four states, so five is not shortest"

      refute BoundedSearch.nothing_violates_before?(spec, constants, predicate, 9)
    end

    test "a one-state counterexample is shortest by construction, with no search at all" do
      {spec, constants} = broken()

      # An initial state that refutes the invariant cannot be beaten, so this must not
      # depend on exploring anything — including on the spec being explorable.
      assert BoundedSearch.nothing_violates_before?(spec, constants, fn _ -> false end, 1)
    end
  end

  describe "reachable_within/3" do
    test "zero steps is exactly the initial states" do
      {spec, constants} = broken()

      assert BoundedSearch.reachable_within(spec, constants, 0) == MapSet.new([%{n: 0}])
    end

    test "and it grows one level at a time" do
      {spec, constants} = broken()

      assert BoundedSearch.reachable_within(spec, constants, 1) ==
               MapSet.new([%{n: 0}, %{n: 1}])

      assert BoundedSearch.reachable_within(spec, constants, 2) ==
               MapSet.new([%{n: 0}, %{n: 1}, %{n: 2}])
    end

    test "it stops when the frontier empties, rather than spinning to the bound" do
      {spec, constants} = broken()

      # `Broken` reaches n = 5 and stops. Asking for a thousand steps must cost what six
      # cost, not what a thousand would.
      assert BoundedSearch.reachable_within(spec, constants, 1_000) ==
               BoundedSearch.reachable_within(spec, constants, 6)
    end

    # Two searches, no shared traversal, same answer. This is evidence rather than a
    # tautology precisely because the dedup mechanisms differ: the checker fingerprints a
    # canonical encoding, and this compares state terms.
    test "reaches the same states the checker does, on several specs" do
      cases = [
        {TestSpecs.Broken, %{}},
        {TestSpecs.Cube, %{}},
        {TestSpecs.Counter, %{max: 3}},
        {TestSpecs.TwoStarts, %{}}
      ]

      for {module, constants} <- cases do
        spec = Spec.Compiled.from_module(module)

        result =
          ModelChecker.run(module, %{
            constants: constants,
            invariants: [],
            action_properties: [],
            check_deadlock: false
          })

        found = BoundedSearch.reachable_within(spec, constants, 1_000)

        assert MapSet.size(found) == result.distinct_states,
               "#{inspect(module)}: the independent search found #{MapSet.size(found)} " <>
                 "states, the checker #{result.distinct_states}"
      end
    end
  end
end
