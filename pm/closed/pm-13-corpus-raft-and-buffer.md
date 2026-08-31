---
id: pm-13
title: "Corpus: raft_election and bounded_buffer, and the two bugs raft_election found"
labels: [In-Progress]
created: 2026-08-31
gitlab_issue: 13
gitlab_synced: true
---

## Scope

Two more differential entries, taking the D-9 acceptance corpus from three of six to
five of six.

| Entry | Distinct states | Depth | What it adds |
|---|---|---|---|
| `raft_election` | 58,359 | 19 | Params drawn from the **pre-state** — "pick a message from the network" — and the first entry that ends somewhere |
| `bounded_buffer` | 4,460 | 29 | A **sequence** in state, where order matters and a set-shaped fingerprint would collapse states |

Both agree with TLC exactly on every field the corpus compares.

## Why these two

`raft_election` is the first entry whose params are a function of the state rather than
a constant. That is a different way for successor generation to be wrong: the set a
param ranges over changes from state to state, so a generator that read the post-state,
or filtered on the wrong bound param, still produces plausible successors — just not
these ones. 58,359 states is a large enough space that being wrong by a little is
invisible in every way except the count.

`bounded_buffer` puts a sequence in state. `distributed_lock` showed that a fingerprint
must not flatten a tuple; this shows it must not canonicalise a list the way it
canonicalises a set, because `<<a, b>>` and `<<b, a>>` are two states and `{a, b}` is
one.

Both also **end**. That is new, and it is the part of the comparison that needed
building out.

## What `raft_election` found

Two bugs, both in `spec/07-examples.md` Example 2 — this repository's own documentation,
not a paraphrase of it. That is the corpus doing the job it exists for.

**1. The headline safety property was false.** `election_safety` — "at most one leader
per term, Raft's fundamental property" — is violated in 8 states. `handle_vote_response`
did not check the term of the response, so a candidate that timed out twice counted a
vote granted in the *earlier* term towards its current candidacy:

```
s1 times out (term 1), s2 grants; s1 times out again (term 2);
s1 counts s2's TERM-1 grant and reaches leader at term 2;
meanwhile s2 wins term 2 legitimately with s3's vote.
```

Real Raft drops a response whose term is not the current one. The example now does too:
`require msg.term == current_term[s]`.

**2. The `terminal` predicate admitted nothing.** It said the network was empty
(`size(messages) == 0`), and no reachable end state satisfies that. Nothing ever removes
a refusal, a grant to a server that has stopped being a candidate, or a grant for a term
the recipient has moved past — so all 655 end states were reported as deadlocks. The
predicate now says what it meant: every server at the term bound, and nothing left that
anyone can act on.

Both are the pattern the previous handoff named: the design was settled at the level of
syntax and API surface, and the level below that is where it gave way.

## Two changes outside the entries

**`bin/tlc-expected` takes two passes when a spec ends.** `-continue` keeps an invariant
violation from ending TLC's search, but a reached deadlock ends it regardless, leaving
states on the queue. `bounded_buffer` reports 4,459 states and depth 28 that way, and
4,460 / 29 when the search is allowed to finish. So `deadlock` is taken from the first
pass and the counts and invariant verdicts from a second one with `-deadlock`, which is
the only pass that searched everything. Entries that do not deadlock still take one run.

**The corpus tests compare where the search *stops*, not whether TLC deadlocked.** TLC
calls any state with no successors a deadlock; ExTLA reports one only where no `terminal`
admits it (§5.3). Comparing the two booleans directly would fail every entry with a
legitimate end state. What is compared instead is that both sides stopped somewhere, and
a spec that declares a terminal is then held to both halves of its claim:

- too narrow — a stuck state no terminal admits is still a deadlock, and the run fails
- too broad — a terminal admitting a state that has successors comes back as
  `terminal_but_live` in the coverage report

That pair is what caught bug 2 above, and it is a stronger check than the boolean
equality it replaces.

## One test-suite change

The corpus is now big enough that running the same search once per assertion is minutes
of nothing, so each entry became its own ExUnit module (`TLA.DifferentialCase`) with a
`setup_all` that searches once — `setup_all` cannot live inside a `describe`, and
separate modules let ExUnit run the entries concurrently. The invariants TLC says hold
are now checked in a single run rather than one run each. 313 tests, 46s.

## Next

`paxos`, the last entry. Only then is Phase 1 done, and the README says so.

## Related

`[[pm-12-corpus-two-more-entries]]`, `[[pm-11-element-typed-collections]]` — this entry
adds two more variables (`messages`, `buffer`) that §1.5 can only type as `:set` and
`:seq` where TLA+ types their elements.
