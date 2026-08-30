# HANDOFF — 2026-08-30 — Phase 1 components built, corpus half done

Supersedes `HANDOFF-2026-08-30-ci-and-phase1.md`, whose blocker (a dead
ssh-agent socket) turned out to be fixed by reconnecting with agent forwarding.
This file is self-contained; read it first.

---

## WHERE THINGS STAND

**Every component of Phase 1 exists** (`spec/06-architecture.md` §Phase 1).
`mix tla.check MySpec` explores the state space breadth-first, reports the
shortest counterexample when it finds one, prints what the run exercised, and
exits with a code that distinguishes "verified" from "we ran out of budget".

**The Phase 1 acceptance gate is half met.** D-9 makes the differential corpus
the acceptance criterion, and three of its six entries are in:

| Entry | Distinct states | Depth | Agreement with TLC |
|---|---|---|---|
| `die_hard` | 16 | 8 | exact, including the 6-step counterexample |
| `two_phase_commit` | 288 | 11 | exact |
| `distributed_lock` | 34 | 7 | exact |

Every one agreed on the first run. That is the payoff for landing the oracle
before the checker: the agreement is measured, not assumed.

303 tests, all green. CI is green on `main` — `check` (format / compile with
warnings-as-errors / test) and `verify` (regenerates every `expected.json` from
TLC and fails on drift).

---

## WHAT IS BUILT

```
lib/tla/
  state.ex           TLA.State + validate!/1 (the §6 permitted-terms check)
  config.ex          compile-time mode/0, max_states/0, workers/0
  fingerprint.ex     canonical/1, compute/2, collision_estimate/2
  set.ex             TLA.Set — powerset, cross, choose, quantifiers
  function.ex        TLA.Function — construct, function_set, EXCEPT
  spec.ex            use TLA.Spec, @before_compile, the compiled struct
  spec/dsl.ex        constant/variable/init/action/invariant/...
  spec/rewriter.ex   §1's three name classes
  spec/block.ex      §2's simultaneous assignment, near-miss derivation
  spec/params.ex     §3's single nondeterminism mechanism
  spec/temporal.ex   §5.1's bounded fragment
  spec/type.ex       §1.5 grammar: validation, resolution, membership
  spec/helpers.ex    the vocabulary spec blocks are written in
  spec/test.ex       assert_spec/2
  state_graph.ex     parent pointers + fingerprints, ETS-backed
  model_checker.ex   breadth-first search, config, result
  model_checker/safety.ex
  trace.ex           replay-based regeneration, format/1
  coverage.ex        never-enabled, vacuity, near misses
lib/mix/tasks/tla.check.ex
```

Not built, and raising rather than pretending: liveness (`check_liveness: true`),
symmetry (`symmetry:`, `verify_symmetry:`), parallel exploration, Layers 1 and 3.

---

## HOW THE WORK IS RUN

Process, from the project's labels:
`Proposal -> Accepted -> Planned -> In-Progress -> Review (MR) -> merge`.

Each work item is a `pm/pm-N-*.md` file mirrored to a GitLab issue, an MR that
closes it, and a move to `pm/closed/` in the *next* MR. **GitLab does not
auto-close issues from `Closes #N`** on this instance — close them with
`glab issue close N` after merging.

Every MR: push, wait for the pipeline, merge only on green.

```bash
glab ci status --branch <branch> --live=false
glab mr merge <n> --yes --remove-source-branch
```

---

## OPEN PROPOSALS

- **#1 / `pm-1-verification-ledger.md`** — drift-gated coverage golden and
  spec-version stamps. Predates this session's work; its Phase 1 items
  (`TLA.Spec.version/1`, the coverage golden, the JSON schema) are now buildable:
  `TLA.Coverage` exists and `mix tla.check --format json` emits structured output.
- **#7 / `pm-7-access-outside-domain.md`** — `balances[from]` compiles to
  `Access.get/2`, so `f[x]` outside the domain is `nil`, and `nil >= amount` is
  silently `true` under Erlang term order. TLA+ leaves it undefined. Worth
  deciding before the guard path is exercised harder.
- **#11 / `pm-11-element-typed-collections.md`** — §1.5 cannot type the elements
  of a set or a sequence, so `two_phase_commit`'s `msgs` is `:set` where TLA+
  says `msgs \subseteq Message`. That entry checks a strictly weaker `type_ok`
  than TLC does.

---

## RESUME HERE

1. **Finish the corpus** — `raft_election` (safety only; its liveness is refuted
   by the term bound by design), `bounded_buffer`, `paxos`. Each is a new way for
   the checker to be wrong, and the mechanism for catching that already runs in
   CI. `test/differential/README.md` §Writing an entry has the two things that
   bite: TLC compares strings strictly (use model values for tags), and the
   invariant-name mapping is stated per entry, not guessed.

   Only when all six agree is Phase 1 actually done. The README says so.

2. **Then decide between** Phase 2 (liveness: the edge table, per-state ENABLED
   bits, Tarjan, per-binding fairness, symmetry) and the two open proposals
   above. #7 is the one that could change spec semantics, so deciding it earlier
   costs less.

3. **`bin/tlc-expected --check`** is the oracle gate. Run it after touching any
   corpus entry; CI runs it on every pipeline.

---

## THINGS THE SPEC GOT WRONG, NOW FIXED IN IT

Recorded here because they are the pattern to expect from the remaining phases —
the design was settled at the level of syntax and API surface, and the level
below that is where it gave way.

- `__using__` cannot register attributes from inside its `quote`: Elixir 1.20
  expands a whole `defmodule` body before evaluating any of it.
- Nothing could see the constants — guards, transitions and predicates all take
  them now.
- `param_sources` did not exist, so §7's "fairness over a state-drawn param"
  diagnostic was unimplementable.
- The block macros' documented signature does not parse.
- `TLA.Trace.generate/2` could not generate anything as typed.
- §1.5 had no way to say "an integer", so §8's own `balances` type was
  unsatisfiable — the implicit `type_ok` refuted the worked example.
- Coverage cannot be computed from the finished graph, because the graph
  deliberately retains nothing to compute it from.
