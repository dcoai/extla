defmodule Mix.Tasks.Tla.Check do
  @shortdoc "Run model checking on TLA.Spec modules"

  @moduledoc """
  Run model checking on `TLA.Spec` modules.

  ## Usage

      mix tla.check                                 # every spec in the project
      mix tla.check Specs.TransferProtocol
      mix tla.check Specs.TransferProtocol --max-states 100000
      mix tla.check Specs.TransferProtocol --format json

  ## Where the constants come from

  A spec cannot be checked without an assignment for each of its constants, and
  the task takes them, in order of precedence, from:

  1. application config — `config :extla, Specs.X, constants: %{accounts: …}`
  2. `constant :accounts, default: MapSet.new([…])` beside the declaration

  A constant with neither is an error naming both places it could be supplied.

  ## Options affecting the VERDICT

      --strict-coverage    Treat a never-enabled action or a vacuous property as a
                           failure rather than a warning.
      --allow-incomplete   Exit 0 even if the run was bounded. Off by default: see
                           the exit codes.
      --fingerprint-bits   64 (default) or 128.

  ## Other options

      --max-states         State limit for the run.
      --workers            Explore on N processes (default 1). Refused together
                           with liveness, so a spec that declares a `temporal`
                           has its safety checked in parallel and says so.
      --safety-only        Skip liveness. Liveness is checked whenever the spec
                           declares a `temporal`; this turns it off, and with it the
                           liveness graph the check needs.
      --verify-symmetry    Run the model with and without the `symmetry:` reduction
                           and fail if any verdict differs. Nothing can establish a
                           symmetry declaration's soundness statically, so this is
                           the check that catches a wrong one (08-decisions.md D-17).
      --profile            Report what each of YOUR declarations cost, in reductions
                           (`TLA.Profile`). Off by default and free when off. In
                           reductions rather than milliseconds because a reduction is
                           a function of the code and the data and not of the machine
                           or its load — so two profiles are comparable, and a wall
                           time taken on a busy box is not.
      --format             human (default) or json.

  ## Exit codes

      0  verified
      1  violation (a counterexample was printed — a trace, or a lasso where a
         temporal property was refuted)
      2  incomplete — the state limit or a state constraint bounded the run, so
         the spec was NOT verified
      3  coverage failure (with --strict-coverage)

  Exit code 2 exists because "we ran out of budget" is not "it holds", and a tool
  that returns them as the same number teaches its users to believe something
  false.
  """

  use Mix.Task

  alias TLA.Mix.SpecTarget
  alias TLA.{Coverage, ModelChecker, Profile, Spec, Trace}

  @switches [
    max_states: :integer,
    workers: :integer,
    fingerprint_bits: :integer,
    strict_coverage: :boolean,
    allow_incomplete: :boolean,
    safety_only: :boolean,
    verify_symmetry: :boolean,
    profile: :boolean,
    format: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, names} = OptionParser.parse!(args, strict: @switches)
    modules = SpecTarget.resolve!(names)

    if modules == [] do
      Mix.raise("no TLA.Spec modules found. Name one, or `use TLA.Spec` in a module.")
    end

    results = Enum.map(modules, &check(&1, opts))

    case Keyword.get(opts, :format, "human") do
      "json" -> IO.puts(encode(results))
      "human" -> Enum.each(results, &report/1)
      other -> Mix.raise("unknown --format #{inspect(other)}; expected human or json")
    end

    exit_with(results, opts)
  end

  # ── Running ─────────────────────────────────────────────────────────────────

  defp check(module, opts) do
    spec = Spec.Compiled.from_module(module)
    config = config(spec, opts)
    result = ModelChecker.run(spec, config)
    warnings = result.warnings ++ symmetry_note(spec, config) ++ workers_note(spec, config)
    {module, %{result | warnings: warnings}}
  rescue
    error in TLA.Symmetry.UnsoundError -> {module, {:unsound_symmetry, error}}
  end

  defp config(spec, opts) do
    constants = SpecTarget.constants!(spec)

    symmetry = symmetry(spec)

    # A spec that declares a `temporal` is asking for it to be checked, so the default is
    # to check it. A spec that declares none pays nothing: the liveness graph is only
    # built when there is a question for it to answer. Under a symmetry reduction it is
    # not checked at all — the two are not sound together, and `report/1` says so rather
    # than leaving the spec's own warning to imply the tool forgot.
    # Under `--workers n` liveness is not checked either, for the same reason and handled
    # the same way: the pairing is refused in `TLA.ModelChecker`, so the task must decide
    # rather than hand the user a raise for asking two reasonable things at once.
    # `workers_note/2` says why, beside the symmetry one.
    check_liveness? =
      spec.temporals != [] and not Keyword.get(opts, :safety_only, false) and symmetry == [] and
        workers(opts) == 1

    %{
      constants: constants,
      check_liveness: check_liveness?,
      workers: workers(opts),
      profile: Keyword.get(opts, :profile, false)
    }
    |> maybe_put(:max_states, opts[:max_states])
    |> maybe_put(:fingerprint_bits, opts[:fingerprint_bits])
    |> maybe_symmetry(symmetry, Keyword.get(opts, :verify_symmetry, false))
  end

  # `--workers 0` or a negative one is a typo, not an intent, and the checker's own
  # refusals are about combinations rather than shapes — so it is caught here.
  defp workers(opts) do
    case Keyword.get(opts, :workers, 1) do
      n when is_integer(n) and n > 0 -> n
      n -> Mix.raise("--workers must be a positive integer, got: #{inspect(n)}")
    end
  end

  # The same shape as `symmetry_note/2`, for the same reason: the spec's own warning says
  # the temporal properties went unchecked, and this says which flag decided that.
  defp workers_note(spec, %{workers: n}) when n > 1 do
    if spec.temporals != [] do
      [
        "liveness was not checked: `--workers #{n}` and liveness are refused together — " <>
          "the edge table and ENABLED bits are built per-process, so a parallel run would " <>
          "answer a temporal property from a partial graph. Check them without `--workers`."
      ]
    else
      []
    end
  end

  defp workers_note(_spec, _config), do: []

  # The spec's own warning says the temporal properties went unchecked; this says why,
  # rather than leaving it to read as though the tool forgot.
  defp symmetry_note(spec, config) do
    if Map.get(config, :symmetry, []) != [] and spec.temporals != [] do
      [
        "liveness was not checked: symmetry reduction and liveness are not sound together " <>
          "— the quotient graph can have cycles the real state space does not. Check the " <>
          "temporal properties in a run without `symmetry:`."
      ]
    else
      []
    end
  end

  # Declared beside the constants, because it is a claim about them.
  defp symmetry(spec) do
    :extla
    |> Application.get_env(spec.module, [])
    |> Keyword.get(:symmetry, [])
  end

  defp maybe_symmetry(config, [], _verify), do: config

  defp maybe_symmetry(config, names, verify),
    do: Map.merge(config, %{symmetry: names, verify_symmetry: verify})

  defp maybe_put(config, _key, nil), do: config
  defp maybe_put(config, key, value), do: Map.put(config, key, value)

  # The resolution itself lives on `Spec.Compiled`, so that Layer 3's conformance checking
  # resolves constants the same way rather than a second way. What is here is the Mix
  # flavour of the failure.
  # ── Reporting ───────────────────────────────────────────────────────────────

  defp report({module, {:unsound_symmetry, error}}) do
    Mix.shell().info("")
    Mix.shell().info("#{inspect(module)} — UNSOUND SYMMETRY")
    Mix.shell().info("\n" <> Exception.message(error))
  end

  defp report({module, result}) do
    Mix.shell().info("")
    Mix.shell().info("#{inspect(module)} — #{verdict(result)}")

    Mix.shell().info(
      "  #{result.distinct_states} distinct states, #{result.transitions} transitions, " <>
        "depth #{result.diameter}, #{result.duration_ms}ms"
    )

    if result.violation, do: Mix.shell().info("\n" <> Trace.format(result.violation))

    Mix.shell().info(
      "\n" <> Coverage.format(result.coverage, title: "COVERAGE: #{inspect(module)}")
    )

    # Only when it was asked for. `nil` is not an empty profile — it is the absence of a
    # measurement, the distinction `TLA.Coverage` already makes for a near-miss count.
    if result.profile do
      Mix.shell().info(
        "\n" <> Profile.format(result.profile, title: "PROFILE: #{inspect(module)}")
      )
    end

    for warning <- result.warnings, do: Mix.shell().info("warning: " <> warning)
  end

  defp verdict(%{status: :ok}), do: "verified"

  defp verdict(%{status: :violation, violation: %{prefix: prefix}}),
    do: "LIVENESS: #{prefix.property}"

  defp verdict(%{status: :violation, violation: %{property: nil}}), do: "DEADLOCK"
  defp verdict(%{status: :violation, violation: %{property: name}}), do: "VIOLATION: #{name}"
  defp verdict(%{status: :max_states_reached}), do: "INCOMPLETE (state limit)"
  defp verdict(%{status: :constrained}), do: "INCOMPLETE (state constraint)"

  # The JSON result schema (#66). Versioned and ordered, deliberately.
  #
  # A reader must be able to REFUSE a shape it does not know rather than misread it, so the
  # envelope leads with `schema_version`. Without it, the only way to notice that ExTLA's
  # output changed is to get the wrong answer from it — and #1 section (d) wants agentronic
  # consuming this to place `model_checked` and `refinement_checked` above `static_gate` on its
  # evidence ladder. A cross-project reader that cannot detect a shape change is a maintenance
  # tax on both projects.
  #
  # `specs` is a sorted LIST of self-describing entries rather than a map keyed by module name:
  # a consumer iterating results should not have to know that the key was a module, and the
  # order is stable so two runs diff cleanly.
  # Bumped to 2 by #130, which added `profile`. A purely ADDITIVE key, and it bumps anyway:
  # "additive changes do not count" is the reasoning that makes a version stop meaning
  # anything, and this one exists so a reader can refuse a shape it does not know rather than
  # misread it. The cost is bounded and self-repairing -- `TLA.Mix.TraceFile` refuses a v1
  # document with a message naming both versions and telling the reader to re-run
  # `mix tla.check --format json`, which regenerates it.
  @schema_version 2

  defp encode(results) do
    specs =
      results
      |> Enum.map(fn {module, result} -> Map.put(result_json(result), :spec, inspect(module)) end)
      |> Enum.sort_by(& &1.spec)

    Jason.encode!(%{schema_version: @schema_version, specs: specs}, pretty: true)
  end

  @doc false
  def schema_version, do: @schema_version

  @doc false
  # Exposed for `TLA.SpecOptionsTest`, which holds `spec/04`'s documented option list and this
  # to each other. A module attribute is not readable at runtime, and the alternative — the test
  # parsing this file's source for `@switches` — would be a second parser to keep working.
  def switches, do: @switches

  defp result_json({:unsound_symmetry, error}) do
    %{
      empty_result()
      | status: :unsound_symmetry,
        message: Exception.message(error)
    }
  end

  defp result_json(result) do
    %{
      empty_result()
      | status: result.status,
        distinct_states: result.distinct_states,
        states_found: result.states_found,
        transitions: result.transitions,
        diameter: result.diameter,
        deadlock: result.deadlock,
        duration_ms: result.duration_ms,
        fingerprint_bits: result.fingerprint_bits,
        collision_estimate: result.collision_estimate,
        warnings: result.warnings,
        coverage: %{
          actions: result.coverage.actions,
          never_enabled: result.coverage.never_enabled,
          invariants: result.coverage.invariants,
          vacuous: result.coverage.vacuous,
          terminal_but_live: result.coverage.terminal_but_live,
          bounded_by: result.coverage.bounded_by
        },
        profile: profile_json(result.profile),
        violation: violation_json(result.violation)
    }
  end

  # Every entry carries every key. A field that is absent because nothing measured it is
  # `null`, which is NOT the same fact as zero: a zero near-miss count is a finding, and not
  # having looked is not (`TLA.Coverage`'s own distinction). A consumer must be able to tell
  # them apart, so nothing here is defaulted to 0 on the way out.
  defp empty_result do
    %{
      status: nil,
      message: nil,
      distinct_states: nil,
      states_found: nil,
      transitions: nil,
      diameter: nil,
      deadlock: nil,
      duration_ms: nil,
      fingerprint_bits: nil,
      collision_estimate: nil,
      warnings: [],
      coverage: nil,
      profile: nil,
      violation: nil
    }
  end

  # `nil` rather than an empty map when profiling was off: not-measured is not zero, and a
  # consumer that reads `%{}` as "nothing cost anything" would be wrong in the one direction
  # that matters. The key is `{kind, name}` on the struct and cannot be a JSON object key, so
  # each declaration is written self-describing -- the same reason `specs` is a list.
  defp profile_json(nil), do: nil

  defp profile_json(profile) do
    %{
      run_reductions: profile.run_reductions,
      otp_version: profile.otp_version,
      calibration: profile.calibration,
      declarations:
        profile.declarations
        |> Enum.map(fn {{kind, name}, entry} ->
          %{
            kind: kind,
            name: name,
            evaluations: entry.evaluations,
            reductions: entry.reductions,
            per_eval: entry.per_eval,
            observed: entry.observed
          }
        end)
        |> Enum.sort_by(&{&1.kind, &1.name})
    }
  end

  # `TLA.Trace.to_json/1` rather than a local encoder: an earlier one wrote states and
  # bindings with `inspect/1`, which reads well and parses back into nothing — and
  # `05-layer3-conformance.md`'s pipeline feeds this output straight into
  # `mix tla.replay --trace`. The human rendering is `Trace.format/1` and is unchanged.
  defp violation_json(nil), do: nil
  defp violation_json(violation), do: Trace.to_json(violation)

  # ── Exit ────────────────────────────────────────────────────────────────────

  defp status_of({:unsound_symmetry, _error}), do: :unsound_symmetry
  defp status_of(result), do: result.status

  defp exit_with(results, opts) do
    statuses = Enum.map(results, fn {_module, result} -> status_of(result) end)

    coverages =
      for {_module, %{coverage: coverage}} <- results, do: coverage

    allow_incomplete = Keyword.get(opts, :allow_incomplete, false)
    strict = Keyword.get(opts, :strict_coverage, false)

    cond do
      # A wrong `symmetry:` is a failure of the same kind as a violation: the answer the
      # run gave cannot be trusted.
      :unsound_symmetry in statuses ->
        exit({:shutdown, 1})

      :violation in statuses ->
        exit({:shutdown, 1})

      not allow_incomplete and Enum.any?(statuses, &(&1 in [:max_states_reached, :constrained])) ->
        exit({:shutdown, 2})

      strict and Enum.any?(coverages, &(not Coverage.clean?(&1))) ->
        exit({:shutdown, 3})

      true ->
        :ok
    end
  end
end
