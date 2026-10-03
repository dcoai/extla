defmodule ExTLA.Ledger do
  @moduledoc """
  The verification ledger: every item each `ExTLA.Spec` declares, its content version, the
  strongest verification covering it, and whether that coverage is current (#1).

  `ExTLA.Coverage` already computes never-enabled actions and vacuous properties, and today it
  reports them to a terminal. "Nobody reads a terminal from three weeks ago, and CI does not
  diff it" (#1, failure mode 3). This renders the same findings into an artifact CI
  byte-compares, so a coverage regression is a build failure rather than scrollback.

  ## What may never appear here

  Durations, dates, seeds, machine names, worker counts. A golden is a stable function of
  source; anything that varies independently makes it drift against itself on a quiet day, and
  a gate that cries wolf is one somebody switches off.

  That rule has a subtle case worth naming, because it is invisible unless you read
  `ExTLA.Coverage`'s own documentation: **`distinct_generated` is excluded.** It attributes each
  state to whichever action reached it first, so it is "a function of the search order rather
  than of the model" and moves under `workers:` while the total does not. Putting it in a
  golden would produce drift with no change to any spec. `enabled_in` is used instead — how
  many states an action was enabled in is a property of the model.

  ## The two honesty conditions (#1, decision 3)

  1. **A spec that cannot be run still gets rows.** A spec whose constants have neither a
     `default:` nor a config entry cannot be checked, and silently omitting it would let a
     coverage document imply a completeness it does not have. It appears with its items and
     `NOTHING`, naming the constants that are missing.
  2. **A bounded run's numbers are lower bounds.** When `max_states`, a `state_constraint`, or
     a counterexample stopped the search, the rows say so — the same reason
     `:max_states_reached` exists (D-10). An unqualified count from a truncated run is a false
     claim of exhaustiveness.
  """

  alias ExTLA.{ModelChecker, Spec}
  alias ExTLA.Mix.SpecTarget

  @typedoc "One catalogued spec item."
  @type row :: %{
          kind: atom(),
          name: atom(),
          version: String.t() | nil,
          evidence: atom(),
          fresh: atom(),
          exercised: String.t(),
          bounded?: boolean()
        }

  @typedoc "One spec's section of the ledger."
  @type section :: %{
          module: module(),
          source: String.t() | nil,
          runnable?: boolean(),
          missing: [atom()],
          error: String.t() | nil,
          bounded_by: atom(),
          rows: [row]
        }

  @doc """
  Check every discoverable spec and build the ledger.

  A spec that cannot be run is not an error here — it is a finding, per honesty condition 1.
  """
  def run(modules \\ SpecTarget.resolve!([])) do
    freshness = freshness_by_spec()
    Enum.map(modules, &section(&1, freshness))
  end

  # Freshness per spec, derived from the `spec_version:` stamps refinement mappings carry (#67).
  #
  # A stamp is a claim that someone re-read a mapping against a particular version of a spec.
  # So an item is `fresh` when a mapping has confirmed against the spec AS IT STANDS, `stale`
  # when one confirmed against a version that has since moved, and `unstamped` when nothing has
  # claimed anything.
  #
  # `stale` wins over `fresh` when a spec has several mappings and they disagree: one mapping
  # being current does not make another one's outdated claim true, and reporting the optimistic
  # answer would hide exactly the mapping that needs re-reading.
  defp freshness_by_spec do
    Mix.Tasks.Tla.Stamp.states()
    |> Enum.reject(&(&1.status == :unstamped))
    |> Enum.group_by(& &1.spec, & &1.status)
    |> Map.new(fn {spec, statuses} ->
      cond do
        :stale in statuses -> {spec, :stale}
        :unverifiable in statuses -> {spec, :unverifiable}
        true -> {spec, :fresh}
      end
    end)
  end

  defp section(module, freshness) do
    fresh = Map.get(freshness, module, :unstamped)
    spec = Spec.Compiled.from_module(module)
    versions = ExTLA.Spec.Hash.item_versions(module)

    case Spec.Compiled.resolve_constants(spec) do
      {:ok, constants} ->
        case check(spec, constants) do
          {:ok, coverage, temporals} ->
            checked(module, spec, versions, coverage, temporals, fresh)

          {:exit, reason} ->
            errored(module, spec, versions, reason, fresh)
        end

      {:error, missing} ->
        unrunnable(module, spec, versions, missing, fresh)
    end
  end

  # Run the check in its own process and OBSERVE its exit, rather than wrapping the call in a
  # rescue. A spec that raises is a finding this document should carry — "this spec cannot be
  # checked" is exactly the kind of thing a verification ledger exists to make visible — and a
  # rescue would let one bad spec's failure read like an absence of findings.
  #
  # `Task.async` is the wrong tool here: it LINKS, so one crashing spec kills the run.
  # `spawn_monitor` observes the exit without being killed by it.
  #
  # Process isolation gets that without hiding anything: the exit reason is recorded and
  # rendered, and every OTHER spec still gets its row.
  #
  # No timeout, deliberately. A deadline would make the golden a function of machine speed, so
  # a slow CI runner could flip rows and produce drift with no spec changing. The checker's own
  # `max_states` bound is what makes this terminate; that bound is part of the model and shows
  # up honestly as LOWER BOUNDS.
  defp check(spec, constants) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        coverage = ModelChecker.run(spec, %{constants: constants}).coverage
        send(parent, {:ledger_coverage, self(), coverage, temporal_verdicts(spec, constants)})
      end)

    receive do
      {:ledger_coverage, ^pid, coverage, temporals} ->
        Process.demonitor(ref, [:flush])
        {:ok, coverage, temporals}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:exit, reason}
    end
  end

  # One liveness run PER temporal property, because the checker halts at the first refutation
  # and a single run therefore cannot say which of several properties it evaluated (#191).
  #
  # This ledger used to run once, without `check_liveness: true`, and then write
  # `model_checked … checked` beside every temporal not marked vacuous. Eleven rows carried that
  # claim from a run that never asked the question, and one of them -- `IdlingUnfair`'s
  # `eventually_two` -- is REFUTED under liveness. The document's own prose names this as the
  # precise lie it exists to prevent, and its drift gate protected a golden that was stable
  # while wrong: the gate ensures the golden matches the generator, and says nothing about
  # whether the generator is right.
  #
  # Selecting one temporal per run uses the `temporals:` selection, which since #185 refuses a
  # name that matches nothing -- so a renamed property cannot silently drop out of the ledger.
  # Safety is not re-run: `invariants: []` and `action_properties: []` leave only the graph
  # build and the one liveness question. The cost is one graph per temporal per spec, measured
  # against the corpus before this landed and recorded on #234.
  defp temporal_verdicts(spec, constants) do
    Map.new(spec.temporals, fn %{name: name} ->
      result =
        ModelChecker.run(spec, %{
          constants: constants,
          check_liveness: true,
          invariants: [],
          action_properties: [],
          temporals: [name]
        })

      {name, temporal_verdict(result, name)}
    end)
  end

  defp temporal_verdict(%{status: :ok}, _name), do: :checked

  defp temporal_verdict(%{status: :violation, violation: %{prefix: %{property: name}}}, name),
    do: :refuted

  # A safety violation or a deadlock halts before liveness runs; the run says so in its warnings
  # (#186), and this ledger carries that forward rather than reading it as a pass.
  defp temporal_verdict(%{warnings: warnings, status: status}, _name) do
    reason =
      Enum.find_value(warnings, "#{status} before liveness ran", fn w ->
        if w =~ "not checked", do: w
      end)

    {:not_evaluated, reason}
  end

  # A spec whose check raised. Every item is listed with NOTHING: nothing was verified, and
  # the section heading carries why.
  defp errored(module, spec, versions, reason, fresh) do
    %{
      module: module,
      source: source(module),
      runnable?: false,
      missing: [],
      error: describe(reason),
      bounded_by: :none,
      rows:
        Enum.map(items(spec), fn {kind, name} ->
          %{
            kind: kind,
            name: name,
            version: Map.get(versions, {kind, name}),
            evidence: :nothing,
            fresh: fresh,
            exercised: "raised",
            bounded?: false
          }
        end)
    }
  end

  # The exception's module name only. A message would carry state values that vary with the
  # search order, and a golden cannot hold anything that moves on its own.
  defp describe({%{__struct__: mod}, _stacktrace}), do: inspect(mod)
  defp describe({reason, _stacktrace}) when is_atom(reason), do: inspect(reason)
  defp describe(_), do: "unknown"

  defp checked(module, spec, versions, coverage, temporals, fresh) do
    bounded? = coverage.bounded_by != :none
    vacuous = MapSet.new(coverage.vacuous, & &1.property)

    %{
      module: module,
      source: source(module),
      runnable?: true,
      missing: [],
      error: nil,
      bounded_by: coverage.bounded_by,
      rows:
        Enum.map(items(spec), fn {kind, name} ->
          {evidence, exercised} = verdict(kind, name, coverage, vacuous, temporals)

          %{
            kind: kind,
            name: name,
            version: Map.get(versions, {kind, name}),
            evidence: evidence,
            fresh: fresh,
            exercised: exercised,
            bounded?: bounded?
          }
        end)
    }
  end

  # Honesty condition 1. Every item still gets a row; the evidence is NOTHING because none was
  # produced, and the section says which constants would let it be.
  defp unrunnable(module, spec, versions, missing, fresh) do
    %{
      module: module,
      source: source(module),
      runnable?: false,
      missing: missing,
      error: nil,
      bounded_by: :none,
      rows:
        Enum.map(items(spec), fn {kind, name} ->
          %{
            kind: kind,
            name: name,
            version: Map.get(versions, {kind, name}),
            evidence: :nothing,
            fresh: fresh,
            exercised: "cannot run",
            bounded?: false
          }
        end)
    }
  end

  # Every kind `ExTLA.Spec.Hash.kinds/0` names, in that order, so a kind added to the DSL is a
  # row here on the day it is added — or a `FunctionClauseError` from `verdict/5`, which is
  # the honest failure. A hand-written list of three (#202) left `action_property` and
  # `terminal` with no rows under a header promising every item a spec declares.
  defp items(spec) do
    Enum.flat_map(ExTLA.Spec.Hash.kinds(), fn kind ->
      Enum.map(declarations(spec, kind), &{kind, &1.name})
    end)
  end

  defp declarations(spec, :action), do: spec.actions
  defp declarations(spec, :invariant), do: spec.invariants
  defp declarations(spec, :temporal), do: spec.temporals
  defp declarations(spec, :action_property), do: spec.action_properties
  defp declarations(spec, :terminal), do: spec.terminals

  # An action never enabled, or a property that held vacuously, was not verified — it was
  # merely present while a check ran. Calling that `model_checked` is the precise lie this
  # ledger exists to prevent.
  defp verdict(:action, name, coverage, _vacuous, _temporals) do
    if name in coverage.never_enabled do
      {:nothing, "never enabled"}
    else
      case Map.get(coverage.actions, name) do
        %{enabled_in: n} -> {:model_checked, "enabled in #{n}"}
        nil -> {:nothing, "never enabled"}
      end
    end
  end

  defp verdict(:invariant, name, coverage, _vacuous, _temporals) do
    case Map.get(coverage.invariants, name) do
      # `nil` near-misses is "not measured", which is a different fact from zero: zero is a
      # finding, and not having looked is not.
      %{near_misses: nil} -> {:model_checked, "not measured"}
      %{near_misses: n} -> {:model_checked, "#{n} near-miss"}
      nil -> {:nothing, "not evaluated"}
    end
  end

  # An action property is checked on every transition the search took, so its evidence is
  # the transition count — and a run that took none checked it against nothing.
  defp verdict(:action_property, _name, coverage, _vacuous, _temporals) do
    case coverage.actions |> Map.values() |> Enum.map(& &1.states_generated) |> Enum.sum() do
      0 -> {:nothing, "no transitions"}
      n -> {:model_checked, "on #{n} transitions"}
    end
  end

  # A terminal is consulted only where a behaviour ends. One that admitted no such state was
  # never the reason a behaviour was allowed to end there — the run would have reported the
  # same deadlocks without it — and that is not verified, it is unused.
  defp verdict(:terminal, name, coverage, _vacuous, _temporals) do
    case Map.get(coverage.terminals, name) do
      %{admitted: 0} -> {:nothing, "admitted no end state"}
      %{admitted: 1} -> {:model_checked, "admitted 1 end state"}
      %{admitted: n} -> {:model_checked, "admitted #{n} end states"}
      nil -> {:nothing, "not evaluated"}
    end
  end

  # A refuted property was checked MORE thoroughly than a holding one -- the checker produced a
  # witness -- so it is `model_checked` strength with the word that matters. It gets its own
  # evidence rung rather than a detail string because a reader scanning the column for what
  # was verified must not read a refutation as a pass, and `checked` beside a refuted property
  # is what this ledger used to write.
  defp verdict(:temporal, name, _coverage, vacuous, temporals) do
    cond do
      name in vacuous ->
        {:nothing, "VACUOUS"}

      Map.get(temporals, name) == :refuted ->
        {:refuted, "REFUTED"}

      Map.get(temporals, name) == :checked ->
        {:model_checked, "checked"}

      match?({:not_evaluated, _}, Map.get(temporals, name)) ->
        {:nothing, elem(Map.get(temporals, name), 1)}

      true ->
        {:nothing, "not evaluated"}
    end
  end

  defp source(module) do
    with true <- Code.ensure_loaded?(module),
         path when is_list(path) <- module.module_info(:compile)[:source] do
      path |> List.to_string() |> Path.relative_to_cwd()
    else
      _ -> nil
    end
  end

  @evidence_order [
    :model_checked,
    :refuted,
    :refinement_checked,
    :simulated,
    :property,
    :unit_test
  ]

  @doc """
  The `Surfex.Golden` spec for `TLA_COVERAGE.md` — data only.

  One group per spec module, so a reader sees a spec's gaps together rather than having to
  reassemble them from a flat table.
  """
  def golden_spec(sections) do
    all = rows(sections)

    %{
      name: "TLA_COVERAGE.md",
      purpose: "Every item each ExTLA.Spec declares, and the verification that covers it.",
      task: "tla.coverage",
      gate: "surface-drift",
      hardness: :hard,
      prose: prose(),
      stats: [
        Surfex.Golden.stat(
          "#{length(sections)} specs · #{length(all)} items",
          Enum.map(@evidence_order, fn e ->
            {to_string(e), Enum.count(all, &(&1.evidence == e))}
          end) ++
            [{"nothing", length(gaps(sections))}]
        ),
        Surfex.Golden.stat(
          "freshness",
          [
            {"fresh", Enum.count(all, &(&1.fresh == :fresh))},
            {"stale", Enum.count(all, &(&1.fresh == :stale))},
            {"unstamped", Enum.count(all, &(&1.fresh == :unstamped))}
          ]
        )
      ],
      columns: ["Item", "Kind", "Version", "Evidence", "Fresh", "Exercised", "Locus"],
      groups: Enum.map(sections, &group/1)
    }
  end

  defp group(section) do
    %{
      heading: heading(section),
      rows: Enum.map(section.rows, &row_cells(&1, section))
    }
  end

  # Honesty condition 1 is stated in the heading, not buried in a cell: a spec that could not
  # be run is a fact about the whole section, and a reader scanning headings must not have to
  # infer it from every row saying "cannot run".
  # A spec whose check raised gets its own heading: "cannot run" and "ran and blew up" are
  # different findings, and collapsing them would hide the second behind the first.
  defp heading(%{error: error} = section) when is_binary(error) do
    "#{inspect(section.module)} — RAISED #{error}: nothing verified"
  end

  defp heading(%{runnable?: false} = section) do
    "#{inspect(section.module)} — CANNOT RUN: no assignment for " <>
      Enum.map_join(section.missing, ", ", &inspect/1)
  end

  defp heading(%{bounded_by: :none} = section) do
    "#{inspect(section.module)} — #{length(section.rows)} items · gap #{gap_count(section)}"
  end

  # Honesty condition 2, likewise in the heading. `:violation` counts as bounded because a run
  # that stopped at a counterexample stopped mid-expansion.
  defp heading(section) do
    "#{inspect(section.module)} — #{length(section.rows)} items · gap #{gap_count(section)} · " <>
      "LOWER BOUNDS (#{section.bounded_by})"
  end

  defp gap_count(section), do: Enum.count(section.rows, &(&1.evidence == :nothing))

  defp row_cells(row, section) do
    %{
      "Item" => {:code, to_string(row.name)},
      "Kind" => {:atom, row.kind},
      "Version" => if(row.version, do: {:version, row.version}, else: :absent),
      "Evidence" => {:atom, row.evidence},
      "Fresh" => {:atom, row.fresh},
      "Exercised" => exercised_cell(row),
      "Locus" => if(section.source, do: {:locus, section.source, nil}, else: :absent)
    }
  end

  # A bounded run's count is a floor. Rendering it unqualified would be a false claim of
  # exhaustiveness, so the marker travels with the number rather than only with the section.
  defp exercised_cell(%{bounded?: true, exercised: text}), do: {:raw, "≥ " <> text}
  defp exercised_cell(%{exercised: text}), do: {:raw, text}

  defp prose do
    """
    Evidence, strongest→weakest: `model_checked` ▸ `refuted` ▸ `refinement_checked` ▸
    `simulated` ▸ `property` ▸ `unit_test` ▸ **NOTHING**. ExTLA reports only evidence ExTLA
    produces; the weaker classes exist so a consuming project can merge this into its own ladder.

    `refuted` is `model_checked` strength with the word that matters: the checker produced a
    counterexample, which is a stronger fact about the property than a pass. It is its own
    class so a reader scanning for what was verified cannot read a refutation as one. Every
    temporal property gets its own liveness run — the checker halts at the first refutation, so
    one run cannot say which of several properties it evaluated.

    `NOTHING` is the backlog. An action that was never enabled, a property that held
    vacuously, a temporal property the run never reached, an action property checked against
    no transition, and a terminal that admitted no end state were not verified — they were
    merely present while a check ran, and calling that `model_checked` is the precise lie this
    document exists to prevent. Every kind the DSL declares has rows here; the kind list is
    `ExTLA.Spec.Hash.kinds/0`, not a list written by hand.

    A section marked **LOWER BOUNDS** was truncated by `max_states`, a `state_constraint`, or a
    counterexample, and its counts are floors rather than totals. A section marked
    **CANNOT RUN** has constants with neither a `default:` nor a config entry; its items are
    listed anyway, because omitting them would imply a completeness this document does not have.

    `Exercised` reports `enabled_in` and never `distinct_generated`: the latter attributes a
    state to whichever action reached it first, so it moves under `workers:` without any spec
    changing.

    No durations, dates, seeds or machine names appear here. A golden is a stable function of
    source; anything varying independently makes it drift against itself on a quiet day.
    """
  end

  @doc "Render the ledger."
  def render(sections), do: sections |> golden_spec() |> Surfex.Golden.render()

  @doc "Every row across every section — the ledger's flat census."
  def rows(sections), do: Enum.flat_map(sections, & &1.rows)

  @doc "Items with no verification at all: the backlog this document exists to keep visible."
  def gaps(sections), do: sections |> rows() |> Enum.filter(&(&1.evidence == :nothing))
end
