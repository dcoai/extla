# Invariants

ExTLA tutorial. Previous: [The DSL in practice](02-dsl.md).

An `invariant` is a boolean over the variables that must hold in every reachable state. The
checker evaluates each one in each state it discovers, and stops at the first state where one is
false — that is the counterexample [Getting started](../getting-started.md) ends with.

This page is about the rest of it: how to decide what to assert, how to read the report when every
invariant *holds* (which is where a spec that verifies for the wrong reason gives itself away),
how to state a property of a **step** rather than a state, and the failure you are most likely to
meet first — a specification that finishes its work and is refuted for it.

## Choosing what to assert

A specification with no invariants verifies instantly and proves nothing. The question is what to
write, and there is a usable order.

**Start with the types, which you have already written.** Every `variable`'s `type:` is checked in
every state as an invariant named `type_ok`, so the shape of your state is asserted before you
write a line. That is not a formality: a spec whose action drives a variable out of range is
refuted by it, and it is the invariant that most often catches a spec that is simply wrong about
its own state.

**Then ask what the system promises its callers**, and write each promise as a predicate that must
never be false. Not "the code does X" — a specification is not a paraphrase of an implementation
— but the things you would be embarrassed to be wrong about. For a lock: at most one holder. For a
queue: nothing is delivered twice, nothing is lost. For an allocator: no two clients hold the same
resource. These are usually few, short, and about *relationships between variables* rather than
about any one of them.

**Say what an invariant is for when the name will not carry it.** `desc:` is not decoration — it
is printed with the violation:

<!-- tla:skip reason=an invariant declaration on its own, not a compilable module -->
```elixir
invariant :mutual_exclusion,
  desc: "at most one client holds the lock — THE property this design exists to keep" do
  Enum.count(^clients, fn c -> pc[c] == :holding end) <= 1
end
```

**Then use the coverage report to check your own work**, which the next two sections are about.
The report is the only place that will tell you an invariant you were proud of was never once at
risk.

## `type_ok` is an invariant you did not write

The `type:` on each variable is checked as an invariant named `type_ok`, in every state, which is
why the table lists one the spec never declared. A state outside its type is reported as a
violation of it. The type is not used to prune the search: a spec whose action drives a variable
out of range does not get a smaller state space, it gets a counterexample.

## The near-miss column

`holding_means_taken` reads *nobody is holding, or the lock is not free* — an implication, in the
`p or q` shape. Such an invariant can hold two ways: trivially, because `p` was true and `q` did not
matter, or because `p` was false and `q` carried it. The second is a **near miss**: a state in which
the invariant was actually pressed against. Of twenty states, twelve had a holder, and in each of
them `free == false` is what kept the invariant true.

`mutual_exclusion` shows `-`: it has no top-level `or`, so there is no non-trivial branch to
count, and the column says *not measured* rather than pretending. An invariant that IS measured
and reports `0` is flagged `<-- never at risk`: it held in every state without ever being pressed,
which is indistinguishable from `true`, and is the first thing to be suspicious of when a spec
verifies too easily.

## An action that was never enabled

The other way a spec verifies for the wrong reason. Add a `cancel` action to the lock — a waiting
client may give up — and make the mistake that is easiest to make:

<!-- tla:spec -->
```elixir
defmodule Tutorial.CancelLock do
  use TLA.Spec

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

  action :cancel, params: [c: ^clients] do
    require pc[c] == :wating
    pc = update(pc, c, fn _ -> :idle end)
  end

  invariant :mutual_exclusion do
    Enum.count(^clients, fn c -> pc[c] == :holding end) <= 1
  end

  invariant :holding_means_taken do
    Enum.all?(^clients, fn c -> pc[c] != :holding end) or free == false
  end
end
```

```sh
mix tla.check Tutorial.CancelLock
```

<!-- tla:check module=Tutorial.CancelLock expect=ok states=20 never_enabled=cancel -->
```
Tutorial.CancelLock — verified
  20 distinct states, 48 transitions, depth 5, 1ms

--- COVERAGE: Tutorial.CancelLock ----------------------------------

Actions                   enabled in      states     distinct
  acquire                            7          12          12
  cancel                             0           0           0   <-- NEVER ENABLED
  release                           12          12           0
  request                            16          24           7


Invariants                  evaluated   near-miss
  holding_means_taken               20          12
  mutual_exclusion                  20           -
  type_ok                           20           -

1 warning. Re-run with --strict-coverage to fail on these.
--------------------------------------------------------------------
warning: action :cancel was never enabled
```

`:wating` is not `:waiting`, and `pc[c]` is never equal to it, so `cancel` is never enabled — and
the spec **verifies**, with the same twenty states as before. Every invariant holds in a system that
has no cancellation in it. Nothing about the verdict is wrong; what is wrong is what it is a
verdict about. The coverage table is the only place that shows, and `--strict-coverage` is how you
make it exit 3 rather than print a warning.

## `action_property` — a property of a *step*

An invariant is a claim about each state on its own. Some properties are not of that kind: *money
is never created*, *the audit log only ever grows*, *the lock is never stolen from its holder*. Each
compares a state with the one before it, and no predicate over a single state can express any of
them — every state involved is perfectly legal, and it is the *transition* between two of them that
is wrong.

`action_property` is that claim. `old` and `new` are bound to the pre- and post-state, and the
property is evaluated on every step the checker takes:

<!-- tla:spec -->
```elixir
defmodule Tutorial.AuditedLock do
  use TLA.Spec

  constant :clients, default: set([:alice, :bob])

  variable :holder, type: ^clients | :none
  variable :log,    type: seq(^clients)

  init do
    holder = :none
    log    = seq()
  end

  action :acquire, params: [c: ^clients] do
    require holder == :none
    holder = c
    log    = append(log, c)
  end

  action :release do
    require holder != :none
    holder = :none
  end

  # Housekeeping, and the bug: it throws away everything but the first entry.
  action :compact do
    require len(log) > 1
    log = seq([head(log)])
  end

  invariant :holder_is_logged do
    holder == :none or len(log) > 0
  end

  action_property :log_only_grows do
    len(new.log) >= len(old.log)
  end
end
```

Note what an invariant could *not* have caught. Every state this spec reaches is fine: a holder or
none, a log of some length, and `holder_is_logged` holds throughout. There is no bad state to find
— only a bad step, from a log of two entries to a log of one.

<!-- tla:check module=Tutorial.AuditedLock expect=violation property=log_only_grows length=5 -->
```
Tutorial.AuditedLock — VIOLATION: log_only_grows
  10 distinct states, 10 transitions, depth 5, 7ms

═══ VIOLATION: log_only_grows ══════════════════════════════════════

State 1 (Init):
  holder = :none
  log    = []

── acquire(c: :alice) ────────────────────

State 2:
  holder = :alice   ← changed
  log    = [:alice]   ← changed

── release ────────────────────

State 3:
  holder = :none   ← changed
  log    = [:alice]

── acquire(c: :alice) ────────────────────

State 4:
  holder = :alice   ← changed
  log    = [:alice, :alice]   ← changed

── compact ────────────────────

State 5 [VIOLATION]:
  holder = :alice
  log    = [:alice]   ← changed

════════════════════════════════════════════════════════════════════
```

Read the last step, because that is where the whole finding is: the log holds two entries, and
`compact` replaces it with one. `len(new.log) >= len(old.log)` is `1 >= 2`, and false.

Every state in that trace is legal. State 4 is a perfectly good state — a client holding the lock,
two entries logged — and so is State 5. **The counterexample is the arrow between them**, which is
why the trace for an action property is read differently from the trace for an invariant: for an
invariant you look at where it ended, and for an action property you look at the last thing that
happened.

Delete the `compact` action and the spec verifies.

`02-dsl-semantics.md` [§4](../../spec/02-dsl-semantics.md#4-action_property-uses-old-and-new) is
normative on `old` and `new` — in particular that a bare variable name inside an
`action_property` is a compile error, because there it would be ambiguous which of the two you
meant.

## When the trace is too big to read

That trace was five states of two variables and you read it by eye. Real ones are not like
that. A Raft election counterexample is nineteen states of five variables, several of them
maps over three servers, and the question you actually have — *when did the quorum first
form*, *how many acceptors had promised by state 12* — is a **function of the state**.
Answering it from the dumps means reading nineteen blocks and doing arithmetic by hand.

So ask the function instead. `TLA.Trace.explore/3` takes your own expressions, one row each,
and evaluates them at every state:

<!-- tla:run expect=ok -->
```elixir
result = TLA.ModelChecker.run(Tutorial.AuditedLock, %{constants: %{clients: MapSet.new([:alice, :bob])}})
trace = result.violation

TLA.Trace.explore(trace,
  holder: & &1.holder,
  logged: &length(&1.log),
  held?: &(&1.holder != :none)
)
```

```
═══ EXPLORE: log_only_grows ════════════════════════════════════════

              1        2        3        4        5
           init  acquire  release  acquire  compact
  ─────────────────────────────────────────────────
  holder  :none   :alice    :none   :alice   :alice
  logged      0        1        1        2        1
  held?   false     true    false     true     true

  Bindings:
    2  acquire(c: :alice)
    4  acquire(c: :alice)
════════════════════════════════════════════════════════════════════
```

`logged` going `2 → 1` at the last step is the whole finding, on one line.

TLA+ has the same tool — the Toolbox's **Trace Explorer** — and there it needs a generated
specification, a second TLC run and a GUI panel, because a TLA+ state is not a value your
program can hold. Here a state is a plain map and an expression over one is an anonymous
function, so the whole apparatus is `Enum.map/2`.

Three things worth knowing:

- **`changed_only: true`** hides the rows that never move. On a wide trace most rows never
  move, and the one that does is the one you are looking for.
- **A lasso works too.** The repeating states are marked `↺`, so a liveness counterexample
  does not read as though it ended.
- **An expression that raises is reported at the state it raised in**, and the rest of the
  table still renders. You are exploring this trace *because* something in it is wrong, so an
  expression that assumes an invariant this trace violates is the normal case, not an error.

### Without re-running the checker

A counterexample from a CI run or an incident months ago can be explored from the file:

```
mix tla.check Tutorial.AuditedLock --format json > ce.json

mix tla.explore Tutorial.AuditedLock --trace ce.json \
  --expr "logged: length(log)" \
  --expr "held?: holder != :none"
```

`--expr` is repeatable, and inside one the state is in scope as each variable by its own name
and as `state`, the whole map. It compiles and evaluates what you typed, which is what the
Toolbox does with the expressions typed into its panel — there is no way to put an anonymous
function on a command line.

Nothing is searched: the states are read off disk. The module argument is there because the
trace's atoms are resolved against the ones the system already has, so the spec must be
loaded before its counterexample can be decoded.

## Deadlock, and the `terminal` you will need

This is the first thing that will go wrong for you, so it is worth meeting deliberately.

**A reachable state with no enabled action is a deadlock, and the checker reports it as a
violation.** That is the right default — for a lock, a queue, a protocol, a state nothing can leave
is a bug. But it means that **any specification which finishes its work is refuted**, because
finishing looks exactly like being stuck.

Here is the same lock, made one-shot: each client may take it once and is then `:done`.

<!-- tla:spec -->
```elixir
defmodule Tutorial.OneShotLock do
  use TLA.Spec

  constant :clients, default: set([:alice, :bob])

  variable :free, type: [true, false]
  variable :pc,   type: [^clients ~> [:idle, :waiting, :holding, :done]]

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

  action :finish, params: [c: ^clients] do
    require pc[c] == :holding
    free = true
    pc   = update(pc, c, fn _ -> :done end)
  end

  invariant :mutual_exclusion do
    Enum.count(^clients, fn c -> pc[c] == :holding end) <= 1
  end
end
```

Nothing about it is wrong. Every client gets the lock, uses it, and is done. And:

```sh
mix tla.check Tutorial.OneShotLock
```

<!-- tla:check module=Tutorial.OneShotLock expect=deadlock states=15 depth=7 -->
```
Tutorial.OneShotLock — DEADLOCK
  15 distinct states, 20 transitions, depth 7, 10ms

═══ DEADLOCK ═══════════════════════════════════════════════════════

State 1 (Init):
  free = true
  pc   = %{alice: :idle, bob: :idle}

── request(c: :alice) ────────────────────
…
── finish(c: :bob) ────────────────────

State 7 [VIOLATION]:
  free = true
  pc   = %{alice: :done, bob: :done}   ← changed

════════════════════════════════════════════════════════════════════
```

Read the last state: both clients are `done`, the lock is free, and **no action is enabled**
— `request` needs `:idle`, `acquire` needs `:waiting`, `finish` needs `:holding`. The system has
finished, and the checker cannot tell that from being wedged. Exit code 1.

The counterexample is still worth reading even here, because the state it ends in is the answer:
if that state is what success looks like, you have found a missing declaration rather than a bug.

### Declaring the end state

`terminal` names the states that are final on purpose:

<!-- tla:spec -->
```elixir
defmodule Tutorial.OneShotLockDone do
  use TLA.Spec

  constant :clients, default: set([:alice, :bob])

  variable :free, type: [true, false]
  variable :pc,   type: [^clients ~> [:idle, :waiting, :holding, :done]]

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

  action :finish, params: [c: ^clients] do
    require pc[c] == :holding
    free = true
    pc   = update(pc, c, fn _ -> :done end)
  end

  invariant :mutual_exclusion do
    Enum.count(^clients, fn c -> pc[c] == :holding end) <= 1
  end

  terminal :all_done do
    Enum.all?(^clients, fn c -> pc[c] == :done end)
  end
end
```

<!-- tla:check module=Tutorial.OneShotLockDone expect=ok states=15 depth=7 -->
```
Tutorial.OneShotLockDone — verified
  15 distinct states, 20 transitions, depth 7, 1ms
```

**The same fifteen states, the same twenty transitions** — the search did not change at all. What
changed is that one of those states is now declared to be an ending. That is the whole mechanism,
and it is worth being clear about what it does *not* do
([§5.3](../../spec/02-dsl-semantics.md#5-3-terminal-states-are-declared-not-inferred)):

- **Invariants are still checked** in a terminal state. Declaring an ending does not exempt it.
- **No action is disabled** by it. A `terminal` is a claim about a state, not a stop instruction.
- **For liveness it stutters forever**, so a `p ~> q` whose `q` has not happened by then is
  violated there — which is the correct verdict, because it never will happen.

There is also `check_deadlock: false`, which turns the whole check off. Prefer the declaration: it
says *which* states are meant to be final and leaves deadlock detection on for every other state,
which is where you want it.

### A `terminal` that is too generous

The declaration is a claim, and like any claim it can be wider than you meant. Suppose
`someone_done` instead of `all_done` — one client finishing admits the state:

<!-- tla:spec -->
```elixir
defmodule Tutorial.OneShotLockLoose do
  use TLA.Spec

  constant :clients, default: set([:alice, :bob])

  variable :free, type: [true, false]
  variable :pc,   type: [^clients ~> [:idle, :waiting, :holding, :done]]

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

  action :finish, params: [c: ^clients] do
    require pc[c] == :holding
    free = true
    pc   = update(pc, c, fn _ -> :done end)
  end

  invariant :mutual_exclusion do
    Enum.count(^clients, fn c -> pc[c] == :holding end) <= 1
  end

  # `any?`, not `all?` — one client finishing admits the state.
  terminal :someone_done do
    Enum.any?(^clients, fn c -> pc[c] == :done end)
  end
end
```

It still verifies, and the coverage report is where it shows up:

<!-- tla:check module=Tutorial.OneShotLockLoose expect=ok states=15 -->
```
Tutorial.OneShotLockLoose — verified
  15 distinct states, 20 transitions, depth 7, 1ms
…
1 warning. Re-run with --strict-coverage to fail on these.
--------------------------------------------------------------------
warning: terminal :someone_done admitted a live state
```

**`terminal_but_live`**: a state the predicate called final still had an enabled action. It is not
an error — a system may legitimately be allowed to stop early — but it almost always means the
predicate is broader than the end state it was written for, and a broad `terminal` is how a real
deadlock gets admitted as an ending. `--strict-coverage` makes it exit 3.

---

Next: [Temporal properties, and the difference fairness makes](04-temporal.md).
