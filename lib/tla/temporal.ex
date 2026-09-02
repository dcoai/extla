defmodule TLA.Temporal do
  @moduledoc """
  `ENABLED`, as the liveness graph records it.

  ## Two ways to evaluate a temporal formula

  `TLA.ModelChecker.Liveness` evaluates the §5.1 fragment over the *state graph*, by
  looking for a strongly connected component a fair behaviour could cycle in forever.
  That answers a question about every behaviour of the spec at once, which is what model
  checking is for.

  The operators here answer the other question: does **this one behaviour** satisfy the
  formula? That is what Layer 3 needs — an implementation produces a trace, and the trace
  is checked against the properties the spec claims. It is also a cross-check on the
  first: a lasso the model checker hands back as a counterexample must come back
  `:violated` when evaluated here, and its cycle must satisfy every fairness constraint
  the spec declares. Two independent implementations of the same semantics that disagree
  mean one of them is wrong.

  ## Three verdicts, because a finite trace is not a behaviour

  A behaviour is infinite; a trace is a prefix of one. A prefix can *refute* `always(P)`
  — one state where P is false settles it — and can *satisfy* `eventually(P)`, but it can
  do neither the other way round: P might fail after the trace ends, or hold after it.
  So every operator here returns `:holds`, `:violated` or **`:inconclusive`**, and never
  collapses the third into the first. That is the same rule as `:max_states_reached` in
  Layer 2, applied one level down.

  A **lasso** removes the doubt. When the trace is a prefix followed by a cycle that
  repeats forever — which is what a model-checker counterexample is, and what a
  simulation that reaches a `terminal` state produces — the behaviour is fully described
  by finitely many states, and every operator gives a definite answer. Pass the index the
  cycle returns to as `lasso_start`; `TLA.Trace.to_behavior/1` computes it.

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

  alias TLA.{ModelChecker, State}

  @typedoc """
  What a finite trace establishes about a formula. `:inconclusive` is not a failure — it
  is the trace saying it does not reach far enough to know.
  """
  @type verdict :: :holds | :violated | :inconclusive

  @typedoc "A state predicate, as a `temporal` block compiles to."
  @type predicate :: (State.t() -> boolean())

  @typedoc """
  An action, as TLA+ means it: a relation on a pair of consecutive states.
  """
  @type action_predicate :: (State.t(), State.t() -> boolean())

  @type behavior :: State.behavior()

  @typedoc """
  The index the cycle returns to, or `nil` when the trace is a prefix of something longer
  and the operators cannot settle a question the states do not answer.
  """
  @type lasso_start :: non_neg_integer() | nil

  @doc """
  `ENABLED A`: whether the action has a legal successor from this state — some binding of
  its params for which every generator is non-empty and the guard holds.

  `binding` restricts the question to one binding of the leading params, which is what
  per-binding fairness asks (`02-dsl-semantics.md` §5.2): `ENABLED AcquireLock(p1)` is
  `enabled?(state, acquire_lock, constants, %{p: :p1})`. The default `%{}` restricts
  nothing and asks `ENABLED \\E p : AcquireLock(p)`, which is the whole-action form and a
  strictly weaker question — the distinction §5.2 exists for.
  """
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
  def enabled_among?(enabled_bindings, binding) when binding == %{},
    do: enabled_bindings != []

  def enabled_among?(enabled_bindings, binding),
    do: Enum.any?(enabled_bindings, &extends?(&1, binding))

  @doc """
  Whether a full binding agrees with a partial one everywhere the partial one speaks.

  Per-binding fairness, the ENABLED bits and `TLA.ModelChecker.Liveness`'s "was this
  action taken inside the component" all ask it, so it has one definition rather than
  three.
  """
  def extends?(full, partial), do: Enum.all?(partial, fn {k, v} -> Map.get(full, k) == v end)

  # ── Operators over one behaviour ────────────────────────────────────────────

  @doc """
  `[]P` — P holds in every state.

  Refutable by any trace: one state where P is false settles it. Establishable only when
  the trace is a lasso, because otherwise P may fail after it ends.
  """
  def always(behavior, predicate, lasso_start \\ nil) do
    check!(behavior, lasso_start)

    if Enum.all?(behavior, predicate), do: settled(lasso_start, :holds), else: :violated
  end

  @doc """
  `<>P` — P holds in at least one state.

  The mirror of `always/3`: satisfiable by any trace, refutable only by a lasso.
  """
  def eventually(behavior, predicate, lasso_start \\ nil) do
    check!(behavior, lasso_start)

    if Enum.any?(behavior, predicate), do: :holds, else: settled(lasso_start, :violated)
  end

  @doc """
  `<>[]P` — P becomes true and stays true forever.

  Neither satisfiable nor refutable without a lasso: any prefix extends to a behaviour
  where P holds forever after it, and to one where it does not. With a lasso it is
  decided by the cycle alone — the states outside it occur finitely often and cannot
  settle what happens "forever after".
  """
  def eventually_always(behavior, predicate, lasso_start \\ nil) do
    check!(behavior, lasso_start)

    case cycle(behavior, lasso_start) do
      nil -> :inconclusive
      cycle -> if Enum.all?(cycle, predicate), do: :holds, else: :violated
    end
  end

  @doc """
  `[]<>P` — P is true infinitely often.

  With a lasso, exactly "P occurs somewhere in the cycle": the cycle's states are the
  ones that recur, and nothing else does.
  """
  def always_eventually(behavior, predicate, lasso_start \\ nil) do
    check!(behavior, lasso_start)

    case cycle(behavior, lasso_start) do
      nil -> :inconclusive
      cycle -> if Enum.any?(cycle, predicate), do: :holds, else: :violated
    end
  end

  @doc """
  `P ~> Q` — whenever P holds, Q holds then or later.

  `:inconclusive` for any trace without a lasso, and that is not a weakness of the
  implementation: a P with no Q after it may still get its Q in the next state, and a
  trace where every P was answered may fail at the first state past the end. Neither
  direction is settled by a prefix.
  """
  def leads_to(behavior, p, q, lasso_start \\ nil)

  def leads_to(behavior, _p, _q, nil) do
    check!(behavior, nil)
    :inconclusive
  end

  def leads_to(behavior, p, q, lasso_start) do
    check!(behavior, lasso_start)

    # Q somewhere in the cycle answers every P at once: the cycle recurs forever, so
    # whatever position a P is at, a Q comes after it.
    if Enum.any?(cycle(behavior, lasso_start), q) do
      :holds
    else
      unanswered? =
        behavior
        |> Enum.with_index()
        |> Enum.any?(fn {state, index} ->
          p.(state) and not Enum.any?(Enum.drop(behavior, index), q)
        end)

      if unanswered?, do: :violated, else: :holds
    end
  end

  @doc """
  `[][A]_v` — every step either satisfies A or leaves every variable in `vars` alone.

  The stuttering allowance is what makes a TLA formula about a system rather than about a
  transcript: a step that changes nothing the spec models is always permitted.
  """
  def box_action(behavior, action, vars, lasso_start \\ nil) do
    check!(behavior, lasso_start)

    legal? =
      Enum.all?(steps(behavior, lasso_start), fn {pre, post} ->
        action.(pre, post) or State.unchanged?({pre, post}, vars)
      end)

    if legal?, do: settled(lasso_start, :holds), else: :violated
  end

  @doc """
  `<><A>_v` — some step satisfies A and changes at least one variable in `vars`.

  The `<A>_v` form excludes stuttering deliberately: "A happened" has to mean something
  moved, or every behaviour satisfies it by standing still.
  """
  def diamond_action(behavior, action, vars, lasso_start \\ nil) do
    check!(behavior, lasso_start)

    taken? =
      Enum.any?(steps(behavior, lasso_start), fn {pre, post} ->
        action.(pre, post) and not State.unchanged?({pre, post}, vars)
      end)

    if taken?, do: :holds, else: settled(lasso_start, :violated)
  end

  @doc """
  The steps of a behaviour, as `{pre, post}` pairs.

  Under a lasso the last step is the one that closes it — from the final state back to
  `lasso_start`. Leaving it out would lose the step a fairness constraint is most often
  satisfied by, and would let a cycle of one state have no steps at all.
  """
  def steps(behavior, lasso_start \\ nil)

  def steps(behavior, nil), do: Enum.zip(behavior, tl(behavior))

  def steps(behavior, lasso_start),
    do: Enum.zip(behavior, tl(behavior) ++ [Enum.at(behavior, lasso_start)])

  @doc """
  The states that recur forever: the cycle of a lasso, or `nil` without one.
  """
  def cycle(_behavior, nil), do: nil
  def cycle(behavior, lasso_start), do: Enum.drop(behavior, lasso_start)

  defp settled(nil, _verdict), do: :inconclusive
  defp settled(_lasso_start, verdict), do: verdict

  defp check!([], _lasso_start) do
    raise ArgumentError, "a behaviour has at least one state; got an empty one"
  end

  defp check!(_behavior, nil), do: :ok

  defp check!(behavior, lasso_start)
       when is_integer(lasso_start) and lasso_start >= 0 do
    if lasso_start < length(behavior) do
      :ok
    else
      raise ArgumentError,
            "lasso_start #{lasso_start} is past the end of a #{length(behavior)}-state " <>
              "behaviour; it is the index the cycle returns to."
    end
  end
end
