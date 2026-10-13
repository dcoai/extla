# Differential corpus

The Phase 1 acceptance gate (`spec/04-layer2-model-checker.md` §Differential testing,
`spec/08-decisions.md` D-9): for every entry, ExTLA and TLC must agree on

1. the number of distinct reachable states,
2. whether each invariant holds, and
3. the length of the shortest counterexample where one exists.

The corpus also records TLC's verdict on every **temporal** property — `holds` or
`violated` — and since Phase 2's `check_liveness: true`, ExTLA is compared against those
too. The oracle landed a slice before the checker did, for the reason the corpus itself
came before the checker: a liveness answer with nothing to compare it against is a claim
rather than a measurement.

## Results

What the corpus has measured so far, against TLC.

The acceptance criterion is not "the tests pass" but [D-9](../../spec/08-decisions.md): the
checker must agree with TLC on **every** spec in the differential corpus. It does, on
all seven — distinct states, search depth, where the search stops, every invariant, every
temporal property, every action property, and for `die_hard` the shortest counterexample,
which is the same six-step trace action for action.

| Entry | Distinct states | Depth | Agreement |
|---|---|---|---|
| `die_hard` | 16 | 8 | ✅ including the counterexample |
| `two_phase_commit` | 288 | 11 | ✅ |
| `distributed_lock` | 34 | 7 | ✅ |
| `raft_election` | 58,359 | 19 | ✅ including where it ends |
| `bounded_buffer` | 4,460 | 29 | ✅ including where it ends |
| `paxos` | 3,921 | 17 | ✅ |
| `audit_log` | 3 | 3 | ✅ including the counterexample |

`audit_log` is three states and is not there to be an interesting system. It is the
corpus's only entry whose subject is a **declaration kind** rather than an algorithm:
`action_property` — a predicate over a *step*, which TLC checks as a `PROPERTY` and not
as an `INVARIANT` — was the one Layer 2 feature the oracle had never been shown, which
is how #112 lived for as long as the feature had. Its `compact` action empties the log,
so the offending step's post-state *is* the initial state; a checker that builds the
counterexample from the wrong end of the step therefore returns a different **length**
rather than merely a different path, and D-9's comparison can see it. Reintroducing #112
on this entry turns a passing suite into `ExTLA returned 1 states` against TLC's 4, while
all six other entries stay green.

These are measurements, not assertions: `expected.json` is TLC's own output, CI
regenerates it from TLC on every pipeline, and a corpus entry that drifts fails the
build. The oracle landed before the checker precisely so this column could be measured
rather than assumed.

The corpus also records TLC's verdict on each entry's **temporal** properties, and
`check_liveness: true` now agrees with all seven — including the one that matters:
`raft_election`'s `eventually_elect_leader` comes back *violated*, refuted by the model's
term bound by design, with a seven-state prefix that ends in the split vote and stutters
there forever. That row is what distinguishes a working liveness checker from one that
answers "holds" to everything.

| Entry | Property | TLC | ExTLA |
|---|---|---|---|
| `distributed_lock` | `no_starvation`, `lock_eventually_released` | holds | holds |
| `bounded_buffer` | all four | holds | holds |
| `raft_election` | `eventually_elect_leader` | **violated** | **violated** |

`no_starvation` holds only under *per-binding* strong fairness — `\A p : SF(Acquire(p))`,
not `SF(\E p : Acquire(p))`. The same spec with weak fairness is refuted, with p1 waiting
while p2 takes the lock and gives it back forever.

**Symmetry reduction** collapses states that differ only by a permutation of an
interchangeable constant. `mix run bench/symmetry.exs`:

| Model | States | Time |
|---|---|---|
| `raft_election`, 3 servers | 58,359 → 9,871 | 23.3s → 6.6s |
| `distributed_lock`, 3 processes and 2 resources | 184 → 26 | 11ms → 6ms |

Nothing can establish that a `symmetry:` declaration is sound — a constant flows into
arbitrary Elixir, so the check is undecidable, and it is the author's obligation
([D-17](../../spec/08-decisions.md)). `verify_symmetry: true` is what makes a wrong one
*detectable*: it runs the model both ways and fails if any verdict differs. Both models
above pass it.

The corpus paid for itself along the way. `raft_election` is
[Example 2](../../spec/07-examples.md) of this repository's own documentation, and TLC refuted
its headline safety property — a candidate that timed out twice counted a vote granted
in the *earlier* term, and two servers reached `leader` in the same term. The example
now carries the term check that Raft has and it did not. Writing the entries also found
six gaps in the DSL and the harness, each fixed where it was found — most recently that
four entries were typing a variable *weaker* than the TLA+ they are checked against, and
that `f[x]` outside a function's domain was `nil` rather than an error.

**Phase 3** added Layer 1 invariants on running processes and the Layer 3 conformance
bridge — `ExTLA.GenServer`, `ExTLA.Refinement`, `mix extla.simulate` and `mix extla.replay`.
**Phase 4** added parallel exploration (**5.40x at 8 workers**; `raft_election` went from
23.4 s to 1.65 s, with the corpus agreeing with TLC at 1, 2, 4 and 8), `ExTLA.PropertyTest`,
and `mix extla.visualize`.

## Layout

```
test/differential/<name>/
  <Name>.tla          the TLA+ spec, as TLC checks it
  <Name>.cfg          TLC config: CONSTANTS, INVARIANTS, PROPERTIES, SYMMETRY
  spec.ex             the same model in the ExTLA DSL
  expected.json       what TLC reported — generated by bin/tlc-expected, never hand-edited
```

`expected.json` is the oracle, so it is machine-written and machine-checked. A human
editing it to make a test pass would be editing the definition of "correct", which is
why CI regenerates it from TLC on every pipeline and fails on any difference.

```json
{
  "generated_by": "bin/tlc-expected",
  "tla_tools_version": "v1.7.4",
  "tlc_version": "2.19",
  "module": "DieHard",
  "constants": {},
  "distinct_states": 16,
  "diameter": 8,
  "deadlock": false,
  "invariants": {
    "TypeOK": "holds",
    "NotSolved": {"violated_at": 7}
  },
  "properties": {}
}
```

| Field | Meaning |
|---|---|
| `distinct_states` | Distinct reachable states in the complete search |
| `diameter` | Depth of the complete state graph search — the BFS level at which the frontier empties |
| `deadlock` | Whether TLC reached a state with no successors. A `terminal` declaration (`spec/02-dsl-semantics.md` §5.3) is how ExTLA accepts one of these on purpose |
| `invariants` | `"holds"`, or `{"violated_at": n}` where `n` is the number of states in the shortest counterexample — 7 states is a 6-step trace |
| `properties` | `"holds"` or `"violated"`, per temporal property, under the fairness the module's `Spec` conjoins |

`raft_election`'s `EventuallyElectLeader` is the row worth having. A liveness checker
that reports everything as holding agrees with every other row in this file, and only
that one tells it apart from a working one.

The verdict on a property is that one word and nothing more. TLC's counterexample is a
lasso, and a lasso is not canonical the way a breadth-first shortest counterexample is —
two correct checkers can hand back different cycles for the same violated property. A
fixture the checker cannot be expected to match would be worse than no fixture, so the
shape of the lasso is left out of `expected.json`.

**It is not left unchecked.** A fixture is not the only way to check a counterexample, and
for a lasso it is the wrong way. What the corpus does instead needs no oracle at all,
because a counterexample is a claim about the *spec* and the spec is right here:

- **`ExTLA.Trace.validate/3`** — every counterexample the corpus produces, safety and
  liveness alike, is checked to be a behaviour the spec admits: it starts at a state an
  `init` block produces, every step names an action enabled there *with that binding*, and
  every step's post-state is what that action's transition actually returns. Before this
  existed, a counterexample with real states, real actions and a fabricated pairing between
  them passed every gate the project had.
- **`ExTLA.TemporalCheck`** — the property is evaluated over the behaviour directly, with
  `ExTLA.Temporal`'s operators, which share no code with `ExTLA.ModelChecker.Liveness`. A
  lasso the checker calls a counterexample must come back `:violated`, and its cycle must
  satisfy every fairness constraint the spec declares — otherwise the checker has handed
  back a behaviour the spec's own assumptions forbid.

So the lasso is checked against the spec rather than against TLC, which is stronger for
this particular thing: TLC's agreement would only say the two tools found *a* cycle, and
this says the cycle handed back is real.

A disagreement on `distinct_states` is the most valuable signal the project has: it
means successor generation or state identity is wrong. `diameter` catches the narrower
failure of a search that terminated early but happened to reach the same count.

## The passes

An entry takes one TLC run for safety and one more per temporal property, because
`-continue` covers neither of the two other ways a run can stop early.

**A deadlock ends the search regardless.** `bin/tlc-expected` takes `deadlock` from the
first run and, when there was one, re-runs with `-deadlock` to get the counts and the
invariant verdicts from a search that actually finished. `bounded_buffer` differs by one
state and one level of depth between the two passes, which is exactly how much of the
state space a first-deadlock stop can hide.

**A temporal violation ends it too.** TLC checks temporal properties *during* the search
and stops at the first one it refutes, wherever the search has got to — two runs of
`raft_election` stopped at 20,253 and 20,291 distinct states. So the safety pass runs
from a derived `.cfg` with the `PROPERTIES` section removed, which is what keeps
`distinct_states` and `diameter` reproducible. Fairness constrains behaviours and not
reachable states, so adding the fairness conjuncts moved neither number in any entry.

**And TLC names no property when one fails.** It reports `Temporal properties were
violated` and hands back a behaviour, so a run checking several of them cannot say which
one it refuted — hence one derived `.cfg` and one run per property. Those runs drop the
`INVARIANTS` too: TLC halts on a violated invariant before it reaches the liveness check,
and `die_hard` has one on purpose.

The derived `.cfg`s are written to a temporary directory rather than beside the module,
so nothing a later run could pick up is left behind. The committed `.cfg` stays the
declaration of record: it is what `PROPERTIES` is read from.

## Corpus

| Entry | Source | TLC oracle | ExTLA `spec.ex` |
|---|---|---|---|
| `die_hard` | Lamport, *Specifying Systems* | ✅ | ✅ |
| `two_phase_commit` | Lamport, TLA+ examples | ✅ | ✅ |
| `distributed_lock` | `spec/07-examples.md` Example 1 | ✅ | generated from the page |
| `raft_election` | `spec/07-examples.md` Example 2 (its liveness property is refuted by the term bound, by design) | ✅ | generated from the page |
| `bounded_buffer` | `spec/07-examples.md` Example 3 | ✅ | generated from the page |
| `paxos` | Lamport, *Paxos Made Simple* TLA+ | ✅ | ✅ |
| `audit_log` | #112's reproduction — the only entry written for this corpus rather than translated into it | ✅ | ✅ |

No entry declares a `SYMMETRY` in its `.cfg`. Three of them could — processes, resources
and servers are interchangeable — but TLC's symmetry sets and its `PROPERTIES` are not
sound together, and neither are ExTLA's (`08-decisions.md` D-22), so an entry that
declared one would have to give up the temporal verdicts this corpus exists to record.
The reduction is measured instead, on the same models, by `bench/symmetry.exs`, and
`verify_symmetry: true` confirms both declarations are sound.

The oracle column is filled in ahead of the ExTLA column deliberately: with the expected
answers already in the repository, every piece of the checker is measured against truth
from the day it is written, rather than against its own output a phase later.

All seven agree, which is what D-9 asks of Phase 1. Each entry was chosen for a different
way the checker could be wrong: `die_hard` for the shortest counterexample,
`two_phase_commit` for a state count too large to eyeball, `distributed_lock` for a
product of param sets and a tuple in state, `raft_election` for params drawn from the
pre-state and an end state that is not a deadlock, `bounded_buffer` for a sequence,
where order distinguishes states a set would not, and `paxos` for a guard that
quantifies over a subset of the messages in flight.

`audit_log` is the exception to that sentence and to the shape of this corpus, and both
deliberately (#114). Every other entry is a system someone would want to verify,
translated into TLA+ so TLC can be asked about it. `audit_log` is three states and was
written *for* the corpus, because the thing it holds the checker to is a **declaration
kind** rather than an algorithm: an `action_property` is a predicate over a step, which
TLC checks as a `PROPERTY` and not as an `INVARIANT`, and it was the one Layer 2 feature
no entry had ever put to TLC. #112 is what that absence cost — an `action_property`
counterexample built from the wrong end of the step, alive for as long as the feature was.

Its content is one decoy. `compact` empties the log, so the offending step's post-state
**is** the initial state, reachable at depth 1 by a route that never touches the offending
step. A checker that walks parent pointers back from the post-state therefore hands back a
one-state trace with no violation in it, and a correct one hands back four states ending in
`compact` — a difference in **length**, which is what D-9 compares and what a comparison of
verdicts alone cannot see. Reintroducing #112 fails this entry with `ExTLA returned 1 states`
against TLC's 4 while leaving the other six green, which is the measurement that says the
decoy is doing the work and not the entry's mere presence.

## The three entries `spec/07-examples.md` publishes

`distributed_lock`, `raft_election` and `bounded_buffer` are **generated from the page**
by `mix extla.examples --write`, and the `surface-drift` job fails on a difference. Their
`spec.ex` files are artifacts: edit the fence in `spec/07-examples.md` and regenerate.

This is #280's doing, and the reason is a measurement. Those three moduledocs used to say
"Example N verbatim, which is the point: the corpus checks the documentation, not a
paraphrase of it" — and D-21 rewrote every corpus spec's types **forty-three minutes
after that sentence was written**, leaving the page behind. For a month the page a reader
copies from declared `type: [^resources ~> :set]` where the checker had been given
`set(^processes)`. Two files agreeing by discipline is what discipline spends first.

What the generator changes, and why neither is drift: the module name (`Specs.X` on the
page, `ExTLA.Differential.X` here, because this is a test tree) and `default:` on the
constants (the page shows what a reader writes — the assignment belongs to a run — while
`ExTLA.Ledger` needs one to resolve the spec at all). `ExTLA.Examples` holds those defaults
to the constants this corpus passes TLC's side, so the ledger and the oracle cannot end
up checking two different models.

What each of the three is *for*, which their moduledocs used to carry:

- **`distributed_lock`** — a product of param sets, and a tuple in state. TLC checks the
  safety half; the temporal properties and fairness constraints are declared and
  unchecked in Phase 1, and the run says so in its warnings.
- **`raft_election`** — params drawn from the **pre-state** rather than from a constant,
  because nearly every action begins "pick a message from the network", so the set a
  param ranges over changes from state to state. It is also the first entry that *ends*
  somewhere: the split vote at `^max_term` is a `terminal`, not a deadlock.
- **`bounded_buffer`** — a **sequence** in state. Order matters in a sequence and does not
  in a set, so a fingerprint that canonicalised a list the way it canonicalises a set
  would collapse states differing only in what is at the head — and the state count is
  where that shows up.

## Writing an entry

Four things bite when translating a spec into TLA+ for TLC.

**Use model values, not strings, for tags.** TLC compares strings strictly and
*raises* on `"idle" = <<"holding", r>>` rather than returning FALSE, so a spec whose
control state is sometimes a tag and sometimes a tuple will not run. Declaring
`CONSTANTS idle, requesting, holding` and assigning `idle = idle` in the `.cfg` makes
them model values, which are simply unequal to anything they are not — and reads as
what they translate to on the ExTLA side: atoms.

**A `terminal` has to admit every stuck state, and only stuck states.** TLC calls any
state with no successors a deadlock and stops there; ExTLA reports one only where no
`terminal` predicate admits it. So the two sides are compared on where the search
*stops*, and a spec that declares a terminal is held to both halves of that claim: a
stuck state no terminal admits is still a deadlock (the run fails), and a terminal that
admits a state which has successors comes back as `terminal_but_live` in the coverage
report. Writing `raft_election` failed the first test — the end state of a split vote
still has undeliverable vote responses in the network, so a terminal saying the network
is empty admits none of them.

**Fairness has to be per binding where the ExTLA spec says so.** `\A p \in Procs :
SF_vars(A(p))` is not `SF_vars(\E p \in Procs : A(p))` (`spec/02-dsl-semantics.md` §5.2).
The second says only that *some* process acts infinitely often, which is too weak to
prove anything about a particular one — and `distributed_lock`'s `NoStarvation` is about
a particular one. Getting this wrong makes the oracle agree with a checker that is also
wrong, which is the one failure this corpus cannot catch for itself.

**State the invariant-name mapping.** TLA+ modules prefix by convention (`TPTypeOK`)
and ExTLA's implicit type invariant is always `:type_ok`, so the differential test
carries a per-entry `names` map. It is stated rather than guessed, which also means an
invariant that goes missing from the DSL spec is *reported* rather than silently
skipped.

The state-count comparison runs with nothing selected on either side —
`invariants: [], action_properties: []`. An ExTLA action property that the TLA+ module
does not have would otherwise halt the search early and make the counts differ for a
reason that is not a bug.

## Running

```sh
bin/tlc-expected              # regenerate every entry's expected.json
bin/tlc-expected die_hard     # regenerate one
bin/tlc-expected --check      # re-run TLC and fail on drift (what CI runs)
```

The script fetches `tla2tools.jar` into `.tla/` on first use and verifies its SHA-256
against the version pinned at the top of the script. The pin is deliberate: TLC's state
counts are the fixture, so the tool that produces them is part of the fixture, and
bumping it is a reviewable commit in which every `expected.json` is expected to change.

`mix test test/differential` runs ExTLA on `spec.ex` with the same constants and
compares against these files. It is part of the ordinary suite, so the `check` CI stage
already runs it; the `verify` stage is what keeps `expected.json` honest by regenerating
it from TLC.

Each entry searches its state space once for the counts, once for the invariants TLC
says hold, and once more per invariant TLC says is violated. The grouping is not a
shortcut: a run that checks several invariants and completes has established every one
of them, because nothing stopped it early — the same argument that lets TLC report on
several `INVARIANTS` from one search. A violated one still needs a run of its own,
because TLC halts at the first violation and so does this checker, so the shortest
counterexample *for that invariant* is only what a run checking only it reports.

## Why `die_hard` is first

It is the smallest spec that exercises all three comparisons at once: a small closed
state space (16 states), an invariant that holds (`TypeOK`), and an invariant that is
violated at a known depth (`NotSolved`, at 7 states). Its counterexample *is* the
solution to the puzzle, so the shortest-counterexample comparison is checkable by hand:
a checker that reports a longer trace has not searched breadth-first, and one that
reports no trace cannot find bugs at all.
