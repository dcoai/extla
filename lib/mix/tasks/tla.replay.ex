defmodule Mix.Tasks.Tla.Replay do
  @shortdoc "Drive a TLA.GenServer through a spec-level behaviour"

  @moduledoc """
  Drive a `TLA.GenServer` through a spec-level behaviour, or check a captured one.

  ## Usage

      # Replay a model-checker counterexample (from `mix tla.check --format json`)
      mix tla.replay MyApp.TransferServer --trace counterexample.json

      # Check a captured trace from a running system
      mix tla.replay MyApp.TransferServer --captured incident.json

  `--trace` needs `concrete_message/2` on the refinement module: it starts from *abstract*
  actions and has to produce the message that causes each. `--captured` needs only
  `abstract/1` and `abstract_action/1`, and starts nothing — it is a pure check over
  recorded data, which is what makes it usable in CI against a fixture or offline against
  an incident.

  ## The file formats

  `--trace` takes what `mix tla.check --format json` writes, either the whole document
  (an object keyed by spec module) or a single trace object lifted out of it.

  `--captured` takes an array of `{"message": …, "state": …}` objects, oldest first, where
  `state` is the CONCRETE state the implementation was in *after* that message. Both
  encodings are `TLA.State.Json`'s, so a state is written the way the checker writes one
  and no second format has to be learned.

  ## Steps a trace names and this cannot drive

  A trace's actions are not all actions of the spec. `TLA.Simulation` writes `:unmapped`
  for a message the refinement mapping does not model — its *normal* answer, not an error —
  and `:restart` for a crash injected by `--inject-failures`. `concrete_message/2` has no
  clause for either, and calling it regardless is what this used to do (#168).

  `:unmapped` is **skipped**, and listed in the report and in `skipped` under `--format
  json`. The claim `:unmapped` makes is that the message does not move the abstract state,
  so the behaviour is unchanged by it; the trace's post-state is still checked. A replay
  that skipped a step and then exited `0` would report more than it did.

  `:restart` is **reproduced**: the server is killed and started again, and recovery is
  checked to land where the trace says it did — all `TLA.Simulation` checks about a restart
  either. `:kill` rather than a polite stop, because a crash runs no `terminate/2`. Only
  for a server this task started.

  ## Exit codes

      0  the behaviour was reproduced, or the capture conforms
      1  a conformance violation — the step and its finding are printed
      2  the implementation could not follow the trace. Not a conformance failure:
         the spec permits a behaviour the code does not take, and which of the two
         is wrong is not something this can decide
      3  the trace names a step this cannot reproduce — a `:restart` against a
         server it was handed and does not own. A limit of the replay rather than
         a claim about the implementation, which is why it is not 2
  """

  use Mix.Task

  alias TLA.{Replay, State}

  @switches [trace: :string, captured: :string, format: :string, init_arg: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, names} = OptionParser.parse!(args, strict: @switches)
    module = module!(names)

    result =
      case {Keyword.get(opts, :trace), Keyword.get(opts, :captured)} do
        {nil, nil} -> Mix.raise("pass --trace <file> or --captured <file>.")
        {trace, nil} -> Replay.counterexample(module, read_trace!(trace, module))
        {nil, captured} -> Replay.trace(module, read_capture!(captured))
        {_both, _files} -> Mix.raise("pass one of --trace or --captured, not both.")
      end

    case Keyword.get(opts, :format, "human") do
      "json" -> IO.puts(Jason.encode!(json(module, result), pretty: true))
      "human" -> report(module, result)
      other -> Mix.raise("unknown --format #{inspect(other)}; expected human or json")
    end

    exit_with(result)
  end

  defp module!([name]) do
    module = Module.concat([name])

    cond do
      not Code.ensure_loaded?(module) ->
        Mix.raise("#{inspect(module)} is not a module in this project.")

      not function_exported?(module, :__tla_spec_module__, 0) ->
        Mix.raise(
          "#{inspect(module)} does not `use TLA.GenServer`, so there is no specification " <>
            "to replay against."
        )

      true ->
        module
    end
  end

  defp module!([]), do: Mix.raise("name the TLA.GenServer module to replay against.")
  defp module!(many), do: Mix.raise("one module at a time; got #{Enum.join(many, ", ")}.")

  # `mix tla.check --format json` writes a versioned envelope; a file holding one lifted-out
  # trace is accepted too. `TLA.Mix.TraceFile` holds the reading, shared with
  # `mix tla.explore` so the two cannot drift on what they accept or how they refuse it.
  defp read_trace!(path, module) do
    TLA.Mix.TraceFile.read!(path, inspect(module.__tla_spec_module__()))
  end

  defp read_capture!(path) do
    case decode_file!(path) do
      entries when is_list(entries) ->
        Enum.map(entries, fn
          %{"message" => message, "state" => state} ->
            {State.Json.decode!(message), State.Json.decode!(state)}

          other ->
            Mix.raise(
              "#{inspect(other)} is not a captured step: expected " <>
                ~s({"message": …, "state": …}.)
            )
        end)

      _other ->
        Mix.raise("#{path} must hold an array of captured steps, oldest first.")
    end
  end

  defp decode_file!(path) do
    unless File.exists?(path), do: Mix.raise("#{path} does not exist.")

    case Jason.decode(File.read!(path)) do
      {:ok, data} -> data
      {:error, error} -> Mix.raise("#{path} is not JSON: #{Exception.message(error)}")
    end
  end

  # ── Reporting ───────────────────────────────────────────────────────────────

  defp report(module, result) do
    Mix.shell().info("")
    Mix.shell().info("#{inspect(module)} — #{verdict(result)}")
    Mix.shell().info("  #{result.steps_checked} steps checked")

    if result.violation do
      Mix.shell().info(
        "\n  step #{result.violation.step}, message #{inspect(result.violation.message)}"
      )

      Mix.shell().info("\n" <> result.violation.detail)
    end

    if result.detail, do: Mix.shell().info("\n  " <> result.detail)
  end

  defp verdict(%{status: :ok}), do: "REPRODUCED"
  defp verdict(%{status: :violation, violation: %{kind: kind}}), do: "CONFORMANCE: #{kind}"
  defp verdict(%{status: :not_followed}), do: "NOT FOLLOWED"

  # A trace can name a step this task cannot reproduce — a `:restart`, where the caller
  # supplied the server it is not ours to kill. Its own verdict, because "not followed" is
  # a claim about the implementation and this is a limit of the replay (#168).
  defp verdict(%{status: :not_replayable}), do: "NOT REPLAYABLE"

  defp json(module, result) do
    %{
      module: inspect(module),
      status: result.status,
      steps_checked: result.steps_checked,
      skipped: Enum.map(result.skipped, fn {step, action} -> %{step: step, action: action} end),
      detail: result.detail,
      violation:
        result.violation &&
          %{
            step: result.violation.step,
            kind: result.violation.kind,
            action: result.violation.action,
            message: inspect(result.violation.message),
            detail: result.violation.detail
          }
    }
  end

  defp exit_with(%{status: :ok}), do: :ok
  defp exit_with(%{status: :violation}), do: exit({:shutdown, 1})
  defp exit_with(%{status: :not_followed}), do: exit({:shutdown, 2})

  # Its own code, and not 2: `2` says the implementation did not take a step the spec
  # permits, which is a finding about the pair. This says the replay could not try.
  defp exit_with(%{status: :not_replayable}), do: exit({:shutdown, 3})

  @doc false
  # Exposed for `TLA.SpecOptionsTest`, which holds this and the specification's documented
  # option list to each other (#163). `tla.check` gained this at #134 and nothing else did, so
  # for six work items its section was the only flag list in the spec that stayed correct.
  def switches, do: @switches
end
