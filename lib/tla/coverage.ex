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

  @type action_coverage :: %{
          enabled_in: non_neg_integer(),
          states_generated: non_neg_integer(),

          # How many of this action's successors were NEW when it produced them — an
          # attribution of first discovery, and therefore a function of the search order
          # rather than of the model. A state reachable by two actions is credited to
          # whichever reached it first, so the split across actions moves under
          # `workers:` while the TOTAL across them does not. Read it as "this action was
          # a frontier opener" and not as a property of the spec; nothing in the report
          # is derived from it, for that reason.
          distinct_generated: non_neg_integer()
        }

  @type invariant_coverage :: %{
          evaluated_in: non_neg_integer(),
          near_misses: non_neg_integer() | nil
        }

  @type vacuity :: %{
          property: atom(),
          # The quantifier bindings of the instance, outermost first; `[]` when unquantified.
          binding: [term()],
          reason: :antecedent_never_held | :consequent_always_held
        }

  @type t :: %__MODULE__{
          actions: %{atom() => action_coverage()},
          never_enabled: [atom()],
          invariants: %{atom() => invariant_coverage()},
          vacuous: [vacuity()],
          # Bindings of an action that no reachable state ever drew, for actions whose params
          # all draw from constants or literals. Empty under symmetry, where the visited
          # bindings are a subset by construction and the universe is left `:unknown`.
          unreached_params: %{atom() => [map()]},
          terminal_but_live: [atom()],

          # How many successor-less states each `terminal` admitted (#202). A terminal that
          # admitted none was never the reason a behaviour ended — the run would have reported
          # the same deadlocks without it — and the ledger cannot call that verified.
          terminals: %{atom() => %{admitted: non_neg_integer()}},

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
            terminals: %{},
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
      terminals: Map.new(spec.terminals, &{&1.name, %{admitted: 0}}),
      seen_bindings: Map.new(spec.actions, &{&1.name, MapSet.new()}),
      param_universe: Map.new(spec.actions, &{&1.name, :unknown})
    }
  end

  @doc """
  Record a newly discovered state: which invariants were evaluated on it, which
  were pressed against, and which temporal probes it satisfied.
  """
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
  Record that this action was enabled in a state, and with which bindings.

  Called *before* the successors are generated, and that is the whole point (#128). Enablement is
  established the moment the guard admits a binding: it is true before any successor exists, and
  it stays true whether or not the expansion finishes. Recording it at the end instead meant a
  violation that halted the expansion lost the enablement of the action that caused it — so a run
  reported `never_enabled: [:compact]` while naming `compact` in its counterexample, and warned
  the user that the offending action had a broken guard.

  It was invisible for as long as it was because every earlier case had another witness:
  `die_hard`'s actions are enabled in eleven or twelve states each, so losing one leaves eleven
  and nothing looks wrong. It becomes a false claim rather than an undercount only when the true
  count is one, which no corpus entry was small enough to produce until `audit_log`.

  `seen_bindings` belongs here too: it is a fact about the bindings the guard admitted, not about
  what expanding them produced.
  """
  def observe_enabled(coverage, _name, []), do: coverage

  def observe_enabled(coverage, name, bindings) do
    actions = Map.update!(coverage.actions, name, &%{&1 | enabled_in: &1.enabled_in + 1})

    seen =
      Map.update!(coverage.seen_bindings, name, fn set ->
        if MapSet.size(set) > @universe_cap, do: set, else: Enum.into(bindings, set)
      end)

    %{coverage | actions: actions, seen_bindings: seen}
  end

  @doc """
  Record what expanding one state through one action produced.

  The other half of `observe_enabled/3`, and deliberately not the same call: *was this action
  enabled here* and *how many states did it generate* are different facts, known at different
  moments. This one stays where the numbers are known — after the expansion — because a halt
  there legitimately means the count is not known, which is what `bounded_by` already says.
  """
  def observe_generated(coverage, name, generated, distinct) do
    actions =
      Map.update!(coverage.actions, name, fn entry ->
        %{
          entry
          | states_generated: entry.states_generated + generated,
            distinct_generated: entry.distinct_generated + distinct
        }
      end)

    %{coverage | actions: actions}
  end

  @doc """
  Record a successor-less state and which `terminal` predicates admitted it.

  `admitting` is the list of terminal names whose predicate held there — the same evaluation
  `TLA.ModelChecker.Safety.classify_stuck/3` made to call the state terminal rather than
  deadlocked, handed over so it is counted once and not evaluated twice. An empty list is a
  deadlock, and counts against nothing.
  """
  def observe_stuck(coverage, admitting) do
    terminals =
      Enum.reduce(admitting, coverage.terminals, fn name, acc ->
        Map.update!(acc, name, &%{&1 | admitted: &1.admitted + 1})
      end)

    %{coverage | terminals: terminals}
  end

  @doc """
  Record a state that a `terminal` predicate admits but that still has an
  enabled action. Not an error — nothing is cut — but almost always a predicate
  broader than the end state it was written for.
  """
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
  Combine one worker's accumulator into the coordinator's.

  `TLA.ModelChecker.Parallel` gives each worker a **fresh** accumulator from `init/3` and
  merges what comes back, so `from` describes only that worker's share of the level. The
  three initial probe values — `ever: false`, `always: true`, `evaluated: false` — are the
  identities of the operations below, which is what makes a worker that observed nothing
  contribute nothing.

  Three different rules, and using the wrong one produces a report that looks right:

    * **Counts add.** Each state is observed by exactly one worker — the one that won its
      fingerprint — and each `{state, action}` pair is expanded by exactly one worker, so
      nothing is observed twice and summing is exact rather than approximate.

      One of them is exact only in total: `distinct_generated` attributes a state to the
      action that reached it *first*, and which action that is depends on the order the
      search took. Its sum over all actions is invariant — every distinct state is
      credited exactly once — and its split across them is not. That is a property of the
      quantity, not of this merge; a single-threaded run redistributes it too if the
      actions are declared in a different order.

      And none of them is exact when the run **halted**. A search that stops at a
      counterexample stops mid-expansion, so every count is a lower bound rather than a
      census — which is what `bounded_by: :violation` records. Under workers the bound is
      looser and varies between runs: the coordinator starts a whole level at once and
      halts on the first violation it receives, so how much of that level was already
      merged depends on which worker finished when. Two runs of the same violating spec at
      different worker counts agree on the verdict and on the counterexample's length, and
      need not agree on the counts.
    * **Sets union, and predicates fold.** `ever` is a disjunction over reachable states,
      `always` a conjunction; splitting the states across workers and combining with `or`
      and `and` is the same computation in a different order.
    * **`param_universe` does neither.** It is a property of the CONSTANTS, not of any
      state: `observe_universe/4` enumerates it once, on the first initial state, before
      any worker exists. Every worker's copy is therefore either the coordinator's own or
      `:unknown`, and merging it could only replace a computed universe with an unknown
      one. The coordinator's is kept, deliberately.
  """
  def merge(%__MODULE__{} = into, %__MODULE__{} = from) do
    %__MODULE__{
      into
      | actions: merge_with(into.actions, from.actions, &merge_action/2),
        invariants: merge_with(into.invariants, from.invariants, &merge_invariant/2),
        probes: merge_with(into.probes, from.probes, &merge_probe/2),
        seen_bindings: merge_with(into.seen_bindings, from.seen_bindings, &merge_bindings/2),
        terminals:
          merge_with(into.terminals, from.terminals, fn a, b ->
            %{admitted: a.admitted + b.admitted}
          end),
        live_terminals: MapSet.union(into.live_terminals, from.live_terminals)
    }
  end

  # Both accumulators come from the same `init/3`, so their key sets are identical and a
  # key present in one and not the other would be a bug rather than a case to handle.
  defp merge_with(into, from, fun), do: Map.merge(into, from, fn _key, a, b -> fun.(a, b) end)

  defp merge_action(a, b) do
    %{
      a
      | enabled_in: a.enabled_in + b.enabled_in,
        states_generated: a.states_generated + b.states_generated,
        distinct_generated: a.distinct_generated + b.distinct_generated
    }
  end

  # `near_misses` is `nil` for an invariant that declares no `near_miss:`, and stays nil —
  # `nil + nil` would be an error and `0` would be a claim the invariant never made.
  defp merge_invariant(a, b) do
    near =
      case {a.near_misses, b.near_misses} do
        {nil, nil} -> nil
        {x, y} -> x + y
      end

    %{a | evaluated_in: a.evaluated_in + b.evaluated_in, near_misses: near}
  end

  defp merge_probe(a, b) do
    %{
      a
      | ever: a.ever or b.ever,
        always: a.always and b.always,
        evaluated: a.evaluated or b.evaluated
    }
  end

  # The cap is a bound on the REPORT, not on the search, so it is applied here the way
  # `observe_enabled/3` applies it: once past it, stop growing the set rather than trim it.
  defp merge_bindings(a, b) do
    if MapSet.size(a) > @universe_cap, do: a, else: MapSet.union(a, b)
  end

  @doc """
  Finish the accumulator into the report.
  """
  def finalize(coverage, bounded_by) do
    %__MODULE__{
      actions: coverage.actions,
      never_enabled: for({name, %{enabled_in: 0}} <- coverage.actions, do: name) |> Enum.sort(),
      invariants: coverage.invariants,
      vacuous: vacuous(coverage.probes),
      unreached_params: unreached(coverage),
      terminal_but_live: coverage.live_terminals |> MapSet.to_list() |> Enum.sort(),
      terminals: coverage.terminals,
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

  # One probe pair per INSTANCE, and the instances come from the same expansion the liveness
  # checker uses (#200). This module used to walk the formula itself and key a probe by the
  # innermost binding alone, so under a nested quantifier every outer instance landed on one
  # key and only the last survived: an outer instance whose antecedent never held anywhere
  # reported `vacuous == []`, while the checker — expanding correctly — checked it as its own
  # property. The binding is now the full bound list, outermost first, and the checker's
  # instance for `[x, y]` and the probe for `[x, y]` are the same thing by construction.
  defp probes(spec, constants) do
    spec.temporals
    |> Enum.flat_map(fn temporal ->
      temporal
      |> TLA.Spec.Compiled.temporal_instances(constants)
      |> Enum.flat_map(&walk(&1.formula, &1.name, &1.bound))
    end)
    |> Map.new(fn probe -> {{probe.property, probe.binding, probe.role}, probe} end)
  end

  defp walk({:always, inner}, property, binding), do: walk(inner, property, binding)
  defp walk({:eventually, inner}, property, binding), do: walk(inner, property, binding)

  defp walk({:leads_to, antecedent, consequent}, property, binding) do
    [
      probe(property, binding, :antecedent, antecedent),
      probe(property, binding, :consequent, consequent)
    ]
  end

  defp walk({:predicate, predicate}, property, binding),
    do: [probe(property, binding, :consequent, predicate)]

  # The third copy of the fragment's enumeration, and the one a user met FIRST: coverage runs
  # by default, so `always(Enum.all?(^procs, fn p -> … end))` — which is `always(pred)` and
  # means exactly what it looks like — died here with a `FunctionClauseError` before liveness
  # was ever asked for (#277). The front end now takes that formula as a predicate and refuses
  # what is genuinely off-fragment, so this clause is an internal invariant.
  defp walk(formula, property, _binding) do
    raise ArgumentError,
          "temporal property #{inspect(property)} reached the coverage probes as a shape " <>
            "they do not walk: #{inspect(formula)}. This is a bug in ExTLA, not in the " <>
            "specification: `TLA.Spec.Temporal` refuses a formula outside " <>
            "02-dsl-semantics.md §5.1 at compile time. Please report it."
  end

  defp probe(property, binding, role, predicate) do
    %{
      property: property,
      binding: binding,
      role: role,
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
  def clean?(coverage) do
    accusable(coverage) == [] and coverage.vacuous == [] and
      coverage.terminal_but_live == [] and
      Enum.all?(coverage.invariants, fn {_, entry} -> entry.near_misses != 0 end)
  end

  # A never-enabled action is a finding about the SPEC — "a typo in a guard", as the moduledoc
  # puts it — and a run that stopped early cannot support that claim. It cannot tell an action
  # whose guard is never true from one whose states it never reached (#128). The list stays in
  # the report either way, because it is data; what a truncated run may not do is accuse, and
  # `--strict-coverage` may not fail a build on it.
  #
  defp accusable(%{bounded_by: :none} = coverage), do: coverage.never_enabled
  defp accusable(_bounded), do: []

  @doc """
  The warnings, one line each.
  """
  def warnings(coverage) do
    Enum.map(coverage.never_enabled, &never_enabled_line(&1, coverage.bounded_by)) ++
      Enum.map(coverage.vacuous, &vacuity_line/1) ++
      Enum.map(coverage.terminal_but_live, &"terminal #{inspect(&1)} admitted a live state") ++
      unreached_lines(coverage) ++
      for {name, %{near_misses: 0}} <- coverage.invariants,
          do: "invariant #{inspect(name)} was never at risk"
  end

  # A binding no reachable state ever drew is a finding of the never-enabled kind, one
  # binding at a time: the action ran, and these values of it never could (#212). Computed
  # since the report existed and surfaced nowhere until now. A never-enabled action's whole
  # universe is unreached and already has its own line, so those are not repeated.
  defp unreached_lines(coverage) do
    for {action, bindings} <- Enum.sort(coverage.unreached_params),
        action not in coverage.never_enabled do
      shown = bindings |> Enum.take(3) |> Enum.map_join(", ", &inspect/1)
      more = if length(bindings) > 3, do: ", …", else: ""
      verb = if length(bindings) == 1, do: "binding was", else: "bindings were"

      "action #{inspect(action)} was enabled, but #{length(bindings)} of its #{verb} never " <>
        "drawn: #{shown}#{more}"
    end
  end

  defp never_enabled_line(name, :none), do: "action #{inspect(name)} was never enabled"

  defp never_enabled_line(name, bound) do
    "action #{inspect(name)} was not enabled in any state this run reached — the run was " <>
      "bounded by #{inspect(bound)}, so this is not a finding about the spec"
  end

  defp vacuity_line(%{property: property, binding: [], reason: reason}),
    do: "property #{inspect(property)} is VACUOUS: #{reason(reason)}"

  defp vacuity_line(%{property: property, binding: binding, reason: reason}),
    do:
      "property #{inspect(property)} is VACUOUS for #{Enum.map_join(binding, ", ", &inspect/1)}: #{reason(reason)}"

  defp reason(:antecedent_never_held), do: "its antecedent never held in any reachable state"
  defp reason(:consequent_always_held), do: "it held in every reachable state"

  @doc """
  Print the warnings unless the run was clean, or fail under `strict_coverage`.

  Warnings by default, errors on request: a never-enabled action is a bug often
  enough to be worth a build failure, but not always, and a tool that refuses to
  proceed on a judgement call gets its check turned off entirely.
  """
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
