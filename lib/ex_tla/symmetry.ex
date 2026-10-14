defmodule ExTLA.Symmetry do
  @moduledoc """
  Symmetry reduction: states that differ only by a permutation of interchangeable
  constants are one state.

  `symmetry: [:processes]` says the elements of `^processes` are interchangeable — process
  ids, account names, replica ids. For a symmetric set of size *n*, the reachable space
  shrinks by up to a factor of *n!*, which is the difference between tractable and not for
  exactly the specs this tool is for.

  The mechanism is canonical form. Before a state is fingerprinted it is rewritten under
  every permutation of every symmetric set and the smallest encoding wins, so two
  symmetric states share a fingerprint by construction and the second is never explored.

  ## What it costs

  *n*! encodings per state for one symmetric set of size *n*, and the product for several.
  Three processes and two resources is twelve encodings per state to explore up to twelve
  times fewer states — a wash at best in wall-clock, a clear win at four or five elements.
  It is a lever to be measured on your model, not assumed.

  ## What it assumes, and who checks it

  Symmetry is sound only if nothing in the spec can tell the elements apart: no
  `Enum.at(^accounts, 0)`, no `Enum.sort`, no `<` on process names, no dependence on list
  position. **Nothing verifies this statically**, and ExTLA does not pretend otherwise: a
  constant flows into arbitrary Elixir, so the check is undecidable,
  and any conservative approximation rejects the `Enum.all?(^processes, …)` every real
  spec is built from. Soundness is the author's obligation, exactly as it is in TLC.

  What the tool does instead is make a wrong declaration *detectable*.
  `verify_symmetry: true` runs the same model with and without the reduction and fails if
  any verdict differs. Counts differ on purpose — that is what the reduction is for — so
  it is the verdicts that are compared. Run it once on a small constant assignment before
  trusting the reduction on the large one.
  """

  alias ExTLA.Fingerprint

  @typedoc "One permutation, as the substitution it performs on the elements it moves."
  @type mapping :: %{term() => term()}

  defmodule UnsoundError do
    @moduledoc """
    Raised by `verify_symmetry: true` when the reduced and unreduced runs disagree.

    The declaration is wrong: something in the spec can tell the symmetric elements apart,
    so collapsing them dropped a state whose verdict mattered.
    """
    defexception [:message]
  end

  @doc """
  Every permutation a `symmetry:` declaration induces, as substitutions.

  The identity is among them, so the unpermuted encoding always competes. Elements are
  sorted first, so the permutation list — and therefore every fingerprint — is the same on
  every run.
  """
  def mappings(constants, names) do
    names
    |> Enum.map(&elements!(constants, &1))
    |> Enum.map(&substitutions/1)
    |> ExTLA.Product.fold(%{}, &Map.merge/2)
  end

  defp elements!(constants, name) do
    case Map.fetch(constants, name) do
      {:ok, value} ->
        enumerate!(name, value)

      :error ->
        raise ArgumentError,
              "symmetry names #{inspect(name)}, which this run assigned no value. Symmetry " <>
                "is declared over CONSTANTS (04-layer2-model-checker.md §Symmetry)."
    end
  end

  defp enumerate!(name, value) do
    if is_list(value) or is_struct(value, MapSet) do
      Enum.sort(value)
    else
      raise ArgumentError,
            "symmetry names #{inspect(name)}, whose value is #{inspect(value)}. Only a set " <>
              "or a list has elements to permute."
    end
  end

  defp substitutions(elements) do
    for permuted <- permutations(elements), do: Map.new(Enum.zip(elements, permuted))
  end

  defp permutations([]), do: [[]]

  defp permutations(elements) do
    for element <- elements, rest <- permutations(elements -- [element]), do: [element | rest]
  end

  @doc """
  The canonical encoding of a state: the smallest of its encodings under every permutation.

  Comparing encodings rather than terms is deliberate. `ExTLA.Fingerprint.canonical/1` is
  already the thing state identity is defined by, so the smallest encoding is a canonical
  form in exactly the sense the fingerprint cares about — and Erlang's term order, which
  compares an integer below an atom, is not.
  """
  def canonical(state, mappings) do
    mappings
    |> Enum.map(&Fingerprint.canonical(permute(state, &1)))
    |> Enum.min()
  end

  @doc """
  A state with every occurrence of a symmetric element replaced, wherever it appears —
  as a value, inside a set or a sequence, as a map key, or nested in any of those.
  """
  def permute(term, mapping) when map_size(mapping) == 0, do: term

  def permute(%MapSet{} = set, mapping), do: MapSet.new(set, &permute(&1, mapping))

  def permute(%module{} = struct, mapping) do
    struct
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {key, permute(value, mapping)} end)
    |> then(&struct!(module, &1))
  end

  def permute(map, mapping) when is_map(map) do
    Map.new(map, fn {key, value} -> {permute(key, mapping), permute(value, mapping)} end)
  end

  def permute(list, mapping) when is_list(list), do: Enum.map(list, &permute(&1, mapping))

  def permute(tuple, mapping) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&permute(&1, mapping)) |> List.to_tuple()
  end

  def permute(term, mapping), do: Map.get(mapping, term, term)

  @doc """
  What a reduced and an unreduced run must agree on.

  Not the counts: a sound reduction changes those on purpose, and comparing them would
  fail on every declaration that worked. What has to survive the reduction is every answer
  the run gives — whether it verified, what it refuted, whether it got stuck, and which
  actions it never enabled.
  """
  def verdict(result) do
    %{
      status: result.status,
      deadlock: result.deadlock,
      refuted: refuted(result.violation),
      never_enabled: Enum.sort(result.coverage.never_enabled)
    }
  end

  defp refuted(nil), do: nil
  defp refuted(%{prefix: prefix}), do: prefix.property
  defp refuted(%{property: property}), do: property

  @doc """
  Compare the two runs, raising with what differed.
  """
  def verify!(reduced, full, names) do
    with_reduction = verdict(reduced)
    without = verdict(full)

    cond do
      # A truncation is not a verdict difference (#170). The compared fields exclude counts
      # but include `status` and `never_enabled`, and BOTH are bound-sensitive -- while both
      # runs get the same `max_states` and the reduction's whole purpose is that the
      # unreduced run is bigger. So on any model large enough to need symmetry, the
      # unreduced run hits the bound first and the difference reads as unsoundness.
      #
      # Measured on a 7-state-reduced, 20-state-full model at `max_states: 13`: a SOUND
      # declaration produced "status: :ok with the reduction, :max_states_reached without"
      # and a maximally confident accusation about the spec.
      #
      # Refusing to answer is the honest move and matches how `ExTLA.Conformance` treats a
      # bounded graph. Raising the unreduced run's budget was considered and rejected: it
      # makes the check's cost unpredictable and can still truncate.
      bounded?(reduced) or bounded?(full) ->
        {:inconclusive, bounded_message(names, reduced, full)}

      with_reduction == without ->
        :ok

      true ->
        raise UnsoundError, message: unsound_message(names, with_reduction, without)
    end
  end

  @bounded [:max_states_reached, :constrained]

  defp bounded?(result), do: result.status in @bounded

  defp bounded_message(names, reduced, full) do
    which =
      [{"with the reduction", reduced}, {"without it", full}]
      |> Enum.filter(fn {_label, result} -> bounded?(result) end)
      |> Enum.map_join(", ", fn {label, result} -> "#{label} (#{result.status})" end)

    "symmetry: #{inspect(names)} could not be verified: the run was bounded #{which}, so " <>
      "the two runs did not explore the same thing and a difference between them would be " <>
      "a fact about the bound rather than about the declaration. Re-run without the bound, " <>
      "or with a larger one."
  end

  defp unsound_message(names, with_reduction, without) do
    # A fixed order, not `Map.keys/1`: since OTP 26 a small map's atom keys come back in
    # atom-table order, which depends on which modules happened to create those atoms first,
    # so the same verdict printed its lines in a different order from one VM to the next.
    differences =
      [:status, :deadlock, :refuted, :never_enabled]
      |> Enum.filter(&(Map.get(with_reduction, &1) != Map.get(without, &1)))
      |> Enum.map_join("\n", fn key ->
        "  #{key}: #{inspect(Map.get(with_reduction, key))} with the reduction, " <>
          "#{inspect(Map.get(without, key))} without"
      end)

    """
    symmetry: #{inspect(names)} is not sound for this spec. The same model gives different
    answers with and without the reduction:

    #{differences}

    Something in the spec can tell the elements of #{inspect(names)} apart — an
    `Enum.at`, a sort, a comparison on names, a dependence on list position — so
    collapsing them dropped a state whose verdict mattered. Nothing can check this
    statically (08-decisions.md D-17); this is the check that catches it.\
    """
  end
end
