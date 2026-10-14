defmodule Mix.Tasks.Extla.Replay do
  @shortdoc "Drive a ExTLA.GenServer through a spec-level behaviour"

  @moduledoc """
  Drive a `ExTLA.GenServer` through a spec-level behaviour, or check a captured one.

  ## Usage

      # Replay a model-checker counterexample (from `mix extla.check --format json`)
      mix extla.replay MyApp.TransferServer --trace counterexample.json

      # Check a captured trace from a running system
      mix extla.replay MyApp.TransferServer --captured incident.json

  ## Driving options (`--trace` only)

      --init-arg TERM   the argument the server is started with (default []): a literal
                        term such as `[start: 0]`; an expression is refused, never run
      --server NAME     drive a running, registered process (`MyApp.Server` or `:name`)
                        instead of starting one; it is not stopped afterwards
      --timeout MS      milliseconds to wait for each reply (default 5000)

  They are `ExTLA.Replay.counterexample/3`'s `:init_arg`, `:server` and `:timeout`.
  `--init-arg` with `--server` is refused, since a running server is not started. All
  three are refused with `--captured`, which drives nothing.

  `--trace` needs `concrete_message/2` on the refinement module: it starts from *abstract*
  actions and has to produce the message that causes each. `--captured` needs only
  `abstract/1` and `abstract_action/1`, and starts nothing — it is a pure check over
  recorded data, which is what makes it usable in CI against a fixture or offline against
  an incident.

  ## The file formats

  `--trace` takes what `mix extla.check --format json` writes: either the whole document —
  `{"schema_version": …, "specs": [...]}`, from which the entry for the server's spec is
  used — or a single trace object lifted out of it. A document written by a different schema
  version is refused, naming both versions; re-run `mix extla.check --format json`.

  `--captured` takes an array of `{"message": …, "state": …}` objects, oldest first, where
  `state` is the CONCRETE state the implementation was in *after* that message. Both
  encodings are `ExTLA.State.Json`'s, so a state is written the way the checker writes one
  and no second format has to be learned.

  ## Steps a trace names and this cannot drive

  A trace's actions are not all actions of the spec. `ExTLA.Simulation` writes `:unmapped`
  for a message the refinement mapping does not model — its *normal* answer, not an error —
  and `:restart` for a crash injected by `--inject-failures`. `concrete_message/2` has no
  clause for either.

  `:unmapped` is **skipped**, and listed in the report and in `skipped` under `--format
  json`. The claim `:unmapped` makes is that the message does not move the abstract state,
  so the behaviour is unchanged by it; the trace's post-state is still checked.

  `:restart` is **reproduced**: the server is killed with `:kill`, not stopped politely,
  because a crash runs no `terminate/2`. It is then started again, and the replay checks
  that recovery lands in the state the trace records. This is possible only for a server
  this task started; against `--server` a restart exits 3.

  ## Output

      --format human|json   the report as text (default) or as a JSON document

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

  alias ExTLA.{Replay, State}

  @switches [
    trace: :string,
    captured: :string,
    format: :string,
    init_arg: :string,
    server: :string,
    timeout: :integer
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, names} = OptionParser.parse!(args, strict: @switches)
    module = module!(names)

    result =
      case {Keyword.get(opts, :trace), Keyword.get(opts, :captured)} do
        {nil, nil} ->
          Mix.raise("pass --trace <file> or --captured <file>.")

        {trace, nil} ->
          replay_opts = replay_opts!(opts)
          Replay.counterexample(module, read_trace!(trace, module), replay_opts)

        {nil, captured} ->
          drives_nothing!(opts)
          Replay.trace(module, read_capture!(captured))

        {_both, _files} ->
          Mix.raise("pass one of --trace or --captured, not both.")
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
          "#{inspect(module)} does not `use ExTLA.GenServer`, so there is no specification " <>
            "to replay against."
        )

      true ->
        module
    end
  end

  defp module!([]), do: Mix.raise("name the ExTLA.GenServer module to replay against.")
  defp module!(many), do: Mix.raise("one module at a time; got #{Enum.join(many, ", ")}.")

  # `ExTLA.Replay.counterexample/3`'s options, from the command line. They were accepted
  # here and never passed on (#165): `--init-arg` parsed and dropped, and `:server` and
  # `:timeout` unreachable. Each is checked before any file is read, so a refusal names the
  # flag rather than the file.
  defp replay_opts!(opts) do
    if Keyword.has_key?(opts, :server) and Keyword.has_key?(opts, :init_arg) do
      Mix.raise(
        "--init-arg starts a server; --server names one that is already running, so the " <>
          "argument would never be used. Pass one or the other."
      )
    end

    Enum.flat_map(opts, fn
      {:server, name} -> [server: server!(name)]
      {:init_arg, text} -> [init_arg: init_arg!(text)]
      {:timeout, ms} -> [timeout: timeout!(ms)]
      _other -> []
    end)
  end

  # `--captured` checks a recording: it starts no server and sends nothing, so these would
  # be accepted and silently mean nothing, which is #165's defect over again.
  defp drives_nothing!(opts) do
    case Enum.filter([:init_arg, :server, :timeout], &Keyword.has_key?(opts, &1)) do
      [] ->
        :ok

      given ->
        flags = Enum.map_join(given, ", ", &("--" <> String.replace(to_string(&1), "_", "-")))

        Mix.raise(
          "--captured checks a recording and drives no server, so #{flags} would have " <>
            "nothing to act on. Drop them, or replay a counterexample with --trace."
        )
    end
  end

  # A registered name, as an atom (`:name`) or an alias (`MyApp.Server`). The task runs in
  # its own VM after `app.start`, so the process has to be one the application starts and
  # registers. A pid printed by another VM names nothing here.
  defp server!("#PID<" <> _ = text), do: pid_refused!(text)
  defp server!("<" <> _ = text), do: pid_refused!(text)

  defp server!(text) do
    name =
      case text do
        ":" <> atom -> String.to_atom(atom)
        alias -> Module.concat([alias])
      end

    case Process.whereis(name) do
      nil ->
        Mix.raise(
          "no process is registered as #{inspect(name)} in this VM. mix extla.replay runs " <>
            "in its own VM after app.start, so --server must name a process your " <>
            "application starts and registers. Without --server the module is started for " <>
            "the replay."
        )

      _pid ->
        name
    end
  end

  defp pid_refused!(text) do
    Mix.raise(
      "--server takes a registered name (MyApp.Server or :name), not a pid: #{text} was " <>
        "printed by another VM and names nothing in this one."
    )
  end

  # A literal term only. An argument from the command line is data, so nothing in it runs:
  # a call, a variable or an operator is refused rather than evaluated.
  defp init_arg!(text) do
    case Code.string_to_quoted(text) do
      {:ok, quoted} ->
        if Macro.quoted_literal?(quoted) do
          {term, _binding} = Code.eval_quoted(quoted)
          term
        else
          Mix.raise(
            "--init-arg must be a literal term (atoms, numbers, strings, lists, tuples, " <>
              "maps); #{inspect(text)} is an expression, and an argument from the command " <>
              "line is never run."
          )
        end

      {:error, _} ->
        Mix.raise("--init-arg #{inspect(text)} does not parse as an Elixir term.")
    end
  end

  defp timeout!(ms) when ms > 0, do: ms

  defp timeout!(ms),
    do: Mix.raise("--timeout must be a positive number of milliseconds; got #{ms}.")

  # `mix extla.check --format json` writes a versioned envelope; a file holding one lifted-out
  # trace is accepted too. `ExTLA.Mix.TraceFile` holds the reading, shared with
  # `mix extla.explore` so the two cannot drift on what they accept or how they refuse it.
  defp read_trace!(path, module) do
    ExTLA.Mix.TraceFile.read!(path, inspect(module.__tla_spec_module__()))
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
  # Exposed for `ExTLA.SpecOptionsTest`, which holds this and the specification's documented
  # option list to each other (#163). `extla.check` gained this at #134 and nothing else did, so
  # for six work items its section was the only flag list in the spec that stayed correct.
  def switches, do: @switches
end
