defmodule ExTLA.Simulation.Generator do
  @moduledoc """
  Random messages, derived from a spec's own action definitions.

  The spec's `params:` are where nondeterminism lives (`02-dsl-semantics.md` §3), so they
  are also the domain of possible messages: pick an action, pick a binding of its params
  from the generators the action declares, and ask the refinement for the concrete message
  that causes it.

  ## Why the refinement is an argument

  A specification has no notion of a message — that is the whole reason
  `c:ExTLA.Refinement.concrete_message/2` exists — so a generator returning one needs the
  mapping as well. The alternative, returning `{action, params}` and mapping later, would
  put half the generator in its caller; `ExTLA.PropertyTest.action_sequences/3` is that
  spec-level form, for a consumer's own property tests.
  """

  alias ExTLA.{ModelChecker, Spec}

  @doc """
  A generator over every action, enabled or not.

  Returns `(abstract_state -> {action, params, message}) | nil`, `nil` when nothing can be
  generated in that state. Messages for disabled actions are the point rather than waste:
  an implementation that accepts a message the spec forbids in that state is exactly what
  `ExTLA.GenServer.Runtime.check_step!/5` reports as `:not_enabled`, and a generator that never sends one can
  never find it.
  """
  def from_spec(spec_module, refinement, constants) do
    spec = Spec.Compiled.from_module(spec_module)
    fn state -> pick(spec, refinement, ModelChecker.steps(spec, constants, state)) end
  end

  @doc """
  A generator restricted to actions whose guard holds in the current state.

  Cheaper per step, and the right choice when the question is "does the implementation
  follow the spec where the spec has something to say" rather than "does it refuse what
  the spec forbids". A simulation that only ever sends enabled messages cannot produce a
  `:not_enabled` finding, which is worth knowing before choosing it.
  """
  def enabled_only(spec_module, refinement, constants) do
    spec = Spec.Compiled.from_module(spec_module)
    fn state -> pick(spec, refinement, ModelChecker.enabled_steps(spec, constants, state)) end
  end

  # The candidates come from `ExTLA.ModelChecker` rather than from a comprehension here:
  # "what may happen next" has one implementation, and it is the checker's — the one the
  # differential corpus compares against TLC.
  defp pick(_spec, _refinement, []), do: nil
  defp pick(_spec, refinement, candidates), do: to_message(refinement, Enum.random(candidates))

  defp to_message(refinement, {action, binding}),
    do: {action, binding, refinement.concrete_message(action, binding)}
end
