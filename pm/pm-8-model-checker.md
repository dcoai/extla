---
id: pm-8
title: "The model checker: StateGraph, BFS, safety, traces — and die_hard agreeing with TLC"
labels: [In-Progress]
created: 2026-08-30
gitlab_issue: 8
gitlab_synced: true
---

## Scope

The checker itself: `TLA.StateGraph` (parent-pointer model), single-threaded
breadth-first `TLA.ModelChecker`, `TLA.ModelChecker.Safety`, `TLA.Trace` with
replay-based state regeneration — and `test/differential/die_hard/spec.ex`, which
makes the corpus gate live.

Not here: `TLA.Coverage`, `mix tla.check`, and the implicit `type_ok` invariant.
Each is its own work item; the checker had to exist first.

## The result

ExTLA and TLC agree on `die_hard` in every respect the corpus compares, and in two
more besides:

| | TLC 2.19 | ExTLA |
|---|---|---|
| distinct states | 16 | 16 |
| states generated | 97 | 97 |
| search depth | 8 | 8 |
| deadlock | none | none |
| `TypeOK` | holds | holds |
| `NotSolved` | violated at 7 states | violated at 7 states |

The counterexample is the same six-step trace, action for action: `fill_big`,
`big_to_small`, `empty_small`, `big_to_small`, `fill_big`, `big_to_small`. It is the
solution to the puzzle, which is what makes it checkable by hand.

That agreement existed from the first run of the checker, which is the whole
argument for landing the oracle in pm-2 before writing a line of it.

## Breadth-first is not an implementation detail

An invariant is evaluated when a state is first discovered, so under BFS the first
violation found is at minimal distance from `init` and the trace is the *shortest*
counterexample. Depth-first would report *a* counterexample — a much less useful
thing to hand someone, and one that could not be compared against TLC's.

Determinism follows the same way: actions are taken in declaration order and bindings
in generator order, so the state graph does not vary between runs. A checker whose
graph varied could not be differentially tested at all.

## Three spec gaps, all recorded

**1. `TLA.Trace.generate/2` cannot generate anything.** It was typed as taking the
graph and a state id, but replay needs the compiled spec and the constants — and
neither is reachable from an id. The graph carries them now.

**2. An initial state has to record which `init` produced it.** Several `init` blocks
are disjuncted, so replay has to know which one to run for the root of the path.
`node_record.init_index` carries it.

**3. A trace with only action names cannot print the example output the spec shows.**
`04`'s own trace example prints `begin_transfer(from: alice, to: bob, amount: 3)`, but
`t()` held `actions: [atom()]` and nothing else. Without the binding a reader cannot
tell which of `|accounts|²` transitions the trace took, which is most of what a
counterexample is for. Traces carry `bindings: [map()]` alongside.

Also: the §8 worked example has an **infinite** state space — `complete_transfer`
appends to `log` and `reset` returns to `:idle`. It cannot be checked without a
`state_constraint`, and the run then reports `:constrained` rather than `:ok`. Said in
§8 now rather than discovered by the next reader.

## Two additions

**`config.invariants`** selects which of a spec's invariants a run checks, the way a
TLC `.cfg` selects `INVARIANT`s. The differential test needs it: TLC halts at the
first violation and so does ExTLA, so reproducing TLC's per-invariant report means one
run per invariant — the same shape `bin/tlc-expected` gets from `-continue`.

**`result.diameter`** is the BFS level at which the frontier empties. It is what TLC
calls "the depth of the complete state graph search", and it catches the narrower
failure of a search that stopped early but coincidentally reached the same state count.

## What raises rather than pretending

`check_liveness: true` and `symmetry:` raise with a message naming the phase they
arrive in. Reporting temporal properties as holding over a spanning tree — which has
no cycles, so every liveness property would "hold" — is precisely the silent
unsoundness this project exists to avoid. A spec that declares temporal properties and
is checked for safety gets a warning saying they were not checked.

Likewise, a bounded run never reports plain `:ok`: `:constrained` for a state
constraint, `:max_states_reached` for the limit. A tool that lets a bound quietly
masquerade as a proof is worse than no tool.

## Verification

225 tests. Beyond the differential entry, the ones that carry weight:

- **The shortest counterexample is asserted state by state**, not just by length.
- **A state before the last one never violates the invariant** — the trace is minimal,
  not merely a witness.
- **`StateGraph.successors/2` raises without a liveness graph.** Parent pointers are a
  spanning tree; deriving successors from them would find only trivial SCCs and report
  every liveness property as holding.
- **The node records hold no states** — asserted directly against the ETS table, since
  the memory argument for D-5 is the reason the whole replay mechanism exists.
- **A declared `terminal` is not a deadlock, and deadlock detection stays on
  everywhere else**, which is the difference between `terminal` and
  `check_deadlock: false`.

## Next

`TLA.Coverage` and `mix tla.check`, then the implicit `type_ok` invariant — which
needs the §1.5 type grammar resolved against the constants at check time.
