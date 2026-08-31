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
  @spec check_invariants!(module(), [atom()], term()) :: :ok | no_return()
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
  @spec check_invariants!(module(), [atom()], term(), :verbose) :: :ok | no_return()
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
  @spec check_action_properties!(module(), [atom()], term(), term()) :: :ok | no_return()
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
  @spec check_action_properties!(module(), [atom()], term(), term(), :verbose) ::
          :ok | no_return()
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
  @spec check_preconditions!(module(), atom(), term(), term()) :: :ok | no_return()
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
  @spec check_postconditions!(module(), atom(), term(), term(), term()) :: :ok | no_return()
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
  @spec extract_state(term(), term()) :: term()
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
