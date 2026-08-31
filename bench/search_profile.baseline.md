# Search profile — baseline

The number `TLA.ModelChecker.Parallel` has to beat, and the breakdown saying which phase
it would have to speed up to do it. Regenerate with `mix run bench/search_profile.exs`;
see that file's header for what each phase is and why the residual is reported rather than
distributed.

**Taken on** 2026-08-31 — AMD Ryzen 7 1700 (8 cores / 16 threads), Debian 13,
Elixir 1.20.4, Erlang/OTP 29 (erts-17.0.5, jit). A number without the machine it was taken
on is not a measurement.

## `raft` — `TLA.Differential.RaftElection`, the corpus constants

58,359 distinct states, 255,270 transitions, diameter 19.

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

400.5 µs/state, 2,497 states/s.

Of the graph line, **fingerprinting alone is 3,298 ms — 98.8% of it.** The ETS lookup and
insert are the remaining 1.2%, which is **0.2% of the search**.

## `buffer` — `TLA.Differential.BoundedBuffer`, the corpus constants

4,460 distinct states, 15,776 transitions, diameter 29. 345 ms wall, 77.5 µs/state,
12,911 states/s. Same shape, less extreme: validation 51.6%, graph 21.4% (fingerprinting
83.7% of it), coverage 9.9%, params+guards 9.0%, invariants 4.8%.

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

**The contended structure is 0.2% of the search.** §06 §Concurrency Architecture worries
about ETS as "the only contended structure", and it is — but on this workload it is
nearly free. A parallel implementation's cost will be coordination — batching states to
workers, collecting frontier states back, merging the six accumulators — not table
contention. That is a different design problem from the one the diagram anticipates, and
it is worth knowing before the coordinator is written.

**93% of the work is per-successor computation over no shared state at all**: validation,
fingerprinting, guards, transitions, invariants. That is the part that parallelises
freely, and it is why parallel exploration is worth doing at all.

**But `State.validate!` is 78% of this search, and it is called on every successor —
including the ones already seen.** A state reached five times is validated five times. The
§6 guarantee (a forbidden term surfaces, naming the variable) is preserved by validating
each state once, at first discovery, since a state that is never discovered is never in
the graph either. On `raft` that is 255,270 validations where 58,359 would do.

Doing that would beat eight cores on this workload — 8× on 78% is 2.9× overall, and
removing three quarters of a phase that *is* 78% is up to 3.5×. It is not in this work
item's scope (#30 profiles; it does not optimise), and it wants a proposal of its own,
because "validate once at discovery" is a claim about §6's guarantee and not only about
speed. Filed as **#33**.
