defmodule TLA.ModelChecker.Parallel do
  @moduledoc """
  Parallel state exploration: one coordinator, N workers, one shared graph.

  `06-architecture.md` §Concurrency Architecture draws it, and §Phase 4 admits it "only
  once the single-threaded checker is correct and has been profiled" — the differential
  corpus establishes the first and `bench/search_profile.baseline.md` the second.

  ## Level-synchronous BFS, and why it is not negotiable

  Each round expands **one whole BFS level** across the workers, and no worker starts on
  level *k+1* until every worker has finished level *k*.

  That costs a barrier per level, and it buys the project's acceptance criterion. D-9's
  differential corpus compares the **length** of the shortest counterexample against
  TLC's. Length, not route: two searches may return different traces of the same length
  and the corpus still holds. A free-running frontier — workers taking whatever is queued,
  in whatever order they get to it — does not preserve length, because a violating state
  can be reached along a longer path before the shorter one has been expanded. Trading
  that for throughput would be trading away the thing that says the checker is right.

  Level-synchrony also makes the answer *deterministic* in the ways that are checked:
  every state discovered while expanding level *k* has depth *k+1*, so whichever worker
  reports a violation first, the trace it reports is the same length.

  ## Work sharing, not stealing

  The coordinator pushes a batch to each worker and waits. Workers never take work from
  one another, so the only structure two processes touch at once is ETS — which #31 made
  `:public` and race-free, and which `bench/search_profile.baseline.md` measures at a
  fraction of a percent of the search.

  ## Why the workers, and not the coordinator, register states

  A worker computes its states' successors *and* calls `StateGraph.add_state/5` on them.
  It would be simpler to send successors back and have the coordinator register them, and
  it would also be nearly pointless: since #33 that function performs fingerprinting and
  §6 validation as well as the ETS write, and the three together are 77% of the `raft`
  search. Registering centrally would leave about a quarter of the work parallel, which
  Amdahl caps near 1.3x however many cores are added.

  What makes it safe is #31: `insert_new/2` is atomic, so of two workers that discover the
  same state in the same level exactly one claims it and the other reads back the winner's
  id. That is also what makes the accumulators *summable* — see `merge/2`.

  ## What is refused

  Liveness. `workers: n > 1` with `check_liveness: true` (or `liveness_graph: true`)
  raises in `TLA.ModelChecker`, beside D-22's symmetry-with-liveness refusal and for a
  similar reason: the edge table and ENABLED bits are per-struct maps, so a parallel run
  would answer from a graph missing the edges other workers found.

  ## `max_states` means the same thing here as on one process

  The limit is checked by each worker, before each state, against the count in the shared
  fingerprint table (`StateGraph.live_state_count/1`) rather than against its own
  accumulator — which holds only that worker's fragment while a level is in flight. So the
  rule is the single-threaded one: the search stops once the graph has passed the budget,
  and what it reports is the count it actually reached rather than the limit it was given.

  The overshoot is what the other workers had in flight at that moment, bounded by the
  batch. Checking once per level instead would have been simpler and would have made the
  overshoot a whole BFS level — thousands of states on `raft` — and a budget that can be
  exceeded twentyfold is not a budget.

  ## What comes back, and why summing it is exact

  A worker returns its own accumulators — counts, the marked-state sets, and a
  `TLA.Coverage` — all starting from zero rather than from the coordinator's values, so
  each is that worker's *contribution*. `merge/2` here and `TLA.Coverage.merge/2` combine
  them.

  Summing is exact rather than approximate, and that is a property of `insert_new/2`: a
  state is observed by exactly one worker (the one that claimed its fingerprint) and a
  `{state, action}` pair is expanded by exactly one worker (the one holding that state in
  its batch). Nothing is counted twice because nothing is *done* twice.
  """

  alias TLA.{Coverage, ModelChecker, StateGraph}

  @doc """
  Explore from a seeded run — one whose `frontier` holds the initial states — and return
  the completed run, in the same shape `TLA.ModelChecker`'s single-threaded search
  returns. `check_temporals/1` and `finish/2` do not know which one produced it.
  """
  @spec explore(ModelChecker.Run.t()) :: ModelChecker.Run.t()
  def explore(run) do
    level = :queue.to_list(run.frontier)
    levels(%{run | frontier: :queue.new()}, level)
  end

  # The frontier is a list rather than a queue between levels: it is consumed whole, in
  # one round, and never appended to while it is being read.
  defp levels(run, []), do: run

  defp levels(run, level) do
    case dispatch(run, level) do
      {:violation, run} -> run
      {:ok, %{outcome: :max_states_reached} = run, _next} -> run
      {:ok, run, next} -> levels(run, next)
    end
  end

  defp dispatch(run, level) do
    level
    |> batches(run.config.workers)
    |> Task.async_stream(&expand_batch(run, &1),
      ordered: false,
      timeout: :infinity,
      max_concurrency: run.config.workers
    )
    |> Enum.reduce_while({:ok, run, []}, fn {:ok, worker}, {:ok, run, next} ->
      # Halting closes the stream, which shuts down the workers still running. A violation
      # anywhere in the level ends the level: every state in it has the same depth, so no
      # worker still running could report a shorter counterexample than this one.
      #
      # `:max_states_reached` does NOT halt here. It is a budget rather than a finding, and
      # every worker in this level has already hit the same shared count — collecting them
      # costs nothing and keeps the reported totals complete for the work that was done.
      # `levels/2` stops on the merged outcome.
      case worker.outcome do
        {:violation, _trace} -> {:halt, {:violation, merge(run, worker)}}
        _ -> {:cont, {:ok, merge(run, worker), :queue.to_list(worker.frontier) ++ next}}
      end
    end)
  end

  # Eight batches per worker, dealt round-robin rather than cut into contiguous chunks.
  #
  # Round-robin because states adjacent in a level are often adjacent in the spec's
  # structure too — the same action from neighbouring states — so contiguous chunks tend
  # to hand one worker all the expensive states and another all the cheap ones.
  #
  # Eight rather than one because it was measured (#41). `Task.async_stream` hands a
  # worker its next batch as soon as it finishes one, so cutting a level finer lets the
  # workers that drew cheap states absorb the stragglers instead of idling at the barrier.
  # On `raft_election` at 8 workers, interleaved and compared on minima: x1 1.00, x8 1.04,
  # x16 1.05, x32 1.00 — it pays until the per-batch overhead outgrows the rebalancing,
  # which it does before x32. Eight sits on the plateau and keeps the task count down on
  # small levels.
  #
  # Nothing is asked for. The count is derived from the workers, and `group_by/3` caps it
  # at the level's own size: a level with fewer states than parts yields one state per
  # batch rather than empty ones.
  @batches_per_worker 8

  defp batches(level, workers) do
    parts = workers * @batches_per_worker

    level
    |> Enum.with_index()
    |> Enum.group_by(fn {_state, index} -> rem(index, parts) end, fn {state, _} -> state end)
    |> Map.values()
  end

  # A worker is the sequential search restricted to one batch and one level: it expands
  # each state through `expand_one/3` — the checker's own `expand/3` — and whatever lands
  # in its frontier is its share of the next level.
  #
  # Its accumulators start at zero rather than at the coordinator's values, so what comes
  # back is this worker's *contribution* and `merge/2` can add them. The ETS tables in the
  # graph are the same tables; only the struct around them is private to the worker.
  defp expand_batch(run, batch) do
    run = %{
      run
      | graph: zeroed(run.graph),
        # A fresh accumulator, not the coordinator's: a worker handed the coordinator's
        # would return it plus its own contribution, and merging that would count the
        # seed twice. `TLA.Coverage.merge/2` is written for contributions.
        coverage: Coverage.init(run.spec, run.config.constants, run.invariants),
        found: 0,
        frontier: :queue.new()
    }

    Enum.reduce_while(batch, run, fn {id, state}, run ->
      # `max_states` is checked here, before each state, against the count in the SHARED
      # table — so it means on eight processes what it means on one: the search stops once
      # the graph has passed the budget, and the overshoot is whatever the other workers
      # had in flight when it did. Checking once per level instead would have made the
      # overshoot a whole BFS level, which on `raft` is thousands of states — a budget that
      # can be exceeded twentyfold is not a budget.
      if StateGraph.live_state_count(run.graph) > run.config.max_states do
        {:halt, %{run | outcome: :max_states_reached}}
      else
        case ModelChecker.expand_one(run, id, state) do
          {:ok, run} -> {:cont, run}
          {:violation, run, trace} -> {:halt, %{run | outcome: {:violation, trace}}}
        end
      end
    end)
  end

  defp zeroed(graph) do
    %{
      graph
      | state_count: 0,
        transition_count: 0,
        diameter: 0,
        initial_states: MapSet.new(),
        deadlocked: MapSet.new(),
        terminal: MapSet.new()
    }
  end

  # Summing counts across workers is exact, and that is a property of `insert_new/2`
  # rather than of arithmetic: of two workers that discover the same state, exactly one
  # claims the fingerprint and increments its own `state_count`. Nothing is counted twice
  # because nothing is *claimed* twice. Transitions partition the same way — each worker
  # generates its own batch's successors and no other's.
  #
  # `diameter` is a max of what the workers report, and NOT the coordinator's level
  # counter — which under level-synchrony would give the same answer, and was considered
  # and rejected (#39). The graph's own `record.depth` is `depth(parent) + 1`, computed in
  # `claim/3` from the parent pointer, so a max over it is the same quantity the
  # single-threaded search reports and is derived from the same place. Reading the level
  # counter instead would make the reported depth a fact about the coordinator's
  # bookkeeping rather than about the graph — a second source of truth for a number the
  # differential corpus compares against TLC.
  defp merge(run, worker) do
    graph = run.graph
    from = worker.graph

    graph = %{
      graph
      | state_count: graph.state_count + from.state_count,
        transition_count: graph.transition_count + from.transition_count,
        diameter: max(graph.diameter, from.diameter),
        initial_states: MapSet.union(graph.initial_states, from.initial_states),
        deadlocked: MapSet.union(graph.deadlocked, from.deadlocked),
        terminal: MapSet.union(graph.terminal, from.terminal)
    }

    # `outcome` is taken from the worker only when it is a violation, and `dispatch/2`
    # halts on that — so a later worker's `:ok` cannot overwrite it.
    outcome = if run.outcome == :ok, do: worker.outcome, else: run.outcome

    %{
      run
      | graph: graph,
        coverage: Coverage.merge(run.coverage, worker.coverage),
        found: run.found + worker.found,
        outcome: outcome
    }
  end
end
