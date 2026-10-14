# When it explodes

ExTLA tutorial. Previous: [From a system you have to a specification you can check](08-modelling.md).

Sooner or later a run does not come back. [The mathematics](01-mathematics.md) explains why —
the state space is a product, so each participant multiplies it — and [modelling](08-modelling.md)
measured it: one more job took that specification from 64 states to 512. This page is what to do
about it, with every number measured on one specification that genuinely hurts.

It is the same job runner, at three jobs and three attempts:

<!-- tla:spec -->
```elixir
defmodule Boom.Runner do
  use ExTLA.Spec

  constant :jobs,         default: set([:j1, :j2, :j3])
  constant :max_attempts, default: 3

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

  terminal :settled do
    Enum.all?(^jobs, fn j -> status[j] == :done or status[j] == :failed end)
  end
end
```

<!-- tla:check module=Boom.Runner expect=ok states=1331 depth=22 output=abridged -->
```
Boom.Runner — verified
  1331 distinct states, 3630 transitions, depth 22, 46ms
```

Eleven reachable combinations per job, three jobs, `11^3`. Each job you add multiplies the space
by eleven, so this is 1,331; four jobs is 14,641 and five is 161,051, which takes nine seconds.
Eight jobs would not finish at all. That is the arithmetic the rest of this page is about.

## First, know which kind of "did not finish" you have

Three outcomes look similar in a terminal and are not the same fact.

**A state limit.** `--max-states` stops the search:

<!-- tla:check module=Boom.Runner expect=incomplete max_states=500 output=abridged -->
```
Boom.Runner — INCOMPLETE (state limit)
  502 distinct states, 1199 transitions, depth 11, 16ms
```

Exit code **2**, and the coverage footer records `bounded_by: :max_states`. Nothing was
established. This is the flag to reach for when you want to know whether a spec *starts* correctly
before committing an hour to it — a bounded run that finds a violation has still found a real one.

**A state constraint** reports the same way and for the same reason, with
`bounded_by: :state_constraint` — §Constrain the space below.

**Still running** is the third, and the only one with no output to read. `--max-states` is how you
convert it into one of the first two.

## The levers, cheapest first

### Shrink the constants

Almost always the right answer, and the one people resist because it feels like giving up. The
same specification at three jobs and two attempts:

<!-- tla:check module=Modelling.Runner expect=ok states=64 depth=11 output=abridged -->
```
Modelling.Runner — verified
  64 distinct states, 112 transitions, depth 11, 2ms
```

1,331 states become 64. What is lost is nothing you were relying on: an interleaving bug that
needs three jobs and three attempts to appear is rare to the point of being worth doubting, and
[modelling](08-modelling.md) makes the argument in full. Try this before anything else on this
page.

### Symmetry, when the participants really are interchangeable

The largest single win available here, because `jobs` is exactly the kind of constant the
reduction is for:

<!-- tla:check module=Boom.Runner expect=ok symmetry=jobs verify_symmetry=true states=286 depth=22 output=abridged -->
```
Boom.Runner — verified
  286 distinct states, 780 transitions, depth 22, 22ms
```

**1,331 to 286** — a factor of nearly five, with the same depth and the same verdict, and
`--verify-symmetry` confirming the declaration was sound. [Symmetry](05-symmetry.md) is the page
for what that flag does and why it is your obligation; the point here is that when it applies it
beats every other lever combined.

### Use more cores

<!-- tla:skip reason=a shell invocation, and the timing below is from this machine -->
```sh
mix extla.check Boom.Runner --workers 4
```

On this model that is **slower** — 90 ms against 55 ms — and the reason is worth knowing: the
coordination costs more than the work saved when there is barely any work. `--workers` pays on a
model large enough to need it, and this project's own benchmark is the honest advertisement:
`raft_election` goes from 23.4 s to 1.65 s at eight workers, a 5.4x speedup on 58,359 states.

What it never buys is tractability. It explores the identical space, so a run that would never
finish still never finishes — reach for it after the levers above, not instead of them. It also
refuses to check liveness ([§Parallel exploration](../reference.md#parallel-exploration)), so a spec with a `temporal` has
its safety checked in parallel and says so.

### Skip liveness while you are iterating

`--safety-only` turns off the temporal checking, and with it the liveness graph the check needs.
Useful when the question you are currently asking is about an invariant; not a reduction, since
the state space is the same.

## Constrain the space

`state_constraint` restricts the search to states worth exploring. It is the sharpest tool here
and the only one that can quietly invalidate your result, so both halves matter.

<!-- tla:skip reason=a config fragment; the runs below are the measurements -->
```elixir
# In a test, or wherever you call the checker directly.
ExTLA.ModelChecker.run(Boom.Runner, %{
  constants: %{jobs: MapSet.new([:j1, :j2, :j3, :j4, :j5]), max_attempts: 3},
  state_constraint: fn state ->
    Enum.count(state.status, fn {_job, s} -> s == :running end) <= 2
  end
})
```

Measured on this specification, three constraints and what each bought:

| Constraint | States | Time |
|---|---|---|
| none | 1,331 | 55 ms |
| at most 2 jobs running | 1,331 | 45 ms |
| at most 2 jobs not queued | 1,304 | 46 ms |
| no job past its first retry | **112** | 5 ms |

Those four rows are measured, and — unlike every other number on this page — they are **not**
machine-checked: a `state_constraint` is a function, and the harness's claims are declarative, so
there is nothing for it to assert here. Said out loud rather than left to look like the rest.

The first row is the lesson people do not expect: **a constraint can buy nothing at all.**
Limiting concurrency to two removed *not one state* — with three jobs there is no reachable state
with three running, so the constraint excludes nothing that existed. The second removed 2%. Both
are guesses about where the states are, and this model's states differ in their attempt counts
rather than in how many jobs run at once. Measure rather than assume.

And the last row is the trap. It is a twelvefold reduction, it runs in 5 ms, and it is
**exactly the wrong constraint for this specification**: the property being checked is
`attempts_bounded`, and the constraint excludes every state where a job has attempted more than
once — which is where a violation of that property could possibly live. The run comes back
`constrained`, exit 2, with `bounded_by: :state_constraint`, and that is the tool telling you it
answered a smaller question than you asked. It is not a verdict, and the danger is reading it as
one.

The rule that follows: **a state constraint must not restrict the variables your property is
about.** Constrain the parts of the state the question does not depend on.

## Fingerprint width, and what a verdict rests on

The checker identifies states by a hash rather than by keeping them, so two distinct states could
in principle collide and one of them go unexplored. Every run reports its own collision
probability:

| `--fingerprint-bits` | Collision estimate at 1,331 states |
|---|---|
| 64 (default) | 4.8 × 10⁻¹⁴ |
| 128 | 2.6 × 10⁻³³ |

At this size the default is already far below any other risk in the exercise — you are more likely
to have mis-modelled the system. It is worth knowing the number exists, and worth raising the width
for a run whose result you intend to rely on at a much larger state count, where the estimate grows
with the square of the number of states.

---

Next: [Putting a specification in your project](10-in-your-project.md).
