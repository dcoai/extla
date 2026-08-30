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

**Phase 1 is done: a spec written in the DSL compiles, and its safety properties are
checked correctly.** `mix tla.check MySpec` explores the state space breadth-first,
reports the shortest counterexample when it finds one, and prints what the run actually
exercised.

The acceptance criterion is not "the tests pass" but [D-9](spec/08-decisions.md): the
checker must agree with TLC. It does — on `die_hard`, ExTLA and TLC agree on the
distinct-state count (16), the search depth (8), every invariant, and the shortest
counterexample, which is the same six-step trace action for action. The oracle landed
before the checker did, so that agreement has held from the checker's first run.

| Piece | State |
|---|---|
| `TLA.State`, `TLA.Config`, `TLA.Fingerprint`, `TLA.Set`, `TLA.Function` | ✅ |
| `TLA.Spec` DSL + the §7 compile-time validator | ✅ |
| `TLA.StateGraph`, breadth-first `TLA.ModelChecker`, `TLA.Trace` | ✅ |
| The implicit `type_ok` invariant | ✅ |
| `TLA.Coverage`, `mix tla.check`, `TLA.Spec.Test` | ✅ |
| Differential corpus vs TLC | `die_hard`; five entries to go |
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
