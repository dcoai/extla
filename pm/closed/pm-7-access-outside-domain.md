---
id: pm-7
title: "`f[x]` outside the domain is silently nil, where TLA+ leaves it undefined"
labels: [In-Progress]
created: 2026-08-30
gitlab_issue: 7
gitlab_synced: true
---

## Problem

Found while building the DSL (pm-6). The worked example of `02-dsl-semantics.md` §8
contains:

```elixir
require balances[from] >= amount
```

`balances[from]` compiles to `Access.get/2`, which returns `nil` for a key outside the
map. `nil >= amount` does not raise: Erlang's term order makes every comparison
between different types total, and `nil` (an atom) sorts above every integer, so
`nil >= 2` is **`true`**.

In TLA+, `f[x]` where `x ∉ DOMAIN f` is undefined, and TLC reports it. Here the guard
quietly succeeds, the action fires from a state it should not have been enabled in,
and the checker explores a state space that the spec does not describe — reporting
success over it.

This is the same failure class the project has already ruled out twice, and for the
same stated reason:

- `TLA.State.get/2` and `prime/3` raise rather than defaulting
  (`01-foundation.md` §Reading a variable that is not there)
- `TLA.Function.except/2` raises rather than extending the domain
- `TLA.Fingerprint` uses SHA-256 rather than `phash2` because a dropped state is
  reported as a pass

`[]` is the one remaining hole, and it is in the syntax the worked example uses.

## Why it was not fixed in pm-6

Because the fix has a real decision inside it, and making it in passing would have
been worse than naming it.

The obvious move — rewrite `expr[key]` to a strict fetch when `expr` is a declared
variable — is wrong as stated. TLA+ applies `[]` to two different things:

| Term | TLA+ meaning | Strict form |
|---|---|---|
| A function (map) | `f[x]`, `x ∈ DOMAIN f` | `Map.fetch!/2` |
| A sequence (list) | `s[i]`, **1-indexed**, `i ∈ 1..Len(s)` | `Enum.fetch!(s, i - 1)` |

So a single rewrite has to dispatch on the runtime type of the collection, and the
sequence case has an off-by-one that is silent if it is wrong — the same class of bug
`TLA.Spec.Helpers.subseq/3` already has a test pinning.

There is also a scope question. `[]` inside a `params:` generator applies to the raw
state map (`s.pending`), and inside an `action_property` to `old.`/`new.` maps. A
rewrite that covers spec variables but not those two is a rule with exceptions, which
is worse than no rule.

## Options

1. **A strict `at/2` helper**, `at(balances, from)`, dispatching on map vs list and
   raising outside the domain — and `[]` on a spec variable becomes a compile error
   naming it. Explicit, no runtime magic, but it changes §8's worked example and
   every example in `07-examples.md`.
2. **Rewrite `[]` on any spec-variable read** to a strict runtime dispatch, leaving
   `[]` on locals and on `old.`/`new.` alone. Keeps the examples as written; the rule
   has the exception described above.
3. **Rewrite `[]` everywhere inside a spec block**, including on locals. One rule, no
   exceptions, but a local holding an ordinary keyword list would start raising.
4. **Leave it, and catch it in the type invariant.** `type_ok` would flag a state
   where a function's domain is wrong — but not a *guard* that read outside the
   domain and enabled an action, which is the actual failure here.

Option 4 does not close the hole. Between 1 and 2, 2 keeps the documents honest and 1
keeps the language simple.

## Acceptance

Whichever is chosen, the corpus is the test: a spec whose guard reads outside a
function's domain must be rejected or must raise, and `die_hard` and the `07-examples`
specs must still agree with TLC. This lands before the guard evaluation path is
exercised in anger by the model checker, so it is worth deciding early.

## Decision — option 3, the rule without exceptions

**Taken: `[]` is TLA+ function application everywhere inside a spec block.** It compiles
to `TLA.Spec.Helpers.at/3`, which raises `TLA.Spec.DomainError` outside the domain — for
a map, for a sequence (1-indexed), and for a term that is neither. Written up as D-20 and
`02-dsl-semantics.md` §1.6.

Option 2 — strict on spec variables, lax on `old.`/`new.` and on a generator's state
argument — was rejected on inspection of where the hole would then remain. Those two are
exactly the places where a spec reaches into a collection it did not build: `old.owner[r]`
and `st.current_term[s]` are reads of a state the block did not construct, which is where
a key that is not there is *most* likely and least visible. A rule with exceptions is
also one an author has to remember the shape of, and this one's exceptions would have had
no principle behind them beyond "harder to implement".

Option 1 (`at/2` as an explicit helper, `[]` a compile error) was rejected for what it
costs the documents: every `pc[p]` in `07-examples.md` and §8 would become `at(pc, p)`,
which is a worse-reading spec in exchange for the same guarantee.

The cost of option 3, stated: a keyword list indexed by its key raises inside a block,
because a list is a sequence and `:mode` is not an index. In a spec that is the right
answer — state is maps and sequences.

## What it took

- `TLA.Spec.Helpers.at/2,3` and `TLA.Spec.DomainError`, whose message names the
  expression as the spec wrote it (`balances[:carol]`) and the domain it is not in.
  `Map.fetch!/2` cannot do that, which is why this is not a one-line delegation.
- One clause in `TLA.Spec.Rewriter`, intercepting the `Access.get` node before the
  generic walk and carrying `Macro.to_string(collection)` along for the message.
- Nothing else. **All six corpus entries still agree with TLC exactly**, which is the
  acceptance this proposal asked for: no spec was relying on the `nil`, and the state
  counts are unchanged.

## Related

`[[pm-6-spec-dsl]]`, `01-foundation.md` §Reading a variable that is not there,
`02-dsl-semantics.md` §1.6 and §8, `08-decisions.md` D-20.
