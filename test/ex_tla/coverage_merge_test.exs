defmodule ExTLA.CoverageMergeTest do
  @moduledoc """
  `ExTLA.Coverage.merge/2`, generatively.

  #38 proved the merge by equality against a single-threaded run on four corpus entries
  and one test spec. That catches a rule that is wrong everywhere; it does not catch one
  that is right on those shapes and wrong in general. These tests are about the shapes
  that differ structurally rather than in size — an invariant with no measurable branch
  (`near_misses: nil`, where `nil + nil` would raise and `0` would be a claim), an action
  no state enables, a spec with no temporals and therefore no probes at all, and params
  with a universe that no run exhausts.

  The report is what a run offers as evidence that it checked anything, so a merge that is
  subtly wrong produces a *plausible* report — which is worse than an obviously missing
  one, and which `mix extla.check --strict-coverage` turns into a failed build.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExTLA.{Coverage, ModelChecker, TestSpecs}

  # Four shapes that differ structurally rather than in size, each landing on a different
  # merge rule:
  #
  #   Unreachable — an action no state enables, a countable `near_misses`, and a param
  #                 universe that is exhausted beside one that is never reached
  #   NoBranch    — an invariant whose `near_misses` is nil, where `nil + nil` would raise
  #   Counter     — temporals, so a non-empty probe table with both truth values in it
  #   Cube        — no temporals, so an empty one
  @fixtures [
    {TestSpecs.Unreachable, %{constants: %{modes: MapSet.new([:a, :b])}, check_deadlock: false}},
    {TestSpecs.NoBranch, %{check_deadlock: false}},
    {TestSpecs.Counter, %{constants: %{max: 3}}},
    {TestSpecs.Cube, %{check_deadlock: false}}
  ]

  describe "a parallel run's report, over spec shapes and worker counts" do
    property "matches the single-threaded one on everything order-independent" do
      check all(
              {module, config} <- StreamData.member_of(@fixtures),
              workers <- StreamData.integer(2..8),
              max_runs: 40
            ) do
        one = ModelChecker.run(module, config)
        many = ModelChecker.run(module, Map.put(config, :workers, workers))

        for field <- [:never_enabled, :vacuous, :unreached_params, :terminal_but_live] do
          assert Map.fetch!(many.coverage, field) == Map.fetch!(one.coverage, field),
                 "#{inspect(module)} at #{workers} workers: coverage.#{field}"
        end

        assert many.coverage.invariants == one.coverage.invariants,
               "#{inspect(module)} at #{workers} workers: invariants"

        for {name, entry} <- many.coverage.actions do
          expected = one.coverage.actions[name]

          assert {entry.enabled_in, entry.states_generated} ==
                   {expected.enabled_in, expected.states_generated},
                 "#{inspect(module)} at #{workers} workers: action #{name}"
        end
      end
    end

    # The one field that is a fact about search order rather than about the model. Its
    # split across actions moves; the total says every distinct state was credited once.
    property "credits every distinct state exactly once, however the level divided" do
      check all(
              {module, config} <- StreamData.member_of(@fixtures),
              workers <- StreamData.integer(2..8),
              max_runs: 40
            ) do
        one = ModelChecker.run(module, config)
        many = ModelChecker.run(module, Map.put(config, :workers, workers))

        assert first_discoveries(many) == first_discoveries(one),
               "#{inspect(module)} at #{workers} workers"
      end
    end
  end

  describe "a run that halts at a violation" do
    # Found by the property above, which failed on a fixture whose invariant was refuted.
    # It is not a merge bug: a violating run stops mid-expansion, so its counts are a
    # lower bound rather than a census — which is what `bounded_by: :violation` says, and
    # the reason `04-layer2-model-checker.md`'s list was extended to carry it.
    #
    # Under workers the bound is looser and varies: `dispatch/2` starts every worker in
    # the level at once and halts on the first violation it receives, so how much of that
    # level's work was already merged depends on which worker finished when. The exact
    # counts are therefore NOT comparable across worker counts, and asserting they were
    # would make a flaky test out of correct behaviour.
    test "reports the same violation, and counts that are a lower bound rather than a census" do
      config = %{constants: %{modes: MapSet.new([:a, :b])}, check_deadlock: false}
      one = ModelChecker.run(TestSpecs.Violating, config)

      assert one.status == :violation
      assert one.coverage.bounded_by == :violation

      for workers <- 2..8 do
        many = ModelChecker.run(TestSpecs.Violating, Map.put(config, :workers, workers))

        # What a parallel run still promises, and what D-9 compares.
        assert many.status == :violation
        assert many.violation.property == one.violation.property
        assert many.violation.length == one.violation.length
        assert many.coverage.bounded_by == :violation

        # And what it does not: the census is partial on both sides, and more of the level
        # may have completed before the halt was seen.
        assert many.coverage.actions[:tick].enabled_in >= 1
      end
    end
  end

  describe "the merge itself" do
    # A worker that expanded nothing returns a fresh accumulator, which happens whenever a
    # level has fewer states than workers — so the identity is exercised on nearly every
    # real run rather than only in this test.
    test "a fresh accumulator is a right identity" do
      for {module, config} <- @fixtures do
        accumulated = coordinator(module, config)
        fresh = fresh(module, config)

        assert Coverage.merge(accumulated, fresh) == accumulated,
               "#{inspect(module)}: merging an empty worker changed the report"
      end
    end

    # The coordinator's position is fixed — see `param_universe` below — but the workers
    # within a level complete in whatever order they finish, and `dispatch/2` merges them
    # in that order. If merging were not commutative among them, the report would depend
    # on the scheduler.
    test "workers commute" do
      for {module, config} <- @fixtures do
        base = coordinator(module, config)
        [a, b] = two_workers(module, config)

        assert Coverage.merge(Coverage.merge(base, a), b) ==
                 Coverage.merge(Coverage.merge(base, b), a),
               "#{inspect(module)}: the report depends on which worker finished first"
      end
    end

    test "and associate, so a level may be merged in any grouping" do
      for {module, config} <- @fixtures do
        base = coordinator(module, config)
        [a, b] = two_workers(module, config)

        assert Coverage.merge(Coverage.merge(base, a), b) ==
                 Coverage.merge(base, Coverage.merge(a, b)),
               "#{inspect(module)}: regrouping the merge changed the report"
      end
    end

    # The asymmetry is the point, and it is why `merge/2` is not commutative in its first
    # argument. `param_universe` is a property of the CONSTANTS: the coordinator
    # enumerates it once, on the first initial state, before any worker exists. A worker's
    # copy is all `:unknown`, so taking the right-hand side would replace a computed
    # universe with an unknown one — and `unreached_params` would then name nothing.
    test "param_universe is taken from the left, never merged" do
      {module, config} = hd(@fixtures)

      coordinator = coordinator(module, config)
      worker = fresh(module, config)

      refute coordinator.param_universe == worker.param_universe,
             "the fixture must have a computed universe, or this test proves nothing"

      assert Coverage.merge(coordinator, worker).param_universe == coordinator.param_universe
      refute Coverage.merge(worker, coordinator).param_universe == coordinator.param_universe
    end

    # `nil` is "this invariant has no measurable branch", and `0` is "it was never at
    # risk" — a finding `Coverage.warnings/1` reports. Adding them would raise; coercing
    # nil to 0 would invent the finding.
    test "an invariant with no measurable branch keeps nil near-misses" do
      module = TestSpecs.NoBranch
      config = %{check_deadlock: false}

      merged = Coverage.merge(coordinator(module, config), hd(two_workers(module, config)))

      assert merged.invariants[:non_negative].near_misses == nil
    end
  end

  defp first_discoveries(result) do
    result.coverage.actions |> Map.values() |> Enum.map(& &1.distinct_generated) |> Enum.sum()
  end

  defp inputs(module, config) do
    spec = ExTLA.Spec.Compiled.from_module(module)
    constants = Map.get(config, :constants, %{})
    invariants = ModelChecker.checked_invariants(spec, constants)
    {spec, constants, invariants}
  end

  defp fresh(module, config) do
    {spec, constants, invariants} = inputs(module, config)
    Coverage.init(spec, constants, invariants)
  end

  # What the coordinator holds when it starts dispatching: a fresh accumulator, the
  # initial states observed, and the param universes enumerated — `seed/1` and
  # `note_universes/2`, in that order and for the same reason.
  defp coordinator(module, config) do
    {spec, constants, invariants} = inputs(module, config)
    initial = Enum.map(spec.init, & &1.(constants))

    coverage =
      Enum.reduce(spec.actions, Coverage.init(spec, constants, invariants), fn action, coverage ->
        Coverage.observe_universe(coverage, action, constants, hd(initial))
      end)

    observe(coverage, spec, constants, invariants, initial)
  end

  # Two workers' contributions over disjoint states, which is what a level actually hands
  # out: a state belongs to exactly one worker's batch.
  defp two_workers(module, config) do
    {spec, constants, invariants} = inputs(module, config)

    reachable =
      spec.init
      |> Enum.map(& &1.(constants))
      |> Enum.flat_map(fn state ->
        [state | Enum.map(ModelChecker.successors(spec, constants, state), &elem(&1, 2))]
      end)
      |> Enum.uniq()

    {left, right} = Enum.split(reachable, div(length(reachable) + 1, 2))

    for batch <- [left, right] do
      observe(Coverage.init(spec, constants, invariants), spec, constants, invariants, batch)
    end
  end

  defp observe(coverage, spec, constants, invariants, states) do
    Enum.reduce(states, coverage, fn state, coverage ->
      coverage = Coverage.observe_state(coverage, invariants, constants, state)

      Enum.reduce(spec.actions, coverage, fn action, coverage ->
        bindings = ModelChecker.enabled_bindings(action, constants, state)

        coverage
        |> Coverage.observe_enabled(action.name, bindings)
        |> then(fn c ->
          # An action with no enabled binding generates nothing, and `observe_enabled/3`
          # already declined to record it.
          if bindings == [],
            do: c,
            else: Coverage.observe_generated(c, action.name, length(bindings), 1)
        end)
      end)
    end)
  end
end
