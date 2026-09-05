defmodule TLA.ProfileParallelTest.Spec do
  @moduledoc """
  Two independent counters, so the state space is a grid rather than a line and every BFS level
  is wide enough for `Task.async_stream` to have something to split. 961 states at the default
  constant — a line would hand one worker everything and the merge would never be exercised.
  """
  use TLA.Spec

  constant :max, default: 30

  variable :a, type: 0..^max
  variable :b, type: 0..^max

  init do
    a = 0
    b = 0
  end

  action :bump_a do
    require a < ^max

    a = a + 1
  end

  action :bump_b do
    require b < ^max

    b = b + 1
  end

  invariant :costly do
    Enum.all?(1..20, fn i -> rem(i, 7) != 0 or a >= 0 end)
  end

  invariant :cheap do
    b >= 0
  end
end

defmodule TLA.ProfileParallelTest do
  @moduledoc """
  `TLA.Profile` under `--workers` (#116, #131).

  Reductions are per-process, so a profile taken on N workers has to sum N contributions rather
  than report whichever process happened to be asked. This is the property a merge can silently
  break: the totals stay plausible while the split across declarations is scrambled, so every
  assertion here is **per declaration** and none of them is an aggregate.
  """
  use ExUnit.Case, async: true

  alias TLA.ModelChecker

  @spec_module TLA.ProfileParallelTest.Spec
  @constants %{max: 30}

  defp profile(workers) do
    ModelChecker.run(@spec_module, %{constants: @constants, profile: true, workers: workers}).profile
  end

  # The same two-reduction margin `TLA.ProfileTest` uses, for the same measured reason: a
  # per-evaluation floor can only be pushed UP, by an evaluation that never ran uninterrupted,
  # and eight workers on a sixteen-thread box beside the rest of the async suite is exactly that
  # condition. Asserting equality here would ship the flake #129 is open about.
  #
  # The counts are a different matter and are asserted exactly. They are a function of the
  # search, so a count that moved would mean the parallel run explored something different —
  # which is a real defect and not a measurement artefact.
  @margin 2

  defp counts(profile) do
    Map.new(profile.declarations, fn {key, entry} -> {key, entry.evaluations} end)
  end

  defp drift(a, b) do
    for {key, entry} <- a.declarations,
        other = Map.fetch!(b.declarations, key),
        abs(entry.per_eval - other.per_eval) > @margin,
        do: {key, entry.per_eval, other.per_eval}
  end

  describe "the totals survive the split" do
    setup do
      %{one: profile(1)}
    end

    # Following the corpus's own worker sweep: agreement at one worker count is agreement with
    # the coordinator, not with parallelism.
    for workers <- [2, 4, 8] do
      test "#{workers} workers report what one worker reports", %{one: one} do
        many = profile(unquote(workers))

        assert counts(many) == counts(one)
        assert drift(many, one) == []
      end
    end

    test "and the evaluation counts do too, which is a claim about the SEARCH", %{one: one} do
      # A count that moved under workers would mean the search itself changed — the thing
      # `parallel_agreement_test.exs` exists to refuse — rather than the merge being wrong.
      for {key, entry} <- profile(8).declarations do
        assert entry.evaluations == Map.fetch!(one.declarations, key).evaluations,
               "#{inspect(key)} was evaluated a different number of times on 8 workers"
      end
    end

    test "an aggregate assertion would not have caught a scrambled split", %{one: one} do
      # Stated as a test so the reason every assertion here is per-declaration is not left to a
      # comment. The sum survives any permutation of the per-declaration values, so a merge that
      # credited `costly`'s evaluations to `cheap` would pass an aggregate check and fail these.
      many = profile(4)
      totals = fn map -> map |> Map.values() |> Enum.sum() end

      assert totals.(counts(many)) == totals.(counts(one))
      assert counts(many) == counts(one)

      scrambled =
        counts(one)
        |> Map.keys()
        |> Enum.zip(counts(one) |> Map.values() |> Enum.reverse())
        |> Map.new()

      assert totals.(scrambled) == totals.(counts(one)),
             "the permutation has to preserve the sum, or it does not make the point"

      assert scrambled != counts(one),
             "the permutation has to actually move something — if every declaration in this " <>
               "spec were evaluated the same number of times, reversing would be a no-op and " <>
               "the refutation below would be vacuous"

      refute counts(many) == scrambled
    end
  end

  describe "the shape of a parallel profile" do
    test "every declaration is present, with no key added or lost by merging" do
      assert Map.keys(profile(8).declarations) |> Enum.sort() ==
               Map.keys(profile(1).declarations) |> Enum.sort()
    end

    test "the coordinator's own work is counted, not just the workers'" do
      # The initial states are seeded in the coordinator, so `type_ok` is evaluated there before
      # any task starts. If `search_and_finish/2` merged only the workers' contributions, this
      # would come back one evaluation short on every worker count.
      for workers <- [1, 8] do
        assert Map.fetch!(profile(workers).declarations, {:invariant, :type_ok}).evaluations > 0
      end
    end

    test "the calibration and the OTP release survive the merge unchanged" do
      one = profile(1)
      many = profile(8)

      assert many.calibration == one.calibration
      assert many.otp_version == one.otp_version
    end

    test "run_reductions is the coordinator's, and does not pretend to be the workers'" do
      # Honest rather than clever: `Profile.reductions/0` is per-process, so a parallel run's
      # denominator is what the coordinator spent. The share it produces is therefore a share of
      # the coordinator's work, and the report says the number it actually measured.
      assert profile(8).run_reductions > 0
    end
  end

  describe "what it refuses" do
    test "liveness and workers together, so there is no profiled-parallel-liveness case" do
      assert_raise ArgumentError, ~r/workers/, fn ->
        ModelChecker.run(@spec_module, %{
          constants: @constants,
          profile: true,
          workers: 4,
          check_liveness: true
        })
      end
    end
  end
end
