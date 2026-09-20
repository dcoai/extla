defmodule TLA.State do
  @moduledoc """
  A state is an immutable snapshot of all specification variables.
  A step is a pair of consecutive states (pre-state and post-state).
  A behavior is a (possibly infinite) sequence of states.

  A state is a plain map, deliberately: it is the value the DSL's transitions
  build and the value `TLA.Fingerprint` hashes, and wrapping it in a struct would
  buy nothing but an extra field in every fingerprint.

  ## Missing variables raise

  `get/2`, `unchanged?/2` and `prime/3` all fail loudly on a variable the state
  does not have. This is not defensiveness; it is the difference between a bug
  and a wrong answer. A misspelled variable read through `Map.get/2` returns
  `nil`, `nil` compares unequal to whatever the guard expected, the action looks
  disabled, and the checker explores a smaller state space and reports success.
  Nothing in the output distinguishes that run from a sound one, which is the
  failure mode `01-foundation.md` §`TLA.Fingerprint` exists to prevent at the
  level below.
  """

  @type variable_name :: atom()
  @type value :: term()

  @type t :: %{variable_name() => value()}

  @type step :: {pre :: t(), post :: t()}

  @type behavior :: [t(), ...]

  # A counterexample is `TLA.Trace.t()` (04-layer2-model-checker.md §TLA.Trace).

  @doc """
  Create a new state from a keyword list or map of variable assignments.

      iex> TLA.State.new(x: 0, y: 1)
      %{x: 0, y: 1}
  """
  def new(assignments), do: Map.new(assignments)

  @doc """
  Return the value of a variable in the given state.

  Raises `KeyError` if the variable is not in the state — see the note on
  missing variables in the module documentation.

      iex> TLA.State.get(%{x: 0}, :x)
      0
  """
  def get(state, var), do: Map.fetch!(state, var)

  @doc """
  Return a new state with the given variable updated.
  Analogous to TLA+ primed variable assignment: `x' = value`.

  Raises `KeyError` if the variable is not already in the state. A TLA+ spec's
  variable set is fixed by its `Init`, so priming a variable that is not in the
  state is a typo, and a typo that silently widens the state is one the
  fingerprint would then faithfully preserve.

      iex> TLA.State.prime(%{x: 0, y: 1}, :x, 2)
      %{x: 2, y: 1}
  """
  def prime(state, var, value), do: Map.replace!(state, var, value)

  @doc """
  Return a new state with multiple variables updated.

      iex> TLA.State.prime_many(%{x: 0, y: 1}, %{x: 2, y: 3})
      %{x: 2, y: 3}
  """
  def prime_many(state, assignments) do
    Enum.reduce(assignments, state, fn {var, value}, acc -> prime(acc, var, value) end)
  end

  @doc """
  Check if two states are identical (stuttering step).

      iex> TLA.State.stuttering?({%{x: 0}, %{x: 0}})
      true
  """
  def stuttering?({pre, post}), do: pre == post

  @doc """
  Return the set of variables that changed between states.

      iex> TLA.State.changed_vars({%{x: 0, y: 1}, %{x: 2, y: 1}})
      MapSet.new([:x])
  """
  def changed_vars({pre, post}) do
    pre
    |> Map.keys()
    |> Enum.concat(Map.keys(post))
    |> Enum.filter(&(Map.get(pre, &1, :__absent__) != Map.get(post, &1, :__absent__)))
    |> MapSet.new()
  end

  @doc """
  Assert that specified variables did NOT change between states.
  Analogous to TLA+ `UNCHANGED <<x, y, z>>`.

      iex> TLA.State.unchanged?({%{x: 0, y: 1}, %{x: 2, y: 1}}, [:y])
      true
  """
  def unchanged?({pre, post}, vars) do
    Enum.all?(vars, fn var -> Map.fetch!(pre, var) == Map.fetch!(post, var) end)
  end

  @doc """
  Assert that every value in the state is deterministically serializable,
  per `02-dsl-semantics.md` §6.

  Returns the state, so it can be threaded into a pipeline. Raises
  `TLA.State.InvalidTermError` naming the variable and the position inside it.

  Pids, references and ports have no stable identity across runs, and funs
  serialize their defining module's version. Floats are excluded for a subtler
  reason: `0.0` and `-0.0` compare equal under `==` but encode differently, so
  two states that a spec author would call equal would be explored twice — and
  `:nan` never equals itself, so a state containing one is not even equal to
  itself.

      iex> TLA.State.validate!(%{x: 0, q: [:a, {1, "b"}]})
      %{x: 0, q: [:a, {1, "b"}]}
  """
  def validate!(state) when is_map(state) do
    Enum.each(state, fn {var, value} -> validate_term!(value, var, []) end)
    state
  end

  defp validate_term!(term, var, path) when is_pid(term), do: reject!(term, var, path, "a pid")

  defp validate_term!(term, var, path) when is_reference(term),
    do: reject!(term, var, path, "a reference")

  defp validate_term!(term, var, path) when is_port(term), do: reject!(term, var, path, "a port")

  defp validate_term!(term, var, path) when is_function(term),
    do: reject!(term, var, path, "a fun")

  defp validate_term!(term, var, path) when is_float(term),
    do: reject!(term, var, path, "a float")

  # A bitstring that is not a whole number of bytes. `TLA.State.Json` has no encoding for one
  # — base64 is bytes — and admitting here what the wire format refuses means a violation the
  # search found is lost when the report is written (#198). The two agree on what a term is.
  defp validate_term!(term, var, path) when is_bitstring(term) and not is_binary(term),
    do: reject!(term, var, path, "a bitstring")

  defp validate_term!(%MapSet{} = term, var, path) do
    Enum.each(term, &validate_term!(&1, var, path ++ ["a MapSet element"]))
  end

  defp validate_term!(%_{} = term, var, path) do
    term |> Map.from_struct() |> validate_term!(var, path)
  end

  defp validate_term!(term, var, path) when is_map(term) do
    Enum.each(term, fn {k, v} ->
      validate_term!(k, var, path ++ ["a map key"])
      validate_term!(v, var, path ++ ["key #{inspect(k)}"])
    end)
  end

  defp validate_term!(term, var, path) when is_list(term) do
    term
    |> Enum.with_index()
    |> Enum.each(fn {v, i} -> validate_term!(v, var, path ++ ["element #{i}"]) end)
  end

  defp validate_term!(term, var, path) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.each(fn {v, i} -> validate_term!(v, var, path ++ ["tuple element #{i}"]) end)
  end

  defp validate_term!(_term, _var, _path), do: :ok

  defp reject!(term, var, path, kind) do
    raise TLA.State.InvalidTermError, variable: var, path: path, term: term, kind: kind
  end

  defmodule InvalidTermError do
    @moduledoc """
    Raised when a spec variable holds a term that cannot be deterministically
    serialized (`02-dsl-semantics.md` §6).
    """

    defexception [:variable, :path, :term, :kind]

    @impl true
    def message(%{variable: var, path: path, term: term, kind: kind}) do
      "spec variable #{inspect(var)}#{where(path)} holds #{kind}: #{inspect(term)}.\n\n" <>
        "State identity is a hash of the variable's value, so a term with no stable\n" <>
        "encoding would make two equal states hash differently and be explored twice.\n" <>
        "Permitted: atoms, integers, binaries, tuples, lists, maps, MapSets, and\n" <>
        "structs built from those (02-dsl-semantics.md §6)."
    end

    defp where([]), do: ""
    defp where(path), do: ", at " <> Enum.join(path, " -> ")
  end
end
