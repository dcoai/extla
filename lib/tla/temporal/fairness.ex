defmodule TLA.Temporal.Fairness do
  @moduledoc """
  The fairness constraints a run actually has, expanded from what the spec declares.

  `02-dsl-semantics.md` §5.2 gives two forms:

      fairness :weak, [:done, :reset]        # WF_vars(Done), WF_vars(Reset)
      fairness :strong, acquire_lock: [:p]   # \\A p \\in Procs : SF_vars(AcquireLock(p))

  The first is one constraint. The second is one constraint *per element* of the set `p`
  ranges over, and the difference is the whole reason §5.2 exists: `WF_vars(\\E p : A(p))`
  says only that *some* process acts infinitely often, which is consistent with one
  process starving while the others take turns, and is too weak to prove anything about a
  particular one. `distributed_lock`'s `no_starvation` is about a particular one.

  So a declaration becomes a list of `{fairness_def, binding}`, and it is that list — the
  graph's `fairness_index` — that the ENABLED bits are indexed by, one bit each, in this
  order.

  ## Why it needs a state

  A param's generator is a function of `(constants, state, bindings_so_far)`, so
  enumerating what `p` ranges over means calling one. §5.2 restricts a quantified param to
  a constant or a literal precisely so the answer cannot depend on the state, and §7
  rejects a state-drawn one at compile time — so any state gives the same answer. The
  checker passes the first initial state, for the same reason `TLA.Coverage` does when it
  enumerates the param universe: it is a real state rather than a stand-in, and a
  stand-in is how a generator that quietly does read the state would go unnoticed.
  """

  alias TLA.{ModelChecker, Spec, State}

  @typedoc """
  One constraint: a declaration, and the binding of the leading params it is about.
  `%{}` is the whole-action form.
  """
  @type constraint :: {Spec.Compiled.fairness_def(), binding :: map()}

  @doc """
  Every fairness constraint of a spec under `constants`, in declaration order and, within
  a per-binding declaration, in generator order.

  The order is the bit order of `TLA.StateGraph`'s enabled bitstrings, so it has to be
  deterministic — the same reason the search itself is.
  """
  @spec expand(Spec.Compiled.t(), map(), State.t()) :: [constraint()]
  def expand(spec, constants, state) do
    Enum.flat_map(spec.fairness, fn fairness ->
      case fairness.per do
        [] ->
          [{fairness, %{}}]

        params ->
          spec
          |> Spec.Compiled.action(fairness.action)
          |> quantified_bindings(params, constants, state)
          |> Enum.map(&{fairness, &1})
      end
    end)
  end

  @doc """
  How a constraint reads, for a message: `SF(acquire_lock, p: :p1)` or `WF(timeout)`.
  """
  @spec describe(constraint()) :: String.t()
  def describe({%{kind: kind, action: action}, binding}) do
    prefix = if kind == :strong, do: "SF", else: "WF"

    case Enum.sort(binding) do
      [] ->
        "#{prefix}(#{action})"

      pairs ->
        "#{prefix}(#{action}, #{Enum.map_join(pairs, ", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)})"
    end
  end

  # The leading params only. §7 has already established that they are a leading prefix of
  # the action's params and that none of them is state-drawn, so this both terminates and
  # gives the same answer in every state.
  defp quantified_bindings(action, params, constants, state) do
    prefix = Enum.take(action.params, length(params))

    ModelChecker.bindings(%{action | params: prefix}, constants, state)
  end
end
