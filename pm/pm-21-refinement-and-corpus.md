---
id: pm-21
title: "Phase 3, slice 1: TLA.Refinement, and the conformance corpus it is measured on"
labels: [In-Progress]
created: 2026-08-31
gitlab_issue: 21
gitlab_synced: true
---

## Two decisions taken, since the phase could not start without them

**Constants at runtime.** `use TLA.GenServer, spec:, refinement:` names no constants, but
every guard, invariant and transition is `(constants, state, …)`. They resolve the way
`mix tla.check` already resolves them: a `constants:` option on `use`, else
`config :extla, MySpec, constants: %{…}`, else the `default:` beside each declaration.
One rule, already documented, already used.

**Phase 3's acceptance criterion.** Phases 1 and 2 were measured against TLC. There is no
TLC for "does this GenServer refine this spec", so Phase 3 gets a **conformance corpus**:
for each entry, a specification, an implementation that conforms, and deliberately wrong
twins that must each be **caught and named correctly**. An entry that must fail is what
distinguishes a working checker from one that says yes to everything — the same argument
that made `raft_election`'s `eventually_elect_leader` the row worth having.

It is weaker than D-9 and the difference is worth stating: TLC *measured* the expected
answers, while the mutants' expected verdicts are **authored**. What the corpus still
buys is that every one of them must fail, and fail for the stated reason.

The first entry is `07-examples.md` Example 4, verbatim — spec, implementation, the
deliberate step bug and the diagnostic it should produce are all already written there.
The corpus checks the documentation rather than a paraphrase of it, which is the rule the
differential corpus was built by.

## Phase 3 — the plan

**Slice 1 — `TLA.Refinement` and the corpus (this one).** The behaviour, `validate!/2`,
and the corpus scaffolding with the mutants `validate!/2` can already reject.

**Slice 2 — Layer 1: `TLA.Invariant`.** The callback-wrapping engine — `defoverridable`
and `super`, `:disabled` emitting nothing, `TLA.Invariant.Violation`, telemetry. Layer 3
wraps callbacks the same way and `use TLA.GenServer` does `use TLA.Invariant`, so this is
the shared machinery and it comes first.

**Slice 3 — Layer 3 core: `TLA.GenServer` and `TLA.GenServer.Runtime`.** Step legality,
stuttering, invariants, action properties, the bounded per-process trace. Every runtime
mutant in the corpus must be caught here, and named `:not_enabled`, `:diverged` or
`:unmapped_but_moved` correctly.

**Slice 4 — `TLA.Replay`.** The phase's stated deliverable: a spec, a counterexample from
the model checker, and that counterexample driven through the real GenServer.

**Slice 5 — `TLA.Simulation` and the mix tasks.** Random walks over the implementation,
`check_temporal_properties/2` over the accumulated trace, `mix tla.simulate` and
`mix tla.replay`.

## Scope of this slice

`TLA.Refinement`: the three callbacks, and `validate!/2` over §05's five rules.

**What `validate!/2` can and cannot establish, stated rather than implied.** §05 lists
five rules; three are decidable where it runs and two are not, and a validator that
claims a check it cannot perform is the failure this project keeps refusing:

| Rule | Where |
|---|---|
| `abstract/1` returns exactly the spec's variables | Runtime — there is no concrete state at compile time to map |
| every value is a permitted state term (§6) | Runtime, same reason |
| `abstract_action/1` is total | Compile time, by **probe**: an improbable term must not raise |
| `concrete_message/2` round-trips modulo partial params | Compile time, where the constants are known |
| every spec action is named by some clause | Compile time **only when `concrete_message/2` is defined** — otherwise there is nothing to enumerate clauses with |

The two runtime rules are checked on every mapping by `abstract!/2`, which is a
`Map.keys` comparison and cheaper than the invariants beside it.

## Acceptance

- `validate!/2` accepts the corpus's conforming refinement and rejects each mapping
  mutant, naming what is wrong.
- A probe of a non-total `abstract_action/1` is reported as non-total, not as a crash.
- `abstract!/2` names the missing or extra variable rather than failing later.
- The corpus records every mutant and the verdict it must produce, including the ones
  slice 3 will check.

## As built

**Two rules turned out to be three-and-a-half.** §05's rule 5 — every spec action is
named by some clause — is decidable only where `concrete_message/2` exists to enumerate
actions with. Without it there is nothing to introspect: Elixir does not hand back a
function's clauses. So it joins the deferred list, and `TLA.Coverage`'s account of what a
run never exercised is where "this action never happened" belongs anyway.
`validate!/3` returns the deferred list rather than returning `:ok` and letting the caller
assume everything was checked.

**Totality is a probe, not a proof,** and the docstring says so. A mapping with no
catch-all is called with a term no implementation would match; if it raises, that is the
report. It cannot be exhaustive and it catches the case that actually happens, which is
somebody forgetting the clause entirely.

**Rule order is a diagnostic decision.** `ActionNeverNamed` was first caught by the
round-trip rule, which reported "reset does not round-trip … maps to `:unmapped`". True,
and worse than "names no message for `[:reset]`" — the same fault, described further from
its cause. `names_every_action!/3` now runs first and the round-trip rule leaves
`:unmapped` alone.

**The sixth mutant does not `use TLA.Refinement`,** because with the behaviour declared
the compiler already warns about a missing callback — loudly enough that `warnings-as-errors`
would not let it compile. What is left for `validate!/3` to catch is a module handed to
`refinement:` that never claimed to be a mapping at all.

**The entry checks its own specification.** A conformance corpus is only worth having if
the spec half is right, so the entry asserts what `mix tla.check` would: `Specs.Counter`
verifies, liveness included, over 11 states.

## Related

`05-layer3-conformance.md` §`TLA.Refinement`, `07-examples.md` Example 4,
`08-decisions.md` D-17 (the same shape of obligation).
