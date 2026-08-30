---
id: pm-6
title: "The specification DSL: TLA.Spec, TLA.Spec.DSL, TLA.Spec.Compiled, and the §7 validator"
labels: [In-Progress]
created: 2026-08-30
gitlab_issue: 6
gitlab_synced: true
---

## Scope

The genuinely unproven part of the design (`spec/06-architecture.md` §Phase 1):
whether the DSL of `02-dsl-semantics.md` can be compiled and checked at all. It can.

- `TLA.Spec` — `use`, and the `@before_compile` that assembles the compiled struct
- `TLA.Spec.DSL` — `constant`, `variable`, `init`, `action`, `invariant`,
  `action_property`, `terminal`, `temporal`, `fairness`
- `TLA.Spec.Compiled` — the struct the model checker will operate on
- `TLA.Spec.Rewriter` — the three name classes of §1
- `TLA.Spec.Block` — §2's simultaneous-assignment semantics
- `TLA.Spec.Params` — §3's single nondeterminism mechanism
- `TLA.Spec.Temporal` — §5.1's bounded fragment
- `TLA.Spec.Type` — §1.5's type grammar
- `TLA.Spec.CompileError` — the §7 diagnostics

## Four things the spec got wrong, found by building it

**1. `__using__` cannot register attributes from inside its `quote`.** Elixir 1.20
expands an entire `defmodule` body before evaluating any of it, so an attribute
written by *generated* code is invisible to the expansion of a later macro. But
`action` has to know, while it expands, which names are declared variables — that is
the whole basis of §1's name resolution. The fix is to accumulate at expansion time:
`__using__` calls `Module.register_attribute/3` on `__CALLER__.module` in its macro
body, and every DSL macro calls `Module.put_attribute/3` in its body rather than
emitting `@tla_...`. Verified by probe before rewriting anything.

**2. Nothing could see the constants.** `init_fn` and the param generators took the
constant assignments; guards, transitions, invariants, action properties, terminals
and temporal predicates did not. Yet §1.1 lets any block reference `^constants`, and
the worked example's own `conservation_of_money` compares against `^max_balance`.
Every compiled function now takes `constants` as its first argument. The alternative
— putting constants in the state — would fingerprint a value that never changes and
inflate the state space for nothing.

**3. `param_sources` did not exist.** §7 requires the diagnostic "fairness over a
state-drawn param", and §5.2 requires the same distinction to expand per-binding
fairness once the constants are known. Neither is possible from `action_def` as it
was typed. Each action now records `[{param, :constant | :literal | :state}]`.

**4. The block macros' signature does not parse.** `defmacro action(name, opts \\ [],
do: block)` cannot be called as `action :x, params: [...] do ... end`: with `do…end`
block syntax the block arrives as a *third* argument, and a `do: block` parameter
pattern matches only the inline `do:` form. Every block macro takes
`(name, opts \\ [], block)` and merges the two, so both call shapes work.

Also: `temporal_def.formula` is a **function of the constants**, not a value — a
`for_all` ranges over a constant set, and every predicate inside it may mention
`^constants`.

## Ten diagnostics beyond §7's table

Written into §7 alongside the originals: `already declared`, `init does not assign`,
`no init block`, `require in init`, `unexpected statement`, `param shadows a
variable`, `constant referenced without ^`, `temporal block is not a single formula`,
plus the `let`-shadowing and duplicate-name cases §1.3 implied but §7 did not list.

`constant referenced without ^` earns its own message rather than falling through to
`undeclared variable`: it is the likeliest typo in the whole DSL.

## The one design call inside the implementation

Locals are **over-approximated**. `bound_names/1` collects every name bound anywhere
in a block — `let` patterns, `fn` arguments, comprehension generators, `case` clause
heads — ignoring scope, and a read of a name in that set is left alone.

Over-approximating is the deliberate direction to be wrong in. Missing a binding
would turn working Elixir into a spurious "undeclared variable"; including one too
many only means a genuine typo is reported by Elixir's own compiler instead of by
ours. The first is a regression, the second is a slightly worse message.

## Verification

188 tests, 35 doctests. The three that matter most:

- **`action :swap do x = y; y = x end` swaps.** §2's rule, and the one most likely
  to surprise an Elixir programmer. Every RHS reads the pre-state, each assignment
  lands in its own temporary, and the post-state is one `Map.merge/2`, so there is no
  intermediate state for the second line to observe.
- **`conservation_of_money` is refuted by `fail_transfer`,** exactly as §8 says it
  should be. If that test ever passes, either the worked example or the DSL has
  stopped meaning what it said.
- **35 diagnostics tests**, one per §7 row plus the additions, each asserting not
  only that the spec is rejected but that the message says something an author can
  act on. §7 calls message quality "a deliverable, not a nicety"; that is only true
  if it is tested.

## Found, not fixed here

`balances[from]` compiles to `Access.get/2`, which returns `nil` outside the domain —
and `nil >= amount` is a silent `false` in Elixir rather than an error. In TLA+ `f[x]`
with `x ∉ DOMAIN f` is undefined. This is the silent-wrongness class the project
rejects everywhere else, but making `[]` strict is a semantic decision with its own
edge cases (TLA+ sequences are 1-indexed, so `seq[i]` is not `Access.get` either).
Filed as its own proposal rather than decided in passing.

## Next

The model checker: `TLA.StateGraph` with the parent-pointer model, single-threaded
BFS, `TLA.ModelChecker.Safety` including `terminal` states and the implicit
`type_ok` invariant — checked against `die_hard`'s `expected.json` from the first
commit.
