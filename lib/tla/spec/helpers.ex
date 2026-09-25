defmodule TLA.Spec.Helpers do
  @moduledoc """
  Functions available inside `action`, `init`, `invariant`, `terminal` and
  `action_property` blocks. `use TLA.Spec` imports this module whole, so this list
  **is** a spec body's vocabulary.

  Two kinds of name live here, and the difference is the point (D-38).

  **Thin wrappers over a standard Elixir function.** `set/1`, `put/2`, `union/2`,
  `len/1`, `sum/1` and the rest are one-line covers over `MapSet` and `Enum`.
  They exist for readability rather than capability — `len(buffer)` and
  `sum(values(balances))` read as the TLA+ they translate, and a spec author
  writing `MapSet.size/1` directly gets the same result.

  **Delegations to the foundation.** Every set-theoretic and function operator
  `01-foundation.md` specifies is reachable from a spec body *unqualified*, and
  every one of them is a `defdelegate` to `TLA.Set` or `TLA.Function`. This
  module holds no second implementation of any of them. Until #319 it held four,
  and two had already drifted from their counterparts — `for_each/2` refused a
  sequence where `TLA.Function.construct/2` deduplicated one, and `domain/1` read
  a sequence as `1..Len(s)` where `TLA.Function.domain/1` answered a set with the
  struct's own field names. #318 is the measurement; D-38 is the decision.

  Every one of these is total and deterministic, which is the whole design: an
  action body must be a pure deterministic function of `(pre_state, params)`
  (`02-dsl-semantics.md` §3), so nothing here may branch the search, read the
  clock, or depend on anything but its arguments.

  Where a name would silently produce a wrong answer on a missing key, it
  raises instead: `update/3`, `head/1` and `tail/1` all fail loudly, for the
  reason set out in `01-foundation.md` §Reading a variable that is not there.
  """

  # ── Function application ──

  @doc """
  TLA+: `f[x]` — function application, which is what `f[x]` compiles to inside
  every spec block (`02-dsl-semantics.md` §1.6, D-20).

  A TLA+ function is undefined outside its domain, and a sequence is a function
  on `1..Len(s)`, so both raise here rather than returning `nil`:

      iex> TLA.Spec.Helpers.at(%{alice: 3, bob: 0}, :alice)
      3

      iex> TLA.Spec.Helpers.at([:a, :b, :c], 2)
      :b

  `Access.get/2`, which `f[x]` compiles to in ordinary Elixir, returns `nil`
  outside the domain instead — and `nil >= amount` is `true` under Erlang term
  order, so a guard reading a key it does not have would silently enable its
  action and the checker would explore a state space the spec does not describe.
  """
  def at(collection, key), do: at(collection, key, nil)

  @doc """
  `at/2`, plus the source text of the collection expression for the message. The
  rewriter has that text; a spec author calling `at/2` by hand does not.
  """
  def at(f, key, where) when is_map(f) and not is_struct(f) do
    case Map.fetch(f, key) do
      {:ok, value} -> value
      :error -> raise TLA.Spec.DomainError, collection: f, key: key, where: where
    end
  end

  def at(seq, index, where) when is_list(seq) and is_integer(index) and index >= 1 do
    case Enum.fetch(seq, index - 1) do
      {:ok, value} -> value
      :error -> raise TLA.Spec.DomainError, collection: seq, key: index, where: where
    end
  end

  def at(collection, key, where),
    do: raise(TLA.Spec.DomainError, collection: collection, key: key, where: where)

  # ── Set operations ──

  @doc "The empty set. TLA+: `{}`."
  def set, do: MapSet.new()

  @doc "A set from an enumerable. TLA+: `{a, b, c}`."
  def set(elements), do: MapSet.new(elements)

  @doc "TLA+: `S \\\\cup {e}`."
  def put(set, elem), do: MapSet.put(set, elem)

  @doc "TLA+: `S \\\\ {e}`."
  def delete(set, elem), do: MapSet.delete(set, elem)

  @doc "TLA+: `e \\\\in S`."
  def member?(set, elem), do: MapSet.member?(set, elem)

  @doc "TLA+: `Cardinality(S)`."
  def size(set), do: MapSet.size(set)

  @doc "TLA+: `IsFiniteSet(S)` — here, whether the term is a set at all."
  def is_set(term), do: is_struct(term, MapSet)

  @doc "TLA+: `S \\\\cup T`."
  def union(a, b), do: MapSet.union(a, b)

  @doc "TLA+: `S \\\\cap T`."
  def intersection(a, b), do: MapSet.intersection(a, b)

  @doc "TLA+: `S \\\\ T`."
  def difference(a, b), do: MapSet.difference(a, b)

  @doc "TLA+: `S \\\\subseteq T`."
  def subset?(a, b), do: MapSet.subset?(a, b)

  # ── Set operations, delegated to the foundation ──
  #
  # `01-foundation.md` specifies these on `TLA.Set`; D-38 makes them reachable
  # unqualified from a spec body without a second implementation. A delegation
  # rather than a re-export because `defdelegate` is a compile-time check that
  # the target exists — a renamed operator fails here rather than at a user's
  # first call.

  @doc """
  TLA+: `SUBSET S` — the power set. Exponential in `|S|`; see `TLA.Set.powerset/1`.
  """
  defdelegate powerset(set), to: TLA.Set

  @doc "TLA+: `S1 \\\\X S2` — the Cartesian product."
  defdelegate cross(s1, s2), to: TLA.Set

  @doc "TLA+: `S1 \\\\X S2 \\\\X ... \\\\X Sn`, over a list of sets."
  defdelegate cross_many(sets), to: TLA.Set

  @doc "TLA+: `UNION S` — the distributed union of a set of sets."
  defdelegate distributed_union(set_of_sets), to: TLA.Set

  @doc """
  TLA+: `{f(x) : x \\\\in S}` — set mapping. The result may be smaller than the
  input, exactly as in TLA+: a non-injective `f` collapses elements.
  """
  defdelegate set_map(set, fun), to: TLA.Set, as: :map

  @doc "TLA+: `{x \\\\in S : P(x)}` — set filtering."
  defdelegate set_filter(set, predicate), to: TLA.Set, as: :filter

  @doc "TLA+: `\\\\A x \\\\in S : P(x)`. Vacuously true for the empty set."
  defdelegate for_all?(set, predicate), to: TLA.Set

  @doc "TLA+: `\\\\E x \\\\in S : P(x)`. False for the empty set."
  defdelegate exists?(set, predicate), to: TLA.Set

  @doc "TLA+: `a..b` as a set. Empty when `a > b`."
  defdelegate range(a, b), to: TLA.Set

  # ── Sequence operations ──
  #
  # A TLA+ sequence is 1-indexed, which is why `subseq/3` subtracts one and
  # nothing else here takes an index.

  @doc "The empty sequence. TLA+: `<<>>`."
  def seq, do: []

  @doc "A sequence from a list. TLA+: `<<a, b, c>>`."
  def seq(elements), do: elements

  @doc "TLA+: `Append(s, e)`."
  def append(seq, elem), do: seq ++ [elem]

  @doc "TLA+: `Head(s)`. Raises on the empty sequence, where `Head` is undefined."
  def head(seq), do: hd(seq)

  @doc "TLA+: `Tail(s)`. Raises on the empty sequence, where `Tail` is undefined."
  def tail(seq), do: tl(seq)

  @doc "TLA+: `Len(s)`."
  def len(seq), do: length(seq)

  @doc """
  TLA+: `SubSeq(s, m, n)` — elements `m` through `n` inclusive, **1-indexed**.

      iex> TLA.Spec.Helpers.subseq([:a, :b, :c, :d], 2, 3)
      [:b, :c]

  `n < m` is the empty sequence, whatever `m` and `n` are — TLC's `SubSeq(s, 2, 0)` is `<<>>`
  even for an empty `s`. Otherwise both bounds must lie in `1..Len(s)`, and one outside raises
  `TLA.Spec.DomainError` the way `at/2` does for the same off-by-one (#197).

  This was `Enum.slice(seq, m - 1, n - m + 1)`, which has Elixir's index semantics rather than
  TLA+'s: `subseq([1, 2, 3], 0, 1)` returned `[3]`, a zero index wrapping to the end, and a
  negative `m` counted from the end. An off-by-one in a spec then produced a valid sequence
  that was not the one the author wrote, silently — the exact shape `at/2` refuses.

      iex> TLA.Spec.Helpers.subseq([:a, :b, :c], 3, 2)
      []
  """
  def subseq(seq, m, n) when is_list(seq) and is_integer(m) and is_integer(n) and n < m, do: []

  def subseq(seq, m, n) when is_list(seq) and is_integer(m) and is_integer(n) do
    len = length(seq)

    cond do
      m < 1 -> raise TLA.Spec.DomainError, collection: seq, key: m, where: subseq_where(m, n)
      n > len -> raise TLA.Spec.DomainError, collection: seq, key: n, where: subseq_where(m, n)
      true -> Enum.slice(seq, m - 1, n - m + 1)
    end
  end

  def subseq(other, m, n),
    do: raise(TLA.Spec.DomainError, collection: other, key: m, where: subseq_where(m, n))

  defp subseq_where(m, n), do: "SubSeq(s, #{inspect(m)}, #{inspect(n)}) — s"

  # ── Function (map) operations, delegated to the foundation ──

  @doc """
  TLA+: `[x \\\\in S |-> f(x)]` — `TLA.Function.construct/2` under the name a spec
  body uses.

      iex> TLA.Spec.Helpers.for_each(MapSet.new([:a, :b]), fn _ -> 0 end)
      %{a: 0, b: 0}

  `S` is a set: a list is a sequence, and building a function over one
  deduplicated it silently (#211), so it is refused by name.
  """
  defdelegate for_each(domain, f), to: TLA.Function, as: :construct

  @doc """
  TLA+: `[f EXCEPT ![k] = g(@)]` — `TLA.Function.except_with/3` under the name a
  spec body uses.

  Raises on a key outside the domain — see `TLA.Function` for why extending it
  instead would be worse than failing.
  """
  defdelegate update(map, key, f), to: TLA.Function, as: :except_with

  @doc "TLA+: `[f EXCEPT ![a] = v, ![b] = w]` — several points at once."
  defdelegate except(f, updates), to: TLA.Function

  @doc """
  TLA+: `[S -> T]` — the set of all total functions from `S` to `T`.
  `|T|^|S|` elements; see `TLA.Function.function_set/2`.
  """
  defdelegate function_set(domain, range), to: TLA.Function

  @doc "TLA+: `[field1: S1, field2: S2]` — the set of all such records."
  defdelegate record_set(field_specs), to: TLA.Function

  @doc "The values of a function, as a list."
  def values(map), do: Map.values(map)

  @doc "The keys of a function, as a list."
  def keys(map), do: Map.keys(map)

  @doc """
  TLA+: `DOMAIN f`, as a set.

  A sequence is a function on `1..Len(s)` — that is what `at/2` applies it as — so its
  domain is that range (#211).

      iex> TLA.Spec.Helpers.domain(%{a: 1, b: 2})
      MapSet.new([:a, :b])

      iex> TLA.Spec.Helpers.domain([:x, :y, :z])
      MapSet.new([1, 2, 3])
  """
  defdelegate domain(f), to: TLA.Function

  # ── Arithmetic ──

  @doc "The sum of an enumerable of numbers; 0 when empty."
  def sum(enum), do: Enum.sum(enum)

  @doc """
  The sum of `f` over an enumerable.

      iex> TLA.Spec.Helpers.sum([{:a, 1}, {:b, 2}], fn {_, n} -> n end)
      3
  """
  def sum(enum, f), do: enum |> Enum.map(f) |> Enum.sum()

  # ── Deterministic choice ──

  @doc """
  `CHOOSE x \\\\in S : P(x)` — deterministically select an element satisfying the
  predicate. Returns the same element for the same set and predicate; raises if
  none satisfies it.

  It does NOT branch. Nondeterminism comes from `params:` only
  (`02-dsl-semantics.md` §3) — an earlier draft gave this function branching
  semantics, which both contradicts the TLA+ operator it is named for and cannot
  be implemented: a function returning one element cannot produce several
  successors.

  Delegates to `TLA.Set.choose/2`, which fixes the choice as the least satisfying
  element in Erlang term order.

      iex> TLA.Spec.Helpers.choose(MapSet.new([3, 1, 2]), &(&1 > 1))
      2
  """
  defdelegate choose(set, predicate \\ fn _ -> true end), to: TLA.Set
end
