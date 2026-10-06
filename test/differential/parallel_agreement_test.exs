# The corpus, at 1, 2, 4 and 8 workers.
#
# `differential_test.exs` establishes that the single-threaded checker agrees with TLC on
# every entry. This file establishes that a parallel run agrees with the single-threaded
# one — so agreement with TLC is transitive, without paying for six more TLC-shaped
# comparisons per worker count.
#
# The comparison is deliberately NOT `==` on the two results: `duration_ms` differs by
# construction, and state ids are allocated at discovery so they differ by discovery
# order. What is compared is every field the corpus itself compares, plus the coverage
# report and the accumulators a parallel run has to merge to get those right.
#
# `06-architecture.md` §Phase 4 and D-9 are the reason this file exists at all: a wrong
# answer computed on eight cores is still wrong, and parallelism makes every correctness
# bug harder to reproduce.
defmodule ExTLA.Differential.ParallelAgreementTest do
  use ExUnit.Case, async: false

  @moduletag verifies: [
               "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Differential testing against TLC",
               "spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/Module: `ExTLA.ModelChecker.Parallel`"
             ]

  alias ExTLA.ModelChecker

  @worker_counts [2, 4, 8]

  # The whole corpus would be six entries at four worker counts. `raft_election` alone is
  # 58,359 states, so the sweep runs on the entries that are cheap and exhaustive, and
  # raft — the one large enough for workers to be doing anything real — gets its own test
  # at the top count.
  @sweep [
    %{name: "die_hard", module: ExTLA.Differential.DieHard, constants: %{}},
    %{
      name: "two_phase_commit",
      module: ExTLA.Differential.TwoPhaseCommit,
      constants: %{rms: MapSet.new([:r1, :r2, :r3])}
    },
    %{
      name: "distributed_lock",
      module: ExTLA.Differential.DistributedLock,
      constants: %{processes: MapSet.new([:p1, :p2]), resources: MapSet.new([:r1, :r2])}
    },
    %{
      name: "bounded_buffer",
      module: ExTLA.Differential.BoundedBuffer,
      constants: %{
        producers: MapSet.new([:p1, :p2]),
        consumers: MapSet.new([:c1, :c2]),
        buffer_size: 3,
        max_items: 6
      }
    }
  ]

  @raft %{
    name: "raft_election",
    module: ExTLA.Differential.RaftElection,
    constants: %{servers: MapSet.new([:s1, :s2, :s3]), max_term: 2}
  }

  describe "a parallel run answers what the single-threaded one answers" do
    for entry <- @sweep, workers <- @worker_counts do
      test "#{entry.name} at #{workers} workers", _ctx do
        entry = unquote(Macro.escape(entry))
        assert_agrees(entry, unquote(workers))
      end
    end

    @tag timeout: 300_000
    test "raft_election at 8 workers" do
      assert_agrees(@raft, 8)
    end
  end

  describe "the counterexample a parallel run reports" do
    # The property D-9 actually asserts, and the reason the search is level-synchronous.
    # A parallel run may return a different trace of the same length and the corpus still
    # holds; a free-running frontier could return a LONGER one, which would not.
    test "is the same length as the single-threaded one, on every violated invariant" do
      entry = %{
        name: "distributed_lock",
        module: ExTLA.Differential.DistributedLock,
        constants: %{processes: MapSet.new([:p1, :p2]), resources: MapSet.new([:r1, :r2])}
      }

      spec = ExTLA.Spec.Compiled.from_module(entry.module)

      for invariant <- spec.invariants, workers <- @worker_counts do
        one = check(entry, 1, invariants: [invariant.name])
        many = check(entry, workers, invariants: [invariant.name])

        assert many.status == one.status,
               "#{invariant.name} at #{workers} workers: #{inspect(many.status)} " <>
                 "vs #{inspect(one.status)} on one"

        if one.status == :violation do
          assert many.violation.property == one.violation.property
          assert many.violation.length == one.violation.length
        end
      end
    end
  end

  describe "halting" do
    test "a violation is reported once, not once per worker" do
      # `Broken`'s invariant is refuted at depth 4 and its state space keeps going to
      # n == 5, so there is a level with several states in it when the violation is
      # found — the shape where a per-worker report would show up as duplicates.
      for workers <- @worker_counts do
        result = ModelChecker.run(ExTLA.TestSpecs.Broken, %{workers: workers})

        assert result.status == :violation
        assert result.violation.property == :below_three

        assert result.violation.length ==
                 ModelChecker.run(ExTLA.TestSpecs.Broken, %{}).violation.length
      end
    end
  end

  describe "max_states under workers" do
    # The reading, by name: `max_states` is a budget checked BEFORE expanding each state,
    # against the count in the shared table — so the search stops once the graph has passed
    # the budget, exactly as it does on one process, and the overshoot is what the other
    # workers had in flight at that moment.
    @tag timeout: 300_000
    test "stops past the budget and reports the count it actually reached" do
      limit = 1_000

      for workers <- [1 | @worker_counts] do
        {result, graph} =
          ModelChecker.explore(@raft.module, %{
            constants: @raft.constants,
            workers: workers,
            max_states: limit,
            invariants: [],
            action_properties: []
          })

        assert result.status == :max_states_reached
        assert result.coverage.bounded_by == :max_states

        # The count is a fact about the run, not the limit it was given — the same honesty
        # `:max_states_reached` exists for one level up, where "we ran out of budget" must
        # not be returned as "it holds".
        assert result.distinct_states == :ets.info(graph.fingerprints, :size),
               "at #{workers} workers the reported count is not the graph's"

        assert result.distinct_states >= limit
        assert result.distinct_states < 58_359, "the limit did nothing at #{workers} workers"

        # Measured at 2 to 25 across worker counts. The bound is generous; what it
        # discriminates against is checking the limit once per LEVEL, which on `raft` at
        # this budget would overshoot by thousands rather than by tens.
        assert result.distinct_states - limit <= 200,
               "overshoot of #{result.distinct_states - limit} at #{workers} workers is a " <>
                 "level rather than a batch"
      end
    end

    test "a state space smaller than the budget is not bounded at any worker count" do
      for workers <- [1 | @worker_counts] do
        result =
          ModelChecker.run(ExTLA.TestSpecs.Cube, %{
            workers: workers,
            max_states: 1_000,
            check_deadlock: false
          })

        assert result.status == :ok, "the budget fired early at #{workers} workers"
        assert result.distinct_states == 8
        assert result.coverage.bounded_by == :none
      end
    end
  end

  describe "shapes that are not a full level" do
    # `Broken` is a chain: one state per BFS level, six levels. With eight workers every
    # level has fewer states than workers, so most workers are handed no batch at all —
    # and `batches/2` must not produce an empty batch for them, nor a level of `[]` that
    # reads as "the search is finished".
    test "a level smaller than one batch completes" do
      config = %{invariants: [], action_properties: []}
      one = ModelChecker.run(ExTLA.TestSpecs.Broken, config)
      many = ModelChecker.run(ExTLA.TestSpecs.Broken, Map.put(config, :workers, 8))

      assert many.status == one.status
      assert many.distinct_states == one.distinct_states
      assert many.diameter == one.diameter
    end
  end

  defp assert_agrees(entry, workers) do
    one = explore(entry, 1)
    many = explore(entry, workers)

    fields = [
      :status,
      :distinct_states,
      :transitions,
      :diameter,
      :deadlock,
      :states_found,
      :terminal,
      :deadlocked,
      :initial_states,

      # The report is what a run offers as evidence it checked anything, so a merge that
      # is subtly wrong here is worse than a missing one: `never_enabled` naming an action
      # that WAS enabled is a false statement about the model.
      #
      # `coverage` is compared with `distinct_generated` folded to its total. That field
      # attributes a state to the action that reached it FIRST, which is a fact about the
      # search order and not about the model — `two_phase_commit` credits
      # `rm_rcv_abort_msg` with 152 first discoveries on one process and 118 on two, and
      # the total is 287 either way. Comparing the split would assert something neither
      # run promises; comparing the total asserts the thing that must hold, which is that
      # every distinct state was credited exactly once.
      :coverage,
      :first_discoveries
    ]

    for field <- fields do
      assert Map.fetch!(many, field) == Map.fetch!(one, field),
             "#{entry.name} at #{workers} workers: #{field} was " <>
               "#{inspect(Map.fetch!(many, field))}, one worker said " <>
               "#{inspect(Map.fetch!(one, field))}"
    end
  end

  defp explore(entry, workers) do
    {result, graph} =
      ModelChecker.explore(entry.module, %{
        constants: entry.constants,
        workers: workers,
        invariants: [],
        action_properties: []
      })

    # The accumulators the corpus reads through the graph rather than the result. They are
    # what `merge/2` has to get right, and a run that unioned them wrong would still
    # report a plausible `distinct_states`.
    #
    # Compared by SIZE, not by contents. A state id is allocated at discovery, and
    # discovery order under workers is not the sequential order — so the same terminal
    # state is id 4454 on one process and 4549 on eight. The ids are keys, never a
    # meaning; what has to agree is how many states were marked, and `distinct_states`
    # above already establishes that both runs found the same states to mark.
    Map.merge(result, %{
      terminal: MapSet.size(graph.terminal),
      deadlocked: MapSet.size(graph.deadlocked),
      initial_states: MapSet.size(graph.initial_states),
      coverage: comparable(result.coverage),
      first_discoveries:
        result.coverage.actions |> Map.values() |> Enum.map(& &1.distinct_generated) |> Enum.sum()
    })
  end

  defp check(entry, workers, opts) do
    ModelChecker.run(
      entry.module,
      Map.merge(
        %{constants: entry.constants, workers: workers, action_properties: []},
        Map.new(opts)
      )
    )
  end

  # Everything about the report except the one field whose value is a fact about the
  # search order. See the note on `:coverage` above.
  defp comparable(coverage) do
    actions =
      Map.new(coverage.actions, fn {name, entry} ->
        {name, Map.delete(entry, :distinct_generated)}
      end)

    %{coverage | actions: actions}
  end
end
