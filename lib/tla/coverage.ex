defmodule TLA.Coverage do
  @moduledoc """
  What a model-checking run exercised.

  A green check mark is only as good as what was behind it. Three ways a run can
  report success while having verified almost nothing:

  - **An action that was never enabled.** A typo in a guard (`status == :Idle`)
    turns an action off entirely. The spec still model-checks — it is simply a
    *weaker* spec now, and a weaker spec passes more easily.
  - **A property satisfied vacuously.** `P ~> Q` where `P` never holds in any
    reachable state is trivially true and says nothing about `Q`.
  - **An invariant that was never at risk.** An invariant no reachable state ever
    came close to falsifying is indistinguishable from `true`.

  None of these are exotic; they are the routine failure mode of specification
  work. Reporting them is not a nice-to-have — it is the difference between a
  verdict and a claim.

  ## Collected during the run, not computed after it

  `04-layer2-model-checker.md` says coverage is "computed from the completed
  state graph; no additional exploration". The second half is right and the first
  is not: the graph deliberately retains neither states nor per-action counts
  (D-5), so there is nothing in it to compute these from. They are accumulated
  while the search runs, which costs no additional exploration — the intent of
  the sentence — and is the only way to have them at all.
  """

  alias TLA.Spec.Compiled

  @type action_coverage :: %{
          enabled_in: non_neg_integer(),
          states_generated: non_neg_integer(),
          distinct_generated: non_neg_integer()
        }

  @type invariant_coverage :: %{
          evaluated_in: non_neg_integer(),
          near_misses: non_neg_integer() | nil
        }

  @type vacuity :: %{
          property: atom(),
          binding: term() | nil,
          reason: :antecedent_never_held | :consequent_always_held
        }

  @type t :: %__MODULE__{
          actions: %{atom() => action_coverage()},
          never_enabled: [atom()],
          invariants: %{atom() => invariant_coverage()},
          vacuous: [vacuity()],
          unreached_params: %{atom() => [map()]},
          terminal_but_live: [atom()],

          # `:violation` is not in `04-layer2-model-checker.md`'s list, and it
          # belongs there: a run that stopped at a counterexample stopped
          # mid-expansion, so its counts are a lower bound for exactly the same
          # reason a bounded run's are. Leaving it out would let a partial census
          # read as a complete one.
          bounded_by: :none | :state_constraint | :max_states | :violation
        }

  defstruct actions: %{},
            never_enabled: [],
            invariants: %{},
            vacuous: [],
            unreached_params: %{},
            terminal_but_live: [],
            bounded_by: :none,

            # Accumulator-only, dropped by finalize/3.
            probes: %{},
            seen_bindings: %{},
            param_universe: %{},
            live_terminals: MapSet.new()

  # Enumerating every param combination is only worth it while the answer is
  # readable. Past this the report would be a wall of bindings nobody reads, and
  # computing it would cost more than the search.
  @universe_cap 10_000

  @doc """
  A fresh accumulator for a run.
  """
  @spec init(Compiled.t(), map(), [Compiled.invariant_def()]) :: t()
  def init(spec, constants, invariants) do
    %__MODULE__{
      actions:
        Map.new(spec.actions, fn action ->
          {action.name, %{enabled_in: 0, states_generated: 0, distinct_generated: 0}}
        end),
      invariants:
        Map.new(invariants, fn invariant ->
          {invariant.name,
           %{evaluated_in: 0, near_misses: if(invariant[:near_miss], do: 0, else: nil)}}
        end),
      probes: probes(spec, constants),
      seen_bindings: Map.new(spec.actions, &{&1.name, MapSet.new()}),
      param_universe: Map.new(spec.actions, &{&1.name, :unknown})
    }
  end

  @doc """
  Record a newly discovered state: which invariants were evaluated on it, which
  were pressed against, and which temporal probes it satisfied.
  """
  @spec observe_state(t(), [Compiled.invariant_def()], map(), TLA.State.t()) :: t()
  def observe_state(coverage, invariants, constants, state) do
    invariants =
      Enum.reduce(invariants, coverage.invariants, fn invariant, acc ->
        Map.update!(acc, invariant.name, fn entry ->
          near =
            case {entry.near_misses, invariant[:near_miss]} do
              {nil, _} -> nil
              {count, near_miss} -> if near_miss.(constants, state), do: count + 1, else: count
            end

          %{entry | evaluated_in: entry.evaluated_in + 1, near_misses: near}
        end)
      end)

    probes =
      Map.new(coverage.probes, fn {key, probe} ->
        holds = probe.predicate.(state)

        {key,
         %{probe | ever: probe.ever or holds, always: probe.always and holds, evaluated: true}}
      end)

    %{coverage | invariants: invariants, probes: probes}
  end

  @doc """
  Record what expanding one state produced for one action.
  """
  @spec observe_action(t(), atom(), [map()], non_neg_integer(), non_neg_integer()) :: t()
  def observe_action(coverage, _name, [], _generated, _distinct), do: coverage

  def observe_action(coverage, name, bindings, generated, distinct) do
    actions =
      Map.update!(coverage.actions, name, fn entry ->
        %{
          entry
          | enabled_in: entry.enabled_in + 1,
            states_generated: entry.states_generated + generated,
            distinct_generated: entry.distinct_generated + distinct
        }
      end)

    seen =
      Map.update!(coverage.seen_bindings, name, fn set ->
        if MapSet.size(set) > @universe_cap, do: set, else: Enum.into(bindings, set)
      end)

    %{coverage | actions: actions, seen_bindings: seen}
  end

  @doc """
  Record a state that a `terminal` predicate admits but that still has an
  enabled action. Not an error — nothing is cut — but almost always a predicate
  broader than the end state it was written for.
  """
  @spec observe_live_terminal(t(), Compiled.t(), map(), TLA.State.t()) :: t()
  def observe_live_terminal(coverage, spec, constants, state) do
    admitting =
      spec.terminals
      |> Enum.filter(& &1.predicate.(constants, state))
      |> MapSet.new(& &1.name)

    %{coverage | live_terminals: MapSet.union(coverage.live_terminals, admitting)}
  end

  @doc """
  Note the universe of parameter combinations for an action, so the unexercised
  ones can be named. Only actions whose every param draws from a constant or a
  literal have one: the set a state function returns changes from state to state,
  so there is no fixed universe to subtract from.
  """
  @spec observe_universe(t(), Compiled.action_def(), map(), TLA.State.t()) :: t()
  def observe_universe(coverage, action, constants, state) do
    universe =
      if Enum.all?(action.param_sources, fn {_, source} -> source in [:constant, :literal] end) do
        enumerate(action, constants, state)
      else
        :state_dependent
      end

    %{coverage | param_universe: Map.put(coverage.param_universe, action.name, universe)}
  end

  defp enumerate(%{params: []}, _constants, _state), do: :none

  defp enumerate(action, constants, state) do
    Enum.reduce_while(action.params, [%{}], fn {name, generator}, bound ->
      next =
        for binding <- bound,
            value <- generator.(constants, state, binding),
            do: Map.put(binding, name, value)

      if length(next) > @universe_cap, do: {:halt, :too_large}, else: {:cont, next}
    end)
    |> case do
      :too_large -> :too_large
      combinations -> MapSet.new(combinations)
    end
  end

  @doc """
  Finish the accumulator into the report.
  """
  @spec finalize(t(), :none | :state_constraint | :max_states | :violation) :: t()
  def finalize(coverage, bounded_by) do
    %__MODULE__{
      actions: coverage.actions,
      never_enabled: for({name, %{enabled_in: 0}} <- coverage.actions, do: name) |> Enum.sort(),
      invariants: coverage.invariants,
      vacuous: vacuous(coverage.probes),
      unreached_params: unreached(coverage),
      terminal_but_live: coverage.live_terminals |> MapSet.to_list() |> Enum.sort(),
      bounded_by: bounded_by
    }
  end

  # ── Temporal probes ─────────────────────────────────────────────────────────
  #
  # Vacuity does not need the liveness graph, only the reachable states: a
  # `P ~> Q` whose P never holds anywhere is trivially true whatever the cycles
  # look like. So it is reported in Phase 1, where the property itself is not yet
  # checked — which is the more important half, since an unchecked property that
  # would have been vacuous is doubly worth knowing about.

  defp probes(spec, constants) do
    spec.temporals
    |> Enum.flat_map(fn temporal ->
      temporal.formula.(constants)
      |> walk(temporal.name, nil, constants)
    end)
    |> Map.new(fn probe -> {{probe.property, probe.binding, probe.role, probe.index}, probe} end)
  end

  defp walk(formula, property, binding, constants, index \\ 0)

  defp walk({:always, inner}, property, binding, constants, index),
    do: walk(inner, property, binding, constants, index)

  defp walk({:eventually, inner}, property, binding, constants, index),
    do: walk(inner, property, binding, constants, index)

  defp walk({:leads_to, antecedent, consequent}, property, binding, _constants, index) do
    [
      probe(property, binding, :antecedent, index, antecedent),
      probe(property, binding, :consequent, index, consequent)
    ]
  end

  defp walk({:predicate, predicate}, property, binding, _constants, index),
    do: [probe(property, binding, :consequent, index, predicate)]

  defp walk({:for_all, set, instantiate}, property, _binding, constants, _index) do
    set.(constants)
    |> Enum.sort()
    |> Enum.with_index()
    |> Enum.flat_map(fn {element, index} ->
      instantiate.(element) |> walk(property, element, constants, index)
    end)
  end

  defp probe(property, binding, role, index, predicate) do
    %{
      property: property,
      binding: binding,
      role: role,
      index: index,
      predicate: predicate,
      ever: false,
      always: true,
      evaluated: false
    }
  end

  # Only a leads-to can be vacuous. `always(P)` holding in every reachable state
  # is the property doing its job, not a vacuity, and flagging it would train
  # people to ignore the report — which is the one thing a coverage report cannot
  # survive. A `P ~> Q` is vacuous in two ways: P never held anywhere, so the
  # implication was never triggered; or Q held everywhere, so it was satisfied
  # without reference to P.
  defp vacuous(probes) do
    probes
    |> Map.values()
    |> Enum.filter(&(&1.evaluated and &1.role == :antecedent))
    |> Enum.group_by(&{&1.property, &1.binding})
    |> Enum.flat_map(fn {{property, binding}, antecedents} ->
      consequents =
        probes
        |> Map.values()
        |> Enum.filter(
          &(&1.role == :consequent and &1.property == property and &1.binding == binding)
        )

      cond do
        Enum.all?(antecedents, &(not &1.ever)) ->
          [%{property: property, binding: binding, reason: :antecedent_never_held}]

        consequents != [] and Enum.all?(consequents, & &1.always) ->
          [%{property: property, binding: binding, reason: :consequent_always_held}]

        true ->
          []
      end
    end)
    |> Enum.sort_by(&{&1.property, inspect(&1.binding)})
  end

  defp unreached(coverage) do
    for {action, universe} <- coverage.param_universe,
        is_struct(universe, MapSet),
        unused = MapSet.difference(universe, Map.fetch!(coverage.seen_bindings, action)),
        MapSet.size(unused) > 0,
        into: %{} do
      {action, unused |> MapSet.to_list() |> Enum.sort_by(&inspect/1)}
    end
  end

  # ── Rendering ───────────────────────────────────────────────────────────────

  @doc """
  Whether this run found anything worth a warning.
  """
  @spec clean?(t()) :: boolean()
  def clean?(coverage) do
    coverage.never_enabled == [] and coverage.vacuous == [] and
      coverage.terminal_but_live == [] and
      Enum.all?(coverage.invariants, fn {_, entry} -> entry.near_misses != 0 end)
  end

  @doc """
  The warnings, one line each.
  """
  @spec warnings(t()) :: [String.t()]
  def warnings(coverage) do
    Enum.map(coverage.never_enabled, &"action #{inspect(&1)} was never enabled") ++
      Enum.map(coverage.vacuous, &vacuity_line/1) ++
      Enum.map(coverage.terminal_but_live, &"terminal #{inspect(&1)} admitted a live state") ++
      for {name, %{near_misses: 0}} <- coverage.invariants,
          do: "invariant #{inspect(name)} was never at risk"
  end

  defp vacuity_line(%{property: property, binding: nil, reason: reason}),
    do: "property #{inspect(property)} is VACUOUS: #{reason(reason)}"

  defp vacuity_line(%{property: property, binding: binding, reason: reason}),
    do: "property #{inspect(property)} is VACUOUS for #{inspect(binding)}: #{reason(reason)}"

  defp reason(:antecedent_never_held), do: "its antecedent never held in any reachable state"
  defp reason(:consequent_always_held), do: "it held in every reachable state"

  @doc """
  Print the warnings unless the run was clean, or fail under `strict_coverage`.

  Warnings by default, errors on request: a never-enabled action is a bug often
  enough to be worth a build failure, but not always, and a tool that refuses to
  proceed on a judgement call gets its check turned off entirely.
  """
  @spec warn_unless_clean(t(), keyword() | map()) :: :ok | {:error, [String.t()]}
  def warn_unless_clean(coverage, opts \\ []) do
    strict =
      if is_map(opts), do: Map.get(opts, :strict_coverage, false), else: opts[:strict_coverage]

    case {clean?(coverage), strict} do
      {true, _} -> :ok
      {false, true} -> {:error, warnings(coverage)}
      {false, _} -> Enum.each(warnings(coverage), &IO.puts(:stderr, "warning: " <> &1))
    end
  end

  @doc """
  Render for terminal output.
  """
  @spec format(t(), keyword()) :: String.t()
  def format(coverage, opts \\ []) do
    title = Keyword.get(opts, :title, "COVERAGE")
    rule = String.duplicate("-", max(0, 68 - String.length(title) - 5))

    sections =
      [actions_table(coverage), invariants_table(coverage), properties_section(coverage)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    "--- " <>
      title <>
      " " <>
      rule <>
      "\n\n" <>
      sections <>
      footer(coverage) <>
      String.duplicate("-", 68) <> "\n"
  end

  defp actions_table(%{actions: actions}) when map_size(actions) == 0, do: ""

  defp actions_table(coverage) do
    rows =
      coverage.actions
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map_join("\n", fn {name, entry} ->
        flag = if entry.enabled_in == 0, do: "   <-- NEVER ENABLED", else: ""

        "  " <>
          String.pad_trailing(Atom.to_string(name), 24) <>
          number(entry.enabled_in) <>
          number(entry.states_generated) <>
          number(entry.distinct_generated) <> flag
      end)

    "Actions" <>
      String.duplicate(" ", 19) <>
      "enabled in      states     distinct\n" <>
      rows <> "\n"
  end

  defp invariants_table(%{invariants: invariants}) when map_size(invariants) == 0, do: ""

  defp invariants_table(coverage) do
    rows =
      coverage.invariants
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map_join("\n", fn {name, entry} ->
        near =
          case entry.near_misses do
            nil -> String.pad_leading("-", 12)
            count -> number(count)
          end

        flag = if entry.near_misses == 0, do: "   <-- never at risk", else: ""

        "  " <>
          String.pad_trailing(Atom.to_string(name), 24) <>
          number(entry.evaluated_in) <> near <> flag
      end)

    "\nInvariants" <> String.duplicate(" ", 16) <> "  evaluated   near-miss\n" <> rows <> "\n"
  end

  defp properties_section(%{vacuous: []}), do: ""

  defp properties_section(coverage) do
    "\nProperties\n" <>
      Enum.map_join(coverage.vacuous, "\n", fn entry -> "  " <> vacuity_line(entry) end) <> "\n"
  end

  defp footer(coverage) do
    bound =
      case coverage.bounded_by do
        :none ->
          ""

        :state_constraint ->
          "\nA state constraint bounded this run: the numbers are a lower bound, not a census.\n"

        :max_states ->
          "\nThe state limit bounded this run: the numbers are a lower bound, not a census.\n"

        :violation ->
          "\nThis run stopped at a counterexample, mid-expansion: the numbers are a lower " <>
            "bound, not a census.\n"
      end

    count = length(warnings(coverage))

    warning =
      if count == 0 do
        ""
      else
        "\n#{count} warning#{if count == 1, do: "", else: "s"}. " <>
          "Re-run with --strict-coverage to fail on these.\n"
      end

    bound <> warning
  end

  defp number(value), do: String.pad_leading(to_string(value), 12)
end
