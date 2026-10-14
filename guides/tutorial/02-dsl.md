# The DSL in practice

ExTLA tutorial. Previous: [The mathematics of TLA](01-mathematics.md).

Here is the lock, for three clients this time. Each client is idle, waiting, or holding; the lock
is free or not; any waiting client may take a free lock.

<!-- tla:spec -->
```elixir
defmodule Tutorial.Lock do
  use ExTLA.Spec

  constant :clients, default: set([:alice, :bob, :carol])

  variable :free, type: [true, false]
  variable :pc,   type: [^clients ~> [:idle, :waiting, :holding]]

  init do
    free = true
    pc   = for_each(^clients, fn _ -> :idle end)
  end

  action :request, params: [c: ^clients] do
    require pc[c] == :idle
    pc = update(pc, c, fn _ -> :waiting end)
  end

  action :acquire, params: [c: ^clients] do
    require pc[c] == :waiting
    require free
    free = false
    pc   = update(pc, c, fn _ -> :holding end)
  end

  action :release, params: [c: ^clients] do
    require pc[c] == :holding
    free = true
    pc   = update(pc, c, fn _ -> :idle end)
  end

  invariant :mutual_exclusion do
    Enum.count(^clients, fn c -> pc[c] == :holding end) <= 1
  end

  invariant :holding_means_taken do
    Enum.all?(^clients, fn c -> pc[c] != :holding end) or free == false
  end
end
```

(The second invariant is there for [Invariants](03-invariants.md), which is about reading what
the checker says of it.)

## Three kinds of name

Inside a spec block, a name means one of three things, and the spelling tells you which
([§1](../../spec/02-dsl-semantics.md#1-the-three-name-classes)). A **pinned** name, `^clients`, is a
constant: fixed for a whole run, supplied by `default:` or by config. A **bare** name, `free` or
`pc`, is a state variable: on the right of `=` it is the value before the step, on the left it is
the value after. And `let x = …` binds a local, which is ordinary Elixir and means nothing to the
checker. The compiler holds you to this — a constant written without its pin is an error rather
than a variable that happens not to exist:

<!-- tla:compile_error match="referenced without `^`" -->
```elixir
defmodule Tutorial.Unpinned do
  use ExTLA.Spec

  constant :limit, default: 3
  variable :n, type: 0..3

  init do
    n = 0
  end

  action :tick do
    require n < limit
    n = n + 1
  end
end
```

The message names the rule and the section that states it.

## Types

`type:` is a small language of its own ([§1.5](../../spec/02-dsl-semantics.md#1-5-type-annotations)):
a list of literals is a choice among them, `a..b` is a range, `[^clients ~> t]` is a map whose keys
are exactly the clients and whose values have type `t` — a TLA+ function — and there are unions
(`^clients | :none`), tuples, records, `set(t)` and `seq(t)`. The type is not a restriction on
exploration; it is checked as an invariant, and [Invariants](03-invariants.md) says what that
means.

## Operations on sets and functions

`type: set(t)` says a variable **is** a set. This says what you can do with one.

All of TLA+'s set theory is in scope inside a spec block, unqualified, through
`ExTLA.Spec.Helpers`, the module every spec imports. The simple set operations — `set`, `put`,
`delete`, `member?`, `size`, `union`, `intersection`, `difference`, `subset?` — are one-line
wrappers over `MapSet`, there for readability. The rest are delegations to `ExTLA.Set` and
`ExTLA.Function`, and the helper module holds no second implementation of them, so a spec block
and code calling those modules directly get the same answers.

| TLA+ | In a spec block |
|---|---|
| `{}`, `{a, b, c}` | `set()`, `set([a, b, c])` |
| `e \in S` | `member?(s, e)` |
| `S \cup T`, `S \cap T`, `S \ T` | `union(s, t)`, `intersection(s, t)`, `difference(s, t)` |
| `S \cup {e}`, `S \ {e}` | `put(s, e)`, `delete(s, e)` |
| `S \subseteq T` | `subset?(s, t)` |
| `Cardinality(S)` | `size(s)` |
| `SUBSET S` | `powerset(s)` |
| `UNION S` | `distributed_union(s)` |
| `S \X T` | `cross(s, t)` |
| `S1 \X … \X Sn` | `cross_many([s1, s2, s3])` |
| `\A x \in S : P(x)` | `for_all?(s, fn x -> … end)` |
| `\E x \in S : P(x)` | `exists?(s, fn x -> … end)` |
| `{f(x) : x \in S}` | `set_map(s, fn x -> … end)` |
| `{x \in S : P(x)}` | `set_filter(s, fn x -> … end)` |
| `CHOOSE x \in S : P(x)` | `choose(s, fn x -> … end)` |
| `a..b` as a set | `range(a, b)` |
| `[x \in S \|-> e]` | `for_each(s, fn x -> … end)` |
| `[f EXCEPT ![k] = v]` | `update(f, k, fn _ -> v end)` |
| `[f EXCEPT ![a] = v, ![b] = w]` | `except(f, a: v, b: w)` |
| `DOMAIN f` | `domain(f)` |
| `[S -> T]` | `function_set(s, t)` |
| `[a: S, b: T]` | `record_set(a: s, b: t)` |

Four of the delegated names differ from the module they come from. `set_map/2` and
`set_filter/2` are `ExTLA.Set.map/2` and `ExTLA.Set.filter/2`, because an unqualified `map(xs, f)`
in a spec block reads as `Enum.map/2` to every Elixir programmer who opens the file, and these
return a **set** — possibly a smaller one, since a non-injective function collapses elements,
exactly as in TLA+. `for_each/2` is `ExTLA.Function.construct/2`, and `update/3` is
`ExTLA.Function.except_with/3`.

Here is a spec that uses them. A node acknowledges once; the value commits when some quorum has
acknowledged. The guard says *"there exists a subset of the nodes which is a majority and all of
whose members have acknowledged"* — `\E q \in SUBSET Nodes : Cardinality(q) * 2 > Cardinality(Nodes) /\ q \subseteq acked`,
one clause at a time:

<!-- tla:spec -->
```elixir
defmodule Tutorial.Quorum do
  use ExTLA.Spec

  constant :nodes, default: set([:n1, :n2, :n3])

  variable :acked,     type: set(^nodes)
  variable :votes,     type: [^nodes ~> 0..1]
  variable :committed, type: [true, false]

  init do
    acked     = set()
    votes     = for_each(^nodes, fn _ -> 0 end)
    committed = false
  end

  action :ack, params: [n: ^nodes] do
    require not member?(acked, n)

    acked = union(acked, set([n]))
    votes = update(votes, n, fn _ -> 1 end)
  end

  action :commit do
    require exists?(powerset(^nodes), fn q ->
              size(q) * 2 > size(^nodes) and subset?(q, acked)
            end)

    committed = true
  end

  invariant :committed_needs_quorum do
    not committed or size(acked) * 2 > size(^nodes)
  end

  invariant :votes_match_acks do
    for_all?(^nodes, fn n -> member?(acked, n) == (votes[n] == 1) end)
  end
end
```

<!-- tla:check module=Tutorial.Quorum expect=ok states=12 depth=5 output=abridged -->
```
Tutorial.Quorum — verified
  12 distinct states, 23 transitions, depth 5, 1ms
```

`committed_needs_quorum` states the same fact as `commit`'s guard the *other* way — by
cardinality rather than by quantifying over subsets. Writing a property twice in two forms and
letting the checker reconcile them is a good habit: if the two ever disagree, one of them is
what you meant.

### Two traps

**`for_each/2` takes a set, not a sequence.** `[x \in S |-> e]` ranges over a set, and a list is
a *sequence* — a function on `1..Len(s)` already. Building a function over one would silently
deduplicate it, so it is refused by name instead:

<!-- tla:run expect=raise match="builds a function over a set" -->
```elixir
ExTLA.Spec.Helpers.for_each([:alice, :alice, :bob], fn c -> c end)
```

**`domain/1` of a sequence is `1..Len(s)`, not its elements.** A sequence *is* a function on
its indices — that is how `s[i]` applies one — so `domain([:a, :b, :c])` is
`MapSet.new([1, 2, 3])`. A set is neither a function nor a sequence and is refused by name.

## Operations on sequences

`type: seq(t)` says a variable is a sequence: an Elixir list, read the TLA+ way, **1-indexed**.
These are thin wrappers over list operations, written as the TLA+ they translate:

| TLA+ | In a spec block |
|---|---|
| `<<>>`, `<<a, b, c>>` | `seq()`, `seq([a, b, c])` |
| `Append(s, e)` | `append(s, e)` |
| `Head(s)`, `Tail(s)` | `head(s)`, `tail(s)` |
| `Len(s)` | `len(s)` |
| `SubSeq(s, m, n)` | `subseq(s, m, n)` |
| `s[i]` | `s[i]`, or `at(s, i)` |

`head/1` and `tail/1` raise on the empty sequence, where TLA+ leaves them undefined, and `s[i]`
and `subseq/3` raise on an index outside `1..len(s)` rather than wrapping or returning `nil`
(`subseq(s, m, n)` with `n < m` is the empty sequence). The
same `s[i]` applies a function: `pc[c]` is `at(pc, c)`, and a key outside the domain raises too.

Three more help with arithmetic over a function: `values(f)` and `keys(f)` are its values and
keys as lists, and `sum(xs)` (or `sum(xs, fn x -> … end)`) adds them up — `sum(values(balances))`
is the total of a map of balances.

## Nondeterminism is `params:`, and only `params:`

`action :request, params: [c: ^clients]` is three actions, one per client, and the checker tries
every one in every state. That is where all the branching in a spec comes from. A `params:` entry
may draw from a constant, from a literal range or list, or from the state — `params: [c: fn s ->
s.some_set end]` — and a state function that returns nothing disables the action, exactly as a
false guard would ([§3](../../spec/02-dsl-semantics.md#3-nondeterminism-comes-from-params-and-only-from-params)).
The body, given its params, is deterministic.

## An action is a conjunction

The rule most likely to surprise an Elixir programmer
([§2](../../spec/02-dsl-semantics.md#2-an-action-block-is-a-conjunction-not-a-sequence)): the lines of
an action are not executed one after another. Every `require` is a guard on the state before the
step; every assignment is an equation about the state after it; every right-hand side reads the
pre-state, whatever order the lines are in; and a variable not assigned is unchanged. So a variable
cannot be assigned twice — that is two equations about one value, not a last write winning:

<!-- tla:compile_error match="assigned 2 times" -->
```elixir
defmodule Tutorial.Twice do
  use ExTLA.Spec

  variable :n, type: 0..3

  init do
    n = 0
  end

  action :tick do
    n = 1
    n = 2
  end
end
```

And every name on the left of `=` must be a declared variable — the compiler will not invent one:

<!-- tla:compile_error match="undeclared variable" -->
```elixir
defmodule Tutorial.Undeclared do
  use ExTLA.Spec

  variable :n, type: 0..3

  init do
    n = 0
  end

  action :tick do
    m = n + 1
  end
end
```

## The run

```sh
mix extla.check Tutorial.Lock
```

<!-- tla:check module=Tutorial.Lock expect=ok states=20 depth=5 -->
```
Tutorial.Lock — verified
  20 distinct states, 48 transitions, depth 5, 8ms

--- COVERAGE: Tutorial.Lock ----------------------------------------

Actions                   enabled in      states     distinct
  acquire                            7          12          12
  release                           12          12           0
  request                           16          24           7


Invariants                  evaluated   near-miss
  holding_means_taken               20          12
  mutual_exclusion                  20           -
  type_ok                           20           -
--------------------------------------------------------------------
```

Twenty states for three clients, and every one of them satisfies both invariants. The rest of
that report is the [next page](03-invariants.md).

---

Next: [Invariants](03-invariants.md).
