defmodule Mix.Tasks.Tla.Mutants do
  @shortdoc "Measure what the correctness gates catch"

  @moduledoc """
  Break the checker on purpose, and report which gate noticed (#46).

      mix tla.mutants                    # sweep, and write test/mutation/survivors.json
      mix tla.mutants --check            # sweep, and fail on any drift (CI)
      mix tla.mutants --only drops_an_action
      mix tla.mutants --timeout 600

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

  `mix tla.mutants` exits 0 with survivors in it. The gap is the measurement — #46 exists
  to size it, not to pretend it is closed — so a survivor is reported and recorded rather
  than failing the run. What fails is a survivor that was not *expected*, which is drift.

  `build_error` and `timeout` are neither kills nor survivals. They mean the mutant never
  ran, and a sweep in which three mutants failed to compile is not a sweep with three
  kills.
  """

  use Mix.Task

  alias TLA.Mutation
  alias TLA.Mutation.Catalogue

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
        if opts[:check], do: check(results, opts[:only]), else: write(results, opts[:only])

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
        "catalogue. Run `mix tla.mutants` with no --only to record."
    )
  end

  defp write(results, nil) do
    File.mkdir_p!(Path.dirname(@artifact))
    File.write!(@artifact, encode(results))
    Mix.shell().info("wrote #{@artifact}")
  end

  defp check(results, _only) do
    fresh = encode(results)

    recorded =
      case File.read(@artifact) do
        {:ok, contents} ->
          contents

        {:error, :enoent} ->
          Mix.raise(
            "#{@artifact} does not exist. Run `mix tla.mutants` to record what the gates " <>
              "catch, and commit it — the file is the measurement."
          )
      end

    if fresh == recorded do
      Mix.shell().info("no drift: the gates catch what #{@artifact} says they catch")
    else
      Mix.raise(drift_message(Jason.decode!(recorded), Jason.decode!(fresh)))
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
      "\nRe-run `mix tla.mutants` and commit the result. A gate that got weaker is a\n",
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
    end

    counts = summary(results)

    Mix.shell().info(
      "\n  killed #{counts["killed"]} · survived #{counts["survived"]} · " <>
        "build_error #{counts["build_error"]} · timeout #{counts["timeout"]}\n"
    )
  end

  defp note(%{outcome: :survived, expected: :nothing}),
    do: "survived (expected — this is the gap #46 exists to measure)"

  defp note(%{outcome: :survived}), do: "SURVIVED — no gate caught it"
  defp note(%{outcome: :killed, gate: gate}), do: "killed by #{gate}"
  defp note(%{outcome: :build_error}), do: "build_error — it never ran, so it was not caught"
  defp note(%{outcome: :timeout}), do: "timeout — it never finished, so it was not caught"
end
