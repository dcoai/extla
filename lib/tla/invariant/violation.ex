defmodule TLA.Invariant.Violation do
  @moduledoc """
  A Layer 1 property that did not hold, and what to do about it.

  The struct is the report; `report!/2` decides its fate from the mode the instrumented
  module was compiled under (`TLA.Config.mode/0`):

  - `:enabled` — raise. The default in dev and test, where a violated invariant is a bug
    and stopping at it is the point.
  - `:log_only` — log and continue. For staging, where the process surviving matters more
    than the report being unmissable.
  - `:disabled` — never reached: the mode emits no wrapper at all, so nothing calls this.

  ## The message is the product

  A violation that says "invariant `:balance_non_negative` does not hold" leaves the
  reader to diff the state by eye. This renders the state, and for an action property both
  states with the changed variables marked — the same reasoning as `TLA.Trace.format/1`,
  which is where a Layer 2 counterexample gets its worth.
  """

  defexception [:type, :name, :module, :message, :state, :old_state, :args]

  @type t :: %__MODULE__{
          type: :invariant | :action_property | :precondition | :postcondition,
          name: atom(),
          module: module(),
          message: String.t(),
          state: map(),
          old_state: map() | nil,
          args: tuple() | nil
        }

  require Logger

  @doc """
  Report a violation, according to the mode the module was compiled under.
  """
  @spec report!(t(), TLA.Config.mode()) :: :ok | no_return()
  def report!(violation, mode \\ :enabled)

  def report!(%__MODULE__{} = violation, :enabled), do: raise(violation)

  def report!(%__MODULE__{} = violation, :log_only) do
    Logger.error(message(violation),
      extla_type: violation.type,
      extla_name: violation.name,
      extla_module: violation.module
    )

    :ok
  end

  def report!(%__MODULE__{}, :disabled), do: :ok

  @impl true
  def message(%__MODULE__{} = violation) do
    [
      banner(violation),
      describe(violation),
      "  module: #{inspect(violation.module)}",
      arguments(violation),
      states(violation)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp banner(%{type: type, name: name}) do
    title = "#{type |> Atom.to_string() |> String.upcase()} VIOLATED: #{name}"
    "═══ " <> title <> " " <> String.duplicate("═", max(0, 68 - String.length(title) - 5))
  end

  defp describe(%{message: nil}), do: ""
  defp describe(%{message: ""}), do: ""
  defp describe(%{message: description}), do: "  " <> description

  defp arguments(%{args: nil}), do: ""
  defp arguments(%{args: message}), do: "  message: #{inspect(message)}"

  defp states(%{old_state: nil, state: state}), do: "  state:\n" <> variables(state, %{})

  defp states(%{old_state: old, state: new}) do
    "  before:\n" <> variables(old, %{}) <> "\n\n  after:\n" <> variables(new, old)
  end

  defp variables(state, compared_to) when is_map(state) do
    width =
      state |> Map.keys() |> Enum.map(&String.length(label(&1))) |> Enum.max(&>=/2, fn -> 0 end)

    state
    |> Enum.sort_by(fn {key, _} -> label(key) end)
    |> Enum.map_join("\n", fn {key, value} ->
      changed =
        if is_map(compared_to) and map_size(compared_to) > 0 and
             Map.get(compared_to, key, :__absent__) != value,
           do: "   ← changed",
           else: ""

      "    " <> String.pad_trailing(label(key), width) <> " = " <> inspect(value) <> changed
    end)
  end

  defp variables(state, _compared_to), do: "    " <> inspect(state)

  # A variable reads as `balance`, not `:balance` — the same way `TLA.Trace` prints a
  # spec's variables. A concrete state may be keyed by anything, so anything else is
  # inspected.
  defp label(key) when is_atom(key), do: Atom.to_string(key)
  defp label(key), do: inspect(key)
end
