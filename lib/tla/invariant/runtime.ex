defmodule TLA.Invariant.Runtime do
  @moduledoc """
  The engine behind Layer 1's callback wrappers. Not called directly.

  Everything here is reached from code `TLA.Invariant`'s `@before_compile` emitted into
  the instrumented module, and the division of labour between the two is deliberate:
  **anything decidable at compile time is decided there.** The `callbacks:` option is
  resolved when the wrapper is generated, so a hot callback checking two of a module's
  nine invariants calls this with two names rather than nine and a filter.

  ## Telemetry

  `[:extla, :invariant, :violated]` and its three siblings fire whenever one does, if
  `:telemetry` is available — it is an optional dependency, and whether it was there is
  decided when ExTLA compiles rather than on every check.

  Success events are opt-in (`config :extla, telemetry: :verbose`) and **unemitted**
  otherwise, because `:telemetry.execute/3` costs about a microsecond even with no
  handlers attached and a single transition can fire four of them. Violations are rare and
  worth their cost; successes are the hot path.

  "Unemitted" is why each check has two arities. The wrapper calls the three-argument form
  unless the module compiled under `:verbose`, and that form contains no timing and no
  success event to skip — not a branch that declines to fire one.
  """

  alias TLA.Invariant.Violation

  @telemetry Code.ensure_loaded?(:telemetry)

  @doc """
  Check the named invariants against a state.

  The names come from the wrapper, already filtered by `callbacks:`.
  """
  def check_invariants!(module, names, state) do
    Enum.each(names, fn name ->
      unless module.__tla_invariant__(name, state) do
        report(module, %Violation{
          type: :invariant,
          name: name,
          module: module,
          message: module.__tla_describe__(:invariant, name),
          state: state
        })
      end
    end)
  end

  @doc """
  The same, timing each check and emitting a `:checked` event. Called only from a module
  compiled under `config :extla, telemetry: :verbose`.
  """
  def check_invariants!(module, names, state, :verbose) do
    Enum.each(names, fn name ->
      measured(:invariant, module, name, fn -> module.__tla_invariant__(name, state) end)
      |> unless_ok(fn ->
        report(module, %Violation{
          type: :invariant,
          name: name,
          module: module,
          message: module.__tla_describe__(:invariant, name),
          state: state
        })
      end)
    end)
  end

  @doc """
  Check the named action properties over a transition.
  """
  def check_action_properties!(module, names, old_state, new_state) do
    Enum.each(names, fn name ->
      unless module.__tla_action_property__(name, old_state, new_state) do
        report(module, %Violation{
          type: :action_property,
          name: name,
          module: module,
          message: module.__tla_describe__(:action_property, name),
          state: new_state,
          old_state: old_state
        })
      end
    end)
  end

  @doc """
  The same, under `:verbose`.
  """
  def check_action_properties!(module, names, old_state, new_state, :verbose) do
    Enum.each(names, fn name ->
      measured(:action_property, module, name, fn ->
        module.__tla_action_property__(name, old_state, new_state)
      end)
      |> unless_ok(fn ->
        report(module, %Violation{
          type: :action_property,
          name: name,
          module: module,
          message: module.__tla_describe__(:action_property, name),
          state: new_state,
          old_state: old_state
        })
      end)
    end)
  end

  @doc """
  Check every precondition whose pattern matches `message`.

  A message no pattern matches has no preconditions and passes — `:no_match` is the
  generated clause's way of saying "this declaration is not about this message", which is
  a different thing from a predicate that returned false.
  """
  def check_preconditions!(module, callback, message, state) do
    Enum.each(module.__tla_conditions__(:precondition), fn {index, description} ->
      case module.__tla_precondition__(index, message, state) do
        :no_match ->
          :ok

        true ->
          :ok

        false ->
          report(module, %Violation{
            type: :precondition,
            name: callback,
            module: module,
            message: description,
            state: state,
            args: message
          })
      end
    end)
  end

  @doc """
  Check every postcondition whose pattern matches `message`.
  """
  def check_postconditions!(module, callback, message, old_state, new_state) do
    Enum.each(module.__tla_conditions__(:postcondition), fn {index, description} ->
      case module.__tla_postcondition__(index, message, old_state, new_state) do
        :no_match ->
          :ok

        true ->
          :ok

        false ->
          report(module, %Violation{
            type: :postcondition,
            name: callback,
            module: module,
            message: description,
            state: new_state,
            old_state: old_state,
            args: message
          })
      end
    end)
  end

  @doc """
  The post-state carried by a callback's return value.

  `pre_state` is the fallback because not every return carries one: `{:stop, reason,
  reply, state}` does, a bare `{:stop, reason}` from `handle_info` does not, and `:ignore`
  from `init/1` does not. Treating those as stuttering is right — nothing moved — and it
  keeps the wrapper from having to know which callback it is wrapping.
  """
  def extract_state(result, pre_state)

  def extract_state({:reply, _reply, state}, _pre), do: state
  def extract_state({:reply, _reply, state, _extra}, _pre), do: state
  def extract_state({:noreply, state}, _pre), do: state
  def extract_state({:noreply, state, _extra}, _pre), do: state
  def extract_state({:stop, _reason, _reply, state}, _pre), do: state
  def extract_state({:stop, _reason, state}, _pre), do: state
  def extract_state({:ok, state}, _pre), do: state
  def extract_state({:ok, state, _extra}, _pre), do: state
  def extract_state(_result, pre_state), do: pre_state

  @doc """
  The post-state carried by a `:gen_statem` callback's return value.

  A state machine's state is the `{state_name, data}` pair, so `pre` is both the fallback
  and the source of the name a `:keep_state` return leaves alone. This cannot be more
  clauses on `extract_state/2`: `{:stop, reason, new_data}` is a `:gen_statem` return
  carrying DATA, and the identically shaped `{:stop, reason, state}` is a GenServer return
  carrying the whole state. One function cannot answer both.

  `:gen_statem`'s `:state_functions` callback mode is not instrumented — its transitions
  live in functions named after the states, which `@on_definition` cannot recognise. §03
  specifies `handle_event/4`, which is the `:handle_event_function` mode.
  """
  def extract_statem_state(result, pre)

  def extract_statem_state({:next_state, name, data}, _pre), do: {name, data}
  def extract_statem_state({:next_state, name, data, _actions}, _pre), do: {name, data}
  def extract_statem_state({:keep_state, data}, {name, _}), do: {name, data}
  def extract_statem_state({:keep_state, data, _actions}, {name, _}), do: {name, data}
  def extract_statem_state({:repeat_state, data}, {name, _}), do: {name, data}
  def extract_statem_state({:repeat_state, data, _actions}, {name, _}), do: {name, data}
  def extract_statem_state({:stop, _reason, data}, {name, _}), do: {name, data}

  def extract_statem_state({:stop_and_reply, _reason, _replies, data}, {name, _}),
    do: {name, data}

  def extract_statem_state(_result, pre), do: pre

  @doc """
  Check the named invariants against the state an `init/1` produced, if it produced one.

  The tag test lives here rather than in the emitted wrapper for a reason worth recording:
  inside a particular module, `super(arg)` has a known return type, so a `case` on
  `initial_state/1`'s tag has a clause the compiler can prove unreachable — and Elixir's
  type system says so, as a warning, in the user's module, about code the user did not
  write. Behind a function taking `term()` there is nothing to prove.
  """
  def check_initial_invariants!(module, names, result, shape) do
    case initial(result, shape) do
      {:ok, state} -> check_invariants!(module, names, state)
      :none -> :ok
    end
  end

  @doc "The same, under `:verbose`."
  def check_initial_invariants!(module, names, result, shape, :verbose) do
    case initial(result, shape) do
      {:ok, state} -> check_invariants!(module, names, state, :verbose)
      :none -> :ok
    end
  end

  defp initial(result, :genserver), do: initial_state(result)
  defp initial(result, :statem), do: initial_statem_state(result)

  @doc """
  The first state an `init/1` produced, or `:none`.

  `:ignore` and a bare `{:stop, reason}` are refusals to start: there is no first state,
  and an invariant checked against its absence would report a violation of a predicate
  that was never given anything to be about. The `init/1` wrapper checks nothing in that
  case — which is why this returns a tag rather than a state and a fallback.
  """
  def initial_state(result)

  def initial_state({:ok, state}), do: {:ok, state}
  def initial_state({:ok, state, _extra}), do: {:ok, state}
  def initial_state(_result), do: :none

  @doc """
  The same for a `:gen_statem`, whose `init/1` returns `{:ok, state_name, data}`.

  A module is read as a state machine when it defines `handle_event/4`. Without this the
  shared `initial_state/1` would take `{:ok, :red, data}` for `{:ok, state, extra}` and
  check the invariants against the state NAME — which is not the state, and which a
  declaration written as `{name, data} = state` would refuse with a `MatchError` naming
  neither the invariant nor the reason.
  """
  def initial_statem_state(result)

  def initial_statem_state({:ok, name, data}), do: {:ok, {name, data}}
  def initial_statem_state({:ok, name, data, _actions}), do: {:ok, {name, data}}
  def initial_statem_state(_result), do: :none

  @doc """
  Check a transition that no wrapper produced: an `Agent` update.

  An `Agent`'s transitions are functions its *callers* pass in, so there is no callback to
  wrap and no compile-time place to resolve `callbacks:` — which is why this takes every
  declared name and why `callbacks:` is documented as meaningless for an `Agent`
  (§03 §Supported OTP Behaviors). Returns the new state, so it can stand in the middle of
  the `Agent.update/3` function it is called from.
  """
  def check_agent_step!(module, old_state, new_state) do
    if instrumented?(module), do: agent_step!(module, old_state, new_state), else: new_state
  end

  defp agent_step!(module, old_state, new_state) do
    verbose = verbose(module)
    invariants = module.__tla_names__(:invariant)
    properties = module.__tla_names__(:action_property)

    apply(__MODULE__, :check_invariants!, [module, invariants, new_state] ++ verbose)

    apply(
      __MODULE__,
      :check_action_properties!,
      [module, properties, old_state, new_state] ++ verbose
    )

    new_state
  end

  @doc """
  Check the invariants of a state an `Agent` was read at, and return it.

  A read is a stuttering step: nothing moved, so there is no action property to check, but
  the invariants must still hold — the same reason a GenServer callback that returns its
  state unchanged is still checked.
  """
  def check_agent_state!(module, state) do
    if instrumented?(module), do: agent_state!(module, state), else: state
  end

  defp agent_state!(module, state) do
    apply(
      __MODULE__,
      :check_invariants!,
      [module, module.__tla_names__(:invariant), state] ++ verbose(module)
    )

    state
  end

  # Under `mode: :disabled` the declaring module carries no predicates, and an `Agent`
  # call site cannot be compiled away the way a callback can: `Application.compile_env/3`
  # does not expand inside a function body, so the mode is not readable where the call is
  # written. `:disabled` therefore costs an export lookup here rather than nothing — which
  # is the honest price of a transition whose module is an argument. (§03 §Supported OTP
  # Behaviors.)
  defp instrumented?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__tla_names__, 1)
  end

  # The wrappers choose the arity when they are emitted. An `Agent` call site cannot: the
  # module whose declarations apply is an argument, so `:verbose` is a property of a value
  # rather than of the code being compiled, and one lookup per transition is what that
  # costs.
  defp verbose(module) do
    if module.__tla_telemetry__() == :verbose, do: [:verbose], else: []
  end

  # ── Reporting ───────────────────────────────────────────────────────────────

  # A `:checked` event carries how long the predicate took, which is the only number that
  # answers "is this check worth its place on this callback".
  defp measured(kind, module, name, check) do
    started = System.monotonic_time()
    held? = check.()

    emit([:extla, kind, :checked], %{
      module: module,
      name: name,
      duration: System.monotonic_time() - started
    })

    held?
  end

  defp unless_ok(true, _report), do: :ok
  defp unless_ok(_held, report), do: report.()

  defp report(module, violation) do
    emit([:extla, violation.type, :violated], %{
      module: module,
      name: violation.name,
      violation: violation
    })

    Violation.report!(violation, module.__tla_mode__())
  end

  if @telemetry do
    defp emit(event, metadata), do: :telemetry.execute(event, %{count: 1}, metadata)
  else
    defp emit(_event, _metadata), do: :ok
  end

  @doc false
  def telemetry?, do: @telemetry
end
