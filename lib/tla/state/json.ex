defmodule TLA.State.Json do
  @moduledoc """
  The JSON form of a state term, and back again.

  `02-dsl-semantics.md` §6 permits atoms, integers, binaries, tuples, lists, maps,
  `MapSet`s and structs built from those. JSON has objects, arrays, strings and numbers,
  so five of those eight have no JSON of their own and every one of them needs a tag.

  ## Why this exists rather than `inspect/1`

  `mix tla.check --format json` wrote states and bindings with `inspect/1`, which a person
  can read and a machine cannot parse back. §05's own pipeline is
  `mix tla.check --format json` into `mix tla.replay --trace counterexample.json`, and a
  format that only goes one way cannot carry it. The human rendering is
  `TLA.Trace.format/1` and stays exactly as it was.

      %{count: 1, status: :ready}
      #=> %{"m" => [[%{"a" => "count"}, 1], [%{"a" => "status"}, %{"a" => "ready"}]]}

  Maps are pairs rather than JSON objects because a spec's map keys are usually atoms and
  may be anything §6 permits — a JSON object would force every key to a string and lose
  which ones were atoms.

  ## An atom the system does not already have is an error

  A trace file is data from outside the program, and the atom table is never collected, so
  a decoder that creates atoms from a file lets a large one exhaust it. Every atom a real
  trace mentions exists already: the spec module that named it is loaded before its trace
  is read.

  One that does not raises `ArgumentError` — *"not an already existing atom"*, from
  `String.to_existing_atom/1`. The usual cause is a trace belonging to a different
  specification than the module it is being replayed against.
  """

  defmodule Error do
    @moduledoc "A term that is not §6-permitted, or JSON that does not decode to one."
    defexception [:message]
  end

  @doc """
  A state term as data `Jason.encode!/1` accepts.
  """
  @spec encode(term()) :: term()
  def encode(term)

  def encode(integer) when is_integer(integer), do: integer
  def encode(atom) when is_atom(atom), do: %{"a" => Atom.to_string(atom)}
  def encode(binary) when is_binary(binary), do: %{"b" => binary}
  def encode(list) when is_list(list), do: Enum.map(list, &encode/1)
  def encode(tuple) when is_tuple(tuple), do: %{"t" => tuple |> Tuple.to_list() |> encode()}
  def encode(%MapSet{} = set), do: %{"set" => set |> MapSet.to_list() |> encode()}

  def encode(%module{} = struct) do
    %{"struct" => Atom.to_string(module), "m" => struct |> Map.from_struct() |> pairs()}
  end

  def encode(map) when is_map(map), do: %{"m" => pairs(map)}

  def encode(other) do
    raise Error,
          "#{inspect(other)} is not a term a spec's state may hold. " <>
            "02-dsl-semantics.md §6 permits atoms, integers, binaries, tuples, lists, " <>
            "maps, MapSets and structs of those, and forbids pids, references, ports, " <>
            "funs and floats."
  end

  @doc """
  The term a `encode/1` result came from.

  Raises `TLA.State.Json.Error` on JSON this module did not write, and on an atom no
  loaded module has ever mentioned.
  """
  @spec decode!(term()) :: term()
  def decode!(data)

  def decode!(integer) when is_integer(integer), do: integer
  def decode!(list) when is_list(list), do: Enum.map(list, &decode!/1)
  def decode!(%{"a" => name}) when is_binary(name), do: atom!(name)
  def decode!(%{"b" => binary}) when is_binary(binary), do: binary

  def decode!(%{"t" => elements}) when is_list(elements),
    do: elements |> decode!() |> List.to_tuple()

  def decode!(%{"set" => elements}) when is_list(elements), do: MapSet.new(decode!(elements))

  def decode!(%{"struct" => module, "m" => pairs}) when is_binary(module) and is_list(pairs) do
    struct!(atom!(module), unpairs(pairs))
  end

  def decode!(%{"m" => pairs}) when is_list(pairs), do: Map.new(unpairs(pairs))

  def decode!(other) do
    raise Error,
          "#{inspect(other)} is not the JSON form of a state term. Expected a number, an " <>
            "array, or an object tagged \"a\" (atom), \"b\" (binary), \"t\" (tuple), " <>
            "\"set\", \"m\" (map) or \"struct\"."
  end

  defp pairs(map), do: for({key, value} <- map, do: [encode(key), encode(value)])

  defp unpairs(pairs) do
    Enum.map(pairs, fn
      [key, value] ->
        {decode!(key), decode!(value)}

      other ->
        raise Error, "#{inspect(other)} is not a [key, value] pair of an encoded map."
    end)
  end

  # `String.to_existing_atom/1`, whose failure is Elixir's own "not an already existing
  # atom" — which does not name the atom, and this codebase does not rescue an error to
  # improve its message.
  #
  # A first version measured the atom table across the conversion to name it, and CI
  # refuted that: `:erlang.system_info(:atom_count)` is global, so any atom another process
  # creates between the two readings looks like this one. It reported atoms that plainly
  # existed, on a machine running its tests concurrently. A check whose answer depends on
  # what an unrelated process did is not a check.
  defp atom!(name), do: String.to_existing_atom(name)
end
