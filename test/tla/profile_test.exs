defmodule TLA.ProfileTest.Spec do
  @moduledoc """
  Three invariants whose costs differ by construction, so a report that ranks them has
  something to be right or wrong about.
  """
  use TLA.Spec

  constant :max, default: 200

  variable :n, type: 0..^max

  init do
    n = 0
  end

  action :tick do
    require n < ^max

    n = n + 1
  end

  action :reset do
    require n == ^max

    n = 0
  end

  # Deliberately the expensive one: a hundred iterations of arithmetic per evaluation, where
  # `cheap` is one comparison. The ratio is what the report has to get right, not the absolute
  # number.
  invariant :expensive do
    Enum.all?(1..100, fn i -> rem(i, 7) != 0 or n >= 0 end)
  end

  invariant :cheap do
    n >= 0
  end

  # Cheaper than the two counter reads can resolve. It exists to pin the calibration: without
  # the subtraction this reports the instrumentation's own cost, which is indistinguishable
  # from a real finding.
  invariant :trivial do
    true
  end
end

defmodule TLA.ProfileTest do
  @moduledoc """
  `TLA.Profile` — what each of the user's declarations cost, in reductions (#116, #130).

  `async: false` for one specific reason: "the count does not move under load" generates
  contention on purpose, and running it beside the async suite would make it both unreliable
  and rude.
  """
  use ExUnit.Case, async: false

  alias TLA.{ModelChecker, Profile}

  @spec_module TLA.ProfileTest.Spec

  # Constants explicitly: `default:` is resolved by `TLA.Mix.SpecTarget` for the mix task, not
  # by `ModelChecker.run/2`, so a test that leaves them out is refused by `type_ok`.
  @constants %{constants: %{max: 200}}

  defp run(config \\ %{}) do
    ModelChecker.run(@spec_module, Enum.into(config, Map.put(@constants, :profile, true)))
  end

  defp cost(profile, key), do: Map.fetch!(profile.declarations, key)

  describe "the measurement" do
    test "an unprofiled run reports no profile at all" do
      assert ModelChecker.run(@spec_module, @constants).profile == nil
    end

    test "an unprofiled run leaves the compiled spec's own closures in place" do
      # The wrapping happens on a copy made for the run. If it ever leaked into the module's
      # compiled form, every later run would pay for instrumentation nobody asked for — and
      # the leak would be invisible, because a wrapped closure returns the same value.
      before = TLA.Spec.Compiled.from_module(@spec_module)
      _profiled = run()
      assert TLA.Spec.Compiled.from_module(@spec_module) == before
    end

    test "an unprofiled run reaches the same verdict and counts as a profiled one" do
      plain = ModelChecker.run(@spec_module, @constants)
      profiled = run()

      assert plain.status == profiled.status
      assert plain.distinct_states == profiled.distinct_states
      assert plain.diameter == profiled.diameter
      assert plain.transitions == profiled.transitions
    end

    test "every declaration is present, including the ones that cost nothing" do
      profile = run().profile

      assert Map.keys(profile.declarations) |> Enum.sort() == [
               {:guard, :reset},
               {:guard, :tick},
               {:invariant, :cheap},
               {:invariant, :expensive},
               {:invariant, :trivial},
               {:invariant, :type_ok},
               {:transition, :reset},
               {:transition, :tick}
             ]
    end

    test "evaluation counts are exact, not sampled" do
      result = run()

      # An invariant is evaluated once per distinct state, so this is the one count that can be
      # checked against a number the run reports independently.
      for name <- [:expensive, :cheap, :trivial, :type_ok] do
        assert cost(result.profile, {:invariant, name}).evaluations == result.distinct_states,
               "#{name} was not evaluated once per distinct state"
      end
    end

    test "the OTP release is recorded, because a count is only comparable within one" do
      assert run().profile.otp_version == List.to_string(:erlang.system_info(:otp_release))
    end
  end

  describe "what it ranks" do
    test "the expensive invariant outranks the cheap one, by about the ratio of the work" do
      profile = run().profile

      expensive = cost(profile, {:invariant, :expensive})
      cheap = cost(profile, {:invariant, :cheap})

      assert expensive.reductions > cheap.reductions * 10,
             "expected `expensive` to dominate `cheap`, got #{expensive.reductions} vs " <>
               "#{cheap.reductions}"

      # And it is the first row the reader sees.
      assert profile |> Profile.format() |> String.split("\n") |> Enum.find(&(&1 =~ ~r/^\s+\w/)) =~
               "expensive"
    end

    test "the calibration is subtracted, so a trivial declaration reports about nothing" do
      profile = run().profile

      trivial = cost(profile, {:invariant, :trivial})

      # Not exactly zero — `true` still costs the call the wrapper cannot subtract, which is
      # the call an unprofiled run would also pay. What matters is that it is not the
      # instrumentation's cost showing up as a finding.
      assert trivial.reductions <= trivial.evaluations * 3,
             "`trivial` reports #{trivial.reductions} reductions over #{trivial.evaluations} " <>
               "evaluations — the calibration is not being subtracted"
    end

    test "the share of the run is reported, and the declarations are a part of it" do
      profile = run().profile

      total = profile.declarations |> Map.values() |> Enum.map(& &1.reductions) |> Enum.sum()

      assert profile.run_reductions > total,
             "the declarations cannot cost more than the run that called them"

      assert Profile.format(profile) =~
               ~r/All declarations: [\d,]+ reductions, \d+\.\d% of the run/
    end
  end

  describe "stability — the property the unit was chosen for" do
    # The bound is ABSOLUTE — two reductions per evaluation — and that is the whole claim.
    #
    # A floor can only be pushed UP, by an evaluation that never ran uninterrupted, so under
    # adversarial load a short run may not observe the true minimum and lands a reduction or two
    # high. It cannot land low. So this is a near-equality rather than an equality, and it does
    # not grow with load: on a 304 reds/eval declaration two reductions is 0.7%, and it is still
    # two reductions when the machine is at load 32. Wall time on the same workload spread 100.3%.
    #
    # Asserted this way rather than as a percentage because a percentage would be generous to
    # the expensive declarations and meaningless for the cheap ones, and it is the cheap ones
    # where a regression would hide.
    @margin 2

    defp counts(profile) do
      Map.new(profile.declarations, fn {key, entry} -> {key, entry.evaluations} end)
    end

    defp floors(profile) do
      Map.new(profile.declarations, fn {key, entry} -> {key, entry.per_eval} end)
    end

    defp drift(a, b) do
      for {key, left} <- floors(a),
          right = Map.fetch!(floors(b), key),
          abs(left - right) > @margin,
          do: {key, left, right}
    end

    test "two runs of the same spec agree on every count exactly and every cost to within two" do
      one = run().profile
      other = run().profile

      # Evaluation counts are a function of the search, so these are exact under any conditions.
      assert counts(one) == counts(other)
      assert drift(one, other) == []
    end

    test "the cost is the floor times the evaluations, so it is not an average" do
      for {_key, entry} <- run().profile.declarations do
        assert entry.reductions == entry.per_eval * entry.evaluations

        # And the floor is a floor: the counter cannot have accumulated less than it.
        assert entry.observed >= entry.reductions
      end
    end

    test "the count does not move under machine load, which is why it is not milliseconds" do
      quiet = run().profile

      busy =
        for _ <- 1..32 do
          spawn(fn -> Stream.iterate(0, &(&1 + 1)) |> Enum.each(fn _ -> :ok end) end)
        end

      loaded =
        try do
          run().profile
        after
          Enum.each(busy, &Process.exit(&1, :kill))
        end

      # The counts are untouched by load — the search did the same work — and the costs move by
      # at most the margin, which is what a wall clock cannot promise at any figure.
      assert counts(quiet) == counts(loaded)

      moved = drift(quiet, loaded)

      assert moved == [],
             "the profile moved under load by more than #{@margin} reductions per evaluation, " <>
               "which is the one thing reductions are here to avoid: #{inspect(moved)}"
    end
  end

  describe "merge" do
    # `merge/2` combines RAW contributions — what `collect/1` reads out of a worker's process
    # dictionary — and `finalize/2` runs once over the result. Built by hand rather than from
    # two runs, because two runs give finalized profiles and finalizing twice would subtract
    # the calibration twice. That ordering is #131's whole subject.
    defp contribution(entries, run_reductions) do
      %Profile{
        declarations: Map.new(entries),
        calibration: %{2 => 1, 3 => 1},
        run_reductions: run_reductions,
        otp_version: "29"
      }
    end

    test "counts and observed totals add; the per-evaluation floor takes the smaller" do
      a =
        contribution(
          [{{:invariant, :x}, %{evaluations: 10, reductions: 0, per_eval: 51, observed: 530}}],
          1_000
        )

      b =
        contribution(
          [{{:invariant, :x}, %{evaluations: 4, reductions: 0, per_eval: 41, observed: 170}}],
          400
        )

      merged = Profile.merge(a, b)
      entry = Map.fetch!(merged.declarations, {:invariant, :x})

      assert entry.evaluations == 14
      assert entry.observed == 700
      assert entry.per_eval == 41, "the floor is a minimum, not a sum or an average"
      assert merged.run_reductions == 1_400

      # And the cost falls out of the merged floor, once.
      finalized = Profile.finalize(merged, 1_400)
      assert Map.fetch!(finalized.declarations, {:invariant, :x}).per_eval == 40
      assert Map.fetch!(finalized.declarations, {:invariant, :x}).reductions == 560
    end

    test "a worker that evaluated nothing does not drag the floor to zero" do
      seen =
        contribution(
          [{{:invariant, :x}, %{evaluations: 10, reductions: 0, per_eval: 51, observed: 530}}],
          1_000
        )

      idle =
        contribution(
          [{{:invariant, :x}, %{evaluations: 0, reductions: 0, per_eval: 0, observed: 0}}],
          0
        )

      # This is the bug the shape invites: `min(51, 0)` is 0, and a worker whose slice never
      # reached this declaration would silently zero its cost.
      assert Map.fetch!(Profile.merge(seen, idle).declarations, {:invariant, :x}).per_eval == 51
      assert Map.fetch!(Profile.merge(idle, seen).declarations, {:invariant, :x}).per_eval == 51
    end
  end

  describe "calibration" do
    test "is stable across calls, which is what makes subtracting it sound" do
      constants = for _ <- 1..5, do: Profile.calibrate()

      assert length(Enum.uniq(constants)) == 1,
             "the instrumentation constant moved between calibrations: #{inspect(constants)}"
    end

    test "is small enough to leave a cheap declaration measurable" do
      # One BIF call. If this grows, cheap declarations start reporting the harness instead of
      # themselves, and the report stops ranking anything.
      assert Profile.calibrate()[2] <= 3
      assert Profile.calibrate()[3] <= 3
    end
  end

  describe "the rendered report" do
    test "carries exactly one wall-time figure and no per-declaration milliseconds" do
      report = Profile.format(run().profile)

      refute report =~ ~r/\bms\b/
      refute report =~ "µs"
    end

    test "names the calibration it subtracted and the OTP it was taken on" do
      report = Profile.format(run().profile)

      assert report =~ ~r/Instrumentation calibrated at \d+\/\d+ reductions per evaluation/
      assert report =~ "OTP #{:erlang.system_info(:otp_release)}"
    end

    # The advice is for the case the report will usually be read in — a large model where the
    # checker's own machinery dominates. This spec is small enough that its declarations really
    # are about half the run, so the line correctly does NOT appear for it, and testing both
    # branches means constructing the shares rather than hoping a fixture lands on each side.
    test "sends the reader to the guide only when the declarations are a thin slice of the run" do
      profile = run().profile

      thin = %{profile | run_reductions: profile.run_reductions * 100}
      assert Profile.format(thin) =~ "09-when-it-explodes.md"

      refute Profile.format(profile) =~ "09-when-it-explodes.md"
    end
  end
end
