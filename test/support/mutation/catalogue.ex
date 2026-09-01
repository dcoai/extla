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

  ## What it measured, the first time it ran

  **10 killed, 2 survived, 1 timeout, in 8m33s** on the machine
  `bench/search_profile.baseline.md` names. That wall time is why the sweep is its own CI
  job rather than part of `mix test`, and it is a measurement rather than an estimate.

  The two survivors are the specification for the rest of this milestone:

    * **`weakens_a_type_domain`** — expected, and the reason #46 exists. Widening a
      `type:` admits states nothing reaches, so `distinct_states` does not move and
      `expected.json` still matches while ExTLA checks strictly less than TLC.
    * **`drops_a_liveness_edge`** — **not** expected, and the more interesting of the two.
      An out-edge missing from the liveness table is caught by nothing at all: every
      temporal verdict in the corpus still matches. `test/differential/README.md` already
      says the lasso's shape is unchecked; this is what that costs, measured. It is #47's
      to close.

  Three mutants are killed only by `:suite` and not by the corpus — `skips_symmetry_-
  canonicalization`, `wrong_init_index`, `param_universe_from_the_right`. That is not a
  gap; it is the catalogue recording *which* gate does the work, which is the thing a
  kill-count alone cannot say.
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
      },
      %Mutant{
        name: :ignores_a_guard,
        models:
          "an action taken in a state its guard forbids. Measured as a TIMEOUT and not " <>
            "as a gap: without guards the search is bounded only by the variables' " <>
            "declared types, which on raft_election is astronomically large, so no gate " <>
            "that has to finish can ever kill it. The axis is real; a terminating gate " <>
            "is the wrong instrument for it, and #50's generated models — small by " <>
            "construction — are the right one",
        file: "lib/tla/model_checker.ex",
        anchor: """
          def enabled_bindings(action, constants, state) do
            action
            |> bindings(constants, state)
            |> Enum.filter(&action.guard.(constants, state, &1))
          end\
        """,
        replacement: """
          def enabled_bindings(action, constants, state) do
            bindings(action, constants, state)
          end\
        """,

        # `:nothing`, because no gate that has to finish can kill it — and a 45-second
        # budget rather than the sweep's 300, because the sweep already knows it does not
        # finish and four more minutes of waiting to be told so again is the sweep's
        # budget spent on nothing.
        kills: :nothing,
        timeout: 45
      },
      %Mutant{
        name: :drops_a_binding,
        models: "parameter enumeration that misses one binding of an enabled action",
        file: "lib/tla/model_checker.ex",
        anchor: """
          def enabled_bindings(action, constants, state) do
            action
            |> bindings(constants, state)
            |> Enum.filter(&action.guard.(constants, state, &1))
          end\
        """,
        replacement: """
          def enabled_bindings(action, constants, state) do
            action
            |> bindings(constants, state)
            |> Enum.filter(&action.guard.(constants, state, &1))
            |> Enum.drop(1)
          end\
        """,
        kills: :corpus
      },
      %Mutant{
        name: :searches_depth_first,
        models:
          "a frontier that stops being breadth-first, so a counterexample is no longer " <>
            "the shortest — the length D-9 compares and D-27's barrier exists to preserve",
        file: "lib/tla/model_checker.ex",
        anchor: "    case :queue.out(run.frontier) do",
        replacement: "    case :queue.out_r(run.frontier) do",
        kills: :corpus
      },
      %Mutant{
        name: :truncates_the_fingerprint,
        models: "state identity narrow enough to collide, silently merging distinct states",
        file: "lib/tla/fingerprint.ex",
        anchor: "    |> binary_part(0, div(bits, 8))",
        replacement: "    |> binary_part(0, 2)",
        kills: :corpus
      },
      %Mutant{
        name: :skips_symmetry_canonicalization,
        models:
          "a symmetric state that is not put in canonical form, so an orbit is explored twice",
        file: "lib/tla/state_graph.ex",
        anchor: """
          defp fingerprint(graph, state) do
            state
            |> Symmetry.canonical(graph.symmetry)
            |> Fingerprint.of_encoding(bits: graph.fingerprint_bits)
          end\
        """,
        replacement: """
          defp fingerprint(graph, state) do
            Fingerprint.compute(state, bits: graph.fingerprint_bits)
          end\
        """,

        # `:suite` rather than `:corpus`: no differential entry declares `symmetry:`, so
        # the corpus cannot see this one at all. `verify_symmetry:` (D-17) is what should.
        kills: :suite
      },
      %Mutant{
        name: :inverts_a_weak_fairness_bit,
        models: "an ENABLED bit recorded the wrong way round, so fairness is read inverted",
        file: "lib/tla/model_checker.ex",
        anchor: "      <<bits::bitstring, if(on, do: 1, else: 0)::1>>",
        replacement: "      <<bits::bitstring, if(on, do: 0, else: 1)::1>>",
        kills: :corpus
      },
      %Mutant{
        name: :drops_a_liveness_edge,
        models: "an out-edge missing from the liveness table, so a cycle cannot be found",
        file: "lib/tla/state_graph.ex",
        anchor: "      | edges: Map.put(graph.edges, id, edges),",
        replacement: "      | edges: Map.put(graph.edges, id, Enum.drop(edges, 1)),",
        kills: :corpus
      },
      %Mutant{
        name: :off_by_one_in_the_path_walk,
        models: "a trace one step short, because the walk back drops a step",
        file: "lib/tla/state_graph.ex",
        anchor: "        walk_back(graph, parent, [{action, params} | steps])",
        replacement: "        walk_back(graph, parent, steps)",
        kills: :corpus
      },
      %Mutant{
        name: :wrong_init_index,
        models:
          "replay starting from the wrong `init` block, which only a spec with more than " <>
            "one can expose",
        file: "lib/tla/state_graph.ex",
        anchor: "        {index, steps}",
        replacement: "        {0, steps}",

        # `:suite`: every corpus entry has exactly one `init`, so the corpus cannot tell.
        # `TestSpecs.TwoStarts` is the only fixture with two, and whether anything replays
        # through it is what this measures.
        kills: :suite
      },
      %Mutant{
        name: :drops_a_worker_contribution,
        models: "a parallel merge that loses one worker's states, under-counting the search",
        file: "lib/tla/model_checker/parallel.ex",
        anchor: "      | state_count: graph.state_count + from.state_count,",
        replacement: "      | state_count: graph.state_count,",
        kills: :corpus
      },
      %Mutant{
        name: :param_universe_from_the_right,
        models:
          "a coverage merge taking `param_universe` from the worker rather than the " <>
            "coordinator. D-27 names this asymmetry. The CORPUS does not catch it — " <>
            "`finalize/2` drops `param_universe` from the report, so a wrong one shows " <>
            "only where a run has unreached params to name — and #39's unit tests do",
        file: "lib/tla/coverage.ex",
        anchor: "        live_terminals: MapSet.union(into.live_terminals, from.live_terminals)",
        replacement:
          "        live_terminals: MapSet.union(into.live_terminals, from.live_terminals),\n" <>
            "        param_universe: from.param_universe",

        # `:suite`, not `:corpus`. The corpus cannot see it: `finalize/2` drops
        # `param_universe` from the report, so a wrong one surfaces only through
        # `unreached_params`, and only where a run has unreached params to name. #39's
        # `coverage_merge_test.exs` asserts the asymmetry directly, and that is in the
        # suite.
        kills: :suite
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
