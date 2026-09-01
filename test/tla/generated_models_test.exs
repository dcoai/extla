defmodule TLA.GeneratedModelsTest do
  @moduledoc """
  The agreement properties, run on generated models instead of the six hand-written corpus
  entries (#50).

  `verify_symmetry:` and `parallel_agreement_test.exs` compare **ExTLA against ExTLA**.
  They need no TLA+ and no TLC, so the oracle is the only reason their extent is six —
  every corpus entry costs a hand-written TLA+ module and a TLC run. Removing the oracle
  from the loop makes scenario volume a question of time.

  What these buy is **extent**, not a new kind of coverage: the suite already has the
  shapes the corpus lacks (`TestSpecs.TwoStarts` has two `init` blocks, `symmetry_test.exs`
  exercises reductions). A thousand tiny models exercise more *combinations* of those
  shapes than six large ones can.

  Every failure prints the description that produced it, which is the readable form the
  spec was generated from — and the seed ExUnit reports reproduces it exactly.

  ## What they kill, measured

  Four of #54's mutants were applied to `lib/` and this file run alone:

  | mutant | caught here |
  |---|---|
  | `searches_depth_first` | yes |
  | `drops_a_worker_contribution` | yes |
  | `truncates_the_fingerprint` | yes |
  | `drops_a_binding` | **no** |

  The one that escapes is the interesting one, and it delimits exactly what this file can
  and cannot do.

  **A metamorphic property compares two runs and sees only what differs between them.** A
  defect that affects every arm equally is invisible to it: `drops_a_worker_contribution`
  is caught because one worker and eight disagree, and `drops_a_binding` is not, because
  every arm drops the same binding and they agree perfectly on a wrong answer.

  The three that are caught are not caught by metamorphosis alone. `searches_depth_first`
  and `truncates_the_fingerprint` die to `TLA.BoundedSearch` and `TLA.GraphAudit` — an
  independent *re-derivation*, which is an oracle in miniature. And that is why
  `drops_a_binding` survives even those: they share the spec's guards and transitions
  through `enabled_steps/3`, which is precisely what that mutant patches. `BoundedSearch`'s
  own moduledoc names this sharing as unavoidable, and here is the bill for it.

  **So the differential corpus is not made redundant by any number of generated models.**
  A defect in the shared foundation — what the spec's guards and transitions *mean* — is
  invisible to everything that reads them, however many ways it is read. Only TLC, which
  computes them from a different source, can see it. Generated models buy extent over the
  defects that re-derivation can catch; D-9 buys the ones it cannot.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TLA.{ModelChecker, SpecGenerator, Trace}

  # Each property runs the checker several times per generated model, so the count is
  # chosen to keep this near a second rather than to be impressive. A longer sweep belongs
  # in the mutation job, not on `mix test`'s path.
  @runs 40

  describe "workers" do
    # D-27's claim, at unbounded extent. Level-synchronous BFS exists to preserve the
    # counterexample's LENGTH, which is what D-9's corpus compares — so length is asserted
    # here and not merely the counts.
    property "1, 2, 4 and 8 workers answer identically, length included" do
      check all(description <- SpecGenerator.description(), max_runs: @runs) do
        spec = SpecGenerator.compile(description)
        config = %{check_deadlock: false}

        one = ModelChecker.run(spec, config)

        for workers <- [2, 4, 8] do
          many = ModelChecker.run(spec, Map.put(config, :workers, workers))

          assert {many.status, many.distinct_states, many.transitions, many.diameter} ==
                   {one.status, one.distinct_states, one.transitions, one.diameter},
                 "#{workers} workers disagreed:\n\n#{SpecGenerator.format(description)}"

          if one.violation do
            assert many.violation.length == one.violation.length,
                   "the counterexample changed length at #{workers} workers, which is what " <>
                     "D-27's barrier exists to prevent:\n\n#{SpecGenerator.format(description)}"
          end
        end
      end
    end
  end

  describe "counterexamples" do
    # #47's checks, on whatever the generator finds rather than on the one corpus entry
    # that has a violated invariant.
    property "every counterexample is a behaviour the spec admits" do
      check all(description <- SpecGenerator.description(), max_runs: @runs) do
        spec = SpecGenerator.compile(description)
        result = ModelChecker.run(spec, %{check_deadlock: false})

        if result.violation do
          assert Trace.validate(result.violation, spec, %{}) == :ok,
                 "the checker returned a counterexample the spec does not admit:\n\n" <>
                   SpecGenerator.format(description)
        end
      end
    end

    property "and it is the shortest one there is" do
      check all(description <- SpecGenerator.description(), max_runs: @runs) do
        spec = SpecGenerator.compile(description)
        result = ModelChecker.run(spec, %{check_deadlock: false})

        if result.violation do
          invariant = Enum.find(spec.invariants, &(&1.name == result.violation.property))

          assert TLA.BoundedSearch.nothing_violates_before?(
                   spec,
                   %{},
                   &invariant.predicate.(%{}, &1),
                   result.violation.length
                 ),
                 "an independent search found a shorter violation:\n\n" <>
                   SpecGenerator.format(description)
        end
      end
    end
  end

  describe "max_states" do
    # A bound must change what a run REACHED, never what it concluded about what it
    # reached. A truncated run that flipped a verdict would be the worst failure the tool
    # has, and `:max_states_reached` exists so that "we ran out of budget" is never
    # returned as "it holds".
    property "truncation never turns a violation into a clean run" do
      check all(description <- SpecGenerator.description(), max_runs: @runs) do
        spec = SpecGenerator.compile(description)
        full = ModelChecker.run(spec, %{check_deadlock: false})

        for cap <- [1, 2, 5] do
          bounded = ModelChecker.run(spec, %{check_deadlock: false, max_states: cap})

          assert bounded.status in [:violation, :max_states_reached, :ok]

          # The one thing that must not happen: a bounded run reporting a clean :ok over a
          # model that has a violation, with no sign that it stopped early.
          if full.status == :violation and bounded.status == :ok do
            flunk("""
            a run capped at #{cap} states reported :ok over a model that has a violation,
            without reporting that it was bounded:

            #{SpecGenerator.format(description)}
            """)
          end
        end
      end
    end

    property "and a run that finishes under the cap is identical to an uncapped one" do
      check all(description <- SpecGenerator.description(), max_runs: @runs) do
        spec = SpecGenerator.compile(description)
        full = ModelChecker.run(spec, %{check_deadlock: false})

        generous = ModelChecker.run(spec, %{check_deadlock: false, max_states: 10_000})

        assert {generous.status, generous.distinct_states} == {full.status, full.distinct_states},
               "a cap the run never reached changed the answer:\n\n" <>
                 SpecGenerator.format(description)
      end
    end
  end

  describe "the graph the search builds" do
    property "records exactly the successors the spec admits" do
      check all(description <- SpecGenerator.description(), max_runs: @runs) do
        spec = SpecGenerator.compile(description)

        {result, graph} =
          ModelChecker.explore(spec, %{
            check_deadlock: false,
            liveness_graph: true,
            invariants: []
          })

        assert result.status in [:ok, :violation]

        assert TLA.GraphAudit.audit(spec, %{}, graph) == :ok,
               "the graph is not what the spec admits:\n\n#{SpecGenerator.format(description)}"
      end
    end
  end

  describe "the generator itself" do
    property "produces specs that compile, terminate, and are small enough to read" do
      check all(description <- SpecGenerator.description(), max_runs: @runs) do
        spec = SpecGenerator.compile(description)
        result = ModelChecker.run(spec, %{check_deadlock: false})

        assert result.distinct_states >= 1

        # Bounded by construction: every variable is 0..bound and every guard carries the
        # range condition, so the space cannot exceed the product.
        assert result.distinct_states <=
                 :math.pow(description.bound + 1, length(description.vars))

        assert SpecGenerator.format(description) =~ "vars:"
      end
    end
  end
end
