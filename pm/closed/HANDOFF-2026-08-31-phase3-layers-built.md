# HANDOFF — 2026-08-31 — Layer 1 and the conformance bridge are built; start here

Supersedes `HANDOFF-2026-08-31-phase2-done.md`. Self-contained; read it first.

**Phase 3 is most of the way done.** Layer 1 is complete against its whole specification,
Layer 3's step check is built and measured against the corpus that was written before it,
and what is left is the two things that *drive* an implementation rather than watch it:
replay and simulation.

---

## WHERE THINGS STAND

**Phases 1 and 2 are done on the terms the project set for itself** — the differential
corpus is the acceptance criterion (D-9), and ExTLA agrees with TLC on all six entries:
distinct states, depth, where the search stops, every invariant, every temporal property,
and the shortest counterexample where there is one.

**Phase 3, in four merged MRs:**

- **`TLA.Refinement` and the conformance corpus** (#21). The mapping, `validate!/3`, and
  six mapping mutants that must each be caught and named.
- **Layer 1's GenServer engine** (#22). The four declaration macros, `@on_definition` +
  `defoverridable`/`super` wrapping, `callbacks:` and `enabled:` resolved at compile time,
  `:disabled` emitting nothing at all, and `:verbose` telemetry as a second arity rather
  than a branch.
- **Layer 1 for state machines and Agents, and the ExUnit helpers** (#23). `handle_event/4`
  with the `{state_name, data}` pair as the state (D-24), `TLA.Invariant.Agent` with its
  cost stated rather than hidden (D-25), and `TLA.Invariant.Test` — whose reason to exist
  is `refute_invariant/3`.
- **The conformance bridge** (#24). `TLA.GenServer`, `TLA.GenServer.Runtime.check_step!/5`,
  and the three step mutants the corpus had recorded and could not yet check.

513 tests, all green, ~80s. CI green on `main`: `check` (format / warnings-as-errors /
test) and `verify` (regenerates every `expected.json` from TLC and fails on drift).

**§03 Layer 1 is complete against its own specification.** Every module, every macro,
every behaviour in §Supported OTP Behaviors, and §Testing Integration. That was worth
checking rather than asserting — it is the failure Phase 2's ledger correction was about.

---

## WHAT THE STEP CHECK BOUGHT, IN ONE ROW

`CollapsesTwoSteps` is Example 4's own bug: an `increment` that also does `done`'s work.
**Every invariant of the spec holds in its post-state.** `in_bounds` is satisfied by
`count: 1`. A Layer 3 that checked only invariants and action properties reports
conformance on it. The step check reports `:diverged`, with the one-variable diff
`status: spec :incrementing, implementation :ready`.

The corpus test asserts both halves — the violation, and that the invariants pass — so the
claim is measured rather than argued.

---

## WHAT IS NEXT

**A. `TLA.Replay` (§05 line 367).** Drive the implementation through a model-checker
counterexample, or validate a captured production trace. This is the shortest path to the
pipeline §05 §Full verification pipeline describes, and `concrete_message/2` — already
built and already validated for round-tripping — exists for it.

**B. `TLA.Simulation` and `TLA.Simulation.Generator` (§428), then `mix tla.simulate` and
`mix tla.replay`.** Random walks over the real implementation, with all property types
including temporal — `check_temporal_properties/2` is built and waiting for a trace long
enough to be interesting.

**C. #1, the verification ledger.** Small, still open, and still the last
"measured, not asserted" gap: the coverage report is not drift-gated the way
`expected.json` is.

**D. Phase 4's parallel exploration.** Unchanged from the last handoff: the cheapest large
factor left after symmetry, and nothing in the corpus says the state-space wall is being
hit yet.

Recommendation: **A, then B.** They are the same subsystem approached from two ends, and
together they turn Layer 3 from "checks what happens to run" into "runs the thing the spec
says should happen".

---

## HOW THE WORK IS RUN

```bash
glab issue list                                    # the queue
glab issue create --label In-Progress --title …    # one pm/ file per issue, mirrored
git checkout -b feat/<slice>
mix format && mix compile --warnings-as-errors && mix test && bin/tlc-expected --check
glab mr create --source-branch <branch> --target-branch main --title … --yes
until … glab ci status --branch <branch> --live=false …                 # wait for green
glab mr merge <n> --yes --remove-source-branch && glab issue close <n>
```

`pm/` mirrors the GitLab issues; a closed one moves to `pm/closed/`.

---

## THINGS THAT WILL BITE

- **Do not emit a `case` on a tagged return into a user's module.** Elixir's type system
  proves things *inside* that module, so `case Runtime.initial_state(super(arg))` has a
  provably dead arm — and the warning names the user's module, about code they did not
  write. Three constructs hit this (Layer 1's `init/1`, Layer 3's `init/1`, and the
  dispatch on `abstract_action/1`); all three now live behind a function taking `term()`
  or `module()`. Recorded in §03 and §05.
- **`Application.compile_env/3` does not expand inside a function body.** This is why
  `TLA.Invariant.Agent`'s entry points are functions and not macros, and why `:disabled`
  costs an export lookup there (D-25). Anything that wants the mode at a *call site* hits
  this wall.
- **A state machine's state is the pair, everywhere** (D-24). `{state_name, data}` in the
  invariant, in the action property, and out of `init/1`. `:gen_statem`'s returns need
  their own extraction: `{:stop, reason, data}` and a GenServer's `{:stop, reason, state}`
  are the same shape carrying different things.
- **`params` from `abstract_action/1` may be partial, and that is not leniency.** The
  implementation resolves the spec's nondeterminism itself. Every binding extending the
  given ones is a candidate; the step is legal if an *enabled* one reproduces the
  post-state. Narrowing this to exact bindings would make `validate!/3`'s round-trip rule
  unsatisfiable.
- **A mapping fault is not a conformance failure.** An unknown action name, or a param the
  action does not take, raises `ArgumentError` — reporting them as `:not_enabled` blames
  the implementation for a mistake in the mapping.
- **Constants are resolved once, in `Spec.Compiled.resolve_constants/1`.** A spec model
  checked under one assignment and an implementation checked against another are two
  different specifications.
- **A liveness verdict still needs a complete graph** (unchanged): `Liveness.check/3`
  raises rather than answer from a partial edge table. And a Layer 3 trace has no lasso, so
  the temporal properties needing one are `:inconclusive` by construction.

---

## OPEN ISSUES

- **#1 / `pm-1-verification-ledger.md`** — drift-gated coverage golden and spec-version
  stamps. Buildable now.
- **#16 / `pm-16-solver-guided-pruning.md`** — `Research`. Whether an SMT solver could
  prune the search, and why the parts worth doing first are diagnostics rather than
  pruning.
