defmodule TLA.Ledger do
  @moduledoc """
  The verification ledger: every item each `TLA.Spec` declares, its content version, the
  strongest verification covering it, and whether that coverage is current (#1).

  `TLA.Coverage` already computes never-enabled actions and vacuous properties, and today it
  reports them to a terminal. "Nobody reads a terminal from three weeks ago, and CI does not
  diff it" (#1, failure mode 3). This renders the same findings into an artifact CI
  byte-compares, so a coverage regression is a build failure rather than scrollback.

  ## What may never appear here

  Durations, dates, seeds, machine names, worker counts. A golden is a stable function of
  source; anything that varies independently makes it drift against itself on a quiet day, and
  a gate that cries wolf is one somebody switches off.

  That rule has a subtle case worth naming, because it is invisible unless you read
  `TLA.Coverage`'s own documentation: **`distinct_generated` is excluded.** It attributes each
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

  alias TLA.{ModelChecker, Spec}
  alias TLA.Mix.SpecTarget

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
  @spec run([module()]) :: [section]
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
    versions = TLA.Spec.Version.versions(module)

    case Spec.Compiled.resolve_constants(spec) do
      {:ok, constants} ->
        case check(spec, constants) do
          {:ok, coverage} -> checked(module, spec, versions, coverage, fresh)
          {:exit, reason} -> errored(module, spec, versions, reason, fresh)
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
        send(
          parent,
          {:ledger_coverage, self(), ModelChecker.run(spec, %{constants: constants}).coverage}
        )
      end)

    receive do
      {:ledger_coverage, ^pid, coverage} ->
        Process.demonitor(ref, [:flush])
        {:ok, coverage}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:exit, reason}
    end
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

  defp checked(module, spec, versions, coverage, fresh) do
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
          {evidence, exercised} = verdict(kind, name, coverage, vacuous)

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

  defp items(spec) do
    Enum.map(spec.actions, &{:action, &1.name}) ++
      Enum.map(spec.invariants, &{:invariant, &1.name}) ++
      Enum.map(spec.temporals, &{:temporal, &1.name})
  end

  # An action never enabled, or a property that held vacuously, was not verified — it was
  # merely present while a check ran. Calling that `model_checked` is the precise lie this
  # ledger exists to prevent.
  defp verdict(:action, name, coverage, _vacuous) do
    if name in coverage.never_enabled do
      {:nothing, "never enabled"}
    else
      case Map.get(coverage.actions, name) do
        %{enabled_in: n} -> {:model_checked, "enabled in #{n}"}
        nil -> {:nothing, "never enabled"}
      end
    end
  end

  defp verdict(:invariant, name, coverage, _vacuous) do
    case Map.get(coverage.invariants, name) do
      # `nil` near-misses is "not measured", which is a different fact from zero: zero is a
      # finding, and not having looked is not.
      %{near_misses: nil} -> {:model_checked, "not measured"}
      %{near_misses: n} -> {:model_checked, "#{n} near-miss"}
      nil -> {:nothing, "not evaluated"}
    end
  end

  defp verdict(:temporal, name, _coverage, vacuous) do
    if name in vacuous, do: {:nothing, "VACUOUS"}, else: {:model_checked, "checked"}
  end

  defp source(module) do
    with true <- Code.ensure_loaded?(module),
         path when is_list(path) <- module.module_info(:compile)[:source] do
      path |> List.to_string() |> Path.relative_to_cwd()
    else
      _ -> nil
    end
  end

  @evidence_order [:model_checked, :refinement_checked, :simulated, :property, :unit_test]

  @doc """
  The `Surfex.Golden` spec for `TLA_COVERAGE.md` — data only.

  One group per spec module, so a reader sees a spec's gaps together rather than having to
  reassemble them from a flat table.
  """
  @spec golden_spec([section]) :: map
  def golden_spec(sections) do
    all = rows(sections)

    %{
      name: "TLA_COVERAGE.md",
      purpose: "Every item each TLA.Spec declares, and the verification that covers it.",
      task: "tla.coverage",
      gate: "tla-coverage-drift",
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
    Evidence, strongest→weakest: `model_checked` ▸ `refinement_checked` ▸ `simulated` ▸
    `property` ▸ `unit_test` ▸ **NOTHING**. ExTLA reports only evidence ExTLA produces; the
    weaker classes exist so a consuming project can merge this into its own ladder.

    `NOTHING` is the backlog. An action that was never enabled and a property that held
    vacuously were not verified — they were merely present while a check ran, and calling that
    `model_checked` is the precise lie this document exists to prevent.

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
  @spec render([section]) :: iodata
  def render(sections), do: sections |> golden_spec() |> Surfex.Golden.render()

  @doc "Every row across every section — the ledger's flat census."
  @spec rows([section]) :: [row]
  def rows(sections), do: Enum.flat_map(sections, & &1.rows)

  @doc "Items with no verification at all: the backlog this document exists to keep visible."
  @spec gaps([section]) :: [row]
  def gaps(sections), do: sections |> rows() |> Enum.filter(&(&1.evidence == :nothing))
end
