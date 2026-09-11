# Layer 2a: DSL Semantics (Normative)

The `TLA.Spec` DSL reinterprets Elixir syntax. This document is the **normative
definition** of that reinterpretation: exactly how a name in a spec block resolves,
what an action block means, and where nondeterminism comes from.

`04-layer2-model-checker.md` specifies the *checker*. This file specifies the
*language it checks*. Where the two disagree, this file wins.

Every rule here is enforced at compile time (§7). A spec that violates one does not
compile — it never reaches the checker.

---

## 1. The three name classes

Inside a spec block, a bare identifier is one of exactly three things. The class is
determined syntactically, never by inference:

| Syntax | Class | Resolves to |
|---|---|---|
| `^name` | **Constant** | The value bound to `constant :name` at model-check time |
| `name` | **Variable** | The value of `variable :name` in the relevant state |
| `let name = …` | **Local** | An ordinary Elixir binding, scoped to the block |

Anything else — a function call, an atom literal, a number — is ordinary Elixir and
is left untouched by the macro.

### 1.1 Constants use the pin operator

An earlier draft of this DSL wrote constants as bare atoms (`:accounts`), which made
`length(:accounts)` mean "the size of the accounts constant" while `status = :idle`
meant "the literal atom `:idle`". Those two readings of the same syntax cannot be
separated in general, so the DSL now marks constants with `^`:

```elixir
constant :accounts
constant :max_balance

require balances[from] >= amount               # `balances` is a variable
require MapSet.member?(^accounts, from)        # `^accounts` is a constant
let total = ^max_balance * MapSet.size(^accounts)
status = :idle                                 # `:idle` is a literal atom
```

The pin operator already means "the value from outside this scope" everywhere else in
Elixir, so it carries the right connotation, and `^` is unambiguous to the macro:
constants are the pinned names, atoms are always literals.

Referencing an undeclared constant is a compile error (§7).

### 1.2 Variables are bare, and their meaning depends on the block

A bare identifier matching a declared `variable` resolves against a state. *Which*
state depends on the block:

| Block | Bare variable reads | Assignment `name = expr` |
|---|---|---|
| `init` | — (nothing to read) | Defines the initial value |
| `action` | The **pre-state** | Defines the **post-state** (§2) |
| `invariant` | The state being checked | Not permitted |
| `temporal` | The state at each point in the behavior | Not permitted |
| `terminal` | The state being classified (§5.3) | Not permitted |
| `action_property` | **Not permitted** — use `old.` / `new.` (§4) | Not permitted |

### 1.3 Locals use `let`

Because `=` on a declared variable name means "assign the post-state" (§2), an
intermediate value needs its own form:

```elixir
action :complete_transfer, params: [t: fn s -> s.pending end] do
  require status == :transferring

  let {to, amount} = t                        # a local binding
  balances = update(balances, to, &(&1 + amount))   # a post-state assignment
  pending  = delete(pending, t)
end
```

`let` accepts any Elixir pattern. Locals may shadow nothing: `let` binding a name that
is a declared variable or constant is a compile error. The rule is about what a bare name
*means*, not about `let`, so it applies to every binder a spec block has — the `fn x ->`
of a temporal quantifier (§5.1) included. Without it the quantifier body's `x` resolved to
the state variable of that name in every instance, and the bound value was never read.

### 1.4 Reserved names

`state`, `old` and `new` are implicitly bound in some blocks (§4, and Layer 1's blocks
in `03-layer1-invariants.md`). Declaring a `variable` or `constant` with one of those names
is a compile error rather than a subtle capture — the Raft example renames Raft's
`state` to `srv_state` for exactly this reason.

### 1.5 Type annotations

`variable :name, type: t` takes a type expression — a small language of its own,
distinct from the block DSL. It is **stored quoted** and resolved at model-check time
against the constant assignments, because nearly every useful type mentions a
constant (`0..^max_val`, `[^servers ~> :set]`) that has no value when the module
compiles.

| Form | Meaning |
|---|---|
| `:atom`, `0`, `"s"` | Exactly that literal |
| `[:a, :b]` | One of the listed literals |
| `a..b` | An integer in the range; either bound may be `^const` |
| `^name` | Any element of the constant (which must be a set) |
| `t1 \| t2` | Union — a value of either type |
| `{t1, t2, …}` | A tuple of that arity, element-wise |
| `[dom ~> rng]` | A map (TLA+ function) whose keys are exactly `dom` and whose values are in `rng` |
| `%{k: t, …}` | A record: a map with exactly these keys, each value of its type — TLA+'s `[k : T, …]` |
| `:set`, `:seq` | Any `MapSet` / any list; element types unconstrained |
| `set(t)`, `seq(t)` | A `MapSet` / list whose every element is of type `t` — TLA+'s `SUBSET T` and `Seq(T)` |
| `:int`, `:nat` | Any integer / any non-negative integer — TLA+'s `Int` and `Nat` |

A range bound may be an integer, a `^constant`, or arithmetic over them
(`0..(^max_items - 1)`), and it may be negative: Paxos's `maxBal` is `-1` until the
acceptor promises something.

Two operators are overloaded and a reader should know it: inside `type:`, `~>` is the
function arrow and `|` is union; inside a `temporal` block `~>` is leads-to. The two
never occur in the same position, so the macro is never in doubt.

`:set`, `:seq`, `:int` and `:nat` likewise shadow the literal atoms of the same names
at the top level of a type. Inside a list there is nothing to be ambiguous with, so
`[:set]` means the literal atom `:set`.

`set(t)` and `seq(t)` are call forms rather than `{:set, t}` because the tuple form
collides: `{:set, :nat}` is already a legal tuple type of the literal atom `:set` and a
natural. They arrived when the differential corpus found four entries typing a variable
*weaker* than the TLA+ they are checked against — `msgs`, `messages`, `votes_granted`
and `buffer` were all `:set` or `:seq` where TLC checked `msgs \subseteq Message`. An
entry that checks less than its oracle can agree with it for the wrong reason. The
record form arrived with them, because a set of records is what a message set is, and
`set(t)` had nothing useful to say without it.

`:int` and `:nat` were added after the implicit `type_ok` invariant refuted §8's own
worked example: `balances` was typed `[^accounts ~> 0..^max_balance]`, but every account
starts at `^max_balance` and a transfer pushes the recipient above it. The grammar had
no way to say "an integer", so the only expressible types for that variable were all
false. A type language in which the documented example cannot be typed correctly is a
gap in the language, not a mistake in the example.

Types are checked as an implicit invariant named `:type_ok` in every reachable state
— which is why the coverage report lists one without the spec declaring it — and
they are the domain `TLA.Simulation.Generator` draws from. They do not restrict
exploration: a state outside its type is a reported violation, not a pruned branch.

### 1.6 `f[x]` is function application, and it is strict

Inside a spec block, `f[x]` means TLA+ function application, **not** `Access.get/2`.
It compiles to `TLA.Spec.Helpers.at/3`, which raises `TLA.Spec.DomainError` when `x`
is outside the domain of `f`:

| `f` | `f[x]` | Outside the domain |
|---|---|---|
| A map | The value at `x` | Raises |
| A list (a TLA+ sequence, **1-indexed**) | The `x`th element | Raises |
| Anything else | — | Raises |

Ordinary Elixir returns `nil` there, and `nil` is not an error: Erlang's term order
makes every comparison total, and an atom sorts above every integer, so
`balances[:carol] >= amount` is **`true`** for an account that does not exist. The
guard succeeds, the action fires from a state it was never enabled in, and the checker
explores a state space the spec does not describe — reporting success over it. That is
the same failure `01-foundation.md` rules out for reading a variable that is not there,
and it is ruled out here for the same reason (D-20).

The rule has no exceptions inside a block. It holds for a variable (`pc[p]`), a local
(`let q = …; q[k]`), an `action_property`'s `old.`/`new.` (`old.owner[r]`), and a
`params:` generator's own state argument (`st.current_term[s]`). A rule with exceptions
is one an author has to remember the shape of, and the exceptions would be exactly the
places a spec reaches into a collection it did not build.

One consequence worth stating: a keyword list indexed by its key — `opts[:mode]` — is a
list applied to a non-integer, so it raises. Inside a spec block that is the right
answer; state is maps and sequences, and a keyword list in a spec is either a mistake or
a map written the wrong way.

---

## 2. An action block is a conjunction, not a sequence

This is the rule most likely to surprise an Elixir programmer, and it is the one that
makes the DSL mean what TLA+ means.

An `action` body is a **simultaneous assignment** — the conjunction of a guard and a
set of next-state equations — not a sequence of statements. Concretely:

1. **Every right-hand side reads the pre-state.** Assignment order is irrelevant.
2. **Every left-hand side writes the post-state.** Nothing is visible to another
   right-hand side in the same block.
3. **A variable not assigned is implicitly `UNCHANGED`.**
4. **A variable may be assigned at most once.** Two assignments to one variable is a
   compile error, not a last-write-wins.

So this action:

```elixir
action :swap do
  x = y
  y = x
end
```

swaps `x` and `y`. It does not set both to the old `y`. And this:

```elixir
action :broken do
  x = 1
  x = 2         # compile error: `x` assigned twice in action :broken
end
```

does not compile.

`let` bindings *are* sequential — they are ordinary Elixir — and a `let` may read
earlier `let`s. Only state-variable assignment is simultaneous.

### 2.1 Guards

`require expr` is an enabling condition. All `require`s in a block are conjoined, and
they are evaluated against the **pre-state** with the action's params bound. An action
whose guard is false in a state is *not enabled* there and contributes no successor.

`require` may appear anywhere in the block, and it **is** positional with respect to
`let`: guards and bindings are evaluated in source order, so a `require` protects the
`let`s that follow it and not the ones above it. Assignments are separate — they build
the post-state and are evaluated only once the whole guard holds, so no `require` can be
ordered after an assignment in any way that matters.

The order is load-bearing rather than incidental, and §1.6 is why. Function application
is strict, so `f[x]` outside `f`'s domain raises `TLA.Spec.DomainError` rather than
returning `nil`. That makes this legal and necessary:

```elixir
action :consume do
  require Map.has_key?(inbox, ^client)
  let msg = inbox[^client]
  require msg.seq == expected
  ...
end
```

The first `require` is what stops `inbox[^client]` raising, and it only stops it because
the conjunction short-circuits over the binding. Hoisting the guards would evaluate the
`let` first and raise on exactly the states the guard exists to exclude. So the choice is
between a guard that can protect a binding and one that cannot, and the DSL takes the
first (`TLA.Spec.Block.guard_body/2`).

A `require` placed *after* the `let` it should have guarded is therefore a real error and
not a style question: the action raises where it should have been disabled.

One qualification, because it decides when the mistake is visible. The guard is built from
the statements up to and including the **last** `require`, and `let`s that no guard reads
are pruned out of it. So a badly-ordered `let` that only the *assignments* use never
evaluates during the guard at all, and the misplacement costs nothing. It bites when the
binding is consumed by a later `require` — which is exactly when the guard needed
protecting.

---

## 3. Nondeterminism comes from `params:`, and only from `params:`

An earlier draft had two nondeterminism mechanisms: `params:` for constant-drawn
values, and `choose/1,2` inside the block for state-drawn values. That second one was
both redundant and misnamed — `CHOOSE` in TLA+ is *deterministic* Hilbert choice, so a
`choose` that forks the search contradicts the notation ExTLA is modeled on. Worse, it
cannot work: a plain function returning one element cannot produce several successors.

There is now **one** mechanism. A `params:` entry may draw from:

| Form | Meaning | Example |
|---|---|---|
| A constant | Each element of the constant set | `from: ^accounts` |
| A literal range or list | Each element | `amount: 1..10`, `mode: [:a, :b]` |
| A **state function** | Each element of the set the function returns for the pre-state | `t: fn s -> s.pending end` |

**Params bind left to right**, and a state function may take a second argument
receiving the params bound before it. This keeps the combinatorial explosion down where
one param constrains another — filter in the generator rather than generating every
combination and rejecting most of them in the guard:

```elixir
# Generates |servers| x |messages| combinations, most rejected by the guard
params: [s: ^servers, msg: fn st -> st.messages end]

# Generates only the messages actually addressed to `s`
params: [s: ^servers, msg: fn st, %{s: s} -> Enum.filter(st.messages, &(&1.to == s)) end]
```

Both are correct; the second is the one to write.

The state-function form is what replaces `choose`. It is evaluated on the pre-state
before the guard, and the checker generates one successor per element of the returned
enumerable — the direct encoding of TLA+'s `\E t \in pending : …`:

```elixir
# Before (did not work — `choose` cannot fork)
action :complete_transfer do
  require status == :transferring
  {to, amount} = choose(pending)
  …
end

# After — the branching is in `params:`, the body is deterministic
action :complete_transfer, params: [t: fn s -> s.pending end] do
  require status == :transferring
  let {to, amount} = t
  …
end
```

The payoff is that **an action body is now a pure deterministic function of
`(pre_state, params)`**. That single property is what makes successor generation,
enabling checks, symmetry canonicalization (`04-layer2-model-checker.md` §Symmetry) and
Layer 3's refinement check (`05-layer3-conformance.md` §1) all straightforward. Any
construct that reintroduces in-body branching must be rejected for the same reason.

A state function returning an empty enumerable disables the action in that state,
exactly as a false guard would.

### 3.1 `choose/2` keeps its TLA+ meaning

`TLA.Spec.Helpers.choose/2` and `TLA.Set.choose/2` are **deterministic**: they return
the same element for the same set and predicate, and raise if none satisfies it. That
is TLA+'s `CHOOSE`. They do not branch, and they are not a nondeterminism mechanism.

---

## 4. `action_property` uses `old` and `new`

An action property constrains a transition, so bare variable names would be ambiguous.
The block binds two maps and requires explicit qualification:

```elixir
action_property :money_is_conserved do
  sum(values(old.balances)) + pending_total(old) ==
    sum(values(new.balances)) + pending_total(new)
end
```

A bare declared-variable name inside `action_property` is a compile error with a
message naming `old.`/`new.`. Constants are still written `^name` and mean the same
thing in both states.

This replaces the earlier `fn old, new -> … end` form. `invariant` and
`action_property` now have **one** shape between Layer 1 and Layer 2 — a bare boolean
expression — rather than the two shapes the earlier drafts had (`fn state -> … end` in
Layer 1, a bare expression in Layer 2).

---

## 5. `invariant` and `temporal`

Both take a bare boolean expression over variables and `^constants`.

```elixir
invariant :no_negative_balance do
  Enum.all?(values(balances), &(&1 >= 0))
end

temporal :eventually_done do
  eventually(always(status == :done))
end
```

Inside `temporal`, the operators `always/1`, `eventually/1` and `~>/2` (leads-to) are
available and compose. Everything else in the block is an ordinary state predicate.

**A predicate is `true` or `false`, and nothing else is accepted.** Elixir's `and`/`or`
return their last operand, so `n >= 0 and status` evaluates to `status`; a checker that
tested the result for truthiness would count that as holding whenever `status` was
anything but `nil` or `false`. Every predicate — `invariant`, `terminal`,
`action_property`, and each state predicate inside a `temporal` — is compiled with a
result check, and a non-boolean raises `TLA.Spec.PredicateError` naming the declaration
and the value. It raises rather than reporting a violation because a predicate that
returned `:idle` was not violated; it was broken, and a "violation" would send the
author looking for the wrong bug. The check is on the compiled function, so every
consumer — the checker, trace replay, coverage, the ledger — gets the same refusal.

### 5.1 The supported temporal fragment is bounded — say so

ExTLA does **not** implement full LTL. The supported fragment is:

```
formula  ::= always(formula) | eventually(formula) | pred ~> pred | pred
           | Enum.all?(^constant, fn x -> formula end)
pred     ::= any boolean expression over variables and constants
```

There is no negation, conjunction or disjunction *of formulas* (a `pred` may of course
contain `not`/`and`/`or`). The one exception is the quantifier on the second line:
`Enum.all?` over a **constant** with a formula body is `\A x \in C : F(x)`, a
conjunction of instantiated formulas that the checker checks one at a time — each
instance is itself in the fragment, so nothing new is needed to check it. Every
per-process property in `07-examples.md` is written this way. The set must be a
constant or a literal; a state-dependent set would make the formula's shape depend on
the state.

This is deliberate: the fragment above covers the properties people actually write,
and it is checkable by SCC analysis without constructing a Büchi automaton. A formula
outside the fragment is a compile error naming the unsupported operator — never a
silently weaker check.

`P ~> Q` already means `always(P implies eventually(Q))`, so `always(P ~> Q)` is
accepted and means the same thing as `P ~> Q`; the compiler collapses it rather than
rejecting a form TLA+ users write out of habit.

If the fragment is ever widened, it is widened here first, in this section, and the
checker follows.

### 5.2 Fairness is declared per action, or per parameter binding

`fairness :weak, [:done]` attaches WF to the whole action: if *some* binding of
`done` is continuously enabled, *some* binding is eventually taken. That is
`WF_vars(Done)` and it is too weak for any per-process property — it is consistent
with one process requesting forever while the others take turns. TLA+ writes
`\A p \in Procs : WF_vars(Acquire(p))`, and so does ExTLA:

```elixir
fairness :strong, acquire_lock: [:p]                   # SF for each value of p, separately
fairness :weak, release_lock: [:p], return_to_idle: [:p]
fairness :weak, [:done, :reset]                        # whole-action form, unchanged
```

The named params must be a **prefix** of the action's params and must draw from a
constant or a literal (§3) — a state-drawn param cannot be quantified over, because
the set it ranges over changes from state to state. Both are compile errors (§7).
The checker expands `acquire_lock: [:p]` into `|^processes|` separate constraints
once the constants are known, each with its own `ENABLED` computed over the
remaining params (`01-foundation.md` §`TLA.Temporal.enabled?/4`).

Without this form, `no_starvation` in `07-examples.md` Example 1 is unprovable.

### 5.3 Terminal states are declared, not inferred

A reachable state with no enabled action is a **deadlock**, and the checker reports
it as a violation by default. Some specs terminate on purpose — a bounded producer
that has produced `^max_items`, an election whose term bound is exhausted. Those
states are declared:

```elixir
terminal :all_items_consumed do
  produced_count == ^max_items and len(buffer) == 0
end
```

A successor-less state that satisfies a `terminal` predicate is not a deadlock.
Nothing else changes: invariants are still checked there, no action is disabled by
it, and for liveness it is a state that stutters forever — so a leads-to whose
consequent has not held by then is violated there, which is the correct verdict. A
`terminal` that admits a state which still has an enabled action is reported by
coverage as `terminal_but_live`; it is not an error, but it almost always means the
predicate is broader than the end state it was written for.

`check_deadlock: false` remains available as the blunt instrument. Prefer the
declaration: it says *which* states are meant to be final, and keeps deadlock
detection on for all the others.

---

## 6. Terms permitted in state

A spec variable's value MUST be deterministically serializable, because state identity
is a hash of that value (`01-foundation.md` §`TLA.Fingerprint`). Permitted: atoms,
integers, binaries, tuples, lists, maps, `MapSet`s, and structs built from those.

**Forbidden in spec state:** pids, references, ports, funs, floats, and bitstrings that
are not a whole number of bytes. The first four have no stable identity across runs;
floats introduce `-0.0`/`NaN` comparison hazards that make two "equal" states hash
differently; a bitstring such as `<<1::3>>` has no JSON form (`TLA.State.Json` carries
bytes), so admitting it would let a violation the search found be lost when the report
is written. A binary need not be valid UTF-8 — `<<255, 0>>` is a permitted term, and the
wire format carries it as base64 under its own tag. Assigning a forbidden term is a
runtime error from the checker naming the variable, not a silent mis-fingerprint.

**When the check runs:** once per distinct state, as the state enters the state graph,
and before anything else in the checker looks at it. Not once per transition into it —
a state reached five ways is checked once. The guarantee is unaffected, and for a reason
worth stating: a forbidden term is exactly a term whose encoding does not recur, so a
state carrying one can never be mistaken for a state already seen, and is always checked
on the path that reaches it first (D-26).

---

## 7. Compile-time validation

Every rule above is checked when the spec module compiles, because the DSL already
accumulates every declaration it needs. A spec either means something precise or does
not compile.

| Diagnostic | Trigger |
|---|---|
| `undeclared variable` | `=` assigns, or an expression reads, a name that is not a `variable` |
| `undeclared constant` | `^name` where no `constant :name` exists |
| `variable assigned twice` | Two assignments to one variable in one action (§2) |
| `assignment in invariant/temporal` | `=` on a declared variable anywhere outside `init`/`action` — nested under `always`, `and`, a call, or at the top level; the walk is the whole expression, since §1.2 leaves no legitimate nested case |
| `bare variable in action_property` | §4 |
| `let shadows a declared name` | §1.3 — and the same diagnostic for a temporal quantifier (`Enum.all?(^c, fn x -> …)`) whose `x` is a declared variable or constant |
| `unknown action in fairness` | `fairness :weak, [:typo]` |
| `fairness over a state-drawn param` | `fairness :weak, complete_transfer: [:t]` where `t` draws from a state function (§5.2) |
| `fairness params not a prefix` | The per-binding params are not a leading prefix of the action's params (§5.2) |
| `ill-formed type` | A `type:` expression outside the §1.5 grammar |
| `unsupported temporal operator` | A formula outside the §5.1 fragment |
| `param draws from a non-set` | A `params:` entry that is not a constant, range, list, or 1- or 2-arity function |
| `reserved name` | A `variable`/`constant` named `state`, `old` or `new` (§1.4) |
| `forbidden state term` | A pid, reference, port, fun or float assigned to a variable (§6) |
| `already declared` | Two `variable`/`constant` declarations of one name, or two `action`/`invariant`/`terminal`/`temporal`/`action_property` declarations of one name — a second cannot shadow the first, and a name that identifies two things is a name a trace cannot report |
| `init does not assign` | An `init` block that leaves a declared variable out. The partial state would surface much later, as a `KeyError` from whichever action first read it |
| `no init block` | A spec with variables and no `init`. Its state space is empty, and checking it would report success over a search of nothing |
| `require in init` | An `init` block is unconditional; several possible starting states are several `init` blocks |
| `unexpected statement` | A statement in an `init`/`action` body that is not `require`, `let`, or an assignment (§2) |
| `param shadows a variable` | A `params:` entry named after a declared variable, which would make a bare use of that name inside the block ambiguous |
| `constant referenced without ^` | A bare name matching a declared constant — the likeliest typo in the DSL, so it gets its own message rather than falling through to `undeclared variable` (§1.1) |
| `temporal block is not a single formula` | A `temporal` block with more than one statement. Unlike `invariant`, there is no single state in which to compute an intermediate value: the formula is evaluated over a behavior |

Diagnostics carry the spec module, the declaration name, and the offending line. The
quality of these messages is most of the difference between a DSL people adopt and one
they bounce off; they are a deliverable, not a nicety.

---

## 8. Worked example

The transfer protocol from `04-layer2-model-checker.md`, in the settled syntax:

```elixir
defmodule Specs.TransferProtocol do
  use TLA.Spec

  constant :accounts
  constant :max_balance

  variable :balances, type: [^accounts ~> :nat]
  variable :status,   type: [:idle, :transferring, :done, :error]
  variable :pending,  type: :set
  variable :log,      type: :seq

  init do
    balances = for_each(^accounts, fn _ -> ^max_balance end)
    status   = :idle
    pending  = set()
    log      = seq()
  end

  action :begin_transfer,
    params: [from: ^accounts, to: ^accounts, amount: 1..^max_balance] do
    require from != to
    require status == :idle
    require balances[from] >= amount

    balances = update(balances, from, &(&1 - amount))
    pending  = put(pending, {to, amount})
    status   = :transferring
  end

  # `params:` draws from the pre-state — this is `\E t \in pending`
  action :complete_transfer, params: [t: fn s -> s.pending end] do
    require status == :transferring

    let {to, amount} = t
    balances = update(balances, to, &(&1 + amount))
    pending  = delete(pending, t)
    status   = if size(delete(pending, t)) == 0, do: :done, else: :transferring
    log      = append(log, %{to: to, amount: amount})
  end

  action :fail_transfer do
    require status == :transferring
    status  = :error
    pending = set()
  end

  action :reset do
    require status in [:done, :error]
    status = :idle
  end

  invariant :conservation_of_money do
    let total = sum(values(balances)) + sum(pending, fn {_to, amt} -> amt end)
    total == ^max_balance * MapSet.size(^accounts)
  end

  action_property :no_phantom_credit do
    Enum.all?(^accounts, fn a ->
      new.balances[a] <= old.balances[a] or
        Enum.any?(old.pending, fn {to, _} -> to == a end)
    end)
  end

  temporal :no_stuck_pending do
    (status == :transferring) ~> (status in [:done, :error])
  end

  fairness :weak, [:complete_transfer, :reset]
  fairness :strong, [:fail_transfer]
end
```

Note that `conservation_of_money` now *fails* — `fail_transfer` discards `pending`
without refunding it. That is the intended counterexample in
`04-layer2-model-checker.md`'s trace example, and it is reachable in this spec.

Note also that this spec's state space is **infinite**: `complete_transfer` appends to
`log` and `reset` returns to `:idle`, so the log grows without bound. Checking it
exhaustively is impossible, and checking it at all needs a `state_constraint` bounding
`len(log)` (`04-layer2-model-checker.md` §State constraints) — for which the result
reports `:constrained` rather than `:ok`. A worked example that cannot be run as
written would be a poor advertisement for the tool, so it is said here rather than
discovered.
