defmodule TLA.Mutation.Catalogue do
  @moduledoc """
  The mutants, and what each one models (#46).

  Curated rather than blanket. Random AST mutation over the checker would produce
  equivalent mutants and noise; these target the axes the checker can actually be wrong
  on, and each says in one line what real defect it stands for. The catalogue is read more
  often than it is run.

  **A survivor is a finding, not a failure.** `kills: :nothing` marks a mutant expected to
  live through every gate — the gap is the measurement, and `survivors.json` records it.
  The first person to see the sweep report a survivor should reach for a new check, not
  for the delete key.
  """

  alias TLA.Mutation.Mutant

  @doc """
  Every mutant, in a stable order.
  """
  @spec all() :: [Mutant.t()]
  def all do
    [
      %Mutant{
        name: :drops_an_action,
        models: "successor generation that silently omits an action",
        file: "lib/tla/model_checker.ex",
        anchor: "    run.spec.actions\n    |> Enum.reduce_while(",
        replacement: "    Enum.drop(run.spec.actions, 1)\n    |> Enum.reduce_while(",
        kills: :corpus
      },
      %Mutant{
        name: :weakens_a_type_domain,
        models:
          "a corpus entry typing a variable more loosely than the TLA+ it is checked " <>
            "against — the defect found by reading the corpus rather than by running it",
        file: "test/differential/raft_election/spec.ex",
        anchor: "type: [^servers ~> [:follower, :candidate, :leader]]",
        replacement: "type: [^servers ~> [:follower, :candidate, :leader, :zombie]]",

        # Expected to SURVIVE, and that is the whole point of the harness. Widening a
        # `type:` domain admits states no reachable state occupies, so `distinct_states`
        # does not move and `expected.json` still matches — the corpus stays green while
        # ExTLA checks strictly less than TLC does. Nothing in the current gates can see
        # it, which is what makes it the specification for #47, #48 and #50.
        kills: :nothing
      }
    ]
  end

  @doc """
  One mutant by name, or a raise naming what is available.
  """
  @spec fetch!(atom()) :: Mutant.t()
  def fetch!(name) do
    case Enum.find(all(), &(&1.name == name)) do
      nil ->
        raise ArgumentError,
              "no mutant named #{inspect(name)}. The catalogue has: " <>
                Enum.map_join(all(), ", ", &inspect(&1.name))

      mutant ->
        mutant
    end
  end
end
