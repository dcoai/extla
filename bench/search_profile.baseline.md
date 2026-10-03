# Search profile — baseline

Where the search spends its time, and what parallelising it bought.

Two halves. The **phase profile** below says which phase a change would have to speed up —
regenerate with `mix run bench/search_profile.exs`; see that file's header for what each
phase is and why the residual is reported rather than distributed. The **worker sweep** at
the end says what `workers:` actually delivers, and at what — regenerate with
`mix run bench/search_profile.exs workers`.

**Taken on** 2026-08-31 — AMD Ryzen 7 1700 (8 cores / 16 threads), Debian 13,
Elixir 1.20.4, Erlang/OTP 29 (erts-17.0.5, jit). A number without the machine it was taken
on is not a measurement.

## `raft` — `ExTLA.Differential.RaftElection`, the corpus constants

58,359 distinct states, 255,270 transitions, diameter 19.

**Current, after #33** — validation happens once per distinct state, inside
`StateGraph.add_state/5`, rather than once per generated successor:

| | ms | % of wall |
|---|---|---|
| **wall** | **9,547** | 100% |
| graph: fingerprint + §6 + ETS | 7,371 | 77.2% |
| invariant checking (incl. `type_ok`) | 769 | 8.1% |
| parameter generation + guards | 646 | 6.8% |
| coverage bookkeeping | 321 | 3.4% |
| transition application | 302 | 3.2% |
| action properties | 37 | 0.4% |
| (residual) | 101 | 1.1% |

163.6 µs/state, 6,113 states/s.

The graph line now bundles three costs, because `add_state/5` performs all three. Broken
out by measuring each a second time: **fingerprinting 3,153 ms** (42.8% of the line),
**§6 validation 4,072 ms** (55.2% of the line, 42.6% of wall), leaving the ETS lookup and
insert as the ~146 ms remainder — a difference of three larger numbers, so an order of
magnitude rather than a measurement. #31 timed the tables directly and found them free.

**Before #33**, for comparison — the same workload with `State.validate!/1` called on
every successor:

| | ms | % of wall |
|---|---|---|
| **wall** | **23,373** | 100% |
| state validation (§6) | 18,215 | 77.9% |
| graph: fingerprint + ETS | 3,339 | 14.3% |
| invariant checking (incl. `type_ok`) | 753 | 3.2% |
| parameter generation + guards | 671 | 2.9% |
| transition application | 344 | 1.5% |
| coverage bookkeeping | 330 | 1.4% |
| action properties | 41 | 0.2% |
| (residual) | −320 | −1.4% |

400.5 µs/state, 2,497 states/s. Of that graph line, fingerprinting alone was 3,298 ms —
98.8% of it — putting the ETS lookup and insert at 0.2% of the search.

Validation fell from 18,215 ms to 4,072 ms: **4.47x, against the 4.37x that 255,270
transitions over 58,359 distinct states predicts.** The measurement matching the ratio it
should is the evidence that what changed is *how often* validation runs and nothing else.

## `buffer` — `ExTLA.Differential.BoundedBuffer`, the corpus constants

4,460 distinct states, 15,776 transitions, diameter 29.

**After #33**: 264 ms wall, 59.1 µs/state, 16,920 states/s. Graph 47.7% (of which
fingerprinting 45.3% and §6 validation 38.3%, the latter 18.3% of wall), coverage 11.9%,
params+guards 10.4%, invariants 6.1%, transitions 2.0%, properties 0.8%.

**Before #33**: 345 ms wall, 77.5 µs/state, 12,911 states/s. Same shape, less extreme than
raft: validation 51.6%, graph 21.4% (fingerprinting 83.7% of it), coverage 9.9%,
params+guards 9.0%, invariants 4.8%.

## Re-measured after #31

#31 made the tables `:public`, insertion race-free and the id atomic. Interleaved A/B on
the `buffer` entry — alternating the two versions so both arms see the same machine load,
15 runs each, minima compared — gave 368/395 ms before and 373/372 ms after: no measurable
change, which is what a refactor of the 0.2% should look like.

**Read wall times here with the load average beside them.** A `raft` run measured at
23.4 s on a quiet machine came out at 26.1 s and then 30.5 s while the box was at load 7,
with the *phase* numbers moving less than 8% — the measured work barely changed and the
wall swung 30%. The phase proportions are the durable part of this document; the absolute
wall is only comparable against a run taken under the same conditions.

**`write_concurrency` is not set, and that is a measurement.** On a single-writer
insert-and-lookup loop over 255,270 keys: `:protected` 195 ms, `:public` 190 ms (0.97x —
free), `:public, write_concurrency: true` 272 ms (1.39x), `write_concurrency: :auto`
328 ms (1.68x). It buys nothing until there are concurrent writers, and what lock
granularity a coordinator wants depends on how it batches and shards its writes. Setting
it now would pay 39% on the one structure this profile says is already free.

## What this says about Phase 4

**The contended structure is ~1.5% of the search, and was 0.2% before #33.** §06
§Concurrency Architecture worries about ETS as "the only contended structure", and it is —
but on this workload it is nearly free either way. Its share rose only because the search
it is a share *of* got 2.65x shorter; the absolute cost did not move, and #31 timed the
tables directly rather than by subtraction. A parallel implementation's cost will be
coordination — batching states to workers, collecting frontier states back, merging the
six accumulators — not table contention. That is a different design problem from the one
the diagram anticipates, and it is worth knowing before the coordinator is written.

**Nearly all of the remaining work is per-successor computation over no shared state at
all**: fingerprinting, guards, transitions, invariants, and the once-per-state validation
that survives. That is the part that parallelises freely, and it is why parallel
exploration is worth doing at all.

**`State.validate!` was 78% of this search, and #33 has since removed three quarters of
it.** It ran on every successor including the ones already seen — a state reached five
times was validated five times — and now runs once per distinct state, inside
`StateGraph.add_state/5` on the branch where the fingerprint is absent. The §6 guarantee
survives: a forbidden term's encoding does not recur, so a state carrying one never dedups
and is always validated on the path that finds it first.

## The #33 A/B — interleaved, on one machine

Measured by alternating the two arms within each round rather than running them in two
blocks, minima compared, on the machine named at the top of this file:

| entry | before #33 (min) | after #33 (min) | speedup |
|---|---|---|---|
| `raft` | 25,187 ms | 9,487 ms | **2.65x** |
| `buffer` | 356 ms | 219 ms | **1.62x** |

Both arms reported 58,359 states / 255,270 transitions on `raft` and 4,460 / 15,776 on
`buffer` — identical, which is the point: the change removes repeated work, not work.

Note the `raft` "before" minimum of 25,187 ms against the 23,373 ms recorded above. The
two were taken on different days at different loads, and the gap between them is roughly
the size of the effect this document warns non-interleaved comparisons will invent. That
is why the speedup is quoted from the interleaved arms and not from the table.

**What this leaves for #34.** Parallel exploration now has a smaller and differently
shaped target: 9.5 s rather than 23.4 s, with fingerprinting (3.2 s) rather than
validation the largest single phase — and fingerprinting is per-successor computation over
no shared state, which is exactly the part that parallelises freely. Eight cores against
this shape is a better trade than eight cores against the old one, where most of the
parallelism would have gone on work #33 has since deleted.

---

# The worker sweep

`mix run bench/search_profile.exs workers [entry]`. Three rounds, every worker count run
once per round with the order rotated, minima compared — for the reasons the phase profile
above gives and this document repeats below.

## `raft` — 58,359 states, 255,270 transitions, diameter 19

Taken at load 3.2 on the machine named at the top of this file.

| workers | min | speedup | all three rounds |
|---|---|---|---|
| 1 | 8,897 ms | — | 8,897 / 9,632 / 9,848 |
| 2 | 4,925 ms | **1.81x** | 4,925 / 5,002 / 5,120 |
| 4 | 2,623 ms | **3.39x** | 2,661 / 2,623 / 2,695 |
| 8 | 1,647 ms | **5.40x** | 1,704 / 1,745 / 1,647 |

Identical state count, transition count, diameter and status at every worker count — the
sweep prints them per run rather than only summarising, because a sweep whose counts drift
between arms is measuring two different searches and that has to be visible in the output.

**5.4x on 8 cores of a 16-thread machine.** The gap from linear is the barrier: the search
is level-synchronous (D-27), so every round costs the slowest worker in it, and `raft` has
19 rounds. That is the price of comparing counterexample *length* against TLC, which is
D-9's acceptance criterion.

**Compounded with #33, `raft` has gone from 23.4 s to 1.65 s — 14x.**

## `buffer` — the sweep says nothing here, and that is the finding

4,460 states over 29 levels is about 150 states a level, and 29 barriers. Run-to-run
spread on this entry is roughly 90% (198 ms to 382 ms for the same arm), which swamps any
difference between arms: one sweep put 8 workers at 1.93x and the next at 0.89x. Neither
number means anything.

Reported rather than dropped, because "too small to parallelise" is a real answer and the
alternative — quoting whichever run looked better — is how a benchmark starts lying. The
entry stays in the sweep as a smoke check that it runs.

## Batch size, derived rather than asked for

A level is cut into `workers * 8` batches, dealt round-robin, and `Task.async_stream`
hands a worker its next batch as it finishes one — so workers that drew cheap states
absorb the stragglers instead of idling at the barrier. On `raft` at 8 workers,
interleaved, minima:

| batches per worker | 1 | 2 | 4 | 8 | 16 | 32 |
|---|---|---|---|---|---|---|
| speedup | 1.00x | 1.02x | 1.01x | 1.04x | **1.05x** | 1.00x |

It pays until the per-batch overhead outgrows the rebalancing, which happens before 32.
Eight sits on the plateau and keeps the task count down on small levels. It is not a knob:
the count is derived from the workers, and the grouping caps it at the level's own size, so
a level with fewer states than parts yields one state per batch rather than empty ones.

The effect is 4-5% — worth taking, and worth stating at that size rather than as a
headline. On `buffer` the same comparison is inside the noise, as everything on `buffer` is.

## `write_concurrency`, re-measured with real concurrent writers

#31 measured it single-writer (1.39x slower, `:auto` 1.68x) and deferred the decision to
whoever knew how a coordinator would batch its writes. There is one now. `raft` at 8
workers, interleaved, six rounds, minima:

| | unset | `true` | `:auto` |
|---|---|---|---|
| speedup | 1.00x | 1.03x | **0.13x** |

**It stays unset.** `true` is a wash where it was supposed to pay — 3% is inside the
run-to-run spread — and `workers: 1` is the default (D-27), so setting it would charge
every single-threaded run 39% to buy nothing measurable on a path a caller has to opt into.

**`:auto` is 7.6x slower, and the mechanism is an interaction rather than a constant.** It
decentralises the table's counters, so `:ets.info/2` with `:size` has to sum them instead
of reading one:

| table | `:ets.info(t, :size)` |
|---|---|
| protected | 112 ns |
| public | 105 ns |
| public + `write_concurrency: true` | 110 ns |
| public + `write_concurrency: :auto` | **1,832 ns** |

`max_states` reads that size before every expanded state (`StateGraph.live_state_count/1`,
#40). Two decisions taken separately meet on this line, which is why the number is recorded
beside both.
