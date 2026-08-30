---
id: pm-5
title: "TLA.Spec.Helpers — the vocabulary available inside spec blocks"
labels: [In-Progress]
created: 2026-08-30
gitlab_issue: 5
gitlab_synced: true
---

## Scope

`TLA.Spec.Helpers` (`spec/04-layer2-model-checker.md` §Helper Functions Available in
DSL Blocks): the set, sequence, function and arithmetic vocabulary that `use TLA.Spec`
imports into `action`, `init`, `invariant`, `terminal` and `action_property` blocks.

Landed on its own, ahead of the DSL, because every DSL block will be written against
it and because it is the one part of the DSL layer that can be tested without a macro
in sight. It also fixes what the DSL's blocks are allowed to call before the macro
that rejects everything else exists.

## The constraint these all share

An action body must be a pure deterministic function of `(pre_state, params)`
(`02-dsl-semantics.md` §3) — it is the property successor generation, symmetry
canonicalization and Layer 3's refinement check all rest on. So every helper is a
thin, total, deterministic wrapper: nothing here branches the search, reads the clock,
or depends on anything but its arguments. They buy readability, not capability;
`len(buffer)` reads as the TLA+ it translates, and an author who writes `length/1`
directly gets the same answer.

`choose/2` is `defdelegate` to `TLA.Set.choose/2` rather than a second
implementation. There is one `CHOOSE` in ExTLA, it is deterministic, and a second
copy here that happened to branch would reintroduce exactly the nondeterminism
mechanism §3 removed.

## Verification

126 tests overall, 35 doctests. Two carry more than their weight:

- **`subseq/3` is 1-indexed and inclusive at both ends.** TLA+ sequences are
  1-indexed and Elixir's are 0-indexed, and an off-by-one here is silent: the result
  is still a valid sequence, nothing raises, and the spec simply says something other
  than what its author wrote.
- **`put`/`delete` commute.** A set is unordered, so the fingerprint must see one
  state wherever a spec author sees one state.

`head/1` and `tail/1` raise on the empty sequence, where TLA+ leaves `Head` and `Tail`
undefined. Their `@spec`s say `nonempty_list()`, so the tests call them through
`apply/3` — Elixir 1.20's type checker is right to flag a direct call as outside the
declared domain, and the test is asserting what happens when a spec goes there anyway.

## Next

The DSL itself: `TLA.Spec`, `TLA.Spec.DSL`, `TLA.Spec.Compiled`, and the compile-time
validator of `02-dsl-semantics.md` §7.
