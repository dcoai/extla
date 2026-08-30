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

**Design stage. No implementation yet.** The specification is complete and the build
order is settled; Phase 1 has not started. The repository holds a `mix.exs` skeleton,
CI, and the differential-corpus layout so that Phase 1 has an oracle from its first
commit ([D-9](spec/08-decisions.md)).

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
