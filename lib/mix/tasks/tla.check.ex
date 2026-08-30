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
      --safety-only        Skip liveness. (Phase 1 checks only safety anyway.)
      --format             human (default) or json.

  ## Exit codes

      0  verified
      1  violation (a counterexample was printed)
      2  incomplete — the state limit or a state constraint bounded the run, so
         the spec was NOT verified
      3  coverage failure (with --strict-coverage)

  Exit code 2 exists because "we ran out of budget" is not "it holds", and a tool
  that returns them as the same number teaches its users to believe something
  false.
  """

  use Mix.Task

  alias TLA.{Coverage, ModelChecker, Spec, Trace}

  @switches [
    max_states: :integer,
    fingerprint_bits: :integer,
    strict_coverage: :boolean,
    allow_incomplete: :boolean,
    safety_only: :boolean,
    format: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, names} = OptionParser.parse!(args, strict: @switches)
    modules = resolve_modules(names)

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
    {module, ModelChecker.run(spec, config)}
  end

  defp config(spec, opts) do
    constants = constants!(spec)

    %{constants: constants}
    |> maybe_put(:max_states, opts[:max_states])
    |> maybe_put(:fingerprint_bits, opts[:fingerprint_bits])
  end

  defp maybe_put(config, _key, nil), do: config
  defp maybe_put(config, key, value), do: Map.put(config, key, value)

  defp constants!(spec) do
    configured =
      :extla
      |> Application.get_env(spec.module, [])
      |> Keyword.get(:constants, %{})
      |> Map.new()

    constants = Map.merge(Spec.Compiled.default_constants(spec), configured)

    case Spec.Compiled.constant_names(spec) -- Map.keys(constants) do
      [] ->
        constants

      missing ->
        Mix.raise("""
        #{inspect(spec.module)} has no assignment for \
        #{Enum.map_join(missing, ", ", &inspect/1)}.

        Supply them either beside the declaration:

            constant #{inspect(hd(missing))}, default: …

        or in config/config.exs:

            config :extla, #{inspect(spec.module)}, constants: %{#{hd(missing)}: …}
        """)
    end
  end

  # ── Reporting ───────────────────────────────────────────────────────────────

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

    for warning <- result.warnings, do: Mix.shell().info("warning: " <> warning)
  end

  defp verdict(%{status: :ok}), do: "verified"
  defp verdict(%{status: :violation, violation: %{property: nil}}), do: "DEADLOCK"
  defp verdict(%{status: :violation, violation: %{property: name}}), do: "VIOLATION: #{name}"
  defp verdict(%{status: :max_states_reached}), do: "INCOMPLETE (state limit)"
  defp verdict(%{status: :constrained}), do: "INCOMPLETE (state constraint)"

  defp encode(results) do
    payload =
      Map.new(results, fn {module, result} ->
        {inspect(module),
         %{
           status: result.status,
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
           violation: violation_json(result.violation)
         }}
      end)

    Jason.encode!(payload, pretty: true)
  end

  defp violation_json(nil), do: nil

  defp violation_json(trace) do
    %{
      type: trace.type,
      property: trace.property,
      message: trace.message,
      length: trace.length,
      actions: trace.actions,
      bindings: Enum.map(trace.bindings, &inspect/1),
      states: Enum.map(trace.states, &inspect/1)
    }
  end

  # ── Exit ────────────────────────────────────────────────────────────────────

  defp exit_with(results, opts) do
    statuses = Enum.map(results, fn {_module, result} -> result.status end)
    coverages = Enum.map(results, fn {_module, result} -> result.coverage end)
    allow_incomplete = Keyword.get(opts, :allow_incomplete, false)
    strict = Keyword.get(opts, :strict_coverage, false)

    cond do
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

  # ── Discovery ───────────────────────────────────────────────────────────────

  defp resolve_modules([]) do
    Mix.Project.config()
    |> Keyword.fetch!(:app)
    |> :application.get_key(:modules)
    |> case do
      {:ok, modules} -> Enum.filter(modules, &spec?/1)
      :undefined -> []
    end
    |> Enum.sort()
  end

  defp resolve_modules(names) do
    Enum.map(names, fn name ->
      module = Module.concat([name])

      unless spec?(module) do
        Mix.raise("#{inspect(module)} is not a TLA spec: it does not `use TLA.Spec`.")
      end

      module
    end)
  end

  defp spec?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__tla_spec__, 0)
  end
end
