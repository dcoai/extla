defmodule TLA.Simulation do
  @moduledoc """
  Random walks over the real implementation, checked against the spec at every step.

  Where Layer 2 explores every reachable state of the *specification*, this runs the
  *implementation* through random message sequences and checks each transition with the
  same refinement check the runtime wrapper uses. What that catches, and the model checker
  cannot:

  - a refinement mapping that is wrong in a state no test happened to reach;
  - an implementation bug the abstract model does not contain, because the model does not
    contain the implementation;
  - a temporal property that no finite behaviour of the real code satisfies.

  ## The default generator only offers actions the spec enables

  `TLA.Simulation.Generator.enabled_only/3`, not `from_spec/3`. The unrestricted generator
  asks a different question — *does the implementation refuse what the spec forbids in
  this state* — and most servers are not written to. A `handle_call(:done, …)` clause with
  no guard of its own accepts `:done` in a state where the spec's `done` is disabled, and
  the step check reports `:not_enabled`, correctly: it is a true finding about the pair.
  It is also a finding about nearly every server ever written, so hunting it is opt-in.

  Pass `message_generator: TLA.Simulation.Generator.from_spec(spec, refinement, constants)`
  to ask that question deliberately.

  ## What a simulation is not

  It is sampling, not proof. A run that finds nothing has checked the traces it drew, and
  `coverage` says which actions those were — a green result over a generator that never
  produced `reset` says nothing about `reset`. `05-layer3-conformance.md` §Conformance
  Checking Modes puts exhaustive checking and simulation side by side for this reason.

  ## The counterexample it produces is a `TLA.Trace`

  So a simulation failure can be handed straight back to `TLA.Replay.counterexample/3`,
  formatted with `TLA.Trace.format/1`, or read the same way a model-checker counterexample
  is. A finding that arrives in a different shape from the model checker's would be a
  second thing to learn for no reason.
  """

  alias TLA.GenServer.{Driver, Runtime}
  alias TLA.{Spec, Trace}
  alias TLA.Simulation.Generator

  @type config :: %{
          optional(:traces) => pos_integer(),
          optional(:max_steps) => pos_integer(),
          optional(:constants) => map(),
          optional(:message_generator) => (TLA.State.t() ->
                                             term() | {atom(), map(), term()} | nil),
          optional(:inject_failures) => boolean(),
          optional(:seed) => integer() | nil,
          optional(:concurrency) => pos_integer(),
          optional(:init_arg) => term(),
          optional(:timeout) => timeout()
        }

  @type coverage_report :: %{
          actions_hit: %{atom() => non_neg_integer()},
          states_visited: non_neg_integer(),
          invariants_checked: non_neg_integer(),
          actions_covered: float()
        }

  @type result :: %{
          status: :ok | :violation | :error,
          traces_run: non_neg_integer(),
          total_steps: non_neg_integer(),
          violation: Trace.t() | nil,
          detail: String.t() | nil,
          duration_ms: non_neg_integer(),
          seed: integer(),
          restarts: non_neg_integer(),
          coverage: coverage_report()
        }

  @defaults %{
    traces: 100,
    max_steps: 25,
    inject_failures: false,
    concurrency: 1,
    init_arg: [],
    timeout: 5_000
  }

  @doc """
  Run `config.traces` random traces against `module`, stopping at the first finding.

      TLA.Simulation.run(MyApp.TransferServer, %{traces: 1000, max_steps: 50, seed: 42})

  The seed is always in the result, generated when none was given: a random run that finds
  something and cannot be run again has found nothing anybody can act on.
  """
  def run(module, config \\ %{}) do
    config = configure(module, config)
    started = System.monotonic_time(:millisecond)

    outcomes =
      1..config.traces
      |> Task.async_stream(&one_trace(module, config, &1),
        max_concurrency: config.concurrency,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.map(fn {:ok, outcome} -> outcome end)

    summarize(outcomes, config, System.monotonic_time(:millisecond) - started)
  end

  @doc """
  One trace, with the abstract behaviour it produced.

  The behaviour is returned whether or not anything was found, which is what makes this
  the debugging entry point: a run that passed and a run that failed are read the same
  way.
  """
  def run_trace(module, config \\ %{}) do
    config = configure(module, Map.put(config, :traces, 1))
    started = System.monotonic_time(:millisecond)
    outcome = one_trace(module, config, 1)

    {summarize([outcome], config, System.monotonic_time(:millisecond) - started),
     Enum.reverse(outcome.states)}
  end

  @doc """
  Drive `module` through an explicit list of concrete messages.

  The reproduction path for a failing simulation whose messages are known, and the way to
  write a scenario by hand. `TLA.Replay.counterexample/3` is the other direction: from
  *abstract* actions through `concrete_message/2`.
  """
  def replay(module, messages, config \\ %{}) do
    config = configure(module, Map.put(config, :traces, 1))
    started = System.monotonic_time(:millisecond)

    generator = fn _state -> nil end
    outcome = drive(module, %{config | message_generator: generator}, messages)

    summarize([outcome], config, System.monotonic_time(:millisecond) - started)
  end

  # ── One trace ───────────────────────────────────────────────────────────────

  defp one_trace(module, config, index) do
    drive(module, config, :generated, fn -> seed_for(config.seed, index) end)
  end

  # One trace, in a process that OWNS its server (#206). The server is started linked and
  # stays linked, and the process traps exits. Two things follow, and together they are the
  # whole of the lifetime guarantee:
  #
  #   * If anything in the trace raises — a message generator, a refinement mapping, a
  #     `:sys.get_state` on a server that stopped — this process ends abnormally and the
  #     link takes the server with it. The first version unlinked the server right after
  #     starting it and stopped it only on the normal return, so a generator that raised
  #     once left every started server alive: eight `Impl.Conforming` processes after one
  #     failed run.
  #   * If the server crashes — a conformance violation raises inside it — the exit arrives
  #     here as an `{:EXIT, _, _}` message rather than as a kill, and the trace goes on to
  #     report it. `TLA.GenServer.Driver.call/3`'s monitor is still what turns the crash into
  #     an outcome; the EXIT message is left in the mailbox of a process about to end.
  #
  # A `Task` rather than trapping exits in the caller: `run_trace/2` and `replay/3` are called
  # from user code, and flipping a caller's `trap_exit` would be a side effect no function
  # named "run a trace" should have. The caller is linked to the task the way `run/2`'s
  # `Task.async_stream` already links its workers, so a crash reaches the caller as it did.
  #
  # `prepare` runs inside the owning process before the trace: the per-trace seed goes there,
  # because `:rand` state is per process and the generator draws from it in this one.
  defp drive(module, config, messages, prepare \\ fn -> :ok end) do
    fn ->
      Process.flag(:trap_exit, true)
      prepare.()
      owned_drive(module, config, messages)
    end
    |> Task.async()
    |> Task.await(:infinity)
  end

  defp owned_drive(module, config, messages) do
    case start(module, config) do
      {:ok, server} ->
        state = %{empty_state() | server: server, states: [abstract(config, server)]}
        state = steps(state, module, config, messages)
        stop(state.server)
        temporal(state, config)

      # `init/1` is allowed to decline. That is not a `MatchError` on `{:ok, pid} =`; it is
      # an outcome, and one worth reporting by name, since a server that will not start
      # under the simulation's `init_arg` has not been checked against anything.
      {:declined, detail} ->
        %{empty_state() | status: :error, detail: detail}
    end
  end

  defp empty_state do
    %{
      server: nil,
      states: [],
      actions: [],
      bindings: [],
      steps: 0,
      restarts: 0,
      status: :ok,
      violation: nil,
      detail: nil
    }
  end

  defp steps(state, module, config, :generated) do
    Enum.reduce_while(1..config.max_steps, state, fn _step, state ->
      case config.message_generator.(hd(state.states)) do
        nil -> {:halt, state}
        generated -> {:cont, step(state, module, config, generated)} |> continue?()
      end
    end)
  end

  defp steps(state, module, config, messages) when is_list(messages) do
    Enum.reduce_while(messages, state, fn message, state ->
      {:cont, step(state, module, config, {nil, %{}, message})} |> continue?()
    end)
  end

  defp continue?({:cont, %{status: :ok} = state}), do: {:cont, state}
  defp continue?({:cont, state}), do: {:halt, state}

  defp step(state, module, config, generated) do
    {action, binding, message} = normalize(generated)

    case Driver.call(state.server, message, config.timeout) do
      {:ok, _reply} ->
        state
        |> record(action, binding, abstract(config, state.server))
        |> maybe_restart(module, config)

      {:violation, violation} ->
        %{
          state
          | status: :violation,
            violation: violation,
            actions: [action || :unmapped | state.actions],
            bindings: [binding || %{} | state.bindings],
            states: [violation.post || hd(state.states) | state.states],
            steps: state.steps + 1
        }

      {:stopped, reason} ->
        %{state | status: :error, detail: "the server stopped with #{inspect(reason)}"}

      {:timeout, ms} ->
        %{state | status: :error, detail: "no reply within #{ms}ms"}
    end
  end

  # A bare message is what `05-layer3-conformance.md` typed `message_generator` as. The
  # generator here returns the action and binding beside it, because a counterexample
  # naming its actions is worth more than one that is only a list of messages — and a
  # user-supplied generator keeps working either way.
  defp normalize({action, binding, message}), do: {action, binding, message}
  defp normalize(message), do: {nil, %{}, message}

  defp record(state, action, binding, abstract) do
    %{
      state
      | states: [abstract | state.states],
        actions: [action || :unmapped | state.actions],
        bindings: [binding || %{} | state.bindings],
        steps: state.steps + 1
    }
  end

  # A crash is not a step of the specification — nothing in the DSL models one — so a
  # restart is not checked as a transition. What IS checked is where recovery lands: the
  # spec's invariants must hold of the recovered abstract state. A server that comes back
  # in a state its own specification forbids is a finding whatever the spec says about
  # crashing.
  defp maybe_restart(state, module, config) do
    if config.inject_failures and :rand.uniform() < 0.1 do
      Process.exit(state.server, :kill)
      restart(state, module, config)
    else
      state
    end
  end

  defp restart(state, module, config) do
    case start(module, config) do
      {:declined, detail} ->
        %{state | server: nil, status: :error, detail: "on restart, " <> detail}

      {:ok, server} ->
        recovered = abstract(config, server)
        recovery(state, server, recovered, Runtime.check_spec_invariants(config.spec, recovered))
    end
  end

  defp recovery(state, server, recovered, verdict) do
    case verdict do
      :ok ->
        %{
          state
          | server: server,
            restarts: state.restarts + 1,
            states: [recovered | state.states]
        }

      {:violation, violation} ->
        %{
          state
          | server: server,
            restarts: state.restarts + 1,
            status: :violation,
            violation: violation,
            states: [recovered | state.states],
            actions: [:restart | state.actions],
            bindings: [%{} | state.bindings]
        }
    end
  end

  # A finite behaviour can refute `always(P)` and satisfy `eventually(P)` and can do
  # neither the other way round, so only `:violated` is a finding here — `:inconclusive` is
  # the honest answer for a property this trace could not settle, not a failure.
  defp temporal(%{status: :ok} = state, config) do
    behavior = Enum.reverse(state.states)

    case Enum.find(
           Runtime.check_temporal_properties(config.spec, behavior),
           &(elem(&1, 1) == :violated)
         ) do
      nil ->
        state

      {name, :violated} ->
        %{
          state
          | status: :violation,
            violation: %{
              kind: :temporal,
              name: name,
              post: List.last(behavior),
              detail: "the temporal property #{inspect(name)} is violated by this behaviour"
            }
        }
    end
  end

  defp temporal(state, _config), do: state

  # ── Setup and summary ───────────────────────────────────────────────────────

  defp configure(module, config) do
    spec = module.__tla_spec_module__()
    refinement = module.__tla_refinement__()
    constants = Map.get_lazy(config, :constants, fn -> constants!(spec) end)

    @defaults
    |> Map.merge(config)
    |> Map.merge(%{
      spec: spec,
      refinement: refinement,
      constants: constants,
      seed: Map.get(config, :seed) || :erlang.unique_integer([:positive]),
      message_generator:
        Map.get_lazy(config, :message_generator, fn ->
          Generator.enabled_only(spec, refinement, constants)
        end)
    })
  end

  defp constants!(spec_module) do
    {:ok, constants} =
      spec_module |> Spec.Compiled.from_module() |> Spec.Compiled.resolve_constants()

    constants
  end

  # One seed per trace, derived from the run's seed and the trace's index, so that trace
  # 37 of a 1000-trace run can be re-run on its own.
  defp seed_for(seed, index), do: :rand.seed(:exsss, {seed, index, seed + index})

  # Linked, and it stays linked: see `drive/3`.
  defp start(module, config) do
    case GenServer.start_link(module, config.init_arg) do
      {:ok, pid} ->
        {:ok, pid}

      :ignore ->
        {:declined,
         "#{inspect(module)}.init/1 returned :ignore for init_arg #{inspect(config.init_arg)}, " <>
           "so no server started and nothing was checked."}

      {:error, reason} ->
        {:declined,
         "#{inspect(module)}.init/1 failed for init_arg #{inspect(config.init_arg)}: " <>
           "#{inspect(reason)}. No server started and nothing was checked."}
    end
  end

  defp stop(nil), do: :ok

  defp stop(server) do
    if Process.alive?(server), do: Process.exit(server, :kill)
    :ok
  end

  defp abstract(config, server) do
    Runtime.abstract!(config.spec, config.refinement, :sys.get_state(server))
  end

  defp summarize(outcomes, config, duration_ms) do
    failed = Enum.find(outcomes, &(&1.status != :ok))

    %{
      status: (failed && failed.status) || :ok,
      traces_run: length(outcomes),
      total_steps: Enum.sum(Enum.map(outcomes, & &1.steps)),
      violation: failed && failed.violation && trace_of(failed),
      detail: failed && failed.detail,
      duration_ms: duration_ms,
      seed: config.seed,
      restarts: Enum.sum(Enum.map(outcomes, & &1.restarts)),
      coverage: coverage(outcomes, config)
    }
  end

  # The finding, in the shape the model checker reports one in: a `TLA.Trace` that
  # `TLA.Replay.counterexample/3` can drive and `TLA.Trace.format/1` can print.
  defp trace_of(outcome) do
    %Trace{
      type: :safety,
      property: violation_property(outcome.violation),
      message: violation_message(outcome.violation),
      states: Enum.reverse(outcome.states),
      actions: Enum.reverse(outcome.actions),
      bindings: Enum.reverse(outcome.bindings),
      length: length(outcome.actions)
    }
  end

  # What a reader wants in the trace's header. An invariant or an action property has a
  # name and that name IS the finding; a diverged or not-enabled step has no name, and its
  # kind is what distinguishes it from the other four.
  defp violation_property(%{name: name}) when not is_nil(name), do: name
  defp violation_property(%{kind: kind}), do: kind

  # The struct clause first: a `%Violation{}` carries a `detail` of its own, and matching
  # on that key would report a fragment of the message as the whole of it.
  defp violation_message(%TLA.GenServer.Violation{} = violation), do: Exception.message(violation)
  defp violation_message(%{detail: detail}) when is_binary(detail), do: detail

  # `branches_covered` in §05 had no definition anywhere in the project — nothing else
  # names a branch. `actions_covered` is the fraction of the spec's actions a run
  # exercised at least once, which is the number the report was reaching for and one that
  # can be computed from what happened.
  defp coverage(outcomes, config) do
    hit =
      outcomes
      |> Enum.flat_map(& &1.actions)
      |> Enum.reject(&(&1 in [:unmapped, :restart]))
      |> Enum.frequencies()

    spec = Spec.Compiled.from_module(config.spec)
    states = outcomes |> Enum.flat_map(& &1.states) |> Enum.uniq() |> length()
    declared = length(spec.actions)

    %{
      actions_hit: hit,
      states_visited: states,
      invariants_checked:
        Enum.sum(Enum.map(outcomes, &length(&1.states))) * length(spec.invariants),
      actions_covered: if(declared == 0, do: 0.0, else: map_size(hit) / declared)
    }
  end
end
