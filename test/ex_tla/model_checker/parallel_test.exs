defmodule ExTLA.ModelChecker.ParallelTest do
  @moduledoc """
  `ExTLA.ModelChecker.Parallel`'s own behaviour. The comparison against the single-threaded
  checker — which is the correctness gate — is `test/differential/parallel_agreement_test.exs`.
  """

  use ExUnit.Case, async: true

  alias ExTLA.{ModelChecker, TestSpecs}
  alias ExTLA.ModelChecker.Parallel

  describe "what a parallel run refuses" do
    # Beside D-22's symmetry-with-liveness refusal, and phrased the same way: the project
    # raises on an unsound combination rather than warning about it.
    test "workers with check_liveness" do
      assert_raise ArgumentError, ~r/with liveness is refused/, fn ->
        ModelChecker.run(TestSpecs.Counter, %{
          constants: %{max: 2},
          workers: 4,
          check_liveness: true
        })
      end
    end

    test "workers with liveness_graph, which check_liveness implies" do
      assert_raise ArgumentError, ~r/with liveness is refused/, fn ->
        ModelChecker.run(TestSpecs.Counter, %{
          constants: %{max: 2},
          workers: 4,
          liveness_graph: true
        })
      end
    end

    test "the message says what to do instead" do
      error =
        assert_raise ArgumentError, fn ->
          ModelChecker.run(TestSpecs.Counter, %{
            constants: %{max: 2},
            workers: 2,
            check_liveness: true
          })
        end

      assert Exception.message(error) =~ "safety with `workers:`"
      assert Exception.message(error) =~ "liveness on one process"
    end

    test "one worker with liveness is fine — the refusal is about the pairing" do
      result =
        ModelChecker.run(TestSpecs.Counter, %{
          constants: %{max: 2},
          workers: 1,
          check_liveness: true
        })

      assert result.status in [:ok, :violation]
    end
  end

  describe "the shared graph under real concurrency" do
    # #31 established this with 24 processes registering the same state on purpose. This
    # is the same property under the actual search, where the contention is incidental:
    # two workers expanding different states in one level discover a common successor.
    test "a state discovered by two workers has exactly one id" do
      {result, graph} =
        ModelChecker.explore(TestSpecs.Cube, %{workers: 8, invariants: [], action_properties: []})

      # One fingerprint, one node, one id — no state registered twice under contention.
      assert :ets.info(graph.fingerprints, :size) == result.distinct_states
      assert :ets.info(graph.nodes, :size) == result.distinct_states

      ids = graph.nodes |> :ets.tab2list() |> Enum.map(&elem(&1, 0))
      assert length(Enum.uniq(ids)) == length(ids)

      # Every fingerprint points at a node that exists. A worker that lost the
      # `insert_new/2` race reads back the winner's id, so no fingerprint can name an id
      # that was allocated and then abandoned.
      for {_fingerprint, id} <- :ets.tab2list(graph.fingerprints) do
        assert :ets.lookup(graph.nodes, id) != []
      end
    end

    # The gap is documented on `claim/3` and is not a defect: the loser of a race has
    # already taken an id from the atomic, and ids are keys rather than a range. This
    # test says the graph still works when they are not contiguous.
    # #174: setting the batch count and the concurrency both to 1 — making this module
    # fully sequential — left everything green, this file included. Every test here asserts
    # agreement with the single-threaded result, and a sequential run agrees with it
    # perfectly. Agreement is the right property and it cannot see a degraded search.
    #
    # So the two knobs are asserted directly. What this establishes is that the work is
    # divided and the stream is told to run the parts concurrently; it does not establish
    # that the scheduler ran two of them at the same instant, and it says so rather than
    # implying otherwise — a timing assertion would be a flake on the two-core runner
    # (`feedback_no_timing_or_global_state_in_async_tests`) rather than a gate.
    test "the level is divided into more parts than there are workers" do
      level = Enum.to_list(1..200)

      # Eight batches per worker (#41, measured), capped at the level's own size so a small
      # level yields one state per batch rather than empty ones.
      assert length(Parallel.batches(level, 8)) == 64
      assert length(Parallel.batches(level, 1)) == 8
      assert length(Parallel.batches([:only_one], 8)) == 1

      # Every state lands in exactly one batch, whatever the division.
      assert level |> Parallel.batches(8) |> List.flatten() |> Enum.sort() == level
    end

    test "and the stream is told to run that many at once" do
      assert Parallel.concurrency(%{workers: 8}) == 8
      assert Parallel.concurrency(%{workers: 1}) == 1
    end

    test "ids may have gaps, and every recorded state is still reachable by its path" do
      {_result, graph} =
        ModelChecker.explore(TestSpecs.Cube, %{workers: 8, invariants: [], action_properties: []})

      for {id, _record} <- :ets.tab2list(graph.nodes) do
        assert {init_index, path} = ExTLA.StateGraph.path_to(graph, id)
        assert is_integer(init_index)
        assert is_list(path)
      end
    end
  end

  describe "the coverage report a parallel run produces" do
    # The report is the reason a run can be trusted, so a merge that is subtly wrong is
    # worse than one that is obviously missing: `never_enabled` naming an action that WAS
    # enabled is a false statement about the model, and `--strict-coverage` fails the
    # build on it.
    test "is identical to the single-threaded one, everything order-independent" do
      one = ModelChecker.run(TestSpecs.Transfer, transfer_config(1))

      for workers <- [2, 4, 8] do
        many = ModelChecker.run(TestSpecs.Transfer, transfer_config(workers))

        for field <- [:never_enabled, :vacuous, :unreached_params, :terminal_but_live] do
          assert Map.fetch!(many.coverage, field) == Map.fetch!(one.coverage, field),
                 "coverage.#{field} differs at #{workers} workers"
        end

        assert many.coverage.invariants == one.coverage.invariants

        for {name, entry} <- many.coverage.actions do
          expected = one.coverage.actions[name]
          assert entry.enabled_in == expected.enabled_in, "#{name}.enabled_in at #{workers}"

          assert entry.states_generated == expected.states_generated,
                 "#{name}.states_generated at #{workers}"
        end
      end
    end

    # The one field that does NOT match per action, and the invariant that holds instead.
    # `distinct_generated` credits the action that reached a state FIRST, which is a fact
    # about the search order — so the split moves under workers and the total, which says
    # every distinct state was credited exactly once, does not.
    test "credits every distinct state exactly once, however the workers divided them" do
      one = first_discoveries(ModelChecker.run(TestSpecs.Transfer, transfer_config(1)))

      for workers <- [2, 4, 8] do
        many = first_discoveries(ModelChecker.run(TestSpecs.Transfer, transfer_config(workers)))
        assert many == one, "first-discovery total differs at #{workers} workers"
      end
    end

    # The finding that made this merge part of the coordinator's work rather than a later
    # item: a report claiming an action was never enabled when it was is a false statement
    # about the model, and `mix extla.check --strict-coverage` fails the build on it.
    test "names no action as never enabled that a single-threaded run enabled" do
      one = ModelChecker.run(TestSpecs.Transfer, transfer_config(1))
      many = ModelChecker.run(TestSpecs.Transfer, transfer_config(8))

      refute one.coverage.never_enabled ==
               Enum.map(one.coverage.actions, fn {name, _} -> name end),
             "the fixture must enable some action, or this test proves nothing"

      assert many.coverage.never_enabled == one.coverage.never_enabled
    end
  end

  describe "workers: 1" do
    # The parallel path is opt-in and the sequential one is what the corpus is measured
    # against, so `workers: 1` must not quietly become a one-worker parallel run.
    test "takes the single-threaded path and is unchanged" do
      config = %{constants: %{max: 3}}

      one = ModelChecker.run(TestSpecs.Counter, config)
      default = ModelChecker.run(TestSpecs.Counter, Map.put(config, :workers, 1))

      assert one.distinct_states == default.distinct_states
      assert one.coverage == default.coverage
      assert one.warnings == default.warnings
    end
  end

  defp transfer_config(workers) do
    %{
      constants: %{accounts: MapSet.new([:alice, :bob]), max_balance: 2},
      state_constraint: fn state -> length(state.log) <= 1 end,
      check_deadlock: false,
      workers: workers
    }
  end

  defp first_discoveries(result) do
    result.coverage.actions |> Map.values() |> Enum.map(& &1.distinct_generated) |> Enum.sum()
  end
end
