defmodule Mix.Tasks.Extla.Mutants do
  @shortdoc "Measure what the correctness gates catch"

  @moduledoc """
  Break the checker on purpose, and report which gate noticed (#46).

      mix extla.mutants                    # sweep, and write test/mutation/survivors.json
      mix extla.mutants --check            # sweep, and fail on any drift (CI)
      mix extla.mutants --only drops_an_action
      mix extla.mutants --timeout 600

  Runs in `MIX_ENV=test` whichever way it is invoked — `mix.exs` declares that, because
  the catalogue and the runner live in `test/support/` and a sweep in any other
  environment would find neither.

  ## `survivors.json` is machine-written

  Exactly as `expected.json` is, and for the reason `bin/tlc-expected`'s header gives: a
  human editing it to make a build pass would be editing the definition of "correct".
  `--check` re-runs the sweep and fails on drift **in either direction**:

    * a mutant that **newly survives** is a regression in the gates;
    * a mutant that **newly dies** is progress, and progress nobody recorded is progress
      that can be silently lost again.

  ## A survivor is a finding, not a failure

  `mix extla.mutants` exits 0 with survivors in it. The gap is the measurement — #46 exists
  to size it, not to pretend it is closed — so a survivor is reported and recorded rather
  than failing the run. What fails is a survivor that was not *expected*, which is drift.

  `build_error` and `timeout` are neither kills nor survivals. They mean the mutant never
  ran, and a sweep in which three mutants failed to compile is not a sweep with three
  kills.

  ## `inconclusive` is unmeasured, not drift (#378)

  A gate failed, but the failure did not reproduce, or recurred without the mutant
  (`ExTLA.Mutation`'s moduledoc gives the rule). That says nothing about the mutant, so:

    * `--check` keeps the outcome `survivors.json` records for it, compares the rest, and
      prints why it was inconclusive and what failed. It is neither PROGRESS nor
      REGRESSION, which is how one flake under load once failed `main` as "progress";
    * recording refuses: an inconclusive mutant has no outcome to write. Re-run.
  """

  use Mix.Task

  alias ExTLA.Mutation
  alias ExTLA.Mutation.Catalogue

  @artifact "test/mutation/survivors.json"
  @switches [check: :boolean, only: :string, timeout: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)

    # Refused before the sweep rather than after it: a minute of work followed by "that
    # was not a valid combination" is worse than the same message immediately.
    if opts[:check] && opts[:only] do
      Mix.raise("--check compares the whole catalogue; --only cannot say anything about drift.")
    end

    mutants = selected(opts[:only])
    sweep_opts = if t = opts[:timeout], do: [timeout: t], else: []

    Mix.shell().info("sweeping #{length(mutants)} mutant(s) — each one compiles the tree")

    case Mutation.sweep(mutants, sweep_opts) do
      {:ok, results} ->
        report(results)
        if opts[:check], do: check(results), else: write(results, opts[:only])

      {:error, reason} ->
        Mix.raise("the sweep could not start: #{reason}")
    end
  end

  defp selected(nil), do: Catalogue.all()
  defp selected(name), do: [Catalogue.fetch!(String.to_atom(name))]

  # ── The artifact ────────────────────────────────────────────────────────────

  @doc false
  # A pure function of the catalogue and the checker's source: no timestamps, no durations,
  # no captured output, and sorted by name. Everything that varies between two runs of the
  # same code would make the drift gate cry wolf, and a gate that cries wolf gets disabled.
  #
  # Public so those properties can be asserted on a handful of results rather than behind a
  # 56-second sweep — a test nobody can afford to run is a test nobody runs.
  def encode(results) do
    payload = %{
      "mutants" =>
        results
        |> Enum.sort_by(& &1.name)
        |> Enum.map(fn result ->
          %{
            "name" => Atom.to_string(result.name),
            "outcome" => Atom.to_string(result.outcome),
            "gate" => Atom.to_string(result.gate),
            "expected" => Atom.to_string(result.expected),
            "models" => Catalogue.fetch!(result.name).models
          }
        end),
      "summary" => summary(results)
    }

    Jason.encode!(payload, pretty: true) <> "\n"
  end

  defp summary(results) do
    counts = Enum.frequencies_by(results, & &1.outcome)

    for outcome <- ~w(killed survived build_error timeout)a,
        into: %{},
        do: {Atom.to_string(outcome), Map.get(counts, outcome, 0)}
  end

  # `--only` investigates; it does not record. Writing the artifact from one mutant would
  # drop every other mutant's measured status, so it prints and says it did not write —
  # rather than raising, which would make a legitimate investigation end in an error.
  defp write(_results, only) when is_binary(only) do
    Mix.shell().info(
      "not written: --only investigates one mutant, and #{@artifact} records the whole\n" <>
        "catalogue. Run `mix extla.mutants` with no --only to record."
    )
  end

  defp write(results, nil) do
    case Enum.filter(results, &(&1.outcome == :inconclusive)) do
      [] ->
        :ok

      unmeasured ->
        Mix.raise(
          "not written: #{Enum.map_join(unmeasured, ", ", & &1.name)} came out inconclusive, " <>
            "so there is no outcome to record for it. Re-run `mix extla.mutants`."
        )
    end

    File.mkdir_p!(Path.dirname(@artifact))
    File.write!(@artifact, encode(results))
    Mix.shell().info("wrote #{@artifact}")
  end

  defp check(results) do
    recorded =
      case File.read(@artifact) do
        {:ok, contents} ->
          contents

        {:error, :enoent} ->
          Mix.raise(
            "#{@artifact} does not exist. Run `mix extla.mutants` to record what the gates " <>
              "catch, and commit it — the file is the measurement."
          )
      end

    measured =
      case keep_recorded(results, Jason.decode!(recorded)) do
        {:ok, measured} ->
          measured

        {:error, names} ->
          Mix.raise(
            "#{Enum.join(names, ", ")} came out inconclusive and #{@artifact} records no " <>
              "outcome for it, so there is nothing to compare. Re-run `mix extla.mutants --check`."
          )
      end

    fresh = encode(measured)

    if fresh == recorded do
      Mix.shell().info("no drift: the gates catch what #{@artifact} says they catch")
    else
      Mix.raise(drift_message(Jason.decode!(recorded), Jason.decode!(fresh)))
    end
  end

  @doc false
  # An inconclusive result is unmeasured, so the recorded outcome stands for it and the
  # comparison is over the rest. A mutant with no recorded outcome cannot stand in that
  # way, and is returned by name.
  #
  # Public so the substitution is tested on plain data rather than behind a sweep.
  def keep_recorded(results, recorded) do
    was = Map.new(recorded["mutants"], &{&1["name"], &1["outcome"]})
    {unmeasured, measured} = Enum.split_with(results, &(&1.outcome == :inconclusive))

    case Enum.reject(unmeasured, &Map.has_key?(was, Atom.to_string(&1.name))) do
      [] ->
        kept =
          Enum.map(unmeasured, fn result ->
            %{result | outcome: String.to_existing_atom(was[Atom.to_string(result.name)])}
          end)

        {:ok, measured ++ kept}

      missing ->
        {:error, Enum.map(missing, & &1.name)}
    end
  end

  @doc false
  # Named in both directions, because they mean opposite things and a diff alone does not
  # say which happened.
  def drift_message(recorded, fresh) do
    was = Map.new(recorded["mutants"], &{&1["name"], &1["outcome"]})
    now = Map.new(fresh["mutants"], &{&1["name"], &1["outcome"]})

    regressions =
      for {name, outcome} <- now, was[name] == "killed", outcome != "killed", do: {name, outcome}

    progress = for {name, outcome} <- now, was[name] != "killed", outcome == "killed", do: name
    added = for {name, _} <- now, not Map.has_key?(was, name), do: name
    removed = for {name, _} <- was, not Map.has_key?(now, name), do: name

    [
      "#{@artifact} no longer describes what the gates catch.\n",
      lines("REGRESSION — these were killed and now are not", regressions),
      lines("PROGRESS — these are now killed and were not", progress),
      lines("new to the catalogue", added),
      lines("gone from the catalogue", removed),
      "\nRe-run `mix extla.mutants` and commit the result. A gate that got weaker is a\n",
      "defect; a gate that got stronger is progress that has to be recorded or it can be\n",
      "lost again without anything noticing."
    ]
    |> Enum.join()
  end

  defp lines(_label, []), do: ""

  defp lines(label, entries) do
    "\n#{label}:\n" <> Enum.map_join(entries, "\n", &"  #{describe(&1)}") <> "\n"
  end

  defp describe({name, outcome}), do: "#{name} — now #{outcome}"
  defp describe(name), do: to_string(name)

  # ── Reporting ───────────────────────────────────────────────────────────────

  defp report(results) do
    Mix.shell().info("")

    for result <- Enum.sort_by(results, & &1.name) do
      Mix.shell().info("  #{String.pad_trailing(to_string(result.name), 28)} #{note(result)}")

      case evidence(result) do
        "" -> :ok
        lines -> Mix.shell().info(lines)
      end
    end

    counts = summary(results)
    inconclusive = Enum.count(results, &(&1.outcome == :inconclusive))

    Mix.shell().info(
      "\n  killed #{counts["killed"]} · survived #{counts["survived"]} · " <>
        "build_error #{counts["build_error"]} · timeout #{counts["timeout"]} · " <>
        "inconclusive #{inconclusive}\n"
    )
  end

  # What the job log needs to diagnose a result after the fact (#378: 4744's kill could
  # not be, because only the summary was printed). A survival needs nothing; a kill needs
  # the tests it broke; everything else needs the output.
  defp evidence(%{outcome: :survived}), do: ""

  defp evidence(%{outcome: :killed, failures: failures}),
    do: Enum.map_join(failures, "\n", &"      failed: #{&1}")

  defp evidence(%{output: output}),
    do: output |> String.split("\n") |> Enum.map_join("\n", &"      | #{&1}")

  defp note(%{outcome: :survived, expected: :nothing}),
    do: "survived (expected — this is the gap #46 exists to measure)"

  defp note(%{outcome: :survived}), do: "SURVIVED — no gate caught it"
  defp note(%{outcome: :killed, gate: gate}), do: "killed by #{gate}"
  defp note(%{outcome: :build_error}), do: "build_error — it never ran, so it was not caught"
  defp note(%{outcome: :timeout}), do: "timeout — it never finished, so it was not caught"

  defp note(%{outcome: :inconclusive, reason: reason}),
    do: "INCONCLUSIVE (#{reason}) — a gate failed, but not because of the mutant"
end
