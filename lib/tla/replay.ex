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

  `TLA.Refinement.concrete_message/2` — the inverse of `abstract_action/1`, and the
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
          status: :ok | :violation | :not_followed,
          steps_checked: non_neg_integer(),
          violation: violation() | nil,
          detail: String.t() | nil
        }

  @doc """
  Replay a model-checker counterexample against the implementation.

  Accepts a `TLA.Trace` or a lasso (`%{prefix:, cycle:}`), whose cycle is replayed once —
  a lasso describes a behaviour repeating forever, and one pass is what can be executed.

  Options:

  - `:server` — a pid to drive. Without it the module is started with
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

  def trace(_module, [], _opts), do: %{status: :ok, steps_checked: 0, violation: nil, detail: nil}

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
  defp drive(module, spec_module, refinement, trace, opts) do
    server = server(module, opts)
    timeout = Keyword.get(opts, :timeout, 5_000)
    expected = Enum.drop(trace.states, 1)

    steps =
      [trace.actions, trace.bindings, expected]
      |> Enum.zip()
      |> Enum.with_index(1)

    Enum.reduce_while(steps, ok(0), fn {{action, binding, want}, step}, acc ->
      message = refinement.concrete_message(action, binding)

      case send_message(server, message, timeout) do
        {:ok, _reply} ->
          got = abstract(spec_module, refinement, :sys.get_state(server))

          if got == want do
            {:cont, %{acc | steps_checked: step}}
          else
            {:halt, diverged_from_trace(step, action, message, want, got)}
          end

        {:violation, violation} ->
          {:halt, violated(step, message, violation) |> Map.put(:steps_checked, step - 1)}

        {:not_followed, detail} ->
          {:halt,
           %{
             status: :not_followed,
             steps_checked: step - 1,
             violation: nil,
             detail:
               "step #{step} (#{action}) could not be delivered: #{detail}. The spec " <>
                 "permits a behaviour the implementation does not take, so one of the two " <>
                 "is wrong."
           }}
      end
    end)
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

  defp send_message(server, message, timeout) do
    case Driver.call(server, message, timeout) do
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

  defp splice(%Trace{} = prefix, %Trace{} = cycle) do
    %Trace{
      prefix
      | states: prefix.states ++ cycle.states,
        actions: prefix.actions ++ cycle.actions,
        bindings: prefix.bindings ++ cycle.bindings,
        length: prefix.length + cycle.length
    }
  end

  defp ok(steps), do: %{status: :ok, steps_checked: steps, violation: nil, detail: nil}

  defp violated(step, message, violation) do
    %{
      status: :violation,
      steps_checked: max(step - 1, 0),
      detail: nil,
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
