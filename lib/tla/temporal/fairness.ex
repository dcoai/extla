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

  alias TLA.{ModelChecker, Spec, State, Temporal}

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

  # ── Over one behaviour ──────────────────────────────────────────────────────

  @doc """
  `WF_vars(A)` over one behaviour: if A is *continuously* enabled from some point on, it
  is eventually taken.

      WF_vars(A)  ==  []<>~(ENABLED <A>_vars)  \\/  []<><A>_vars

  Either A stops being enabled infinitely often, or it is taken infinitely often. Over a
  lasso both reduce to the cycle, since nothing outside it recurs: the first is "A is
  disabled *somewhere* in the cycle", the second is "an A-step occurs *inside* it". Those
  are exactly the conditions `TLA.ModelChecker.Liveness` reads off a strongly connected
  component, arrived at from the other direction — which is what makes checking one
  against the other worth doing.

  `:inconclusive` without a lasso: a prefix cannot establish that anything happens
  infinitely often, nor that it stops.

  `enabled` is passed separately rather than derived from `action`, and this is where
  `01-foundation.md`'s signature had to give. `ENABLED <A>_v` quantifies over every state
  A could lead to, and a behaviour contains only the states that happened — so no
  function of the observed steps can answer it. `constraint_predicates/3` builds both from
  a spec, which is where the answer actually lives.
  """
  @spec weak_fairness(
          Temporal.behavior(),
          Temporal.action_predicate(),
          Temporal.predicate(),
          [atom()],
          Temporal.lasso_start()
        ) :: Temporal.verdict()
  def weak_fairness(behavior, action, enabled, vars, lasso_start \\ nil)

  def weak_fairness(_behavior, _action, _enabled, _vars, nil), do: :inconclusive

  def weak_fairness(behavior, action, enabled, vars, lasso_start) do
    cond do
      Enum.any?(Temporal.cycle(behavior, lasso_start), &(not enabled.(&1))) -> :holds
      taken?(behavior, action, vars, lasso_start) -> :holds
      true -> :violated
    end
  end

  @doc """
  `SF_vars(A)` over one behaviour: if A is *repeatedly* enabled — even intermittently —
  it is eventually taken.

      SF_vars(A)  ==  <>[]~(ENABLED <A>_vars)  \\/  []<><A>_vars

  The only difference from `weak_fairness/5` is the first disjunct: A must be disabled
  from some point *on*, which over a lasso means disabled in *every* state of the cycle
  rather than in one of them. That single quantifier is the whole distance between the
  two, and it is why `distributed_lock`'s `no_starvation` needs the strong form: a
  competitor takes the lock and gives it back, so acquiring is disabled in some states of
  the cycle and enabled in others, which satisfies WF and not SF.
  """
  @spec strong_fairness(
          Temporal.behavior(),
          Temporal.action_predicate(),
          Temporal.predicate(),
          [atom()],
          Temporal.lasso_start()
        ) :: Temporal.verdict()
  def strong_fairness(behavior, action, enabled, vars, lasso_start \\ nil)

  def strong_fairness(_behavior, _action, _enabled, _vars, nil), do: :inconclusive

  def strong_fairness(behavior, action, enabled, vars, lasso_start) do
    cond do
      Enum.all?(Temporal.cycle(behavior, lasso_start), &(not enabled.(&1))) -> :holds
      taken?(behavior, action, vars, lasso_start) -> :holds
      true -> :violated
    end
  end

  # `[]<><A>_v` over a lasso: an A-step that moves something, among the steps INSIDE the
  # cycle. A step in the prefix happens once and so cannot make anything infinitely often.
  defp taken?(behavior, action, vars, lasso_start) do
    behavior
    |> Temporal.steps(lasso_start)
    |> Enum.drop(lasso_start)
    |> Enum.any?(fn {pre, post} ->
      action.(pre, post) and not State.unchanged?({pre, post}, vars)
    end)
  end

  @doc """
  The `{action, enabled}` predicates for one constraint, over a spec and its constants.

  `action` is the constraint's action read as TLA+ reads one — a relation on a pair of
  states, true when *some* binding the constraint permits carries the first to the
  second. `enabled` is `ENABLED` for the same binding.

  Both are what `weak_fairness/5` and `strong_fairness/5` need and cannot derive for
  themselves, and building them here keeps the arithmetic of §5.2's per-binding form in
  one place.
  """
  @spec constraint_predicates(Spec.Compiled.t(), map(), constraint()) ::
          {Temporal.action_predicate(), Temporal.predicate()}
  def constraint_predicates(spec, constants, {fairness, binding}) do
    action = Spec.Compiled.action(spec, fairness.action)

    taken = fn pre, post ->
      action
      |> ModelChecker.enabled_bindings(constants, pre)
      |> Enum.any?(fn bound ->
        Temporal.extends?(bound, binding) and
          action.transition.(constants, pre, bound) == post
      end)
    end

    {taken, fn state -> Temporal.enabled?(state, action, constants, binding) end}
  end

  # The leading params only. §7 has already established that they are a leading prefix of
  # the action's params and that none of them is state-drawn, so this both terminates and
  # gives the same answer in every state.
  defp quantified_bindings(action, params, constants, state) do
    prefix = Enum.take(action.params, length(params))

    ModelChecker.bindings(%{action | params: prefix}, constants, state)
  end
end
