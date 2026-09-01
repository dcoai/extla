defmodule Mix.Tasks.Tla.Simulate do
  @shortdoc "Run random traces of a TLA.GenServer against its spec"

  @moduledoc """
  Run random traces of a `TLA.GenServer` module against the specification it refines.

  ## Usage

      mix tla.simulate MyApp.TransferServer
      mix tla.simulate MyApp.TransferServer --traces 5000 --steps 100
      mix tla.simulate MyApp.TransferServer --inject-failures --seed 42

  Where `mix tla.check` explores every reachable state of the *specification*, this runs
  the *implementation* and checks each transition against the spec with the same
  refinement check the runtime wrapper uses.

  ## Options

      --traces             How many random traces (default 100).
      --steps              Maximum steps per trace (default 25).
      --seed               Reproduce a previous run. The seed is always reported.
      --concurrency        Traces to run at once (default 1).
      --inject-failures    Kill and restart the server mid-trace, and check that
                           recovery lands in a state the spec's invariants admit.
                           A crash is not a step of the specification — nothing in
                           the DSL models one — so the restart itself is not checked
                           as a transition.
      --unrestricted       Also generate messages for actions the spec DISABLES in
                           the current state, which asks whether the implementation
                           refuses what the spec forbids. Off by default: most
                           servers are not written to, and the resulting
                           `:not_enabled` is a true finding about nearly all of
                           them.
      --format             human (default) or json.
      --against-graph      Also require every observed state to be a node of the
                           model checker's graph and every step an edge. Off by
                           default: it needs a completed graph, which not every
                           simulation target has, and it runs traces one at a
                           time because containment is a question about each
                           behaviour rather than about the verdict.

  ## Exit codes

      0  no finding in the traces that were run
      1  a conformance violation — the counterexample is printed as a trace
      2  the server stopped or stopped answering, which is a finding of a different
         kind: nothing about conformance was decided after that point

  A green run has checked the traces it drew and nothing else. The coverage line says
  which actions those were, and a run over a generator that never produced an action says
  nothing about it.
  """

  use Mix.Task

  alias TLA.{Simulation, Trace}
  alias TLA.Simulation.Generator

  @switches [
    traces: :integer,
    steps: :integer,
    seed: :integer,
    concurrency: :integer,
    inject_failures: :boolean,
    unrestricted: :boolean,
    against_graph: :boolean,
    format: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, names} = OptionParser.parse!(args, strict: @switches)

    module =
      case names do
        [name] -> resolve!(name)
        [] -> Mix.raise("name the TLA.GenServer module to simulate.")
        many -> Mix.raise("one module at a time; got #{Enum.join(many, ", ")}.")
      end

    result = Simulation.run(module, config(module, opts))

    if Keyword.get(opts, :against_graph, false) do
      check_against_graph(module, opts)
    end

    case Keyword.get(opts, :format, "human") do
      "json" -> IO.puts(encode(module, result))
      "human" -> report(module, result)
      other -> Mix.raise("unknown --format #{inspect(other)}; expected human or json")
    end

    exit_with(result)
  end

  defp resolve!(name) do
    module = Module.concat([name])

    cond do
      not Code.ensure_loaded?(module) ->
        Mix.raise("#{inspect(module)} is not a module in this project.")

      not function_exported?(module, :__tla_spec_module__, 0) ->
        Mix.raise(
          "#{inspect(module)} does not `use TLA.GenServer`, so there is no specification " <>
            "to simulate it against. (A module compiled under `config :extla, mode: " <>
            ":disabled` also carries nothing — see 05-layer3-conformance.md.)"
        )

      true ->
        module
    end
  end

  # Cross-layer agreement (#49): every state the server visits must be a node of the
  # checker's graph, and every step an edge. A step the SPEC permits that the graph lacks
  # is a defect in the search — the one finding no other gate here can produce.
  #
  # Traces run one at a time under this flag, because `Simulation.run/2` returns a verdict
  # and not the behaviours, and containment is a question about each behaviour. That is
  # the cost of the flag, and it is why it is off by default.
  defp check_against_graph(module, opts) do
    spec_module = module.__tla_spec_module__()
    spec = TLA.Spec.Compiled.from_module(spec_module)

    constants =
      case TLA.Spec.Compiled.resolve_constants(spec) do
        {:ok, constants} ->
          constants

        {:error, missing} ->
          Mix.raise(
            "--against-graph builds the model checker's graph for " <>
              "#{inspect(spec_module)}, and it has no assignment for " <>
              "#{Enum.map_join(missing, ", ", &inspect/1)}. Give them a `default:` beside " <>
              "the declaration, or in config."
          )
      end

    {result, graph} =
      TLA.ModelChecker.explore(spec_module, %{
        constants: constants,
        liveness_graph: true,
        invariants: [],
        action_properties: []
      })

    unless result.status in [:ok, :violation, :deadlock] do
      Mix.raise(
        "--against-graph needs a complete graph, and checking #{inspect(spec_module)} " <>
          "returned #{inspect(result.status)}. Absence from a truncated graph is a fact " <>
          "about the bound rather than about the search, so this declines to answer " <>
          "rather than report a finding it cannot stand behind."
      )
    end

    traces = Keyword.get(opts, :traces, 100)
    seed = Keyword.get(opts, :seed, :erlang.unique_integer([:positive]))

    finding =
      Enum.find_value(1..traces, fn i ->
        {_result, behaviour} =
          Simulation.run_trace(module, %{
            max_steps: Keyword.get(opts, :steps, 20),
            seed: seed + i
          })

        case TLA.Conformance.against_graph(graph, behaviour, status: result.status) do
          :ok -> nil
          found -> {i, found}
        end
      end)

    case finding do
      nil ->
        Mix.shell().info(
          "\nagainst-graph: #{traces} traces, every state a node and every step an edge."
        )

      {i, found} ->
        Mix.shell().info("\nagainst-graph: trace #{i} (seed #{seed + i}) left the graph.\n")
        Mix.shell().info(TLA.Conformance.explain(found))
        exit({:shutdown, 1})
    end
  end

  defp config(module, opts) do
    %{
      traces: Keyword.get(opts, :traces, 100),
      max_steps: Keyword.get(opts, :steps, 25),
      concurrency: Keyword.get(opts, :concurrency, 1),
      inject_failures: Keyword.get(opts, :inject_failures, false)
    }
    |> put_seed(opts)
    |> put_generator(module, opts)
  end

  defp put_seed(config, opts) do
    case Keyword.fetch(opts, :seed) do
      {:ok, seed} -> Map.put(config, :seed, seed)
      :error -> config
    end
  end

  defp put_generator(config, module, opts) do
    if Keyword.get(opts, :unrestricted, false) do
      spec = module.__tla_spec_module__()
      refinement = module.__tla_refinement__()

      {:ok, constants} =
        spec |> TLA.Spec.Compiled.from_module() |> TLA.Spec.Compiled.resolve_constants()

      Map.put(config, :message_generator, Generator.from_spec(spec, refinement, constants))
    else
      config
    end
  end

  # ── Reporting ───────────────────────────────────────────────────────────────

  defp report(module, result) do
    Mix.shell().info("")
    Mix.shell().info("#{inspect(module)} — #{verdict(result)}")

    Mix.shell().info(
      "  #{result.traces_run} traces, #{result.total_steps} steps, " <>
        "#{result.restarts} restarts, #{result.duration_ms}ms, seed #{result.seed}"
    )

    Mix.shell().info(
      "  covered #{percent(result.coverage.actions_covered)} of the spec's actions: " <>
        actions(result.coverage.actions_hit)
    )

    Mix.shell().info("  #{result.coverage.states_visited} distinct abstract states")

    if result.detail, do: Mix.shell().info("\n  #{result.detail}")

    if result.violation do
      # The trace shows the route; the message shows the finding. A conformance violation
      # carries its whole content in the message — which variable diverged, which guard
      # was false — and `Trace.format/1` prints neither.
      Mix.shell().info("\n" <> result.violation.message)
      Mix.shell().info("\n" <> Trace.format(result.violation))
    end
  end

  defp verdict(%{status: :ok}), do: "NO FINDING"
  defp verdict(%{status: :violation, violation: %{property: nil}}), do: "CONFORMANCE VIOLATION"

  defp verdict(%{status: :violation, violation: %{property: name}}),
    do: "CONFORMANCE VIOLATION: #{name}"

  defp verdict(%{status: :error}), do: "THE SERVER DID NOT ANSWER"

  defp percent(fraction), do: "#{round(fraction * 100)}%"

  defp actions(hit) when hit == %{}, do: "none"

  defp actions(hit),
    do: hit |> Enum.sort() |> Enum.map_join(", ", fn {name, count} -> "#{name} x#{count}" end)

  defp encode(module, result) do
    Jason.encode!(
      %{
        module: inspect(module),
        status: result.status,
        traces_run: result.traces_run,
        total_steps: result.total_steps,
        restarts: result.restarts,
        duration_ms: result.duration_ms,
        seed: result.seed,
        detail: result.detail,
        coverage: result.coverage,
        violation:
          result.violation &&
            %{
              property: result.violation.property,
              message: result.violation.message,
              length: result.violation.length,
              actions: result.violation.actions,
              states: Enum.map(result.violation.states, &inspect/1)
            }
      },
      pretty: true
    )
  end

  defp exit_with(%{status: :ok}), do: :ok
  defp exit_with(%{status: :violation}), do: exit({:shutdown, 1})
  defp exit_with(%{status: :error}), do: exit({:shutdown, 2})
end
