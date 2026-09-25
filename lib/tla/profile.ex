defmodule TLA.Profile do
  @moduledoc """
  What each of *your* declarations cost, measured in reductions (#116).

  `TLA.Coverage` answers how often the checker asked a declaration. This answers how expensive
  the answer was — the other half of the question a spec author has when a run is slow, and the
  only half they can act on. "Invariant checking is 3.2%" is a fact about the checker;
  "`quorum_agrees` cost 2,400 reductions each of 58,359 times" is a fact about the spec in front
  of them.

  ## Why reductions and not milliseconds

  Every performance number this project had before this module was caveated by a CPU model and a
  load average — `bench/search_profile.baseline.md` states the rule ("A number without the machine
  it was taken on is not a measurement") and records a `raft` run swinging from 23.4 s to 30.5 s
  on machine load alone.

  A reduction is the BEAM's own unit of work. The counter is incremented on function calls and
  BIF work and consults neither the clock nor the CPU, so the count is a function of
  `(OTP version, code, data)` and of nothing else. Measured on the machine in that baseline, the
  same fixed workload under 32 competing processes:

      wall       2,512 -> 5,032 µs, a 100.3% spread
      reductions 225,017 -> 225,017

  ## The floor is the measurement, and the total is not

  Accumulating the deltas does *not* give a reproducible number. Eight runs of one spec under 32
  competing processes, totals:

      invariant  19 reds/eval     3,819 -  4,839    26.7% spread
      invariant  34 reds/eval     6,834 -  7,249     6.1%
      guard       2 reds/eval       402 -    594    47.8%

  The excursions are absolute — a reduction or five on some evaluations — so they are negligible
  against an expensive declaration and total against a cheap one. Ranking on those totals gave
  five different orders in ten runs.

  The **per-evaluation minimum** has no such problem. Across the same eight loaded runs every
  declaration's floor came back a single value — 3, 11, 20, 35, 80, 155, 305 — with zero
  variance. That is the honest reading of what is happening: the floor is what the predicate
  costs, and anything above it in a given evaluation is the scheduler getting in the way of the
  measurement rather than the predicate doing more work.

  So the reported cost is `floor x evaluations`. That is reproducible to within a small
  **absolute** margin — two reductions per evaluation — and the margin does not grow with load.
  A floor can only be pushed up, by an evaluation that never ran uninterrupted, so a short run on
  a busy machine may miss the true minimum and land a reduction or two high; it cannot land low.
  On a 304 reds/eval declaration that is 0.7%, and it is still two reductions at load 32, where
  the same workload's wall time spread 100.3%. Evaluation counts are exact under any conditions —
  they are a function of the search, not of the measurement.

  **What the floor cannot see** is a predicate whose cost genuinely varies with the state — one
  that short-circuits on most states and does the work on a few. Its floor is the cheap case, so
  the reported cost understates it. That is why `observed` is kept beside it and why the report
  flags a row whose observed total runs well above its attributed one: the gap is a finding, not
  a defect, and averaging it away would hide the most interesting predicate in the spec.

  ## What this deliberately does not measure

  **Garbage collection.** Reductions do not charge for it, so a predicate that allocates heavily
  is slightly undercharged — measured at ~2% of wall on an allocation-heavy loop, against the 30%
  the wall clock swings on load. The trade is worth it and is stated rather than hidden.

  **The checker's own machinery.** `bench/search_profile.exs` profiles that, in milliseconds, and
  keeps doing so: its phases are ETS and NIF work rather than user code, and whether reductions
  describe *those* well is a separate question nobody has measured. This module wraps the closures
  `TLA.Spec.Compiled` holds and nothing else.

  ## Where the window opens and closes, and why there is no `bounded_by` here

  The window is the **search**, and only the search. It opens where `search_and_finish/2`
  instruments a copy of the spec and closes where that copy stops being called; the graph keeps
  the *uninstrumented* spec, because everything that consults `graph.spec` runs after the search
  has stopped. `TLA.StateGraph`'s moduledoc says what it is for: replay — turning a `path_to/2`
  back into states means applying transitions. Regenerating a counterexample, or materializing
  every state so a liveness predicate can be evaluated over it, is not work the spec's transitions
  did while exploring, and #133 is what it cost when the two were one value: a refuted run charged
  each trace step twice, and a `check_liveness: true` run charged roughly a whole second search.

  That boundary is what lets this module say something `TLA.Coverage` cannot. Coverage's
  `bounded_by` exists because a halted search leaves the **state space** incompletely described:
  its counts are a floor on a question about the spec. This module's counts are not a claim about
  the state space at all — they are a census of **work performed**, and a search that halted
  performed exactly the work it performed, its partial last expansion included. That number is
  complete under every halt condition, so there is deliberately no `bounded_by` on a profile: it
  would qualify a count that is not uncertain.

  A reader who needs to know the run stopped early has `status` and `coverage.bounded_by` on the
  same result struct, which is the honest place for it.

  ## Why the process dictionary

  The closures are called from inside `TLA.ModelChecker.Safety.check_invariants/4`,
  `take_action/6` and `enabled_bindings/3`, and they return only their value — there is nothing to
  thread an accumulator back through, short of changing the signature of every call site in the
  hot path to carry one.

  The dictionary is not merely the convenient answer, it is the *correct* boundary: it is
  per-process, which is exactly what `TLA.ModelChecker.Parallel` already calls a worker's
  "contribution" (`parallel.ex:160`, which starts each worker's `TLA.Coverage` from zero for the
  same reason). A worker reads its own dictionary at the end of its slice and hands back a struct,
  so `merge/2` composes the way `TLA.Coverage.merge/2` does and no shared mutable state touches
  the expansion path.

  Writes are confined to `bump/2` and reads to `collect/1`. Nothing else in the project reads
  these keys.
  """

  alias TLA.Spec

  # Reading the counter twice around a call is the measurement, and it is not free. Only the
  # SECOND read lands inside the bracket, so the constant is one BIF call — measured at 1
  # reduction, and stable at 1 across repeated calibrations on the machine in
  # `bench/search_profile.baseline.md`.
  #
  # It was 5 before the reads were written out as `:erlang.process_info/2` in `wrap2/2` and
  # `wrap3/2` rather than going through `reductions/0`: that extra function call is charged
  # inside the bracket too, and cost four times as much as the thing it was there to read.
  # `reductions/0` survives for the run-level bracket, which is called twice per run and does
  # not care.
  #
  # Subtracted at `finalize/2` — one multiply per declaration at the end — rather than on the
  # hot path, where it would be another few reductions per evaluation to remove a few
  # reductions per evaluation.
  @calibration_samples 2_000

  # Arity of the closure each kind wraps. Calibrated separately rather than assumed equal,
  # because a shared constant that is one reduction wrong gives every guard in the report a
  # systematic floor — and a floor is indistinguishable from a cheap declaration, which is
  # precisely what the report exists to tell apart.
  @arity %{invariant: 2, terminal: 2, action_property: 3, guard: 3, transition: 3}

  # A floor is a MINIMUM over evaluations, and a minimum is only a floor when there are enough
  # of them for an excursion not to have hit every one. Below this many, the "floor" is the
  # samples themselves: a declaration evaluated once reports whatever that one bracket
  # measured, excursion included (#248 — `reset`, applied in exactly one state, read 2
  # reductions on a quiet machine and 29 under load, on three pipelines). Such an entry is still
  # reported, since the count is exact, but marked as not settled rather than presented as a
  # reproducible cost. Four is small on purpose: the claim being protected is reproducibility,
  # and an excursion landing in every one of four brackets is already rare.
  @settled_at 4

  @type kind :: :invariant | :terminal | :action_property | :guard | :transition
  @type key :: {kind(), atom()}
  @type entry :: %{
          evaluations: non_neg_integer(),

          # The declaration's cost: the per-evaluation floor times the number of evaluations.
          # Exact and reproducible -- see the moduledoc on why the floor is the measurement.
          reductions: non_neg_integer(),
          per_eval: non_neg_integer(),

          # What the counter actually accumulated, floor and scheduler excursions together.
          # Carried so nothing is thrown away and so the gap is inspectable: a predicate whose
          # cost genuinely varies with the state shows up as a large `observed - reductions`.
          observed: non_neg_integer(),

          # Whether the floor rests on enough evaluations to be one (`@settled_at`). A cost over
          # fewer is reported, because the count is exact, but it is NOT reproducible and the
          # report says so on the row.
          settled: boolean()
        }

  @type t :: %__MODULE__{
          declarations: %{key() => entry()},

          # Reductions per wrapped call, by arity. Carried on the struct rather than recomputed,
          # so a merged profile subtracts the same constant its contributions were measured with.
          calibration: %{2 => non_neg_integer(), 3 => non_neg_integer()},

          # Every reduction the run spent, declarations and checker machinery alike. The
          # denominator of the share in the report, and the number that says "your model is too
          # big" when the declarations are a thin slice of it.
          run_reductions: non_neg_integer(),

          # A count is only comparable against another taken on the same OTP: BIF reduction costs
          # change between releases. Recorded for the same reason `bin/tlc-expected` pins
          # TLA_TOOLS_VERSION -- the tool that produces a fixture is part of the fixture.
          otp_version: String.t() | nil
        }

  defstruct declarations: %{}, calibration: %{2 => 0, 3 => 0}, run_reductions: 0, otp_version: nil

  @doc """
  A zeroed accumulator for `spec`, with the instrumentation constant calibrated for this machine
  and OTP release.
  """
  def init(%Spec.Compiled{} = spec) do
    %__MODULE__{
      declarations: Map.new(keys(spec), &{&1, zero()}),
      calibration: calibrate(),
      otp_version: List.to_string(:erlang.system_info(:otp_release))
    }
  end

  @doc """
  `spec` with every declaration's closure wrapped in a counter.

  Returns the spec unchanged in shape — same keys, same arities, same return values — so nothing
  downstream can tell the difference except by counting. Also clears this process's accumulator,
  which matters in a test suite where several runs share one process.
  """
  def instrument(%Spec.Compiled{} = spec) do
    Enum.each(keys(spec), &Process.delete(dict_key(&1)))

    %{
      spec
      | invariants: Enum.map(spec.invariants, &wrap_predicate(&1, {:invariant, &1.name})),
        terminals: Enum.map(spec.terminals, &wrap_predicate(&1, {:terminal, &1.name})),
        action_properties:
          Enum.map(spec.action_properties, &wrap_pair(&1, {:action_property, &1.name})),
        actions: Enum.map(spec.actions, &wrap_action/1)
    }
  end

  @doc """
  The same accumulator with every count back at zero, and this process's dictionary cleared.

  What `TLA.ModelChecker.Parallel` hands a worker, for the reason it hands one a zeroed
  `TLA.Coverage`: a worker given the coordinator's totals would return them plus its own, and
  merging that counts the seed twice. Keeps the calibration and the OTP release, which are facts
  about the machine rather than about the work, so a worker does not pay to recalibrate.
  """
  def zero(%__MODULE__{} = profile) do
    Enum.each(Map.keys(profile.declarations), &Process.delete(dict_key(&1)))

    %{profile | declarations: Map.new(profile.declarations, fn {key, _} -> {key, zero()} end)}
  end

  @doc """
  Remove this process's counters from its dictionary. `zero/1` does this on a worker's way
  in; the coordinator calls it on its way out (#212), so the keys do not outlive the run in
  a long-lived process.
  """
  def clear(%__MODULE__{} = profile) do
    Enum.each(Map.keys(profile.declarations), &Process.delete(dict_key(&1)))
    :ok
  end

  @doc """
  This process's contribution, read out of its dictionary.

  Raw: the calibration is subtracted by `finalize/2`, after any merging, so the constant is
  applied exactly once however many workers contributed.
  """
  def collect(%__MODULE__{} = profile) do
    declarations =
      Map.new(profile.declarations, fn {key, _zero} ->
        case Process.get(dict_key(key)) do
          nil -> {key, zero()}
          {evaluations, observed, floor} -> {key, raw(evaluations, observed, floor)}
        end
      end)

    %{profile | declarations: declarations}
  end

  @doc """
  Sum two contributions. Both come from one `init/1`, so their key sets are identical and a key in
  one and not the other would be a bug rather than a case to handle — the same argument
  the private `merge_with/3` in `TLA.Coverage` makes.
  """
  def merge(%__MODULE__{} = into, %__MODULE__{} = from) do
    %{
      into
      | declarations:
          Map.merge(into.declarations, from.declarations, fn _key, a, b ->
            # Counts and observed totals add; the per-evaluation floor is a MINIMUM and takes
            # the smaller of the two. A worker that evaluated nothing has no floor to offer,
            # so its zero must not win — that is what `merge_floor/2` is for.
            %{
              a
              | evaluations: a.evaluations + b.evaluations,
                observed: a.observed + b.observed,
                per_eval: merge_floor(a, b)
            }
          end),
        run_reductions: into.run_reductions + from.run_reductions
    }
  end

  defp merge_floor(%{evaluations: 0}, b), do: b.per_eval
  defp merge_floor(a, %{evaluations: 0}), do: a.per_eval
  defp merge_floor(a, b), do: min(a.per_eval, b.per_eval)

  defp zero, do: %{evaluations: 0, reductions: 0, per_eval: 0, observed: 0, settled: false}

  # Straight off the counter, before the calibration comes out. `settled` is decided by
  # `finalize/2`, after merging, since the count it depends on is the merged one.
  defp raw(evaluations, observed, floor),
    do: %{
      evaluations: evaluations,
      reductions: 0,
      per_eval: floor,
      observed: observed,
      settled: false
    }

  @doc """
  Subtract the instrumentation, turn the per-evaluation floor into a cost, and record what the
  whole run spent.

  `run_reductions` is the CALLER's bracket — the coordinator's — and is ADDED to whatever the
  merged contributions already carry, which is every worker's own bracket (#199). Overwriting
  it, as this once did, made the denominator the coordinator alone: on a single worker that is
  the whole run, on eight it is the scheduling and the seed, and the same spec read 12% at one
  worker and 91% at eight.

  **Called once, after any merging.** It is not idempotent — a second call would subtract the
  calibration a second time — and that is why `collect/1` and `merge/2` leave the raw floor
  alone. A worker collects, the coordinator merges, and this runs at the end.

  Clamped at zero: a declaration cheaper than the two counter reads can measure below the
  calibration floor by a reduction or two, and a negative cost is not a thing to report. It also
  reads correctly — "too cheap to measure" is the honest answer for `invariant :always do true end`.
  """
  def finalize(%__MODULE__{} = profile, run_reductions) do
    declarations =
      Map.new(profile.declarations, fn {{kind, _name} = key, entry} ->
        per_eval = max(entry.per_eval - Map.fetch!(profile.calibration, @arity[kind]), 0)

        {key,
         entry
         |> Map.merge(%{per_eval: per_eval, reductions: per_eval * entry.evaluations})
         |> Map.put(:settled, entry.evaluations >= @settled_at)}
      end)

    %{
      profile
      | declarations: declarations,
        run_reductions: profile.run_reductions + run_reductions
    }
  end

  @doc """
  Every reduction this process has spent. The run brackets itself with two of these.
  """
  def reductions do
    {:reductions, count} = Process.info(self(), :reductions)
    count
  end

  # ── Wrapping ────────────────────────────────────────────────────────────────

  defp wrap_action(action) do
    %{
      action
      | guard: wrap3(action.guard, {:guard, action.name}),
        transition: wrap3(action.transition, {:transition, action.name})
    }
  end

  defp wrap_predicate(declaration, key),
    do: %{declaration | predicate: wrap2(declaration.predicate, key)}

  defp wrap_pair(declaration, key),
    do: %{declaration | predicate: wrap3(declaration.predicate, key)}

  # `bump/2` runs AFTER the second read, so its own cost is not charged to the declaration. That
  # ordering is the reason the calibration constant is as small and as stable as it is.
  defp wrap2(fun, key) do
    dict = dict_key(key)

    fn a, b ->
      {:reductions, before} = :erlang.process_info(self(), :reductions)
      value = fun.(a, b)
      {:reductions, done} = :erlang.process_info(self(), :reductions)
      bump(dict, done - before)
      value
    end
  end

  defp wrap3(fun, key) do
    dict = dict_key(key)

    fn a, b, c ->
      {:reductions, before} = :erlang.process_info(self(), :reductions)
      value = fun.(a, b, c)
      {:reductions, done} = :erlang.process_info(self(), :reductions)
      bump(dict, done - before)
      value
    end
  end

  defp bump(dict, delta) do
    case Process.get(dict) do
      nil -> Process.put(dict, {1, delta, delta})
      {count, total, low} -> Process.put(dict, {count + 1, total + delta, min(low, delta)})
    end
  end

  defp dict_key({kind, name}), do: {__MODULE__, kind, name}

  defp keys(spec) do
    Enum.map(spec.invariants, &{:invariant, &1.name}) ++
      Enum.map(spec.terminals, &{:terminal, &1.name}) ++
      Enum.map(spec.action_properties, &{:action_property, &1.name}) ++
      Enum.flat_map(spec.actions, &[{:guard, &1.name}, {:transition, &1.name}])
  end

  # ── Calibration ─────────────────────────────────────────────────────────────

  # What has to be subtracted is the cost of the two counter READS and nothing else. It is not
  # the whole of what a no-op measures: that also contains one function call, and an unwrapped
  # run pays for its declaration's call too, so subtracting it would charge the harness for work
  # the declaration really does and would push cheap declarations to zero.
  #
  # Isolating the reads needs two samples rather than one. A bracket containing `n` calls costs
  #
  #     d(n) = n * k + c        k = cost of one call, c = cost of the reads
  #
  # so `c = 2*d(1) - d(2)`, with `k` — the part that legitimately belongs to the declaration —
  # cancelling out. Measured this way the constant is 2 on the machine in
  # `bench/search_profile.baseline.md`, which is what an interleaved bare-versus-instrumented
  # A/B measured independently before this module existed.
  @doc false
  # Public so a test can assert the constant is stable across calls, which is the property the
  # whole subtraction rests on. Not part of the API.
  def calibrate, do: %{2 => read_cost(&noop2/0, &noop2x2/0), 3 => read_cost(&noop3/0, &noop3x2/0)}

  # `calibration_samples/0` stood here, returning the four raw floors behind `calibrate/0`.
  # Nothing called it and nothing asserted on it, in `lib/`, `test/` or `bench/` — so it was
  # a published function whose only effect was to appear in `API_SURFACE.md` (#317). The
  # property it would have supported is the one `calibrate/0` is public FOR, and that one is
  # tested: `TLA.ProfileTest` §calibration asserts the constant is stable across five calls
  # and bounded, which is what the subtraction in `finalize/2` rests on.

  defp read_cost(once, twice), do: max(2 * floor_of(once) - floor_of(twice), 0)

  # The minimum over the samples, not the mean: the floor is the true cost of the reads, and
  # everything above it is the scheduler interrupting the measurement.
  defp floor_of(sample) do
    Enum.min(for _ <- 1..@calibration_samples, do: sample.())
  end

  # The calls are written out rather than looped, and that is load-bearing: a comprehension has
  # setup of its own, which is constant in the number of calls and would therefore land in `c`
  # instead of cancelling with `k`. Measured with a loop the constant came out at 10 and pushed
  # every guard in the report to zero, which is how this was found.
  defp noop2 do
    fun = fn _a, _b -> nil end
    {:reductions, before} = :erlang.process_info(self(), :reductions)
    fun.(nil, nil)
    {:reductions, done} = :erlang.process_info(self(), :reductions)
    done - before
  end

  defp noop2x2 do
    fun = fn _a, _b -> nil end
    {:reductions, before} = :erlang.process_info(self(), :reductions)
    fun.(nil, nil)
    fun.(nil, nil)
    {:reductions, done} = :erlang.process_info(self(), :reductions)
    done - before
  end

  defp noop3 do
    fun = fn _a, _b, _c -> nil end
    {:reductions, before} = :erlang.process_info(self(), :reductions)
    fun.(nil, nil, nil)
    {:reductions, done} = :erlang.process_info(self(), :reductions)
    done - before
  end

  defp noop3x2 do
    fun = fn _a, _b, _c -> nil end
    {:reductions, before} = :erlang.process_info(self(), :reductions)
    fun.(nil, nil, nil)
    fun.(nil, nil, nil)
    {:reductions, done} = :erlang.process_info(self(), :reductions)
    done - before
  end

  # ── Rendering ───────────────────────────────────────────────────────────────

  @doc """
  Render for terminal output, in the shape `TLA.Coverage.format/2` uses.
  """
  def format(%__MODULE__{} = profile, opts \\ []) do
    title = Keyword.get(opts, :title, "PROFILE")
    rule = String.duplicate("-", max(0, 68 - String.length(title) - 5))

    sections =
      [
        table("Invariants", :invariant, "evaluations", profile),
        table("Action properties", :action_property, "evaluations", profile),
        table("Terminals", :terminal, "evaluations", profile),
        table("Guards", :guard, "evaluations", profile),
        table("Transitions", :transition, "applied", profile)
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    "--- " <>
      title <>
      " " <>
      rule <>
      "\n\n" <>
      sections <>
      footer(profile) <>
      String.duplicate("-", 68) <> "\n"
  end

  defp table(heading, kind, count_label, profile) do
    rows =
      profile.declarations
      |> Enum.filter(fn {{k, _name}, _entry} -> k == kind end)
      |> Enum.sort_by(fn {{_kind, name}, entry} -> {-entry.reductions, name} end)

    if rows == [] do
      ""
    else
      body =
        Enum.map_join(rows, "\n", fn {{_kind, name}, entry} ->
          "  " <>
            String.pad_trailing(Atom.to_string(name), 24) <>
            number(entry.evaluations) <>
            number(entry.reductions) <>
            number(entry.per_eval) <> varies(entry) <> unsettled(entry)
        end)

      heading <>
        String.duplicate(" ", max(1, 26 - String.length(heading))) <>
        String.pad_leading(count_label, 11) <>
        "  reductions   reds/eval\n" <> body <> "\n"
    end
  end

  # A predicate whose cost depends on the state costs more in total than its floor accounts for,
  # and that gap is the one thing the floor CANNOT tell you. It is a finding rather than a
  # defect — a guard that is cheap on most states and expensive on a few is worth knowing about
  # — so it is flagged rather than hidden or averaged away.
  #
  # The threshold is generous because the gap also contains scheduler excursions: below a third
  # this is noise, above it the predicate is genuinely doing different amounts of work.
  defp varies(%{observed: observed, reductions: attributed}) when attributed > 0 do
    if observed > attributed * 4 / 3, do: "   <-- varies by state", else: ""
  end

  defp varies(_entry), do: ""

  # The count is exact; the cost is not a floor yet. Said on the row, so a reader comparing two
  # runs does not chase a one-sample difference as a regression.
  defp unsettled(%{settled: false, evaluations: n}),
    do: "   <-- floor over #{n} evaluation#{if n == 1, do: "", else: "s"}, not settled"

  defp unsettled(_entry), do: ""

  # Sorted by cost, so the answer is the first row. The share is what says whether to read the
  # table at all — on a large model the checker's own machinery is most of the run, and the honest
  # response to that is a guide reference rather than an optimiser.
  defp footer(profile) do
    total = profile.declarations |> Map.values() |> Enum.map(& &1.reductions) |> Enum.sum()

    share =
      if profile.run_reductions > 0,
        do: Float.round(total * 100 / profile.run_reductions, 1),
        else: 0.0

    "\nAll declarations: #{delimit(total)} reductions, #{share}% of the run's " <>
      "#{delimit(profile.run_reductions)}.\n" <>
      advice(share) <>
      "\nCost is the per-evaluation floor times the evaluations, which is exactly reproducible\n" <>
      "once the floor rests on #{@settled_at} or more of them; a row marked not settled is not.\n" <>
      "Anything above the floor in a given evaluation is the scheduler, not your predicate.\n" <>
      "Instrumentation calibrated at #{profile.calibration[2]}/#{profile.calibration[3]} " <>
      "reductions per evaluation (arity 2/3) and subtracted. OTP #{profile.otp_version}.\n"
  end

  defp advice(share) when share < 25.0 do
    "The rest is the checker's own machinery. Your declarations are not the problem —\n" <>
      "see guides/tutorial/09-when-it-explodes.md before optimising one.\n"
  end

  defp advice(_share), do: ""

  defp number(value), do: String.pad_leading(delimit(value), 12)

  defp delimit(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
