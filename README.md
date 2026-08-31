# ExTLA

TLA+-inspired formal verification for Elixir/OTP systems.

Write specifications as Elixir code, model-check them exhaustively in Elixir, and check
that running GenServers actually conform to them.

```elixir
defmodule Specs.Counter do
  use TLA.Spec

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
```

## Status

**Phase 1 is done, on the terms the project set for itself.**
`mix tla.check MySpec` explores the state space breadth-first, reports the shortest
counterexample when it finds one, and prints what the run actually exercised.

The acceptance criterion is not "the tests pass" but [D-9](spec/08-decisions.md): the
checker must agree with TLC on **every** spec in the differential corpus. It does, on
all six — distinct states, search depth, where the search stops, every invariant, and
for `die_hard` the shortest counterexample, which is the same six-step trace action for
action.

| Entry | Distinct states | Depth | Agreement |
|---|---|---|---|
| `die_hard` | 16 | 8 | ✅ including the counterexample |
| `two_phase_commit` | 288 | 11 | ✅ |
| `distributed_lock` | 34 | 7 | ✅ |
| `raft_election` | 58,359 | 19 | ✅ including where it ends |
| `bounded_buffer` | 4,460 | 29 | ✅ including where it ends |
| `paxos` | 3,921 | 17 | ✅ |

These are measurements, not assertions: `expected.json` is TLC's own output, CI
regenerates it from TLC on every pipeline, and a corpus entry that drifts fails the
build. The oracle landed before the checker precisely so this column could be measured
rather than assumed.

The corpus now also records TLC's verdict on each entry's **temporal** properties,
ahead of any liveness checking on the ExTLA side — the same ordering, for the same
reason. `raft_election`'s `EventuallyElectLeader` comes back *violated*, refuted by the
model's term bound by design, and that is the entry that will tell a working liveness
checker from one that answers "holds" to everything.

The corpus paid for itself along the way. `raft_election` is
[Example 2](spec/07-examples.md) of this repository's own documentation, and TLC refuted
its headline safety property — a candidate that timed out twice counted a vote granted
in the *earlier* term, and two servers reached `leader` in the same term. The example
now carries the term check that Raft has and it did not. Writing the entries also found
six gaps in the DSL and the harness, each fixed where it was found — most recently that
four entries were typing a variable *weaker* than the TLA+ they are checked against, and
that `f[x]` outside a function's domain was `nil` rather than an error.

| Piece | State |
|---|---|
| `TLA.State`, `TLA.Config`, `TLA.Fingerprint`, `TLA.Set`, `TLA.Function` | ✅ |
| `TLA.Spec` DSL + the §7 compile-time validator | ✅ |
| `TLA.StateGraph`, breadth-first `TLA.ModelChecker`, `TLA.Trace` | ✅ |
| The implicit `type_ok` invariant | ✅ |
| `TLA.Coverage`, `mix tla.check`, `TLA.Spec.Test` | ✅ |
| Differential corpus vs TLC | ✅ all six entries |
| TLC's temporal verdicts in the corpus | ✅ oracle only; nothing checks them yet |
| Liveness, fairness, symmetry (Phase 2) | not yet |
| Layer 1 invariants, Layer 3 conformance (Phase 3) | not yet |
| Parallel exploration (Phase 4) | not yet |

Asking for something a later phase brings — `check_liveness: true`, `symmetry:` —
raises rather than quietly checking something weaker.

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
| `spec/` | The specification. `NN-name.md` in dependency order; `README.md` is the index |
| `pm/` | Offline proposal/work-item tracker, used when GitLab is unreachable |
| `research/` | Background reading, including a TLA+ primer |
| `test/differential/` | The TLC differential corpus — paired TLA+ and ExTLA specs the checker must agree with TLC on |

## License

MIT — see [LICENSE](LICENSE).
