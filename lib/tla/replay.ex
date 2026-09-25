defmodule TLA.Replay do
  @moduledoc """
  Run a spec-level behaviour against a real implementation.

  Where `TLA.GenServer`'s wrapper checks whatever the system happens to do, this starts
  from a sequence of *abstract* actions and makes the implementation follow it. Two
  sources of such a sequence, and both matter:

  - `counterexample/3` replays a trace the model checker produced. This closes the loop
    that makes the three layers one tool rather than three: Layer 2 finds a design bug
    before any code exists, and this runs that exact trace against the code.
  - `trace/3` checks a **captured** behaviour — from staging, from production, from a
    recorded test run — with the same `check_step!/5` the runtime wrapper uses. Nothing
    needs to be running: it is a pure function over recorded data, so it runs in CI
    against a fixture or offline against an incident.

  ## A counterexample the implementation cannot follow is itself a finding

  It means the spec permits a behaviour the code does not, so one of the two is wrong.
  That is reported as a result, not as an error — which is why every check in
  `TLA.GenServer.Runtime` has a form that returns its finding. A report saying *which step*
  failed cannot be assembled by catching the exception the wrapper raises.

  ## What drives the server

  `c:TLA.Refinement.concrete_message/2` — the inverse of `c:TLA.Refinement.abstract_action/1`, and the
  callback `validate!/3` round-trips at compile time. A refinement that does not define it
  can be *checked* as it runs and cannot be *driven*, which is most of what this module is
  for; `counterexample/3` says so by name rather than failing with an undefined function.
  """

  alias TLA.GenServer.{Driver, Runtime}
  alias TLA.Trace

  @type violation :: %{
          step: non_neg_integer(),
          kind: :not_enabled | :diverged | :unmapped_but_moved | :invariant | :action_property,
          action: atom() | nil,
          message: term(),
          detail: String.t()
        }

  @type result :: %{
          status: :ok | :violation | :not_followed | :not_replayable,
          steps_checked: non_neg_integer(),
          violation: violation() | nil,
          detail: String.t() | nil,

          # The steps this replay did not drive, oldest first: `{step, action}`. A trace's
          # `actions` may hold entries that are not actions of the spec — `TLA.Simulation`
          # writes `:unmapped` for a message the mapping does not model — and those have no
          # message to send. They are skipped, and they are **listed**, because a replay
          # that skipped steps and answered `:ok` would report more than it did (#168).
          skipped: [{pos_integer(), atom()}]
        }

  @doc """
  Replay a model-checker counterexample against the implementation.

  Accepts a `TLA.Trace` or a lasso (`%{prefix:, cycle:}`), whose cycle is replayed once —
  a lasso describes a behaviour repeating forever, and one pass is what can be executed.

  Options:

  - `:server` — a pid or registered name to drive. Without it the module is started with
    `GenServer.start_link(module, init_arg)`.
  - `:init_arg` — the argument for that start (default `[]`).
  - `:timeout` — per message (default 5000).

  Returns `:not_followed` when the implementation refuses a message the trace calls for —
  the server stopping, or timing out. That is the informative case above: the spec permits
  a step the code does not take.
  """
  def counterexample(module, trace, opts \\ [])

  def counterexample(module, %{prefix: prefix, cycle: cycle}, opts) do
    counterexample(module, splice(prefix, cycle), opts)
  end

  def counterexample(module, %Trace{} = trace, opts) do
    refinement = module.__tla_refinement__()
    spec_module = module.__tla_spec_module__()

    # `Code.ensure_loaded?/1` first: `function_exported?/3` answers about a LOADED module,
    # so on a cold module it reports every optional callback as absent — which would make
    # a perfectly drivable refinement report itself undrivable, depending on what had
    # happened to run first.
    if Code.ensure_loaded?(refinement) and function_exported?(refinement, :concrete_message, 2) do
      drive(module, spec_module, refinement, trace, opts)
    else
      %{
        status: :not_followed,
        steps_checked: 0,
        violation: nil,
        skipped: [],
        detail:
          "#{inspect(refinement)} does not define concrete_message/2, so there is no " <>
            "message to drive #{inspect(module)} with. A refinement without it can be " <>
            "checked as it runs and cannot be replayed."
      }
    end
  end

  @doc """
  Check a captured trace — `[{message, concrete_state}]`, oldest first — against the spec.

  The state in each pair is the state the implementation was in **after** that message.
  Every consecutive pair is a transition, mapped through `abstract/1` and checked with the
  same step check the wrapper uses; the spec's invariants and action properties are checked
  beside it.

  A capture of one entry is checked for the spec's invariants and nothing else: one state
  is not a step.
  """
  def trace(module, captured, opts \\ [])

  def trace(_module, [], _opts),
    do: %{status: :ok, steps_checked: 0, violation: nil, detail: nil, skipped: []}

  def trace(module, [{_message, first} | _] = captured, _opts) do
    spec_module = module.__tla_spec_module__()
    refinement = module.__tla_refinement__()

    abstract =
      Enum.map(captured, fn {message, concrete} ->
        {message, abstract(spec_module, refinement, concrete)}
      end)

    case Runtime.check_spec_invariants(spec_module, abstract(spec_module, refinement, first)) do
      {:violation, violation} ->
        violated(0, elem(hd(captured), 0), violation)

      :ok ->
        abstract
        |> Enum.zip(tl(abstract))
        |> Enum.with_index(1)
        |> Enum.reduce_while(ok(length(captured) - 1), fn {{{_, pre}, {message, post}}, step},
                                                          acc ->
          case checks(spec_module, refinement, message, pre, post) do
            :ok -> {:cont, acc}
            {:violation, violation} -> {:halt, violated(step, message, violation)}
          end
        end)
    end
  end

  # ── Driving a live server ───────────────────────────────────────────────────

  # The trace's own states are the oracle beside the wrapper's checks: the implementation
  # may take a legal step that is not the step the counterexample took, and a replay that
  # only asked "was each step legal" would call that a reproduction.
  #
  # The server is carried through the fold rather than closed over, because a `:restart`
  # step replaces it.
  defp drive(module, spec_module, refinement, trace, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    expected = Enum.drop(trace.states, 1)

    steps =
      [trace.actions, trace.bindings, expected]
      |> Enum.zip()
      |> Enum.with_index(1)

    ctx = %{
      module: module,
      spec_module: spec_module,
      refinement: refinement,
      timeout: timeout,
      opts: opts
    }

    {result, server} =
      Enum.reduce_while(steps, {ok(0), server(module, opts)}, fn {{action, binding, want}, step},
                                                                 {acc, server} ->
        step(ctx, server, acc, {action, binding, want, step})
      end)

    stop_owned(opts, server, timeout)

    finish(result)
  end

  # `TLA.Simulation` stops the server it started; this did not, so a replay left a live
  # `GenServer` behind — one per call, for the lifetime of the caller. The two modules are
  # the same shape and only one cleaned up (#316).
  #
  # Only a server this module started. A caller-supplied `:server` is not ours to stop,
  # which is the same ownership line `restart/5` draws when it refuses to reproduce a
  # `:restart` step against a borrowed server.
  defp stop_owned(opts, server, timeout) do
    if Keyword.has_key?(opts, :server), do: :ok, else: stop(server, timeout)
  end

  # Stopped the way a supervisor stops a child, as `TLA.Simulation` does (#213): a
  # `:shutdown` exit so a server that traps it runs its `terminate/2`, a bounded wait so a
  # `terminate/2` that hangs does not hang the replay, and a kill after that. A server that
  # has already stopped — which is how a `:not_followed` replay usually ends — makes the
  # monitor fire at once with `:noproc`, so this costs nothing on that path.
  defp stop(server, timeout) do
    ref = Process.monitor(server)
    Process.exit(server, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^server, _reason} -> :ok
    after
      timeout ->
        Process.exit(server, :kill)

        receive do
          {:DOWN, ^ref, :process, ^server, _reason} -> :ok
        end
    end
  end

  # Not every entry in a trace's `actions` is an action of the spec. `TLA.Simulation` writes
  # `:unmapped` for a message the mapping does not model — its NORMAL answer, not an error —
  # and `:restart` for a crash it injected under `--inject-failures`. `concrete_message/2`
  # has no clause for either, and this used to call it regardless and die with a
  # `FunctionClauseError` (#168): the advertised simulation-to-replay handoff crashing on
  # its ordinary input.
  defp step(ctx, server, acc, {:unmapped, _binding, want, step}),
    do: skip(ctx, server, acc, want, step)

  defp step(ctx, server, acc, {:restart, _binding, want, step}),
    do: restart(ctx, server, acc, want, step)

  defp step(ctx, server, acc, {action, binding, want, step}) do
    message = ctx.refinement.concrete_message(action, binding)

    case send_message(server, message, ctx.timeout) do
      {:ok, _reply} ->
        got = abstract(ctx.spec_module, ctx.refinement, :sys.get_state(server))

        if got == want do
          {:cont, {%{acc | steps_checked: step}, server}}
        else
          {:halt,
           {with_skips(diverged_from_trace(step, action, message, want, got), acc), server}}
        end

      {:violation, violation} ->
        {:halt,
         {violated(step, message, violation)
          |> Map.put(:steps_checked, step - 1)
          |> with_skips(acc), server}}

      {:not_followed, detail} ->
        {:halt,
         {%{
            status: :not_followed,
            steps_checked: step - 1,
            violation: nil,
            skipped: acc.skipped,
            detail:
              "step #{step} (#{action}) could not be delivered: #{detail}. The spec " <>
                "permits a behaviour the implementation does not take, so one of the two " <>
                "is wrong."
          }, server}}
    end
  end

  # `:unmapped` is a POSITIVE claim — the message does not move the abstract state, which
  # `Runtime.check_stuttering/3` enforced where the step was recorded — so the abstract
  # behaviour is unchanged by it and there is nothing to send. The trace holds abstract
  # actions, not the concrete messages that produced them, so the message is not even
  # recoverable.
  #
  # It is skipped, and **the skip is counted and reported**. A replay that skipped steps and
  # answered `:ok` would be the same defect as a conformance check passing over a behaviour
  # it never examined. The trace's own post-state is still checked, so a step claiming to
  # stutter and moving the state is caught rather than waved past.
  defp skip(ctx, server, acc, want, step) do
    got = abstract(ctx.spec_module, ctx.refinement, :sys.get_state(server))

    if got == want do
      {:cont, {%{acc | steps_checked: step, skipped: acc.skipped ++ [{step, :unmapped}]}, server}}
    else
      {:halt,
       {with_skips(diverged_from_trace(step, :unmapped, :unmapped, want, got), acc), server}}
    end
  end

  # A crash is not a message, so it is REPRODUCED rather than sent: stop the server, start
  # it again, and check that recovery lands where the trace says it did — which is the only
  # thing `TLA.Simulation` checks about a restart either.
  #
  # Skipping it instead would compare the next step against the PRE-crash state, which is
  # the silent corruption this work item exists to remove. Refusing outright would leave
  # every `--inject-failures` counterexample unreplayable, which is the defect. Reproducing
  # is possible only for a server this module started: a caller-supplied `:server` is not
  # ours to kill, and we do not know what to start in its place.
  defp restart(ctx, server, acc, want, step) do
    if Keyword.has_key?(ctx.opts, :server) do
      {:halt,
       {%{
          status: :not_replayable,
          steps_checked: step - 1,
          violation: nil,
          skipped: acc.skipped,
          detail:
            "step #{step} is a `:restart` — a crash the simulation injected, not a " <>
              "message — and reproducing it means stopping the server and starting it " <>
              "again. The `:server` option gave this replay a server it does not own, so " <>
              "it will not. Replay without `:server` to reproduce the restart."
        }, server}}
    else
      restarted = restart_owned(ctx, server)
      got = abstract(ctx.spec_module, ctx.refinement, :sys.get_state(restarted))

      if got == want do
        {:cont, {%{acc | steps_checked: step}, restarted}}
      else
        {:halt,
         {with_skips(diverged_from_trace(step, :restart, :restart, want, got), acc), restarted}}
      end
    end
  end

  # `:kill` and not `GenServer.stop/1`: the simulation's injected failure is a crash, and a
  # crash runs no `terminate/2` (#213). A replay that shut the server down politely would
  # reproduce a different event.
  defp restart_owned(ctx, server) do
    ref = Process.monitor(server)
    Process.exit(server, :kill)

    receive do
      {:DOWN, ^ref, :process, ^server, _reason} -> :ok
    after
      ctx.timeout -> Process.demonitor(ref, [:flush])
    end

    server(ctx.module, ctx.opts)
  end

  defp server(module, opts) do
    case Keyword.fetch(opts, :server) do
      {:ok, pid} ->
        pid

      :error ->
        {:ok, pid} = GenServer.start_link(module, Keyword.get(opts, :init_arg, []))
        Process.unlink(pid)
        pid
    end
  end

  # A skip is not a silent one: it reaches the caller in `skipped` and, where there were
  # any, in `detail` — so a green `mix tla.replay` says what it did not drive.
  defp finish(%{skipped: []} = result), do: result

  defp finish(%{skipped: skipped, detail: nil} = result) do
    %{result | detail: skipped_detail(skipped)}
  end

  defp finish(%{skipped: skipped} = result) do
    %{result | detail: result.detail <> "\n\n" <> skipped_detail(skipped)}
  end

  defp skipped_detail(skipped) do
    steps = Enum.map_join(skipped, ", ", fn {step, action} -> "#{step} (#{action})" end)

    "#{length(skipped)} step(s) were not driven, because the trace names no spec action " <>
      "for them and so no message: #{steps}. Their post-states were still checked."
  end

  defp send_message(server, message, timeout) do
    # `deliver/3` and not `call/3`: the trace's message is `concrete_message/2`'s return,
    # which under D-36 may name its route. A bare term is still a call.
    case Driver.deliver(server, message, timeout) do
      {:ok, reply} -> {:ok, reply}
      {:violation, violation} -> {:violation, violation}
      {:stopped, reason} -> {:not_followed, "the server stopped with #{inspect(reason)}"}
      {:timeout, ms} -> {:not_followed, "no reply within #{ms}ms"}
    end
  end

  # ── Shared ──────────────────────────────────────────────────────────────────

  defp checks(spec_module, refinement, message, pre, post) do
    with :ok <- Runtime.check_transition(spec_module, refinement, message, pre, post),
         :ok <- Runtime.check_spec_invariants(spec_module, post) do
      Runtime.check_action_properties(spec_module, pre, post)
    end
  end

  defp abstract(spec_module, refinement, concrete),
    do: Runtime.abstract!(spec_module, refinement, concrete)

  defp splice(%Trace{} = prefix, nil), do: prefix

  # The cycle's first state IS the prefix's last: `ModelChecker.Liveness` builds it with
  # `Trace.from(graph, List.last(prefix.states), cycle_steps, [])`, and `Trace.from/4`
  # prepends the state it was handed. So the shared state is dropped from the cycle's side,
  # exactly as `Trace.to_behavior/1` has always done.
  #
  # `length` alone was adjusted for this and the list was not — #212 saw half of it — so the
  # spliced trace carried one state more than its actions could describe. `drive/5` zips
  # `actions` against `Enum.drop(states, 1)`, so from the first cycle step onward every
  # action was compared against the state BEFORE it, and **every genuine liveness
  # counterexample replayed as `:not_followed`**: a true finding, inverted, reading as "the
  # implementation does not take a step the spec permits".
  defp splice(%Trace{} = prefix, %Trace{} = cycle) do
    %Trace{
      prefix
      | states: prefix.states ++ tl(cycle.states),
        actions: prefix.actions ++ cycle.actions,
        bindings: prefix.bindings ++ cycle.bindings,
        length: prefix.length + cycle.length - 1
    }
    |> Trace.well_formed!("TLA.Replay.splice/2")
  end

  defp with_skips(result, %{skipped: skipped}), do: Map.put(result, :skipped, skipped)

  defp ok(steps),
    do: %{status: :ok, steps_checked: steps, violation: nil, detail: nil, skipped: []}

  defp violated(step, message, violation) do
    %{
      status: :violation,
      steps_checked: max(step - 1, 0),
      detail: nil,
      skipped: [],
      violation: %{
        step: step,
        kind: violation.kind,
        action: violation.action,
        message: message,
        detail: Exception.message(violation)
      }
    }
  end

  # Every step was legal and the implementation still did not reproduce the trace: it took
  # a different legal step. That is a finding about the replay, not about conformance, so
  # it is reported as `:not_followed` rather than as a violation.
  defp diverged_from_trace(step, action, message, want, got) do
    %{
      status: :not_followed,
      steps_checked: step - 1,
      violation: nil,
      skipped: [],
      detail: """
      step #{step} (#{action}) was legal, but left the implementation in a different \
      abstract state than the counterexample reached.

        message:  #{inspect(message)}
        expected: #{inspect(want)}
        actual:   #{inspect(got)}

      The implementation took a step the spec permits — just not this one. Where the \
      action is nondeterministic, `concrete_message/2` may not name the binding the trace \
      took.\
      """
    }
  end
end
