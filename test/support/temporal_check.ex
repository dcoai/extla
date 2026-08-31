defmodule TLA.TemporalCheck do
  @moduledoc """
  Evaluate a spec's temporal declarations over **one observed behaviour**, with
  `TLA.Temporal`'s operators.

  This is the shape `05-layer3-conformance.md`'s `check_temporal_properties/2` will take
  when Layer 3 needs it. It lives in test support until then, because what it is for here
  is checking `TLA.ModelChecker.Liveness` against an independent implementation of the
  same semantics:

  - a lasso the checker calls a counterexample must come back `:violated` when the
    property is evaluated over it directly; and
  - that lasso's cycle must satisfy every fairness constraint the spec declares, or the
    checker has printed a behaviour the spec's own assumptions forbid.

  The two evaluations share no code. `Liveness` reasons about strongly connected
  components of the state graph; these operators walk a list of states. Agreement between
  them is evidence; a disagreement means one of them is wrong.
  """

  alias TLA.Temporal
  alias TLA.Temporal.Fairness

  @doc """
  The verdict of every instance of the temporal property `name` over a behaviour.

  A list because `Enum.all?(^constant, …)` is a conjunction of instances (§5.1): the
  property is refuted when any one of them is.
  """
  @spec verdicts(TLA.Spec.Compiled.t(), map(), atom(), {TLA.State.behavior(), integer() | nil}) ::
          [Temporal.verdict()]
  def verdicts(spec, constants, name, {behavior, lasso_start}) do
    spec.temporals
    |> Enum.find(&(&1.name == name))
    |> Map.fetch!(:formula)
    |> apply([constants])
    |> instances(constants)
    |> Enum.map(&evaluate(&1, behavior, lasso_start))
  end

  defp instances({:for_all, set, instance}, constants),
    do: Enum.flat_map(set.(constants), &instances(instance.(&1), constants))

  defp instances(formula, _constants), do: [formula]

  # A bare state predicate as a property is a claim about the first state, which is how
  # `TLA.ModelChecker.Liveness` reads it too.
  defp evaluate({:predicate, p}, behavior, _lasso_start),
    do: if(p.(hd(behavior)), do: :holds, else: :violated)

  defp evaluate({:always, {:predicate, p}}, behavior, l), do: Temporal.always(behavior, p, l)

  defp evaluate({:eventually, {:predicate, p}}, behavior, l),
    do: Temporal.eventually(behavior, p, l)

  defp evaluate({:always, {:eventually, {:predicate, p}}}, behavior, l),
    do: Temporal.always_eventually(behavior, p, l)

  defp evaluate({:eventually, {:always, {:predicate, p}}}, behavior, l),
    do: Temporal.eventually_always(behavior, p, l)

  defp evaluate({:leads_to, p, q}, behavior, l), do: Temporal.leads_to(behavior, p, q, l)

  @doc """
  Every fairness constraint of the spec, and its verdict over the behaviour.

  Keyed by `TLA.Temporal.Fairness.describe/1` so a failure names the constraint rather
  than an index into a bitstring.
  """
  @spec fairness_verdicts(
          TLA.Spec.Compiled.t(),
          map(),
          {TLA.State.behavior(), integer() | nil}
        ) :: [{String.t(), Temporal.verdict()}]
  def fairness_verdicts(spec, constants, {behavior, lasso_start}) do
    vars = Enum.map(spec.variables, & &1.name)

    spec
    |> Fairness.expand(constants, hd(behavior))
    |> Enum.map(fn {declaration, _binding} = constraint ->
      {action, enabled} = Fairness.constraint_predicates(spec, constants, constraint)

      verdict =
        case declaration.kind do
          :weak -> Fairness.weak_fairness(behavior, action, enabled, vars, lasso_start)
          :strong -> Fairness.strong_fairness(behavior, action, enabled, vars, lasso_start)
        end

      {Fairness.describe(constraint), verdict}
    end)
  end
end
