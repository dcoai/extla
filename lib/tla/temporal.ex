defmodule TLA.Temporal do
  @moduledoc """
  `ENABLED`, as the liveness graph records it.

  `01-foundation.md` §`TLA.Temporal` also specifies the temporal operators over
  behaviours — `always/2`, `eventually/2`, `leads_to/3` and the rest. They are not
  here: the checker of `spec/04-layer2-model-checker.md` §`TLA.ModelChecker.Liveness`
  evaluates the §5.1 fragment over strongly connected components rather than over
  enumerated behaviours, so nothing has needed them yet. They arrive with whatever
  needs them, which is the rule the rest of the library was built by.

  ## Why this calls into the checker

  Enabledness is a function of an action's params and guard alone (`02-dsl-semantics.md`
  §2.1, §3). It does not consult the state graph — an earlier draft took a `state_graph`
  argument, but the graph records reachable successors, not enabledness, and a
  parent-pointer graph records no successors at all.

  It is computed here by the same `TLA.ModelChecker.enabled_bindings/3` that generates
  the edges, and deliberately so. The bit and the edges sit next to each other in the
  liveness graph and are read together by the fairness rules — "enabled in every state of
  this component, and taken in none of them" is a comparison between them. Two
  implementations of "which bindings are enabled here" would eventually disagree, and a
  fairness constraint reading a bit that disagrees with the edge beside it is unsound in
  the direction that reports a violated property as holding.
  """

  alias TLA.{ModelChecker, Spec, State}

  @doc """
  `ENABLED A`: whether the action has a legal successor from this state — some binding of
  its params for which every generator is non-empty and the guard holds.

  `binding` restricts the question to one binding of the leading params, which is what
  per-binding fairness asks (`02-dsl-semantics.md` §5.2): `ENABLED AcquireLock(p1)` is
  `enabled?(state, acquire_lock, constants, %{p: :p1})`. The default `%{}` restricts
  nothing and asks `ENABLED \\E p : AcquireLock(p)`, which is the whole-action form and a
  strictly weaker question — the distinction §5.2 exists for.
  """
  @spec enabled?(State.t(), Spec.Compiled.action_def(), map(), map()) :: boolean()
  def enabled?(state, action, constants, binding \\ %{}) do
    action
    |> ModelChecker.enabled_bindings(constants, state)
    |> enabled_among?(binding)
  end

  @doc """
  The same question against bindings already computed.

  The checker has the enabled bindings of every action in hand while it expands a state —
  they are what it turns into edges — so the bits cost no guard evaluations of their own.
  """
  @spec enabled_among?([map()], map()) :: boolean()
  def enabled_among?(enabled_bindings, binding) when binding == %{},
    do: enabled_bindings != []

  def enabled_among?(enabled_bindings, binding),
    do: Enum.any?(enabled_bindings, &extends?(&1, binding))

  # A binding of the whole param list extends a binding of a leading prefix when it
  # agrees with it everywhere the prefix says something.
  defp extends?(full, prefix), do: Enum.all?(prefix, fn {k, v} -> Map.get(full, k) == v end)
end
