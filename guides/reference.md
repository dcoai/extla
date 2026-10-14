# Reference

The facts a user of ExTLA looks up rather than learns: how `mix extla.check` differs from calling
the checker yourself, the levers that make a large state space tractable and what each one costs,
how to read a coverage report and a JSON result, what conformance checks, how Layer 1 behaves in
tests and in production, and what ExTLA deliberately does not do.

The [tutorial](tutorial/00-introduction.md) teaches the same ground in order. The DSL itself is
in the [DSL reference](../spec/02-dsl-semantics.md), and every module's options are on its own
page — start at `ExTLA`.

## The CLI and the API

`mix extla.check` and `ExTLA.ModelChecker.run/2` run the same checker. One default differs.

**The CLI infers `check_liveness`; the API does not.** `ExTLA.ModelChecker.run/2` defaults it to
`false`. `mix extla.check` sets it to `true` when the spec declares a `temporal` and none of
`--safety-only`, a `symmetry:` declaration or `--workers` above one applies. The task has the spec
in hand and can tell that liveness is what the author meant; a library caller gets exactly what
they wrote.

So a temporal property `mix extla.check` checks is **not** checked by `ExTLA.Spec.Test.assert_spec/2`
unless its config says `check_liveness: true`. A suite can be green over a temporal property
nothing evaluated.

**A liveness pass that was asked for and did not run is named.** Liveness runs over a finished
graph, so four things skip it: a deadlock, a `state_constraint:` that held states back, the state
budget stopping the search, and a safety counterexample halting it. Each adds one warning to the
result — "N temporal properties were not checked", with the reason and what to do — and the
status is whatever the search produced. That matters most under `--allow-incomplete`, which turns
a bounded run into exit 0.

## Making a large state space tractable

[When the state space explodes](tutorial/09-when-it-explodes.md) is the order to reach for these
in. This is what each one does and what it asks of you.

### State constraints

`state_constraint:` is a predicate on states; a state that fails it is not expanded. It bounds an
otherwise unbounded variable — a growing log, an unbounded counter — without changing the spec:

<!-- tla:skip reason=one config option on its own, not a compilable module -->
```elixir
state_constraint: fn s -> length(s.log) <= 5 end
```

A constrained run is **not** exhaustive, and the result says so: the status is `:constrained`,
the coverage report names the bound, and a temporal property is not checked under it.

### Symmetry

`symmetry:` names constants whose elements are interchangeable — process IDs, account names,
replica IDs. States that differ only by a permutation of those elements are treated as one, so a
symmetric set of size *n* shrinks the reachable space by up to *n*!.

**What it costs.** Each state is put in a canonical form by trying every permutation: *n*!
encodings per state for one symmetric set, and the product for several. At three elements that
is roughly a wash in wall-clock time; at four or five it is a clear win. Measure it on your spec
rather than assuming it.

**Soundness is your obligation.** The reduction is sound only if no property and no action can
tell the elements apart: no `Enum.at(^accounts, 0)`, no `Enum.sort`, no `<` between process
names, nothing that depends on list position. Nothing can check this statically — a constant
flows into arbitrary Elixir, and any conservative check would reject the
`Enum.all?(^processes, …)` almost every symmetric spec is built from. It is the author's
obligation, exactly as it is in TLC.

What ExTLA does is make a wrong declaration **detectable**. `mix extla.check --verify-symmetry`
(`verify_symmetry: true`) runs the model with and without the reduction and fails if any verdict
differs: the status, what was refuted, whether it deadlocked, which actions were never enabled.
The state counts are not compared, because a sound reduction changes them on purpose. Run it once
per spec on a small constant assignment before trusting the reduction on a large one. It refuses
to compare a run that hit the state budget or a constraint, because a truncation is not a verdict.

**Not together with liveness.** The reduced graph identifies states, so a path that leaves an
orbit and one that returns to it look alike, and the quotient can hold cycles the real system
does not — which is exactly what a liveness verdict is read off. Asking for both raises. Check
safety under the reduction, and the temporal properties in a run without it.

### Parallel exploration

`--workers N` (`workers: N`) expands each breadth-first level across N processes and waits for
all of them before starting the next. That barrier is what keeps the counterexample the
**shortest** one: a parallel run may return a different trace than a single-threaded run, but
never a longer one. Every coverage field except `distinct_generated`'s split across actions comes
out exactly as a single-threaded run's.

The default is 1. A parallel search explores the same space and gives the same answer, so the
cores buy speed and not a better result, and how much of a machine to spend is the caller's
decision. `ExTLA.Config.workers/0` returns the machine's answer if you want it.

Liveness is refused under workers, for the same kind of reason it is refused under symmetry: a
cycle spanning two workers' states would not be found. A run that halts at a counterexample
under workers agrees with a single-threaded run on the verdict and the counterexample's length,
not on the counts.

### What is not provided

View abstraction (TLC's `VIEW`) is deferred: it is easy to make unsound, and symmetry covers the
common case. Partial-order reduction is a non-goal — Concuerror already does it at the level
where it pays off.

## Reading the coverage report

A run can report success while having verified almost nothing, and the coverage report is how
you tell. It names three things:

- **An action that was never enabled.** A typo in a guard turns an action off entirely, and the
  spec still verifies — a weaker spec passes more easily. This is the most common finding.
- **A vacuous property.** `P ~> Q` where `P` never holds in any reachable state is trivially true
  and says nothing about `Q`. Under a quantifier, each instance is reported on its own.
- **An invariant that was never at risk.** One whose near-miss count is 0: no reachable state came
  close to falsifying it. Such an invariant is indistinguishable from `true`. A near-miss count is
  measured only for an invariant whose top level is an `or`; anything else reports `nil`, meaning
  "not measured", which is not the same as 0.

`--strict-coverage` fails the build on a never-enabled action or a vacuous property. It does so
only where the run can support the claim: "no reached state did X" says nothing about the states
a bounded run never reached, so on a bounded run these stay in the report, qualified, and do not
fail anything.

Reading a counterexample is covered in the tutorial; `mix extla.explore` evaluates your own
expressions over a saved one.

## The JSON result schema

`mix extla.check --format json` emits a versioned envelope, so a reader can refuse a shape it
does not know rather than misread it:

```json
{
  "schema_version": 3,
  "specs": [
    {
      "spec": "Specs.TransferProtocol",
      "status": "ok",
      "message": null,
      "distinct_states": 3612,
      "states_found": 9004,
      "transitions": 12871,
      "diameter": 14,
      "deadlock": false,
      "duration_ms": 812,
      "fingerprint_bits": 64,
      "collision_estimate": 1.0e-9,
      "warnings": [],
      "coverage": {
        "actions": {"begin_transfer": {"enabled_in": 44, "states_generated": 88,
                                       "distinct_generated": 61}},
        "never_enabled": ["cancel_transfer"],
        "invariants": {"type_ok": {"evaluated_in": 3612, "near_misses": null}},
        "vacuous": [],
        "terminal_but_live": [],
        "terminals": {"all_done": {"admitted": 6}},
        "bounded_by": "none"
      },
      "profile": null,
      "violation": null
    }
  ]
}
```

Four rules the schema keeps:

1. **`schema_version` leads the envelope.** Refuse a version you do not recognise.
2. **`specs` is a list of self-describing entries**, sorted, so two runs diff cleanly.
3. **Every entry carries every key, and absent is `null`, never `0`.** A zero near-miss count is a
   finding; not having measured near-misses is not.
4. **A bounded run is marked.** `coverage.bounded_by` is `none`, `state_constraint`,
   `max_states` or `violation`; anything but `none` means the counts are lower bounds.

`duration_ms` is wall time and varies between runs, so nothing should gate on it.

`profile` is `null` unless the run was asked for one with `--profile`. When present it carries
`run_reductions`, `otp_version`, `calibration` and `declarations`, a sorted list of entries:

```json
"profile": {
  "run_reductions": 84117,
  "otp_version": "29",
  "calibration": {"2": 1, "3": 1},
  "declarations": [
    {"kind": "invariant", "name": "conservation_of_money",
     "evaluations": 3612, "reductions": 505680, "per_eval": 140, "observed": 511204}
  ]
}
```

`reductions` is `per_eval * evaluations`, where `per_eval` is the cheapest evaluation observed
rather than the mean — that is what makes it reproducible under machine load. `observed` is what
the counter actually accumulated; a large gap between the two marks a predicate whose cost varies
with the state. Unlike `duration_ms`, the declaration costs are a function of the code, the data
and the OTP release, so two runs of an unchanged spec on one build agree to within two reductions
per evaluation. A reduction count is comparable only within one OTP release, which is why
`otp_version` is carried. `ExTLA.Profile` explains the measurement.

## What conformance checks

Layer 3 maps a running GenServer's state onto the spec's, and checks every step the
implementation takes:

| Check | Question |
|---|---|
| **Step legality** | Is the abstract post-state what the named spec action produces from the abstract pre-state? |
| **Stuttering** | If the message maps to no action, did the abstract state stay put? |
| Invariants | Does the abstract post-state satisfy the spec's invariants? |
| Action properties | Does the abstract step satisfy the spec's action properties? |
| Temporal | Does the accumulated abstract behaviour satisfy the temporal properties? |

Step legality is what makes this refinement checking rather than a projection with some
predicates on it. Without it, an implementation could take a transition no spec action permits,
and as long as the resulting state satisfied the invariants nothing would notice — and the
transition the design never sanctioned is where the interesting bugs are. It is also cheap: an
action body is a pure function of the pre-state and its parameters, so checking it is one
function application and one comparison per callback.

**A temporal property over a finite trace has three verdicts.** A trace is a prefix of an
infinite behaviour. A prefix can refute `always P` or satisfy `eventually P`, but not the other
way round, so `ExTLA.Temporal`'s operators return `:holds`, `:violated` or `:inconclusive` rather
than a boolean. A lasso — a prefix plus a cycle that repeats — describes an infinite behaviour,
and over one every operator answers definitely. Without one, `<>[]P`, `[]<>P` and `P ~> Q` are
`:inconclusive` for every trace.

ExTLA checks refinement on the behaviours it observes. It does not prove it.

### The verification pipeline

| Mode | When | What it does |
|------|------|--------------|
| Exhaustive | `mix extla.check` | model checks the spec itself |
| Runtime | every transition, in dev and test | step legality, stuttering, invariants and action properties |
| Simulation | `mix extla.simulate`, or `ExTLA.Simulation` in tests | random walks over the real implementation, all property kinds |
| Replay | `mix extla.replay`, or `ExTLA.Replay` in tests | drives the implementation through a counterexample or a captured trace |

Together:

```sh
# 1. Model check the spec: design bugs, before the code exists
mix extla.check Specs.TransferProtocol

# 2. Check the implementation conforms, over random traces
mix extla.simulate MyApp.TransferServer --traces 10000

# 3. Replay the counterexample from step 1 against the real code
mix extla.replay MyApp.TransferServer --trace counterexample.json

# 4. Check a captured production trace against the spec
mix extla.replay MyApp.TransferServer --captured incident.json
```

Step 3 turns a design-level counterexample into an executable reproduction, and step 4 lets a
specification say something about the system that is actually running. `ExTLA.PropertyTest`
derives StreamData generators from the spec for your own property tests beside these.
[Putting a specification in your project](tutorial/10-in-your-project.md) covers running all of
it from your suite.

## Layer 1 in tests and in production

### Testing helpers

`use ExTLA.Invariant.Test` brings in:

- `assert_invariants(module, state)` — every invariant of `module` holds for `state`. On failure
  it names every invariant that failed, not just the first.
- `assert_action_properties(module, old, new)` — every action property holds for the step.
- `refute_invariant(module, name, state)` — the named invariant **fails** for `state`. This is
  the test that proves an invariant can fail at all; one no test has seen return false is
  indistinguishable from `true`.
- `valid_states(module, type_invariant, base_generator)` — a StreamData generator of states the
  named invariant accepts. It filters `base_generator` rather than constructing states, so the
  base generator should already have the type's shape and be accepted at least about half the
  time; at much lower acceptance rates a property fails on some seeds with
  `StreamData.FilterTooNarrowError`.

Each helper raises, rather than failing, when the module carries no predicates — it does not
`use ExTLA.Invariant`, or was compiled under `mode: :disabled` — and `refute_invariant/3` raises
for a name the module does not declare. Otherwise a renamed declaration would turn a test green
by making it check nothing.

<!-- tla:skip reason=an ExUnit module, run by your suite rather than by this page -->
```elixir
defmodule BankAccountTest do
  use ExUnit.Case
  use ExTLA.Invariant.Test

  test "a withdrawal keeps the invariants" do
    state = %{balance: 100, status: :active, transactions: []}
    new_state = %{state | balance: 50, transactions: [{:withdraw, 50}]}

    assert_invariants(BankAccount, new_state)
    assert_action_properties(BankAccount, state, new_state)
  end
end
```

### Telemetry

If `:telemetry` is loaded, Layer 1 emits:

<!-- tla:skip reason=telemetry event names, not code -->
```elixir
# Always:
[:extla, :invariant, :violated]        # metadata: %{module: m, name: n, violation: v}
[:extla, :action_property, :violated]
[:extla, :precondition, :violated]
[:extla, :postcondition, :violated]

# Only under `config :extla, telemetry: :verbose`:
[:extla, :invariant, :checked]         # metadata: %{module: m, name: n, duration: d}
[:extla, :action_property, :checked]
[:extla, :precondition, :checked]
[:extla, :postcondition, :checked]
```

Success events are off by default because they are the hot path: `:telemetry.execute/3` costs
around a microsecond even with no handler attached, and one transition can fire four. The setting
is read at compile time, so without `:verbose` the success events are not emitted at all, rather
than emitted and ignored.

### Performance

| Mode | Overhead | Notes |
|------|----------|-------|
| `:disabled` | none | no wrapper is emitted; the module compiles as written |
| `:enabled` | about 1–5 µs per transition | dominated by the predicates themselves |
| `:log_only` | about 1–5 µs per transition | the same, without the raise |

That is a target for ExTLA's own overhead, not a guarantee: a predicate that walks a
10,000-element list costs what it costs. Three levers when checking is too expensive:

<!-- tla:skip reason=declaration options and config, shown on their own -->
```elixir
# 1. Compile one check out, per invariant
invariant :expensive_check, enabled: Mix.env() == :test do
  deep_structural_audit(state)
end

# 2. Restrict it to some callbacks
invariant :queue_bounded, callbacks: [:handle_cast] do
  length(state.queue) <= 1000
end

# 3. Turn the layer off for an environment
config :extla, mode: :disabled
```

An `Agent`'s checks are the exception: an `Agent` has no callback module to instrument, so
`ExTLA.Invariant.Agent` dispatches at runtime and `:disabled` cannot compile them away.

## What ExTLA is not

Each of these has a better tool already.

- **Not a theorem prover.** ExTLA checks bounded models exhaustively and observed behaviours
  concretely. It does not prove a spec correct for all parameters, and it does not prove that an
  implementation refines a spec — it checks that the behaviours it saw did. TLAPS proves; ExTLA
  checks.
- **It does not explore process interleavings in running code.** It finds design bugs in a state
  machine, not scheduling bugs in an implementation. Concuerror does that, on unmodified tests;
  the two are complementary.
- **It does not extract models from source.** Specs are written, not inferred.
- **It does not generate implementations from specs.** That is Erla+.
- **No real-time or probabilistic extensions.** No clocks and no distributions.

Supervision trees are not modelled yet: `ExTLA.Supervisor.Spec` is deferred, because faithful OTP
restart semantics is a research-scale problem.

## Further reading

These are the project's own records, on GitHub:

- [The specification](https://github.com/dcoai/extla/blob/main/spec/README.md): the full design,
  the normative account behind every page here.
- [Design decisions](https://github.com/dcoai/extla/blob/main/spec/08-decisions.md): why ExTLA is
  shaped the way it is, decision by decision.
- [Prior art](https://github.com/dcoai/extla/blob/main/spec/00-prior-art.md): the other
  verification tools for Elixir and Erlang, and where ExTLA fits among them.
