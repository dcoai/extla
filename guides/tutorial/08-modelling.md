# From a system you have to a specification you can check

ExTLA tutorial. Previous: [Layer 3 — does the implementation conform?](07-layer3.md).

Every page so far has handed you a specification. This one derives one, because deciding *what to
model* is the part nobody can do for you and the part that decides whether the exercise is worth
anything. A model that includes too much cannot be checked; one that includes too little verifies
and proves nothing about your system.

There is no algorithm for it. There are recurring decisions, and this page works through them on
one system, showing what was rejected as well as what was kept.

## The system

A background job runner, of the kind most Elixir applications grow:

- Jobs arrive and are queued. Each has a payload and an id.
- A worker picks up a queued job and runs it. Success marks it done.
- A crash puts it back in the queue to be retried, and after a bounded number of attempts it is
  marked failed rather than retried forever.
- Workers are interchangeable, and there may be several.

The property worth checking is the one that makes the retry bound mean something: **no job is
attempted more times than the bound allows, and a job that ends up failed really did exhaust its
attempts.** A test can sample that. It cannot tell you it is true under every interleaving of
crashes and restarts, which is exactly where a retry bound goes wrong.

## Which fields are state, and which are derivable

The obvious first model transcribes the runner's own struct: statuses, a payload per job, a
worker per job, a count of what is queued. Take the count first, because it is the clearest case
of something that looks like state and is not.

<!-- tla:spec -->
```elixir
defmodule Modelling.WithCount do
  use ExTLA.Spec

  constant :jobs, default: set([:j1, :j2])

  variable :status,       type: [^jobs ~> [:queued, :running, :done]]
  variable :queued_count, type: 0..2

  init do
    status       = for_each(^jobs, fn _ -> :queued end)
    queued_count = 2
  end

  action :start, params: [j: ^jobs] do
    require status[j] == :queued
    status       = update(status, j, fn _ -> :running end)
    queued_count = queued_count - 1
  end

  action :succeed, params: [j: ^jobs] do
    require status[j] == :running
    status = update(status, j, fn _ -> :done end)
  end

  invariant :count_agrees do
    queued_count == Enum.count(^jobs, fn j -> status[j] == :queued end)
  end

  terminal :all_done do
    Enum.all?(^jobs, fn j -> status[j] == :done end)
  end
end
```

<!-- tla:check module=Modelling.WithCount expect=ok states=9 depth=5 output=abridged -->
```
Modelling.WithCount — verified
  9 distinct states, 12 transitions, depth 5, 0ms
```

Now the same model with `queued_count` deleted, and nothing else changed:

<!-- tla:spec -->
```elixir
defmodule Modelling.Lean do
  use ExTLA.Spec

  constant :jobs, default: set([:j1, :j2])

  variable :status, type: [^jobs ~> [:queued, :running, :done]]

  init do
    status = for_each(^jobs, fn _ -> :queued end)
  end

  action :start, params: [j: ^jobs] do
    require status[j] == :queued
    status = update(status, j, fn _ -> :running end)
  end

  action :succeed, params: [j: ^jobs] do
    require status[j] == :running
    status = update(status, j, fn _ -> :done end)
  end

  terminal :all_done do
    Enum.all?(^jobs, fn j -> status[j] == :done end)
  end
end
```

<!-- tla:check module=Modelling.Lean expect=ok states=9 depth=5 output=abridged -->
```
Modelling.Lean — verified
  9 distinct states, 12 transitions, depth 5, 1ms
```

**The same nine states, the same depth.** This is worth being precise about, because the usual
claim — that a redundant variable blows up the state space — is not what happens: `queued_count`
is a *function* of `status`, so it takes exactly one value per status configuration and adds no
reachable states at all.

What it adds is an **obligation**. Every action that changes `status` must also update the count,
and `count_agrees` exists only to check that you did. Forget it in one action:

<!-- tla:spec -->
```elixir
defmodule Modelling.ForgotToCount do
  use ExTLA.Spec

  constant :jobs, default: set([:j1, :j2])

  variable :status,       type: [^jobs ~> [:queued, :running, :done]]
  variable :queued_count, type: 0..2

  init do
    status       = for_each(^jobs, fn _ -> :queued end)
    queued_count = 2
  end

  action :start, params: [j: ^jobs] do
    require status[j] == :queued
    status = update(status, j, fn _ -> :running end)
  end

  action :succeed, params: [j: ^jobs] do
    require status[j] == :running
    status = update(status, j, fn _ -> :done end)
  end

  invariant :count_agrees do
    queued_count == Enum.count(^jobs, fn j -> status[j] == :queued end)
  end

  terminal :all_done do
    Enum.all?(^jobs, fn j -> status[j] == :done end)
  end
end
```

<!-- tla:check module=Modelling.ForgotToCount expect=violation property=count_agrees output=abridged -->
```
Modelling.ForgotToCount — VIOLATION: count_agrees
  2 distinct states, 1 transitions, depth 2, 0ms

═══ VIOLATION: count_agrees ════════════════════════════════════════
invariant :count_agrees does not hold in this state

State 1 (Init):
  queued_count = 2
…
State 2 [VIOLATION]:
  queued_count = 2
…
════════════════════════════════════════════════════════════════════
```

The elided lines show one job started and both still counted as queued. Which job, `:j1` or
`:j2`, can differ between runs: the two are interchangeable, and either one gives a shortest
counterexample.

That counterexample is about **the model's bookkeeping**, not about the job runner. It is time
spent debugging a specification for a defect the system does not have — and the specification is
supposed to be the cheap place to work. So: **if a field is a function of other state, leave it
out.** The implementation may well cache it, and Layer 3's refinement mapping is where that
difference belongs — `abstract/1` computes the abstract value from the concrete one, and the cache
never enters the model.

## Which things are constants, and which are bounds

Two of the runner's parameters look alike and behave completely differently.

**`jobs` is a set, and its elements are interchangeable.** Nothing in the design treats `:j1`
differently from `:j2`. That makes it a `constant` holding a set, it makes the actions take
`params: [j: ^jobs]`, and — as [Symmetry](05-symmetry.md) showed — it makes the model a candidate
for symmetry reduction, because the interchangeability is exactly what that declaration claims.

**`max_attempts` is a number.** It bounds behaviour rather than naming participants. It could have
been modelled as a set of attempt tokens, and that would have been a mistake twice over: it would
have implied the attempts are distinguishable, and it would have multiplied the state space by
permutations that mean nothing.

The test is what the design does with it. If the elements are compared, ordered, or indexed, they
are not interchangeable and a set is the wrong shape. If it only ever appears in arithmetic, it is
a bound.

## What is abstracted away, and what that costs

The runner's real jobs carry a payload, a queue timestamp, an attempt history and a worker pid.
The model has none of them, and the argument is the same in each case: **the property under check
does not read them.** Whether a payload is a 2-byte map or a 2-megabyte blob cannot change whether
a retry bound is respected, so distinguishing the two adds states without changing any verdict —
and there are effectively infinitely many payloads, so a model that included them could not be
checked at all.

State the price out loud, because it is real: **a bug that depends on the payload is now outside
the model.** If a particular payload makes the worker crash in a way that skips the attempt
counter, this specification will not find it — not because the checker is weak, but because the
model you gave it does not contain the notion. That is the trade the whole method makes, and
[the mathematics page](01-mathematics.md) is where it is stated in general.

Two abstractions here are worth naming individually:

- **Workers vanish entirely.** The design says workers are interchangeable and any of them may
  pick up any queued job, so "which worker" is unobservable to the property. What survives is the
  *nondeterminism* — that a queued job may start at any time — and that is `params:`.
- **Time becomes ordering.** There is no clock. A retry does not happen "after 30 seconds", it
  happens at some later step, and every interleaving is explored. If a property genuinely depends
  on a deadline, this is the point at which you find out the method cannot express it.

## How big to make it

Here is the model those decisions produce, with the retry bound the property is about:

<!-- tla:spec -->
```elixir
defmodule Modelling.Runner do
  use ExTLA.Spec

  constant :jobs,         default: set([:j1, :j2])
  constant :max_attempts, default: 2

  variable :status,   type: [^jobs ~> [:queued, :running, :done, :failed]]
  variable :attempts, type: [^jobs ~> 0..^max_attempts]

  init do
    status   = for_each(^jobs, fn _ -> :queued end)
    attempts = for_each(^jobs, fn _ -> 0 end)
  end

  action :start, params: [j: ^jobs] do
    require status[j] == :queued
    require attempts[j] < ^max_attempts
    status   = update(status, j, fn _ -> :running end)
    attempts = update(attempts, j, &(&1 + 1))
  end

  action :succeed, params: [j: ^jobs] do
    require status[j] == :running
    status = update(status, j, fn _ -> :done end)
  end

  action :crash, params: [j: ^jobs] do
    require status[j] == :running
    status = update(status, j, fn _ -> :queued end)
  end

  action :give_up, params: [j: ^jobs] do
    require status[j] == :queued
    require attempts[j] == ^max_attempts
    status = update(status, j, fn _ -> :failed end)
  end

  invariant :attempts_bounded do
    Enum.all?(^jobs, fn j -> attempts[j] <= ^max_attempts end)
  end

  invariant :done_means_attempted do
    Enum.all?(^jobs, fn j -> status[j] != :done or attempts[j] > 0 end)
  end

  terminal :settled do
    Enum.all?(^jobs, fn j -> status[j] == :done or status[j] == :failed end)
  end
end
```

<!-- tla:check module=Modelling.Runner expect=ok states=64 depth=11 output=abridged -->
```
Modelling.Runner — verified
  64 distinct states, 112 transitions, depth 11, 2ms
```

Two jobs and two attempts: sixty-four states, and every interleaving of starting, crashing,
retrying and giving up is in there. Now the growth, measured on the same specification:

| Jobs | `max_attempts` | Distinct states | Depth |
|---|---|---|---|
| 2 | 2 | 64 | 11 |
| 3 | 2 | **512** | 16 |
| 2 | 3 | 121 | 15 |

One more job costs a factor of **eight** — each job contributes its own eight reachable
combinations of status and attempts, and the model is their product. That is state explosion, on a
specification small enough to read on one screen, and it is why the answer to "how big" is
*two or three of everything*.

The reason that is not a cop-out: **interleaving bugs show up at small parameters.** A retry bound
that can be exceeded can be exceeded with two jobs; a lock that can be held twice can be held
twice by two clients. If you cannot construct the bug at three, adding a fourth rarely helps —
and if you genuinely need more, the levers are a state constraint, a smaller constant set, and
the symmetry reduction [Symmetry](05-symmetry.md) covered.

## What was left out entirely

Worth writing down, because the verdict is only about what is in the model:

- **A crash between updating `status` and updating `attempts`.** The model's actions are atomic,
  so this cannot happen in it. A real runner writing two fields non-atomically can, and if that
  matters the model needs to say so — by splitting the action, which is precisely what
  [Getting started](../getting-started.md) does to break the lock.
- **The queue's own durability.** Nothing here models the store losing a job.
- **Partial failure**: a worker that dies without reporting, a job that runs twice because a
  restart lost the fact it had started.
- **Deadlines and throughput.** No clock, no cost.

Each of those is a real property of a real system, and **a model with no action for a thing proves
nothing about that thing.** None of them is a flaw in the method; they are the boundary of this
particular model, and the boundary is a decision you make deliberately and record — not something
you discover later when the verdict turns out to have been about less than you thought.

---

That is the derivation. The specification it produced is a model of a design, and its verdict is
about the model.

Next: [When it explodes](09-when-it-explodes.md).
