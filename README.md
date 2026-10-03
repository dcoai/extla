# ExTLA

TLA+-inspired formal verification for Elixir/OTP systems.

Write specifications as Elixir code, model-check them exhaustively in Elixir, and check
that running GenServers actually conform to them.

<!-- tla:spec -->
```elixir
defmodule Specs.Counter do
  use ExTLA.Spec

  constant :max_val

  variable :count,  type: 0..^max_val
  variable :status, type: [:ready, :incrementing]

  init do
    count  = 0
    status = :ready
  end

  action :increment do
    require status == :ready
    require count < ^max_val

    count  = count + 1
    status = :incrementing
  end

  action :done do
    require status == :incrementing
    status = :ready
  end

  action :reset do
    require status == :ready
    count = 0
  end

  invariant :in_bounds do
    count >= 0 and count <= ^max_val
  end

  temporal :always_returns_to_ready do
    (status == :incrementing) ~> (status == :ready)
  end

  fairness :weak, [:done]
end
```

```
mix tla.check Specs.Counter        # exhaustive model checking + coverage
mix tla.simulate MyApp.Counter     # does the implementation conform?
mix tla.replay   MyApp.Counter     # replay a counterexample against real code
mix tla.explore  Specs.Counter     # evaluate your own expressions over a counterexample
mix tla.visualize Specs.Counter    # the state graph as DOT
mix tla.stamp                      # refinement mappings, against the spec version they were read at
```

**New here?** [Getting started](guides/getting-started.md) is install, one specification and
one counterexample, in half an hour. The [tutorial](guides/tutorial/00-introduction.md) is the
long path — eleven pages, one lock running through all of them, ending with how to keep a
specification in a project of your own. Every code block on both is compiled and run by this
repository's test suite.

## Status

**All four phases are done, on the terms the project set for itself** — see
[spec/06-architecture.md §Implementation Phases](spec/06-architecture.md#implementation-phases),
which is where what-is-built is recorded.

`mix tla.check MySpec` explores the state space breadth-first, checks the invariants and
the temporal properties, reports the shortest counterexample — or the lasso — when it
finds one, and prints what the run actually exercised.

The acceptance criterion is not "the tests pass" but [D-9](spec/08-decisions.md): the
checker must agree with TLC on **every** spec in the differential corpus. It does, on
all seven — distinct states, search depth, where the search stops, every invariant, every
temporal property, every action property, and for `die_hard` the shortest counterexample,
which is the same six-step trace action for action.

| Entry | Distinct states | Depth | Agreement |
|---|---|---|---|
| `die_hard` | 16 | 8 | ✅ including the counterexample |
| `two_phase_commit` | 288 | 11 | ✅ |
| `distributed_lock` | 34 | 7 | ✅ |
| `raft_election` | 58,359 | 19 | ✅ including where it ends |
| `bounded_buffer` | 4,460 | 29 | ✅ including where it ends |
| `paxos` | 3,921 | 17 | ✅ |
| `audit_log` | 3 | 3 | ✅ including the counterexample |

`audit_log` is three states and is not there to be an interesting system. It is the
corpus's only entry whose subject is a **declaration kind** rather than an algorithm:
`action_property` — a predicate over a *step*, which TLC checks as a `PROPERTY` and not
as an `INVARIANT` — was the one Layer 2 feature the oracle had never been shown, which
is how #112 lived for as long as the feature had. Its `compact` action empties the log,
so the offending step's post-state *is* the initial state; a checker that builds the
counterexample from the wrong end of the step therefore returns a different **length**
rather than merely a different path, and D-9's comparison can see it. Reintroducing #112
on this entry turns a passing suite into `ExTLA returned 1 states` against TLC's 4, while
all six other entries stay green.

These are measurements, not assertions: `expected.json` is TLC's own output, CI
regenerates it from TLC on every pipeline, and a corpus entry that drifts fails the
build. The oracle landed before the checker precisely so this column could be measured
rather than assumed.

The corpus also records TLC's verdict on each entry's **temporal** properties, and
`check_liveness: true` now agrees with all seven — including the one that matters:
`raft_election`'s `eventually_elect_leader` comes back *violated*, refuted by the model's
term bound by design, with a seven-state prefix that ends in the split vote and stutters
there forever. That row is what distinguishes a working liveness checker from one that
answers "holds" to everything.

| Entry | Property | TLC | ExTLA |
|---|---|---|---|
| `distributed_lock` | `no_starvation`, `lock_eventually_released` | holds | holds |
| `bounded_buffer` | all four | holds | holds |
| `raft_election` | `eventually_elect_leader` | **violated** | **violated** |

`no_starvation` holds only under *per-binding* strong fairness — `\A p : SF(Acquire(p))`,
not `SF(\E p : Acquire(p))`. The same spec with weak fairness is refuted, with p1 waiting
while p2 takes the lock and gives it back forever.

**Symmetry reduction** collapses states that differ only by a permutation of an
interchangeable constant. `mix run bench/symmetry.exs`:

| Model | States | Time |
|---|---|---|
| `raft_election`, 3 servers | 58,359 → 9,871 | 23.3s → 6.6s |
| `distributed_lock`, 3 processes and 2 resources | 184 → 26 | 11ms → 6ms |

Nothing can establish that a `symmetry:` declaration is sound — a constant flows into
arbitrary Elixir, so the check is undecidable, and it is the author's obligation
([D-17](spec/08-decisions.md)). `verify_symmetry: true` is what makes a wrong one
*detectable*: it runs the model both ways and fails if any verdict differs. Both models
above pass it.

The corpus paid for itself along the way. `raft_election` is
[Example 2](spec/07-examples.md) of this repository's own documentation, and TLC refuted
its headline safety property — a candidate that timed out twice counted a vote granted
in the *earlier* term, and two servers reached `leader` in the same term. The example
now carries the term check that Raft has and it did not. Writing the entries also found
six gaps in the DSL and the harness, each fixed where it was found — most recently that
four entries were typing a variable *weaker* than the TLA+ they are checked against, and
that `f[x]` outside a function's domain was `nil` rather than an error.

**Phase 3** added Layer 1 invariants on running processes and the Layer 3 conformance
bridge — `ExTLA.GenServer`, `ExTLA.Refinement`, `mix tla.simulate` and `mix tla.replay`.
**Phase 4** added parallel exploration (**5.40x at 8 workers**; `raft_election` went from
23.4 s to 1.65 s, with the corpus agreeing with TLC at 1, 2, 4 and 8), `ExTLA.PropertyTest`,
and `mix tla.visualize`.

**What is built** is [`CHANGELOG.md`](CHANGELOG.md), which is gated: `bin/changelog_guard.exs`
fails any commit touching `lib/` that adds no entry. **What was planned**, phase by phase,
and that the plan finished, is
[spec/06-architecture.md §Implementation Phases](spec/06-architecture.md#implementation-phases).
Neither is restated here — a second copy is what let this section claim two phases were
unbuilt for a day and a half after they shipped, and §Phases called itself "the single
source of truth for what is built" for three weeks after it stopped being extended (#282).

Asking for symmetry reduction and liveness in the same run raises rather than quietly
checking something weaker: the quotient graph can hold cycles the real state space does
not, and a cycle is what a liveness verdict is read off ([D-22](spec/08-decisions.md)).
Liveness is refused alongside `workers:` for the neighbouring reason ([D-27](spec/08-decisions.md)).

See [spec/README.md](spec/README.md) for the full specification, and
[spec/08-decisions.md](spec/08-decisions.md) for why it is shaped the way it is.

## Why

There is no Elixir-native model checker, no Elixir library that supports temporal logic
(liveness, fairness, leads-to), and nothing that checks an implementation against a
formal spec. Adjacent work exists — Erla+ generates code from PlusCal, Verlixir
translates to Spin, Concuerror explores schedules, Corsa and Bond do function-level
contracts — but the middle of that space is empty. See
[spec/00-prior-art.md](spec/00-prior-art.md).

## Design principles

1. **Elixir-native** — specs are Elixir code, not a separate language
2. **Incremental adoption** — each layer is independently useful
3. **Zero production cost** — `:disabled` emits no code, rather than cheap code
4. **OTP-aligned** — works with GenServer, Supervisor, and OTP conventions
5. **Test-integrated** — `mix test` runs verification; no separate toolchain
6. **Never claim more than was checked** — an incomplete run fails, a bounded run says
   so, a fingerprint width reports its collision margin, and a run reports which actions
   it never enabled

## Non-goals

Not a theorem prover (TLAPS), not a scheduler explorer (Concuerror), no model extraction
from source (Verlixir), no code generation from specs (Erla+), no real-time or
probabilistic extensions.

## Repository layout

| Path | Contents |
|---|---|
| `guides/` | [Getting started](guides/getting-started.md) and the eleven-page [tutorial](guides/tutorial/00-introduction.md) — the way in, and where to start |
| `spec/` | The specification. `NN-name.md` in dependency order; `README.md` is the index |
| `pm/` | Offline proposal/work-item tracker, used when GitLab is unreachable |
| `research/` | Background reading, including a TLA+ primer |
| `test/differential/` | The TLC differential corpus — paired TLA+ and ExTLA specs the checker must agree with TLC on |

## License

MIT — see [LICENSE](LICENSE).
