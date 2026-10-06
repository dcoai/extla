# Changelog

All notable changes to ExTLA are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**What is built** — module by module, phase by phase — lives in
[`spec/06-architecture.md` §Implementation Phases](spec/06-architecture.md#implementation-phases),
which is the single source of truth for that. This file records what *changed* and when, and
does not restate it.

## [Unreleased]

`mix.exs` reads `0.4.1-dev`: the `-dev` suffix is what keeps a commit from claiming to be the
release it merely follows.

### Added

- **`mix extla.replay` passes `--init-arg`, `--server` and `--timeout` through** (#165).
  The task declared `--init-arg`, so it was accepted, and then dropped: `ExTLA.Replay` was
  called with no options, and its documented `:server` and `:timeout` were unreachable from
  the command line. Now, with `--trace`:
  - `--init-arg` is the argument the server starts with, as a literal Elixir term only
    (`[start: 0]`; an expression is refused, never run);
  - `--server` drives a running registered process instead of starting one, and leaves it
    running;
  - `--timeout` bounds each reply.

  Whatever would otherwise be silently ignored is refused by name: `--init-arg` with
  `--server`, an unregistered name or a printed pid, a non-positive timeout, and any of the
  three with `--captured`, which drives nothing. `spec/05`'s holding note ("accepted and not
  currently read") is replaced. `test/mix/switches_read_test.exs` now holds every task to
  reading every switch it declares; against the old task it names `--init-arg`, and it finds
  no other.

### Changed

- **surfex's relation log is wired up for spec/04, not yet gating** (#351, for #336).
  `.surfex.exs` points surfex at `spec/04-layer2-model-checker.md` with `adoption: :trust`,
  and `.surfex/` holds the (still empty) log. `Surfex.ExUnitFormatter` records every test
  result at its version; the full suite took 192 s with it, against 200–224 s before. The
  `test`, `mutation` and `docs` jobs keep their evidence as artifacts under their own names,
  and a new `relation-evidence` job checks the log against all three together. It is
  `allow_failure` until spec/04 is tagged and baselined (#352–#354). `namespace: "ExTLA"` is
  required, because surfex's default camelizes the app name to `Extla`. A type citation
  (`ExTLA.State.t()`) is read as its module until surfex resolves types itself
  (surfex#137). On current main, `mix surfex.suggest` proposes 30 `implements` and 2,466
  `tests` relations. `CONTRIBUTING.md` is new and states the per-MR loop.

- **CI restores dependencies with depdep v0.9.0, and every one now restores** (#346, for
  #342). Under v0.7.0 one dependency, `telemetry`, was restored and then rebuilt on every run
  as "outdated", and never replaced because the store already held it. The object was fine:
  its entries carried the build path of the project that pushed it, so it unpacked where this
  project's Mix never looks (depdep#131, the mechanism behind depdep#110). v0.9.0 moves each
  restored tree to this project's own build path. The pin's own pipeline read `pulled 7,
  missing 0` with nothing rebuilt or compiled in every job. Keys are unchanged, so there was no
  store refill. v0.8.0's `--explain-rebuilt` comes along for the next refusal worth reading.

### Fixed

- **`ExTLA.Set.cross_many/1` no longer names a caller that does not exist, and docstrings
  that name a caller are checked** (#347, for #324). Its docstring and `spec/01` justified
  the empty product being `{{}}` as "the answer the DSL needs" for an action with no
  parameters. Nothing in `lib/` calls it. The DSL binds parameters with
  `ExTLA.ModelChecker.bindings/3`, a *dependent* product (each parameter's values may depend
  on the state and on earlier parameters), which `cross_many/1`'s fixed list of sets cannot
  express. The two are different operations, so the rationale now stands on its own: the
  empty tuple is the identity of the product. `test/docs/caller_claims_test.exs` reads every
  `lib/` `@doc` and `@moduledoc` from the AST. A backticked project function named in a
  caller claim must exist, and in a function's doc a named caller (called from, used by)
  must reach the documented function, directly or through its own module's helpers. Its
  first run found `ExTLA.Profile`'s moduledoc naming `take_action/6` and
  `enabled_bindings/3` as though they were in `ExTLA.ModelChecker.Safety`; they are in
  `ExTLA.ModelChecker`, which the sentence now names. The gate also refuses a *qualified*
  reference to a private function: ex_doc links it, and the docs job's
  `--warnings-as-errors` refuses the link, which is how this MR's first pipeline failed. A
  claim that names no function, like the old
  "the DSL needs", is not refused, because `lib/` uses the same phrasing for concepts
  ("what Layer 3 needs"). Three more copies of the independent product (`record_set/1`,
  `function_set/2`, `Symmetry.mappings/2`) are #350.

- **`ExTLA.Invariant.Test.valid_states/3` now says what a broad base generator costs**
  (#348, for #344). It filters the base generator through the type invariant, and
  `StreamData.filter/3` raises `FilterTooNarrowError` after 25 rejections in a row, but
  nothing told a consumer that. Measured on a real type invariant over 2,000 seeds, 100-run
  properties raised in none of the runs at about 50% acceptance, in 1 in 90 at about 30%,
  and in 3 in 4 at about 15%. The 30% band is the dangerous one: it passes locally and goes
  red on a rare seed. The docstring and `spec/03` §`valid_states` now say the base generator
  should have the type's shape and be accepted at least about half the time, with a good and
  a bad example, both held by a test. Another test reads the limit from the exception and
  checks that the docstring and the spec state the number StreamData enforces. There is no
  new `max_consecutive_failures:` option: raising the limit would move the failing band, not
  remove it.

- **A property failed on one run in about 12,000, and a guard now makes generator filters say
  why** (#343, for #341). `helpers_test.exs`'s out-of-domain property drew an index and then
  filtered it with `m not in 1..length(s)`. A filter clause in `check all` rejects into the
  generator before it, which raises `StreamData.FilterTooNarrowError` after ten rejections in
  a row. With up to 6 of 21 draws rejected, that happened on 5 of 60,000 seeds, including CI's
  796610 on v0.4.0's release MR. It had been there since #242 (2026-09-11), unseen because CI
  draws a fresh seed per run. The property now generates the same out-of-domain values
  directly: 0 failures in the same 60,000 seeds. The guess that StreamData's `integer/1`
  shrinks its range at small sizes was wrong, since its documentation says the size is
  ignored. `test/docs/property_filters_test.exs` reads `lib/`, `ledger/` and `test/` and
  refuses any filter clause in `check all`/`gen all`, or any `StreamData.filter`, without a
  `# filter: <reason>` above it. The one deliberate filter,
  `ExTLA.Invariant.Test.valid_states/3`, now carries its reason.

## [0.4.0] — 2026-10-03

**A minor line, opened by the namespace.** Every module moved from `TLA` to `ExTLA`, and
every Mix task from `mix tla.*` to `mix extla.*` (#337, D-40). `TLA` was a namespace ExTLA
doesn't own, which Elixir's code anti-patterns call *namespace trespassing*. The change is
breaking and mechanical, and it is why this is 0.4.0 rather than 0.3.21. **Migrating to
0.4.0**, below, is the whole rewrite: the application (`:extla`), telemetry, configuration
and every spec you have written are unchanged.

The rest is the three weeks since 0.3.20, and most of it moves the surface on its own:
- `mix extla.check --format json` is schema 3;
- predicates that return a non-boolean are refused rather than counted as holding;
- a temporal formula outside §5.1's fragment is refused at compile time;
- unknown options, names and flags are refused instead of being dropped.

Beside those are the gates that hold the project to its specification: the surface goldens
(`API_SURFACE.md`, `CLI_SURFACE.md`, `PACKAGE_SURFACE.md`, `DIAGNOSTICS.md`), a decision log
whose every entry is pinned to a test, and the guide harness over `spec/` and `README.md`.
Then the fixes those gates and two reviews found.

**Entries written before the rename name the modules and tasks as they were then** (`TLA.*`,
`mix tla.*`). The CHANGELOG is a record, so they are left as written; read them through the
migration.

### Migrating to 0.4.0

The next release moves every module from `TLA` to `ExTLA` (#337). It is a breaking change, and
it is mechanical.

- **Modules:** `TLA` → `ExTLA` and `TLA.<Name>` → `ExTLA.<Name>`, everywhere a module is
  named: `use TLA.Spec` → `use ExTLA.Spec`, `use TLA.Refinement`, `use TLA.GenServer`,
  `import TLA.Spec.Test`, `alias TLA.{ModelChecker, Trace}`, `%TLA.Trace{}`, and
  `TLA.ModelChecker.run/2`-style calls. One rewrite covers it, as long as it leaves `TLA+` and
  prose alone. For example, replace `TLA` with `ExTLA` where it is followed by `.` and a
  letter or `{`, and is not preceded by a letter, digit, `.` or `:`. Then fix any bare `TLA`
  module reference by hand.
- **Mix tasks:** `mix tla.<task>` → `mix extla.<task>` for `check`, `explore`, `replay`,
  `simulate`, `stamp` and `visualize`: in scripts, CI files, Makefiles and aliases. A module
  that calls a task directly moves from `Mix.Tasks.Tla.*` to `Mix.Tasks.Extla.*`. Switches,
  arguments, output and exit codes are unchanged.
- **Unchanged:** the application name `:extla` (your `deps` entry), telemetry event names
  (already `[:extla, …]`), configuration keys, and every spec you have written. A spec module
  is yours; only the `use` line names ExTLA.

### Fixed

- **A refinement mapping missing a `concrete_message/2` clause is named, not crashed on**
  (#321, closes #299). `TLA.Refinement.validate!/3` answered "does this mapping name every
  action the spec declares" by *calling* `concrete_message/2` for each one, so a mapping
  with no clause for an action raised `FunctionClauseError` from inside the validator —
  where the contract is a `TLA.Refinement.Error` with a sentence naming the action, which is
  precisely what that rule exists to report. It is a **list comparison** now: `use
  TLA.Refinement` installs an `@on_definition` hook recording the first argument of every
  clause, and the spec's actions are compared against the record. Two consequences beyond
  the crash. The clause half of the rule needs no binding, so it is decided even for an
  action with params and no constant values — the shape of a published example, where the
  probe used to skip the action and a missing clause validated clean. And the three shapes
  stay distinct where the crash had collapsed them into two: defining **none** is legal and
  reported as an undecided rule, defining **all** passes, defining **some** is the finding
  and it names the actions it does not cover. A clause whose first argument is a *variable*
  covers everything and is read that way — reading it as covering nothing would report a
  complete mapping as incomplete, which is worse than the crash. `abstract_action/1`'s
  totality probe was deliberately **not** copied: its domain is any message a server might
  receive, so a probe is the only instrument; `concrete_message/2`'s domain is the spec's
  actions, which `validate!/3` is holding (`spec/08-decisions.md` D-39). A mapping that
  declares `@behaviour TLA.Refinement` by hand has no record and the rule is named in the
  deferred list for it rather than claimed. New corpus mutant
  `TLA.Conformance.Counter.Mutants.NoClauseForAction`, one door over from
  `ActionNeverNamed`, which names an action *wrongly* rather than not at all — which is why
  the suite had never exercised this.

### Changed

- **The Mix tasks are `mix extla.*`** (#339, for #337). The same rule as the modules, one
  level down. Elixir lets a library define tasks under `Mix.Tasks`, and its own example names
  the task after the library, so `mix tla.check` was open to the same collision as `TLA.*`.
  The six user tasks, the six ledger tasks that regenerate the goldens, and the test-support
  `mutants` task move to `Mix.Tasks.Extla.*`. CI, golden headers, spec, guides and README use
  the new names, and so does the deferred `mix extla.gen.test` the spec designs.
  `CLI_SURFACE.md`'s discovery reads `extla.*.ex`. Worked test-first like #338: 33 test files
  renamed and run against the old tasks gave 156 red, and each of the 237 that stayed green
  was explained (#339 records the run).

- **Every module lives under `ExTLA`** (#338, for #337; `spec/08` D-40). ExTLA defined its
  modules under `TLA`, a namespace it doesn't own: Elixir's code anti-patterns call that
  *namespace trespassing*, because the VM loads one module per name and two libraries that
  define the same one can't both be used. `TLA` is the name any other TLA+ library would
  reach for first. Files follow the modules (`lib/ex_tla/`, `ledger/ex_tla/`, `test/ex_tla/`),
  and spec, guides, README, usage rules and every golden name `ExTLA.*`.
  `test/ex_tla/namespace_test.exs` holds every module under `lib/` and `ledger/` to the
  namespace. There are no `TLA.*` compatibility modules, since they would be the trespass
  itself. **Migrating to 0.4.0**, above, is the rewrite a consumer applies.
  - The rename was worked **test-first**. 48 test files were renamed and run against the
    unrenamed code: 372 tests went red, and each of the 93 that stayed green was explained.
    They read documents or source, or reach ExTLA through a Mix task still named `tla.*`;
    none exercised nothing (#338 records the run). Not recorded as surfex evidence: a test
    that fails only because a module doesn't exist yet says nothing about its assertions.

- **surfex `~> 0.5.24`** (#335, for #334), up from 0.5.16. Upstream changed only its usage
  rules: `usage-rules.md` is one short agent page pointing to `mix surfex.info`. What ExTLA
  calls is unchanged; `PACKAGE_SURFACE.md` moves only in surfex's own row.

- **surfex comes from Hex, `~> 0.5.16`** (#333, for #332), not the GitLab git tag v0.4.0.
  It was the only git dependency, so CI's `git config insteadOf` rewrite onto the job token
  (#71) — and with it extla's place on `dco-tek/surfex`'s job-token allowlist — has nothing
  left to do and is gone, and depdep keys every dependency in its first pass. What ExTLA
  calls is unchanged: five goldens regenerate byte-identical, and `PACKAGE_SURFACE.md`
  moves only in surfex's own row. 0.5.16 also carries surfex's adoption work (a trust
  baseline, evidence checked across CI jobs, renamed tests keeping their records), which a
  relation-log pilot would build on; nothing here adopts it yet.

- **surfex is pinned at v0.4.0** (#330, for #327), up from v0.1.0. What ExTLA calls —
  `Surfex.Golden.render/1`/`stat/2` and `Surfex.SourceScan`'s `definition_hash/1`,
  `defmodules/1`, `lib_sources/1` and `project_root/1` — is unchanged across the three
  releases, and every golden surfex renders regenerated byte-identical; `PACKAGE_SURFACE.md`
  moved only in the surfex row's own tag. What the bump brings is `lib_sources/1`'s stricter
  first-party rule (surfex #9/#10): the `tmp/` trees a `@tag :tmp_dir` surface test leaves
  behind are no longer scanned, so `API_SURFACE.md` can no longer drift on a machine that has
  just run the tests while CI stays green. v0.4.0's removals (the deprecated v0.2 trace)
  touch nothing here.

- **CI restores dependencies with depdep v0.7.0** (#329, for #328). The store already worked
  for this project — a 100% hit rate over three days — and could not show it: objects pushed
  before v0.7.0 carry no compile time, so a hit had nothing to post as `depdep.saved`. v0.7.0
  pushes the compile time with each object and posts `depdep.compile_carried` for every hit
  that carries one. Its keys come from Mix's own converge (schema v3) and fingerprint the full
  toolchain, so every object path changes — yet the bump's own pipeline was warm, not the
  cold refill depdep warns of: `pulled 6, missing 1`, and `saved ~10.3s`, the first saving
  extla has reported. The one miss, `telemetry`, is restored and then rebuilt as outdated on
  every run, and `--push` does not replace it; that is dco-tek/depdep#110. The CI line is
  unchanged — it already ran `--compile-deps`.

- **The guides teach set operations wherever they teach set types** (#320, closes #183).
  `type: set(t)` told a reader that a variable can *be* a set, and nothing told them how to
  take a union of one: neither `TLA.Set` nor `TLA.Function` was named anywhere in `guides/`,
  `README.md` or `usage-rules.md` — only in `spec/`. So the whole of TLA+'s set theory was
  reachable from a spec body after #319 and invisible to the reader who needed it, and
  anything past a map-keyed lock — a queue, a quorum, a set of messages in flight — had
  nothing to reach for and no signal that it existed. `guides/tutorial/02-dsl.md`, the page
  that introduces `type:`, gains §Operations on sets and functions: the whole vocabulary as a
  TLA+-to-DSL table, a worked spec (`Tutorial.Quorum` — a node acknowledges once, the value
  commits when some subset of the nodes is a majority and has all acknowledged) compiled and
  checked by the guide harness at **12 states, depth 5**, and the two traps, one of them a
  block asserted to raise. That spec is the same model as the `set_vocabulary` corpus entry,
  so what the page teaches is held to TLC and not only to ExTLA. `usage-rules.md` gains a
  ninth rule carrying the traps #319 left: the vocabulary needs no qualification, `set_map/2`
  and `set_filter/2` are renamed because an unqualified `map/2` in a spec block reads as
  `Enum.map/2`, `for_each/2` refuses a sequence by name, and `domain/1` of a sequence is its
  indices. The gate is `test/docs/set_operations_taught_test.exs`, and both its halves are
  found rather than named: the page, by the type form it introduces; the operators it must
  teach, from `lib/tla/spec/helpers.ex`'s own `defdelegate`s — so an operator added to the
  vocabulary and not taught is red, which is how a page drifts back into types-only one
  function at a time. It also fails on an operator the page names that a spec body cannot
  call.

- **One implementation of each TLA+ operator, and `01-foundation.md`'s vocabulary reachable
  from a spec body** (#319, for #183; D-38). `TLA.Set` and `TLA.Function` are specified as
  the foundation everything else builds on, and a spec body could not reach them:
  `TLA.Spec.__using__/1` imports only `TLA.Spec.Helpers`, which **re-implemented** four of
  their operators and exposed none of the rest. An author had to write
  `TLA.Set.powerset/1` in full, and exactly one spec in the repository did — which is also
  the only place the gap was visible. The two copies had already drifted, in the direction
  this project refuses everywhere else (#318): `for_each/2` refused a list **by name**
  because building a function over a *sequence* deduplicated it silently (#211), while
  `TLA.Function.construct/2` still did exactly that — **#211's fix had landed in one copy**
  — and `TLA.Function.domain/1`, being `Map.keys |> MapSet.new`, raised `BadMapError` on a
  sequence and answered a **`MapSet`** — a struct, therefore a map — **with the struct's own
  field names**, a wrong answer that looks like an answer, in the module the specification
  calls the foundation. The duplicates are gone: the foundation holds the implementation and
  adopts the semantics that were right (`construct/2` refuses a sequence by name; `domain/1`
  reads one as the function on `1..Len(s)` and refuses a set by name), and `TLA.Spec.Helpers`
  is a façade of `defdelegate`s that implements **no** operator — only its own thin covers
  over `MapSet` and `Enum`, which have no counterpart there. The façade also widened, so
  `powerset`, `cross`, `cross_many`, `distributed_union`, `set_map`, `set_filter`,
  `for_all?`, `exists?`, `range`, `function_set`, `except` and `record_set` are now callable
  **unqualified** from an `action`, `init`, `invariant`, `terminal` or `action_property`
  block. #183 preferred importing the two modules into the spec body directly; that is not
  available, because `domain/1` and `choose/1,2` exist on both sides and a second import
  makes every shared name ambiguous at its call site — the collision the proposal asked us
  to check is real, and it is between the two modules rather than with `Kernel`. `map/2` and
  `filter/2` arrive as `set_map/2` and `set_filter/2` because an unqualified `map/2` in a
  spec body reads as `Enum.map/2` to every Elixir programmer. The gate is derived, not
  written down: `test/tla/spec/operator_agreement_test.exs` reads `lib/tla/spec.ex`'s own
  `__using__` imports for what is reachable, requires every foundation export to be
  reachable under its own name or a listed alias, and reads `lib/tla/spec/helpers.ex`'s AST
  so that an operator *implemented* there rather than delegated fails the build. A seventh
  differential corpus entry, `test/differential/set_vocabulary/`, is the only one whose
  subject is the vocabulary rather than an algorithm: it calls the operators the way an
  author writes them and TLC says whether they mean what TLA+ means (12 states, diameter 5).
  The Paxos entry's fully-qualified `TLA.Set.powerset/1` is now a plain `powerset/1`.
  `test/docs/spec_api_test.exs` learned to read `defdelegate` as a head, since the block it
  gates is now mostly delegations and a reader that skipped them would exempt exactly the
  block that had just been rewritten.

- **The four declaration kinds agree about a non-boolean, the wrapper stops warning in the
  user's module, and the formatter covers the repository** (#317, closes #182).
  02-dsl-semantics.md §4.2 says "a boolean expression" for invariants, action properties,
  preconditions and postconditions, and notes no difference between them — but the invariant
  path read the value with `unless` while the condition paths matched `true` and `false`
  exactly. So a precondition returning `nil` (a `Map.get/2` on a key that is not there is the
  ordinary way to get one) **killed the server with a `CaseClauseError`** naming a generated
  function, where the same `nil` from an invariant was reported as a violation of the
  declaration the user wrote. The `:verbose` paths diverged a third way, treating a *truthy*
  non-boolean as a violation — so telemetry could change a verdict. All six check paths now
  share one reading, and it is Elixir's own truthiness. Separately, the wrapper bound
  `tla_new_state` unconditionally, so a module carrying **only preconditions** got
  `warning: variable "tla_new_state" is unused` about code it did not write and paid an
  extraction call per transition against the zero-cost principle; the binding is now guarded
  on whether anything downstream reads it, and
  `test/tla/declaration_shapes_test.exs` compiles **all sixteen** declaration combinations,
  because the defect lived in exactly one of them and a test of one combination is what let
  it. `.formatter.exs` covered `{bench,config,lib,test}` while `bin/`, `ledger/` and
  `scripts/` held real Elixir — the CHANGELOG guard, the surface-drift ledger and its six Mix
  tasks — and one of those files was **unformatted while the `format` job passed**; the
  inputs are widened and `test/docs/formatter_inputs_test.exs` holds them to the set
  `git ls-files` reports. Dead code goes with it: `TLA.Config.max_states/0`, which nothing
  read and which duplicated `TLA.ModelChecker`'s own default (two copies of one number is the
  defect class, so it is deleted rather than synchronised — and `spec/01-foundation.md` says
  why); `TLA.Profile.calibration_samples/0`, a published function with no caller and no test;
  and an unreachable third clause of the private `from_init/3` in `TLA.Trace`. The
  ten-percent failure-injection probability was a literal inside the injector with no way to
  reach it, and is now `failure_rate:`, defaulting to `0.1` and pinned by agreement against
  an explicit `0.1` under a fixed seed.

- **A run releases what it allocated: the graph's ETS tables, and the replay's server**
  (#316, for #182). An ETS table is owned by a *process* and is not reachable from a term, so
  discarding a `TLA.StateGraph` freed nothing. `TLA.ModelChecker.run/2` discards the graph and
  left both tables holding one record per distinct state for the **calling process's**
  lifetime — twenty runs, forty tables. It was invisible under ExUnit, where every test is its
  own process and a process's exit takes its tables with it, and it accumulated exactly where
  processes are long-lived: `mix tla.check A B C`, `TLA.Spec.Test`, the ledger's corpus pass.
  `run/2` now searches in a process of its own, so the tables are created there and the
  child's exit is what frees them — on the normal path and **on a raise**, with no `try/after`
  and no delete to forget at a call site. The exception is re-raised in the caller with the
  stack it was raised on, so nothing is swallowed; the cost is one crash report on stderr from
  the isolated process before the diagnosis, which is the same trade `TLA.Ledger` already
  makes. `explore/2` keeps its tables, because the graph *is* its return value, and now says
  so where it is returned — the specification already promised "the caller owns the graph, and
  its ETS tables with it: `run/2` is this with the graph dropped, and it releases them", which
  was true of no code. `TLA.StateGraph.delete/1` is the release that contract needs, and is a
  no-op on a graph already gone. `TLA.Replay` likewise left a live `GenServer` per replay
  where `TLA.Simulation` — the same shape one door over — stops its own; it now stops the
  server it started, the way a supervisor stops a child, and leaves a caller-supplied
  `:server` alone. Counted, not reasoned about: `test/tla/resource_lifetime_test.exs`
  measures the graph's own tables by name and the servers by `$initial_call`, and reproduces
  both numbers — forty and twenty — against the unfixed code.

- **The four `rescue` sites in `lib/` are reviewed one at a time, and the two that hid a
  failure are narrowed** (#315, for #182). CLAUDE.md forbids `try/catch/rescue`, but a count
  is the wrong reading of the rule: a rescue scoped to a *function* rather than a *call*
  reports any failure underneath it as the one it was written for, which is not a swallowed
  error but a **confident wrong diagnosis**. `TLA.Refinement`'s totality probe was scoped to
  the whole of its enclosing function, so a `FunctionClauseError` raised by a *helper* the
  mapping's catch-all called came back as "`abstract_action/1` is not total — add
  `def abstract_action(_), do: :unmapped`", advice to add a clause the mapping already had,
  about a partial helper the message never named. It now reads one stack frame to tell the
  probed call's own failure from any other and re-raises every other untouched. `mix
  tla.explore` refused an undefined *local* name once and let an undefined *remote* call —
  `Enum.no_such_thing(count)` — fill a cell per state, the exact outcome the probe's own
  comment says it exists to prevent; a deterministic failure is now refused once, like a
  `CompileError`. The two that stay stay for a stated reason — for both, the exception is
  data about the **user's own input**, so a blanket removal would have made the trace
  explorer worse than it was — and `mix tla.check`'s is scoped to the single call that
  raises rather than to a body that also builds the config. `test/docs/rescue_inventory_test.exs`
  is the recurrence guard: it names every permitted site, requires a `# PERMITTED RESCUE`
  comment beside each, and fails a rescue that covers more than one call — which is the
  defect itself, gated rather than remembered.

- **The decision log is reopened, and every decision is pinned to a test** (#275, for #176).
  `spec/08-decisions.md`'s last edit was 2026-08-31; **fifteen decisions were made in the
  three weeks after it**, in commit messages and moduledocs where nobody looking for the
  project's reasoning would find them — and one of them contradicted D-18 in the same file
  that cites it. Four decisions are amended (D-7's tagged delivery, D-10's `allow_incomplete`
  escape hatch, D-17's refusal to compare a truncated run, D-18's `desc:` surface), five are
  backfilled as D-28–D-32, and **all thirty-two now carry a `Pinned by:` line** naming the
  test that would fail if they were reversed — or `nothing — <why>`, because "unguarded by
  decision" and "unguarded by oversight" read identically in an empty space.
  `test/docs/spec_decisions_test.exs` holds the two to each other, and `spec/README.md` states
  the three rules that keep this specification true.

### Added

- **`mix tla.stamp --check` exits 1 on a stamp nothing verifies — and there is deliberately
  no CI job for it** (#311, closes #173). The task exited 0 whatever it found, so it could
  never gate, while its own documentation calls a stale stamp a compile error and the task
  "part of the layer's surface, not a convenience".

  `--check` asks one question of each mapping: **is this stamp verified by something?**

  | status | verified by | `--check` |
  |---|---|---|
  | `:fresh` | this task | 0 |
  | `:stale` | this task — and it is **wrong** | **1** |
  | `:unstamped` | nothing to verify; the mechanism is opt-in | 0 |
  | `:unverifiable`, spec source not on disk | nothing | **1** |
  | `:unverifiable`, `spec:` not a literal alias | **the compiler** | 0 |

  **The last row is the finding, and it reverses what #173 assumed.** A `spec:` given as
  `@an_attribute` cannot be resolved by a task that reads source without compiling — but
  `use TLA.GenServer` has the attribute's *value* at expansion, so the compile-time check
  verifies that stamp completely. Measured: `attribute spec, stale stamp:
  {:raised, TLA.Spec.CompileError}`. Failing a build on it would be a false finding about a
  mapping that is fully checked, and a false finding is how a check gets turned off.

  **No CI job**, which is the other half of the answer #173 expected a yes to. A stale stamp
  is *already* a compile error and a spec with no source on disk *already* emits a compile
  warning, so on any project compiling with `--warnings-as-errors` both arrive from the
  `compile` job, earlier and with a better message. A job here would be a second way to
  learn the same thing and a second place to keep in step.

  So the flag serves the workflow the compiler **cannot**: the project does not compile, and
  a script wants the list of mappings to re-read rather than one error at a time — which is
  the situation this task reads source for. It is a flag and not the default because a
  *report* that exits non-zero by default breaks every script that runs it for the numbers.

  D-37 records all of it; `CLI_SURFACE.md` loses its "NO EXIT-CODE TABLE" note.

- **`mix tla.stamp` is exercised end to end, over a tree with all four statuses** (#308, for
  #173). It is the only code in the project that rewrites files under `lib/`, and it was the
  least covered thing in it: **replacing `run/1`'s entire body with a raise left the full
  suite green**. The tests called `states/0` and `module_index/0` and nothing else.

  Two of its four statuses had **never executed**. The real corpus holds only fresh and
  unstamped mappings, so collapsing `:stale` and `:unverifiable` into `:fresh` stayed green
  and the coverage gate did not move, because the golden records `stale 0`. Dead with them:
  both `detail/1` clauses, the "N stale" report, and the documented stale-wins-over-fresh
  precedence. Nor could the corpus hold them — a genuinely stale stamp in a compiled tree is
  a **compile error**, which is what the mechanism is for.

  So `test/fixtures/stamp/` is a tree outside every path the task scans and outside
  `elixirc_paths` in every environment: inert, invisible to this repository's own report,
  and unable to fail a build once #311 makes the task gate. `run/2`, `states/1`, `sources/1`
  and `module_index/1` take their roots as an argument for exactly that — a seam, said to be
  one, rather than a `--root` flag added to the CLI for a test.

  It also separates two defects that look alike: `unverifiable.ex` **reaches** `state/2` and
  is given a status, because its spec's source is not in the index; `dropped.ex` never gets
  that far, because `spec_of/1` returns `nil` for a `spec:` that is not a literal alias and
  the mapping is silently rejected. The second is #173's defect 4, pinned here so that #310
  changing it is deliberate.

### Changed

- **`mix tla.stamp` scans the project's own `elixirc_paths` rather than hardcoded
  directories** (#308). It appended `["lib", "test", "ledger"]` unconditionally — `ledger`
  is a directory of *this* repository, and a consumer running the task got it scanned along
  with their whole `test` tree. `elixirc_paths` is the project's own answer to "where is my
  code", and for this repository it already names `ledger` and the compiled test trees:
  measured before and after, the same 95 sources and the same 8 mappings.

- **The refinement mapping says how a message is delivered, and a cast's completion has an
  answer** (#305, for #172). A decision, not yet a change to the driver — D-36 records it
  and #306 builds it.

  `TLA.GenServer.Driver` sends `{:"$gen_call", …}` unconditionally and is the sole delivery
  path for both Layer 3 drivers, while **spec/05's own canonical refinement maps
  `:complete_transfer` and `:reset` to `handle_cast/2` clauses**. Delivered as a call those
  reach `handle_call/3`, which has no matching clause: the server dies and replay reports
  `:not_followed` — "the spec permits a behaviour the implementation does not take" — about
  a server that is correct. The gap is exactly *checked but not drivable*, and it went
  unseen because the whole conformance corpus uses `handle_call` only.

  **The contract.** `concrete_message/2` may return `{:call, msg}`, `{:cast, msg}` or
  `{:info, msg}`; a bare term is a **call**, which is what it has always meant, so no
  existing mapping changes. The one ambiguity a tagged tuple introduces has a total escape:
  `{:call, {:cast, 5}}`. Inferring delivery from which callback matches was rejected — it
  guesses, and a message two callbacks both match is not decidable that way — and declaring
  it spec-side was rejected as the wrong layer.

  **When a cast is done**, which is the hard half: a **monitored `:sys.get_state/2`**. It is
  a system message through the same mailbox, so it is ordered behind the cast just sent.
  Cost stated rather than asserted: **no additional round-trip**, because both drivers
  already make that call once per step to map the post-state through `abstract/1`. All four
  outcomes stay distinguishable through the monitor, and a cast that never completes is a
  named `{:timeout, ms}` finding, never a silent "followed".

  Both reader-facing documents carry a "not yet delivered (#306)" marker, and
  `test/docs/delivery_contract_test.exs` holds spec/05, `usage-rules.md` and D-36 to the same
  forms — **and asserts the driver still sends a call unconditionally**, so the marker
  cannot outlive the work it points at. The gate retires itself when #306 lands.

- **`usage-rules.md`, and it is gated** (#292, for #181). The project's own governing
  instructions require one and there was none — but the convention is the weaker half of
  the case. The stronger half is that **the DSL is written in Elixir syntax and is not
  Elixir**: assignment is a next-state relation rather than a rebinding, `^name` is a
  constant rather than a match pin, `require` is an enabling condition rather than
  `Kernel.SpecialForms.require/2`, and guard order decides between a disabled action and a
  raised `DomainError`. An agent writing what looks like ordinary Elixir gets each of those
  wrong, and each is a compile error or a silent misspecification. It ships in `files:`, so
  `mix usage_rules.sync` can pull it into a consumer project.

  A usage-rules file is a hand-written enumeration of what the compiler refuses, which is
  this project's most familiar defect class — so it is held to the generated goldens rather
  than trusted. Every diagnostic kind it names must exist in `DIAGNOSTICS.md`; every `D-n`
  it cites must exist in `spec/08-decisions.md`; every `mix tla.*` it tells a reader to run
  must be one the package ships, per `CLI_SURFACE.md`. Its six code blocks are under the
  guide harness like every other page. Demonstrated red by citing `:no_such_diagnostic`
  and `D-99`.


### Fixed

- **`--fingerprint-bits` is refused at the flag, and the two outcomes nothing exercised are
  gated** (#314, closes #180).

  `--fingerprint-bits 7` was passed straight through and raised an `ArgumentError` from
  inside `TLA.Fingerprint`, **mid-search**, with a stack trace through the checker — a typo
  in a flag reported as though the library had failed, after the run had begun.
  `--workers` was already refused at the flag; this is the same treatment, and the widths
  are **asked of `TLA.Fingerprint`** rather than restated, so a width added there cannot
  leave the flag refusing it. Neither flag's refusal had a test; both do now.

  **The other two items were not what they were filed as, and the difference is the point.**
  #180 called `mix tla.simulate`'s exit 2 "produced by nothing" and the "server did not
  answer" path "entirely dead, reachable by nothing". Measured before writing anything:

      TLA.Simulation.run(SlowServer, %{timeout: 200})
      #=> {:error, "no reply within 200ms"}

  Both were **reachable and untested** — a coverage gap, not dead code. The code was right
  and nothing held it to that. So nothing was deleted and nothing was added to make them
  reachable; they are gated, by two routes each, with the measurement recorded beside them.

  The task-level exit-2 test goes through an `init/1` that declines rather than through the
  timeout, because `mix tla.simulate` has no `--timeout` switch and a task-level timeout
  test would wait the default five seconds per step. Adding a flag to make a test convenient
  is surface this issue did not ask for; the timeout path is gated at the library level,
  where it runs in 200ms.

- **`--against-graph` is one suite, under the options it was given** (#313, for #180). It
  ran the full simulation and then **another `--traces` simulations**, one at a time — so
  `mix tla.simulate X --traces 10000 --against-graph` ran twenty thousand traces.

  Worse than the cost: the second suite forwarded **two of the five** options. So
  `--unrestricted --against-graph` audited containment with the **restricted** generator
  while printing that every state was a node and every step an edge; `--inject-failures` and
  `--concurrency` were dropped the same way; the two suites disagreed about the step default
  (25 and 20); and their seeds were derived differently, so *"trace 7 (seed 8)"* named a
  trace the reported seed does not produce at index 7.

  **The graph is built once and handed to `TLA.Simulation` as `against_graph:`**, which
  holds each behaviour against it as that behaviour finishes — beside the temporal check,
  which is the other per-trace question. That is the proposal's second option, and it is the
  larger change it predicted: forwarding, the step default and the seed derivation are not
  three fixes but one, because **one suite cannot diverge from itself**.

  Leaving the graph is its own outcome, `:left_the_graph`, and **not** a conformance
  violation: the implementation may have been right and the *search* wrong, which
  `TLA.Conformance`'s `:checker` class is for and which no other gate in the project can
  produce. Collapsing it into `:violation` would name the implementation for a defect that
  may be the checker's.

  It also settles defect 3's second half at no extra cost: the old check wrote to the shell
  **before** the format dispatch and could exit before reaching it, so `--format json`
  produced an unparseable file and a discarded result. With the check inside the one suite
  there is no earlier writer, and the finding's class travels in the JSON.

  The tests assert on the **config a trace runs under**, never on the report — the old
  second suite printed "every state a node and every step an edge" while using the wrong
  generator, so the output was exactly what could not be trusted.

- **`mix tla.visualize --max-states` bounds the search, and a partial picture is never drawn**
  (#312, for #180). The flag was read **after** `explore/2` and gated rendering only, so the
  search ran to the checker's own million-state default — exploring up to a million states in
  order to draw none of them, and, where that default was *reached*, drawing a truncated
  graph with **no note and exit 0**, as though it were the whole state space.

  It bounds the search now, and means here what it means in `mix tla.check`: **how many
  states to explore**, and therefore at most how many to draw. That removes the truncated
  render by construction rather than by adding a note — past the limit there is nothing to
  draw, so a graph that *is* drawn is one the search finished.

  **The refusal exits 2**, not `Mix.raise`'s 1. `1` here already means "the spec has a
  violation", and a graph too big to draw is not a finding about the spec; `2` is
  `mix tla.check`'s code for a run that did not see the whole state space, which is exactly
  what this is.

  **The cost is stated rather than hidden.** The moduledoc promised the refusal "names the
  real count", and a bounded search cannot know it — so the message says **more than N**.
  That promise was already unkeepable: the number it printed on a truncated run was the
  truncated one. Measured, including the overshoot the message must not present as a census:

      limit=500      status=:max_states_reached  states=502   refuses
      limit=1000000  status=:ok                  states=1000  refuses

  Both rows refuse, which is why the truncated-render case disappears. The existing test
  asserted `"4 states"` — the size of the whole state space, knowable only because the task
  searched all of it to draw none of it — and now asserts that the number is not offered as
  a census.

- **`mix tla.stamp --restamp` handles two stale mappings in one file, and reports a mapping
  it cannot read rather than dropping it** (#310, for #173).

  **The crash.** `rewrite!/1` uses `String.replace/3`, which replaces every occurrence by
  design — and two mappings in one file sharing a stale stamp is the **normal** case, since
  they share a spec and therefore a resolution. `restamp/1` still iterated per mapping, so
  the first call fixed both and the second found nothing: `Mix.raise` told the user to
  hand-edit something already done, and **aborted before any other file was processed**,
  which is most of the damage. It is one rewrite per `{file, stamp}` now, and the guard on a
  stamp that genuinely is not there is unchanged.

  It **refuses rather than guessing** where a group's members resolve to different versions
  — an 8-hex collision between two specs in one file. Rewriting them together would stamp a
  mapping against a spec nobody read it against, and `--restamp` records a judgement rather
  than performing one.

  **The silent drop.** `spec_of/1` returned `nil` for a `spec:` that is not a literal alias
  — `@an_attribute`, a variable, anything the AST does not name outright — and `mappings/1`
  rejected the entry, so the task could go on to say "no refinement mappings found" about a
  file it had read and could not understand. That collapses *cannot be checked* into
  *absent*, which is the one thing the four-status design exists to prevent. Such a mapping
  is `:unverifiable` now, and because `:unverifiable` has two causes calling for different
  fixes, the report says which:

      (spec source not found)
      (spec: is not a literal alias, so it cannot be resolved without compiling)

  Both demonstrated red, and every `--restamp` test works on a **copy** — one that let the
  task rewrite the committed fixture would pass once and then run forever against a tree
  with no stale stamp in it.

- **A bounded run stops accusing, and `--strict-coverage` fails on exactly what the
  specification gives it** (#307, closes #167). Three defects, one theme: a run that did not
  see the whole state space may not make a negative existential claim.

  **The rule, applied once instead of four times.** *No reached state satisfied P* is not
  supportable by a bounded run — it cannot tell a P nothing satisfies from a P whose states
  it never got to. #128 established that for `never_enabled` and it stopped there. The other
  three are the same claim in different words: `:antecedent_never_held`, an invariant with
  zero near misses, and — not named in the proposal — `:consequent_always_held`, which is the
  same claim with the quantifier turned around. All four now downgrade together, and each
  keeps its line in the report carrying the qualifier `never_enabled_line/2` has used since
  #128.

  **`:constrained` meant "a constraint was configured", not "a constraint bound this run".**
  An exhaustive run whose `state_constraint` never fired was reported as unverified, exited
  2, and flunked `assert_spec` — over a predicate that turned out to exclude nothing. The
  coverage accumulator now counts `held_back` where the constraint is applied, so it merges
  correctly under `--workers`, and both the status and `bounded_by` are derived from it.

  **`--strict-coverage` failed on two conditions the specification never gave it.** spec/04
  scopes it to a never-enabled action or a vacuous property and says of `terminal_but_live`
  that it is "not an error — nothing is cut"; the code also failed on that and on zero near
  misses. The root cause was one predicate answering two questions, so they are now two:
  `clean?/1` decides whether there is anything worth **printing** — including the two that
  are not errors — and the new `strict_failures/1` decides what may **fail a build**.

  **The specification's own worked example was the witness.** It renders
  `type_ok … <-- never at risk` and then counts **2 warnings**; the code counted three and
  failed on all of them. The footer now counts `strict_failures/1`, so the sentence beside
  the number — "fail on these" — is true of the things counted. `test/tla/bounded_accusation_test.exs`
  reads the number **out of spec/04** rather than restating it, so an edit to the example
  moves the test.

  All three demonstrated red.

- **An action the server takes by cast is drivable, not merely checkable** (#306, closes
  #172). `TLA.GenServer.Driver` sent `{:"$gen_call", …}` unconditionally and is the sole
  delivery path for both Layer 3 drivers, while **spec/05's own canonical refinement maps
  `:complete_transfer` and `:reset` to `handle_cast/2` clauses**. Delivered as a call those
  reached a `handle_call/3` with no matching clause: the server died and replay reported
  `:not_followed` — "the spec permits a behaviour the implementation does not take" — about
  a server that is correct.

  `Driver.deliver/3` now routes by the form the mapping returns — `{:call, msg}`,
  `{:cast, msg}`, `{:info, msg}`, and a bare term is still a call, so no mapping written
  before this changes. D-36 has the reasoning; `call/3` remains, as `deliver/3` with a
  `{:call, …}`.

  **A cast completes at a `:get_state` system message sent straight after it**, which rides
  the same mailbox and is therefore ordered behind it. Sent raw rather than through
  `:sys.get_state/2`, because that function *exits* the caller on a timeout or a dead
  server and turning an exit back into a value needs a `try/rescue` — which is what this
  module exists to avoid. So all four outcomes stay ordinary messages: a violation raised in
  `handle_cast/2` kills the server and arrives as the same `:DOWN` a call's would, and a
  cast that never completes is a `{:timeout, ms}`, a named finding rather than a silent
  "followed". A driver that moved on unconfirmed would compare the next action against a
  stale state, which is #168's defect class.

  **The compile-time round-trip strips the route before asking**: `abstract_action/1` is
  given what the callback will receive, not the envelope. Without that, a mapping correctly
  saying `{:cast, :done}` round-trips to `:unmapped` and `validate!/3` reports the action as
  one the mapping can never produce — a false finding about a correct mapping, worse than
  the gap it was added to close. It was the first thing that broke.

  **The corpus entry is the substance, not a nicety.** This went unseen because every entry
  in the conformance corpus was `handle_call`-only — a corpus that cannot express a case
  cannot find a bug in it. `Impl.HandlesACast` takes `done` by cast and `reset` by info,
  keeps `increment` a bare term, and is exercised by **both** Layer 3 drivers, since they
  share one delivery path and a fix tested through one proves nothing about the other.

  Demonstrated red: routing casts back to calls fails the new entry with exactly the
  `:not_followed` above.

- **A lasso replays, and a step that names no spec action no longer crashes the replay**
  (#304, closes #168). Two defects in `TLA.Replay`, both on the path from a counterexample
  back to the code — the loop that makes the three layers one tool.

  **The splice.** `ModelChecker.Liveness` builds a cycle with
  `Trace.from(graph, List.last(prefix.states), cycle_steps, [])`, and `Trace.from/4`
  prepends the state it is handed, so the cycle's first state **is** the prefix's last.
  `to_behavior/1` compensates; `splice/2` adjusted `length` for it and **not the list**
  (#212 saw half of it). `drive/5` zips actions against `Enum.drop(states, 1)`, so from the
  first cycle step onward every action was compared against the state *before* it, and
  **every genuine liveness counterexample replayed as `:not_followed`** — which reads as
  "the implementation does not take a step the spec permits". A true finding, inverted.

  It survived because the only lasso in the suite was hand-written and `Trace.validate/3`
  **rejects it**: `length: 1` on a two-state prefix, a one-state cycle carrying an action,
  and a cycle head that is not the prefix's tail. The liveness checker cannot emit that
  shape, so the one test covering the splice exercised something the defect could not
  reach. `test/conformance/replay_edges_test.exs` replaces it with a lasso the checker
  **actually returns**, asserted to pass `validate/3` before it is used for anything.

  **The steps that name no action.** A trace's `actions` are not all actions of the spec:
  `TLA.Simulation` writes `:unmapped` for a message the mapping does not model — its
  *normal* answer — and `:restart` for a crash injected by `--inject-failures`.
  `concrete_message/2` has no clause for either and `drive/5` called it regardless, so the
  advertised simulation-to-replay handoff died with a `FunctionClauseError` on its ordinary
  input.

  `:unmapped` is **skipped, and the skip is reported** — in `skipped`, in the human report
  and in `--format json`. Its claim is that the message does not move the abstract state,
  so the behaviour is unchanged by it; the trace's post-state is still checked, so a step
  that claims to stutter and moves is still a finding. A replay that skipped steps and
  exited `0` would be the defect one door over.

  `:restart` is **reproduced**: the server is killed (`:kill` — a crash runs no
  `terminate/2`) and started again, and recovery is checked to land where the trace says it
  did, which is all `TLA.Simulation` checks about a restart either. Skipping it would
  compare the next step against the pre-crash state. Only for a server this module started:
  with `:server`, the replay refuses with the new `:not_replayable` status and
  `mix tla.replay` exits **3** — a limit of the replay, not a claim about the
  implementation, which is why it is not `2`.

  spec/05 documents both, the new exit code and the `skipped` field; all four defects were
  demonstrated red first.

- **One invariant for a behaviour trace, held by every producer** (#303, for #168). The
  rule — *n states, n - 1 actions, one binding each, `length` == n* — was already written
  down, as a private `misaligned?/1` in `TLA.Trace`, and checked at three **consumers**:
  `from_json!/1`, `to_diffs/1` and `legal_steps/4`. Two producers broke it and neither said
  so. It is now `TLA.Trace.well_formed/1`, public and documented, asserted by
  `well_formed!/2` where a trace is **built** — which is where the fix goes, and what the
  message names.

  `to_diffs/1`'s own comment records what checking it at the far end cost: the misalignment
  was found when `Trace.Explore` and `format/1` disagreed about one trace, three modules
  from where it broke, after `format/1` had rendered three states of four and marked the
  wrong one `[VIOLATION]` (#204, #260).

  **`TLA.Simulation`'s restart path** pushed a state with no action on a *successful*
  restart while its own violation branch pushed all three. Both branches now record the
  same step — a `:restart` from the pre-crash state to where recovery landed — and differ
  only in the verdict about it. It had to be the success branch that was wrong: a run that
  ends in a violation stops, and a run that recovers goes on to take more steps against
  `hd(states)`.

  **`TLA.GenServer.Runtime.record_initial!/3`** recorded a transition from the initial
  state to itself, and `record_transition!/4` seeds an empty buffer with its own `pre` — so
  the first state landed **twice** and every recorded behaviour opened with a step that
  never happened. Fed to `TLA.Conformance.against_graph/3` that self-step classifies as
  **forbidden**, and the layer's two behaviour sources therefore disagreed about the same
  server. It seeds the buffer now.

  The conformance corpus could not have caught the second one: its counter spec has
  `reset`, which from the initial `%{count: 0, status: :ready}` is a **self-loop**, so the
  duplicated state was a legal step of that spec. `test/conformance/behaviour_invariant_test.exs`
  adds `Ratchet`, which has no self-loop anywhere — with a test asserting that, since it is
  the property the central test rests on.

- **`use TLA.GenServer` compiles for a server with no author-written `init/1`, and every
  moduledoc example is compiled** (#301, closes #171 with #300). #300 fixed the injection
  for Layer 1 and left Layer 3, where the same defect is **unconditional** — so
  `TLA.GenServer`'s own front-page example was still broken after the fix that was supposed
  to close it. Layer 3 now filters its wrapped set through `Module.defines?/3` the same way
  Layer 1 does.

  It was found by the gate filed in the same work item rather than by a reader.
  `test/docs/moduledoc_examples_test.exs` extracts every `defmodule … end` from a doc string
  under `lib/` and compiles it in its own process, observing the exit. Nothing was checking
  these: the guide harness globs `guides/`, `spec/` and `README.md` (#281), doctests cover
  six modules, and the options gate reads option lines rather than code — a `defmodule` in a
  moduledoc was checked by nothing at all, which is how the first thing a reader copies
  could be wrong for as long as it had existed.

  A moduledoc has nowhere to carry a `<!-- tla:… -->` annotation, so **compiled is the
  default and the exceptions are listed with reasons** — one, `TLA.Invariant.Test`, because
  compiling an `ExUnit.Case` module outside a running ExUnit raises and it is the reader's
  suite that runs it. Forgetting an exception reddens the build; a skip naming a file with
  no example reddens it too, and the corpus size is asserted, so an extraction that silently
  found nothing cannot report green.

- **A GenServer with no author-written `init/1` compiles** (#300, for #171). It failed with

      ** (ArgumentError) cannot make function init/1 overridable because it was not defined

  from `Module.make_overridable/2`, naming neither this library nor the cause. Layer 1 hit
  it for any module with an invariant that applies to `init`; `use TLA.GenServer` hit it
  **unconditionally**. The example at the top of `TLA.Invariant`'s own moduledoc — the
  first thing a reader copies — produced it.

  `@on_definition` keeps the wrapper off the defaults `use GenServer` injects, which is
  what the moduledoc claimed, and it is true of `handle_call/3`, `handle_cast/2` and
  `handle_info/2`: GenServer injects those in `__using__`, **before** the hook is
  installed. `init/1` it injects from its own `@before_compile`, **after** — so the hook
  does see it, `{:init, 1}` lands in the wrapped set for a module that never wrote one, and
  by then GenServer's `defoverridable init: 1` has moved it out of the definitions table.

  The wrapper is now emitted only for a callback still in the definitions table when
  `__before_compile__/1` runs — which is exactly what `make_overridable/2` requires, asked
  as a question rather than assumed, so it is right for any future callback of the same
  shape rather than a special case for one name. The moduledoc says what is true of
  `init/1` instead of denying the case.

- **`spec/05` says which of its five rules are decided at compile time, and the probe draws
  every binding it can** (#298, closes #169). The section listed five rules "checked, in
  order" and said a mapping not covering the spec's variables "fails the build". Neither
  was true: rules 1 and 2 need a concrete state and are enforced per-callback at runtime,
  rule 5 runs only where the optional `concrete_message/2` exists, and rule 4 was sampled.
  The section now sorts them into decided, probed and deferred, and says why each is where
  it is.

  **The widen-or-not question #169 refused to assume, measured** (D-35). The probe took
  three bindings from the first `init` block; across the differential corpus every action
  has between **0 and 4** bindings at an initial state, because the sets a param draws from
  are mostly empty there — no messages in flight, no locks held — and every corpus spec has
  exactly one `init` block. So the cap was excluding at most one binding per action and the
  first-block restriction nothing at all. It now draws every binding every `init` block
  yields, which is every binding a compile can construct.

  It remains a **probe**, and the specification says so: bindings reachable later in the
  search cannot be drawn without running the search, and running it at compile time is not
  a probe — it is the check the model checker already performs.

- **The deferred list reaches the user, and constants are resolved the way everything else
  resolves them** (#297, for #169). `TLA.Refinement.validate!/3` is built to return the
  rules it could not decide — its moduledoc argues that "a validator that claims a check it
  cannot perform is worse than one that states its limits" — and the only call site was
  `{:ok, _deferred} = …`. A user whose mapping has no `concrete_message/2`, so action
  coverage was **never checked at all**, was never told.

  `use TLA.GenServer` now says so at compile time. Each deferred entry is tagged
  `:always` — the two rules that need a concrete state, deferred for every mapping — or
  `:for_this_mapping`, and only the second kind is printed. A compile-time message that
  fires on every module is one a reader learns to skip, which would leave the ones that
  matter unread.

  It is a **message and not a warning**, and the distinction is load-bearing:
  `concrete_message/2` is an `@optional_callbacks` entry, so a mapping without one is
  legal and documented — it can still be *checked* as it runs, it just cannot be *driven*.
  `IO.warn/2` participates in `--warnings-as-errors`, which this project uses and many
  consumers do, so warning there would turn a documented choice into a build failure. The
  first version of this did exactly that, and the `compile` job caught it on this
  repository's own `Undrivable` fixture.

  **Constants:** `validate!/3` fell back to `default_constants/1`, which reads `default:`
  options and nothing else, so a spec assigned through
  `config :extla, MySpec, constants: %{…}` was validated against the **empty** assignment
  and reported its rules as decided. `resolve_constants/1`, which merges config, was in the
  same module and simply not the one called.

- **The TLA+ primer says which parts of TLA+ this library implements** (#293, closes #181).
  1321 published lines with **zero** occurrences of "ExTLA", shipping in the package and
  rendering in the sidebar, with chapters on PlusCal, TLAPS and TLC's distributed mode. A
  reader arriving from the sidebar got TLA+ with nothing indicating which parts this tool
  implements, which it does not, and which are translated into Elixir syntax.

  The header now says all three, and points at the tutorial for the mapping and at
  `usage-rules.md` for the rules. PlusCal gets the accurate framing rather than a claim the
  project does not make: it is TLA+'s algorithm language and ExTLA's DSL fills that role in
  Elixir, so those chapters describe a notation this library does not use. Not being a
  theorem prover **is** a stated non-goal, and the header cites `spec/06` §Non-goals for
  it — which `test/docs/primer_framing_test.exs` holds to that section, so a non-goal
  becoming a goal cannot leave this page contradicting the architecture.

  **#291's gate caught two real defects while this landed**, which is the first work it has
  done since it was turned on: `usage-rules.md` shipped in `files:` but was not an ExDoc
  `extras:` page, so the primer's link to it would have 404'd in the published docs; and
  the usage rules linked `DIAGNOSTICS.md`, which is a generated golden this repository
  keeps and **does not ship**, so a consumer following it would find nothing. The first is
  fixed by publishing the page, the second by pointing at `spec/02` §7 — the table a
  consumer actually receives.

- **Strong fairness is refuted by something, and the parallel search is asserted to be
  parallel** (#296, closes #174). Two mechanisms that were only ever exercised in the mode
  where they cannot be told apart from their own absence.

  **The Emerson–Lei split.** `weak_break/3` breaks a cycle only when the action is enabled
  in **every** state of it; `strong_break/3` when it is enabled in **any**. That difference
  is the whole of what makes SF stronger than WF, and every strong-fairness fixture was
  only ever *verified* — which `[]` achieves just as well, so replacing the strong branch
  with `[]` left the suite green. Two specs now differ by the single word `:strong`: an
  action enabled intermittently in a cycle and never taken is **fair** to WF (the run is
  refuted) and **unfair** to SF (the run verifies). The verdicts differ, so the branch is
  the only thing that can be producing them.

  **The parallel path.** Setting the batch count and the concurrency both to 1 made
  `TLA.ModelChecker.Parallel` fully sequential and left everything green, because every
  parallel test asserts agreement with the single-threaded result — which a sequential run
  satisfies perfectly. Agreement is the right property and it cannot see this. `batches/2`
  and `concurrency/1` are now `@doc false` and asserted directly: 200 states over 8 workers
  is 64 parts, every state in exactly one, and the stream is told to run that many at once.

  What that establishes is stated in the test rather than implied: the work is **divided**
  and the stream is **told** to run the parts concurrently. It does not establish that the
  scheduler ran two at the same instant, and no deterministic test can — a timing assertion
  would be a flake on the two-core runner rather than a gate.

- **Two checks that could not fail** (#295, closes #175). The Agent layer's `cast/3` and
  `TLA.Invariant.Test`'s `assert_invariants/2`, each proven by #175 by mutating the code and
  watching the suite stay green, and each now demonstrated red against that mutation.

  **`Agent.cast/3`** is the path D-25 is about — an `Agent`'s checks dispatch at runtime and
  `:disabled` still costs a call there — and replacing its `check_agent_step!/3` with a
  plain call left everything green. A cast is asynchronous, so a violation arrives as the
  agent's **exit**, which is exactly what made the check invisible unless something watches
  for it; the test now does.

  **`assert_invariants/2` passed for every state** when a module's invariants had all been
  compiled out by `enabled: false`. `__tla_names__(:invariant)` is then `[]`, the
  comprehension over it is `[]`, and `[]` means "nothing failed". A project that compiles
  its invariants out in production and runs this assertion in a release test was asserting
  nothing, including about the states the invariant existed to reject. It now raises, naming
  `enabled:` as the usual cause. **`refute_invariant/3` has guarded its equivalent since it
  was written**, through `__ensure_declared__/2`; the asymmetry between the two was the
  finding.

  `assert_action_properties/3` had the identical hole and is fixed with it — #175 named only
  the first, and fixing a mechanism at the site it was found is how it goes on running one
  door over (#192).

- **The docs build fails on an unresolved reference** (#291, closes #156). The `docs` job ran
  `mix docs` with no `--warnings-as-errors`, so it emitted warnings and **exited 0** — ten
  when #156 was filed, **34** by the time it was implemented. `TLA.DocLinks` cannot see them:
  it scans `@href` in the built HTML, and an unresolvable reference emits **no href at all**,
  rendering as plain inline code. A gate that cannot see the surface the defect lives on,
  which is #102's shape one door over.

  **Three of the thirty-four were introduced by #277, two days after D-30 was written, by the
  same hand.** Its moduledoc table named `Liveness.shape/4`, `GenServer.Runtime.verdict/3` and
  `Coverage.walk/3` in the backticked autolink form that D-30 exists to forbid, and nothing
  said so. D-30's `Pinned by:` promised this gate; it now names it.

  The thirty-four fell into four classes and each got the treatment its class calls for:
  **wrong markup, right name** — a callback needs `c:`, a type needs `t:`, and
  `Kernel.require/2` is `Kernel.SpecialForms.require/2`; **prose about an internal**, which
  D-30 governs, reworded to name the function plainly; **removed or renamed functions in
  `CHANGELOG.md`**, which D-30 explicitly exempts — *a changelog that cannot name a removed
  function cannot record a removal* — implemented as
  `skip_undefined_reference_warnings_on: ["CHANGELOG.md"]` rather than by rewording history;
  and **references to filtered modules**, for which ex_doc offers no exemption (its warning
  is unconditional) and which D-30's *main* rule covers anyway, since a module
  `filter_modules` keeps out of the published docs is an internal from a consumer's point of
  view.

- **Eight assertions that held when the code under test was broken** (#294, for #175). Each
  was proven by #175 by mutating the code and watching the suite stay green, and each fix
  here was demonstrated red against that same mutation — a fix nobody saw fail is the
  defect one layer up.

  Two were unreachable by any ordinary assertion, because both are claims about a wrapper
  that is **absent**, and absence leaves no trace. Under `telemetry: :verbose` it does: a
  wrapped callback emits `[:extla, :invariant, :checked]`, so "this callback was not
  wrapped" becomes "this callback fired no event" — a positive observation. So
  `callbacks: [:handle_call]` is now proven by a `cast` firing one event and a `call`
  firing two, and "no wrapper on the callbacks `use GenServer` injected" by an unhandled
  message reaching the injected `handle_info/2` and contributing nothing. The old test
  asserted `refute function_exported?(Account, :handle_continue, 2)` — and `use GenServer`
  does not inject `handle_continue/2` at all, so it held whatever the wrapper did.

  The rest: the symmetry warning the test was **named** for is now produced and asserted
  (it asserted two factorials, which hold whatever the warning does); the diagnostic's line
  is compared against where the offending token actually is, not `is_integer/1`, which line
  0 satisfies — and this is the only line assertion in the tree; the three violation-message
  tests assert the **rendering**, since a `defexception` with no working `message/1` falls
  back to inspecting the struct, which embeds every substring they were checking; the guide
  link gate asserts its corpus is non-empty, since renaming `guides/` left 57 of 58 tests
  green; the sorted-tree test compares the tutorial's order against a list it builds itself,
  because `Path.wildcard` already sorts and deleting the production `Enum.sort` stayed
  green; and one test was simply **misnamed** — it promised a per-binding vacuity report and
  asserted that nothing is reported, while the per-binding message is asserted by the nested
  quantifier test #200 added later.

- **The slug cross-check runs, for the first time** (#290, for #156). It validates
  `TLA.GuideCheck.Links.slug/1` against ExDoc's **real generated ids** — the only thing
  proving the link gate's anchor model is true, since every `#heading` link in every guide
  is accepted or rejected by that reimplementation. It lived in `test/guides/`, and the
  `docs` job — the only one that builds `doc/` — runs `mix test test/docs`. So in CI it
  always took its `else` branch, asserted that a directory does not exist, and passed.

  Its author had anticipated vacuity and written a guard; the guard fired on the wrong
  condition, so the check reported green for never having run. **This project's own
  cardinal sin, arriving through directory layout rather than through anyone's decision.**

  It now lives in `test/docs/slug_model_test.exs` with `@moduletag :needs_built_docs`
  (#217's mechanism, which `package_docs_test.exs` next door already uses — and whose
  moduledoc names this very test as what it was avoiding becoming), and its guard **fails**
  on an absent `doc/` rather than passing. Run against a real build it passes, which is the
  first evidence the slug model was ever correct.

- **The guides are reachable from the README** (#289, closes #155). `README.md` contained
  **zero** occurrences of `guides/`, `getting-started` or `tutorial` while linking into
  `spec/` eleven times, and its repository-layout table listed the offline proposal tracker
  and not the guides. `mix.exs` sets `main: "readme"`, so that is the first page every
  hexdocs reader lands on, and it routed them into the normative specification — which
  `mix.exs` itself calls "the authority" that the guides link *to*.

  The front page now opens the two paths by name, `guides/` is in the layout table, and the
  command list names all **six** packaged `mix tla.*` tasks rather than three
  (`mix tla.explore` and `mix tla.stamp` were absent, as #155 found; `mix tla.visualize`
  appeared only in prose).

  `test/docs/readme_entry_test.exs` holds that list to **`CLI_SURFACE.md`**, which is
  generated from the tasks that exist and gated by `surface-drift` — so the README's list
  is a fact about the code rather than a hand-kept set that goes stale the way the install
  pin did. It also fails if the README mentions a task that is *not* packaged, since a
  reader following it could not run one.

  The README's **proportions** are deliberately untouched: the Status section runs half the
  file, sits above the reasons to use the library, and "who is this for" is never stated.
  #155 left that for its own decision on the grounds that bundling a rewrite with a
  navigation fix would stall the fix, and the gate records that rather than quietly
  adopting it.

- **The tutorial's forward chain is restored, and gated** (#288, for #155). Nine of eleven
  pages ended with a `Next:` line; `07-layer3.md` ended with a "Where to next" section
  listing four links into `spec/` — the heading `getting-started.md` uses where it genuinely
  *is* an ending — and `08-modelling.md` ended with closing prose. A reader following the
  tutorial's own navigation finished page 07 and stopped.

  The three stranded pages are how to get from a system you have to a specification worth
  checking, what to do when the state space explodes, and how to keep a specification in a
  project: the three a reader with a real codebase needs most, reachable only from the ExDoc
  sidebar, which a reader of the repository does not have.

  Both contents lists described a seven-page tutorial and now describe the eleven-page one,
  including `01-mathematics.md`, which the introduction omitted despite it being its own
  `Next:` target. The duplicated `specification.` on the introduction's fourth line is gone.

  `test/guides/tutorial_chain_test.exs` is the gate: every page but the last links forward
  to its successor in sorted order, the last links forward to nothing, and — the
  anti-vacuity half — the walk is checked to be reading the whole tutorial and parsing the
  links it finds, since both assertions are comprehensions that pass on an empty list.

- **The install instruction is current, and a gate keeps it that way** (#287, closes #154).
  `guides/getting-started.md` is the repository's only dependency snippet and it read
  `tag: "v0.1.0"` against a release of **v0.3.20** — in documentation that ships in the
  package, on a page whose next chapter teaches `TLA.Trace.explore/3` and
  `mix tla.explore`, neither of which that install has. A reader who followed it and then
  followed the tutorial would conclude they had made a mistake.

  **The mechanism was the interesting part, and it is what changed.** Every other Elixir
  block on that page is compiled and its verdict asserted; the one block exempted by
  `tla:skip reason=a mix.exs fragment, not a spec` is the one that drifted. "Not a spec"
  was true and was taken to mean "not checkable" — but a `mix.exs` fragment parses and a
  `tag:` is a string. `<!-- tla:deps -->` now holds that tag to `CHANGELOG.md`'s newest
  release heading, which is in the tree (so a shallow CI clone with no tags still checks
  it) and is, since #282, the project's record of what is built.

  The tag is **named** rather than replaced with a branch or with prose, and the guide now
  says why: a branch installs unreleased work from a library whose subject is
  verification, prose cannot be followed without leaving the page, and only a literal tag
  can be held to the release record. A version requirement is not available while Hex
  publishing is undecided.

  The other eleven `tla:skip` blocks in `guides/` were reviewed and all are genuine
  fragments — an action body, an ExUnit module, a shell invocation — with nothing in them
  that can go stale against the code.

- **No concurrent test writes VM-global state, and a gate says so** (#285, closes #283).
  `test/conformance/step_test.exs` was `async: true` and set
  `Application.put_env(:extla, :trace_buffer, 3)`. That value is read by
  `TLA.GenServer.Runtime.record_transition!/4` **in whatever process is recording**, so for
  the duration of that one test every concurrently running test that recorded a transition
  saw a 3-state buffer.

  Nothing could have failed on it: a neighbour's trace was truncated, its temporal verdicts
  became `:inconclusive`, and the assertion beside it reads
  `verdict in [:holds, :inconclusive]` — exactly what a corrupted run still satisfies. A
  passing result that meant nothing was checked, arriving through the config of a different
  test file.

  The test moves to `test/conformance/trace_buffer_test.exs`, `async: false`, unchanged —
  it is the only coverage of the bound reached through the **instrumented callback** rather
  than through `Runtime` directly. `test/docs/async_isolation_test.exs` is the guard: it
  reads each test file's **AST** (a textual scan would fail `truncated_behaviour_test.exs`
  for explaining in a comment why it avoids a global) and fails any `async: true` file that
  calls `Application.put_env/delete_env` or `:persistent_term.put/erase`.

  `Process.register/2` is deliberately not checked, and the gate says why: a per-test
  unique name is legitimate and a fixed one is not, and nothing distinguishes them without
  judgment the gate does not have.

- **A refinement mapping is probed only where a binding exists** (#286, closes #284).
  `TLA.Refinement.validate!/3` applied `concrete_message/2` to `%{}` whenever the spec's
  constants had no values — which is whenever a *published* example is compiled, since
  `constant :processes` without a `default:` is what a reader should write. For an action
  with no params `%{}` is the real binding; for one with params it is a binding the search
  would never produce, so a mapping written for the real ones matched no clause and the
  probe raised **`FunctionClauseError` from inside the validator**. Both conformance
  examples in the specification — `spec/05`'s `MyApp.TransferServer` and `spec/07`'s
  `MyApp.LockServer` — could not compile, which is how #281 found this.

  An action this call cannot bind is not evidence of a mapping that never names it, so it
  is **not probed and not reported** — D-28's rule about conclusions drawn from an
  absence, which `against_graph/3` and #278 already apply. It is not silent either: the
  un-probed actions are returned in the list of rules `validate!` "could not decide",
  which is what that list has always been for. No compiler warning, because a published
  example has no constants by design and a warning there is noise a reader cannot act on.

  It survived because **every refinement fixture in `test/conformance/` is for a spec
  whose actions take no params**, so the suite exercised exactly the one case the fallback
  handled. `test/conformance/param_mapping_test.exs` is the missing case, and the two
  specification blocks lost their `tla:skip` — so the guide harness compiles them and a
  regression reddens the gate rather than a unit test.

- **§Implementation Phases withdraws its single-source claim; the graph and §Concurrency
  describe the code** (#282, for #179). The four phases were written as a *plan* and ended
  honestly on 2026-09-01; the sentence "this section is the single source of truth for what
  is built" was added the next day, to a finished enumeration nobody was extending — so
  eight shipped features looked like omissions rather than like work done after a plan
  completed. There is **no Phase 5**: that would be a third hand-maintained list beside a
  gated one. §Phases records the plan, `CHANGELOG.md` records what is built and
  `bin/changelog_guard.exs` fails any `lib/` commit that adds no entry, and `README.md`
  now points at the gated record. D-34's neighbour in `spec/08` is not needed; the
  withdrawal is pinned by `test/docs/shipped_has_a_home_test.exs`, which asserts the eight
  orphans each have a home.

- **The five-step concurrency protocol is deleted rather than corrected** (#282). #38 built
  `Task.async_stream` and added the true description *underneath* the false one without
  removing it, so §Concurrency read as a protocol that does not exist followed by prose
  saying what does. The protocol is gone; #38's paragraphs stand alone.

- **§Storage draws the liveness structures where they live** (#282). The edge table and
  ENABLED bits were drawn inside the ETS box and are per-struct **maps** — the fact that
  *governs* D-27's refusal of liveness alongside `workers:`, admitted in prose seventy
  lines below the diagram. They are now their own box, marked not-shared, so a reader of
  the picture can derive the rule that governs the feature.

- **The module graph describes the code as written** (#282). It drew
  `ModelChecker.check_liveness/2` and `Coverage.compute/2`, neither of which has ever
  existed, and an edge from `TLA.Spec` to `TLA.Invariant` that the code does not have,
  while omitting `TLA.Temporal`'s call back *up* to `ModelChecker.enabled_bindings/3`. It
  was never a copy of the code — it is the design's module tree, from the initial commit.
  Nothing gates it, and the section now says so and states the review rule: check it
  whenever `lib/tla/*.ex` gains or loses a module, which is one `grep -l` per box.

- **`spec/` and `README.md` are under the guide harness: 76 blocks, compiled or skipped with
  a reason** (#281, for #178). Every `elixir` fence in the specification was compiled by
  nothing. Most are API sketches whose signatures `spec_api_test` already holds to
  `API_SURFACE.md`, so the gap was smaller than the count suggests — but "nothing compiles
  this" and "something else gates this" read identically in an unannotated block, and only
  one of them is acceptable. D-34 records the rule and the four kinds of skip.

  **The pass found three things nobody was looking for.** An **empty** `elixir` block stood
  in for `TLA.Profile`'s API block (§Per-declaration cost, since #130) — the section's prose
  describes `instrument/1` beside a fence containing nothing; it now carries the sketch, and
  `spec_api_test` holds it to the golden. And the two conformance examples a reader is most
  likely to copy — `spec/05`'s `MyApp.TransferServer` and `spec/07`'s `MyApp.LockServer` —
  **do not compile**: `TLA.Refinement.validate!/3` probes `concrete_message/2` with an empty
  binding, which a mapping for an action with params cannot answer, so it raises
  `FunctionClauseError` from inside the validator. Filed as #284; both blocks are skipped
  naming it, and those skips are meant to disappear.

  `<!-- tla:skip -->` with no reason is now **refused** (#215): the harness's own rule is
  that an unannotated block is an unchecked claim, and a reasonless skip is an unchecked
  claim wearing an annotation. A `reason=` also runs to the end of the annotation rather
  than to the first space — `reason=a shell invocation, and the timing is from this machine`
  had been parsed as the word "a" ever since reasons existed, which nothing noticed because
  nothing had ever asked what a reason said.

- **`spec/07`'s examples are the corpus, not a copy of it** (#280, for #178). Three corpus
  moduledocs said "Example N verbatim, which is the point: the corpus checks the
  documentation, not a paraphrase of it". `git log` dates that sentence to 2026-08-30/31
  and D-21 to **forty-three minutes later**, where it rewrote every corpus spec's types and
  left the page — so for a month the page a reader copies from declared
  `type: [^resources ~> :set]` where the checker had been given `set(^processes)`.
  `mix tla.examples --write` now generates `test/differential/<entry>/spec.ex` **from the
  page's fence**, and `surface-drift` fails on a difference; the page carries the types
  D-21 settled on.

  The drift was **invisible to the corpus itself** — TLC agrees either way, so all 88
  differential assertions passed with the wrong type on the page. That is the argument for
  a byte-level gate rather than against it: the only instrument that can see this class of
  error is one that compares the text.

  Generating code from a document is the inverse of the five goldens that render documents
  from code, and D-32's reasoning is unchanged: an enumeration kept by hand does not
  announce that it has stopped being true. Compiling the fence in place — the guide
  harness's own principle — would be purer, and #281 should revisit it; it cannot be done
  without taking three specs out of `TLA_COVERAGE.md`, since the ledger finds items by
  parsing the file the BEAM records as a module's source.

- **`spec/02` §8's worked example is pinned to the trace `spec/04` prints** (#280). Its
  `conservation_of_money` is refuted at depth 3 — deliberately: `fail_transfer` discards
  `pending`, and that *is* `04-layer2-model-checker.md`'s worked counterexample, "⚠ money
  lost!" included. Nothing asserted it, and the one test that ran the spec passed
  `invariants: []`, so "fixing" `fail_transfer` — which is what this work item was scoped
  to do — would have left §04's printed trace describing a run that no longer happens,
  with the suite green. The bare `invariants: []` is now `[:type_ok]`, which holds over the
  whole constrained space, so that test still reaches its bound while checking something.

- **The two `:checked` telemetry events that could not fire, now fire** (#279, for #177).
  `03-layer1-invariants.md` documents four success events under `telemetry: :verbose` and
  argues from that count — "a single transition can fire four of them" is the reason they
  are opt-in — while `emit_wrapper/3` passed `:verbose` to the invariant and
  action-property checks only, and `TLA.Invariant.Runtime` had no `:verbose` arity for
  `check_preconditions!` or `check_postconditions!` to receive it. The same file said so
  three hundred lines down, where its API block listed the two arities that existed: #22
  amended the block from the code and left the event table alone.
  `[:extla, :precondition, :checked]` and `[:extla, :postcondition, :checked]` now carry
  `module`, `name` and `duration` like the other two.

  A declaration whose pattern does not match the message fires **nothing**. Its clause
  answers `:no_match` without evaluating the predicate, so an event there would time a
  pattern match and report it as the cost of a check that never ran.

  `telemetry: :verbose` had **no test coverage at all** — #175's third hole, where two
  independent mutations of it stayed green. `test/tla/telemetry_verbose_test.exs` is its
  first: all four events from one transition, their metadata, the `:no_match` silence,
  the opt-in asserted under the default (and the violation events still firing there, so
  "nothing fired" cannot pass on a module that emits nothing at all), and the events held
  to the table in `spec/03` that lists them.

- **A recorded behaviour says what its buffer threw away, and a truncated one cannot
  settle a claim about its beginning** (#278, for #177). `TLA.GenServer.Runtime`'s trace
  buffer drops oldest-first — correctly; an unbounded per-process trace is a memory leak in
  any long-lived GenServer — and recorded nothing about having dropped anything. The
  bare-predicate verdict read the list's head as "the behaviour's first state", which for a
  server past the buffer is a different state, and the answer was not merely
  over-confident: a server 1,200 transitions from `n = 0` reported the property `n == 0`
  **violated**, as a settled fact, about a behaviour that satisfies it. A false refutation
  sends someone to fix a specification that is correct.

  `trace/0` and `get_trace/1` now return `%{states: [...], dropped: n}`, and
  `check_temporal_properties/2` **refuses a bare list** rather than defaulting it to
  `dropped: 0` — defaulting would have left every existing caller compiling and the
  truncated one still lying, which is the argument `TLA.Conformance.against_graph/3`
  already makes for requiring `status:`.

  **Only the bare predicate changes.** Truncation drops a *prefix*, and every other shape
  survives it: `always(P)` answers `:violated` from a retained state that really occurred,
  `eventually(P)` answers `:holds` from a retained witness, and `<>[]P`, `[]<>P` and
  `P ~> Q` need a lasso a recorded trace never has. Making `always` `:inconclusive` on
  truncation — as the work item asked — would discard a sound refutation, which is the
  honesty rule pointed the wrong way; `spec/05` now says so.

- **A temporal formula outside §5.1's fragment is refused at compile time** (#277, for #177).
  `spec/02` promised "a **compile error** naming the unsupported operator" and that "every
  rule here is enforced at compile time"; the fragment's *nesting* bound was enforced
  nowhere at compile time and three times after it. `always(always(P))` was inside the
  grammar — which was recursive — so it compiled, and then met
  `TLA.ModelChecker.Liveness.shape/4`'s `ArgumentError`, three frames into a run, carrying
  no module, declaration or line, and only under `check_liveness: true`. Under the default
  configuration the formula was never looked at and the run reported `:ok`.
  `TLA.Spec.Temporal` now carries the bound as a table and refuses the nesting at the
  declaration, and §5.1's grammar states it instead of contradicting it.

  **Two more doors were open.** `TLA.GenServer.Runtime.verdict/3` and `TLA.Coverage.walk/3`
  each enumerate the same fragment again and neither had a fallback clause, so the same
  formulas died there as a `FunctionClauseError` printing closures and no property name —
  under `mix tla.simulate`, and under the **default** configuration respectively. Both now
  say what reaching them means, which after this change is a bug in ExTLA rather than a
  mistake in the specification.

  **And one formula that was never wrong.** `always(Enum.all?(^procs, fn p -> done[p] end))`
  is `always(pred)`: a quantifier over a constant with a boolean body is an ordinary state
  predicate, as it has always been inside an `invariant`. Taken as the formula-level `\A`
  it built a shape no consumer evaluates and died in the coverage probes, by default, on a
  formula that means exactly what it looks like. It now compiles and checks.

  `test/tla/spec/temporal_fragment_test.exs` is the recurrence guard: it **derives** the
  shapes from the parser's own table and drives every one through all four consumers, so a
  fragment widened in one place goes red rather than quiet.

- **A temporal property's description reaches the counterexample a user reads** (#276, for
  #176). `temporal :x, desc: "…"` was stored by the DSL and dropped by
  `compiled_temporals/1`, so the option #160 kept — on the reasoning that accepting one
  nothing reads is the same defect as an unknown key — reached no consumer. It now travels
  all four hops, and a refutation reads `temporal property :eventually_two is refuted by this
  behaviour — the counter reaches two and does not spin forever`. One hop below it,
  **`TLA.Trace.format/1` printed the banner and dropped the `message` every finding writes**:
  an invariant's violation text, an action property's, the deadlock's pointer at
  `terminal :name do` and every liveness refutation were rendered to nobody, while
  `to_json/1` carried them out to a file the whole time. The new tests assert on the
  rendering rather than on the struct, because one reading `violation.prefix.message` would
  have passed over a counterexample that showed the reader nothing. D-33 records what
  accepting `desc:` obliges, beside D-18's map of which declarations accept it.

- **The specification's API blocks are held to `API_SURFACE.md`** (#164, closes #153). `spec/01–05`
  published **seventeen signatures and seven type shapes the code does not have** — a reader
  coding to them got `UndefinedFunctionError` on the first call — and nothing had compared the
  two, because until #271 there was no side derived from the code to compare against.
  `test/docs/spec_api_test.exs` is the comparison, in four layers: every `defmodule` fence must
  parse (two did not, and three findings hid in them); every head and arity must be a row in the
  golden; every record type's keys must match; and **no `@spec` may appear in the specification
  at all**, which is #68's decision about `lib/` applied to the document that had the same
  problem — 116 of them, wrong in seventeen places. `result()` gains `:deadlock`, `diameter` and
  `profile`, and deliberately not `:unsound_symmetry`, which is `mix tla.check`'s JSON status
  rather than one `run/2` returns.

  Writing the gate first, and running it red before correcting anything, is what made the rest
  visible: **layer 2 passed vacuously on every shape finding it exists for**, because its row
  pattern let the shape column swallow the version cell. The anti-vacuity test now counts parsed
  key sets rather than matched rows. It also surfaced two defects in the golden's own scanner —
  a `def` inside a compile-time conditional was never read, and a wide union was rendered with
  newlines inside a table cell, breaking the row.

### Added

- **`PACKAGE_SURFACE.md`, and the published docs stop advertising what the package omits**
  (#274, from #270). `mix docs` runs under `MIX_ENV=dev` because `ex_doc` is a dev dependency,
  and `elixirc_paths(:dev)` includes `ledger/` — so the published documentation carried
  **eleven modules** a consumer cannot call, TLA.Ledger and mix tla.coverage among them.
  Nobody decided to document the ledger; the docs job's environment did, and the two halves of
  the promise were checked in two environments that cannot see each other (`consumer-compile`
  compiles the package and has no `ex_doc`; the docs job builds pages and never reads
  `files:`). `mix.exs` now filters the docs on the same `files:` list the package is built
  from, `test/docs/package_docs_test.exs` joins the two, and the golden lists every dependency
  as declared beside every module and whether it ships.

- **Every compile diagnostic carries a `kind`, and `DIAGNOSTICS.md` lists them** (#273, from
  #270). `02-dsl-semantics.md` §7 tabulates the diagnostics under a preamble promising that a
  spec violating any rule does not compile, and nothing held the table to the code — nothing
  *could*, because a row's first column was a name its author chose and `TLA.Spec.CompileError`
  carried no identifier to match it against. §7 was **twenty-eight kinds short of the fifty the
  DSL raises**, and one of its rows described §6's term check, which runs at runtime, so the
  preamble was false for exactly that row. `kind` is the join key: 53 raise sites pass one, the
  golden renders them, §7's first column is the kind, and `spec_diagnostics_test.exs` holds the
  four sets — raised, rendered, tabulated, tested — to each other. Renaming one kind reddens
  five of its eight assertions.

- **`CLI_SURFACE.md`: every `mix tla.*` task's switches and exit codes** (#272, from #270).
  One row per `@switches` entry and per documented exit code, read from source, with the
  specification section that reproduces each task **found by searching `spec/*.md` for its
  `defmodule` line**. That derivation replaces `spec_options_test`'s six-entry `@documented`
  list: the set of tasks is now the directory, a task shipped without a spec section fails a
  named assertion instead of going unchecked, and a task with no exit-code table (`mix
  tla.stamp`, #173) reads as a finding rather than a blank. Generating it found two things
  the hand list could not: `mix tla.visualize`'s exit codes had never been read by anything,
  because its moduledoc is an interpolated heredoc, and `mix tla.mutants` was a task no gate
  knew about.

- **`API_SURFACE.md`: what `lib/` declares, as a surfex golden** (#271, from #270). Every
  public function head with the arities its defaults imply, and every named type with its key
  set and atom unions, scanned from source by `Surfex.SourceScan` — so the gate runs before the
  build — and rendered by `mix tla.api_surface --write`. `--check` is HARD: a signature or type
  change without a regenerate fails the build, and so does a hand edit. It is the code's side of
  the comparison the specification's API blocks are held to (#164), which had no side to be
  compared against when #153 found seventeen signatures the code does not have.

### Changed

- **`spec/06-architecture.md` §Dependencies is a link, not a copy** (#274). It carried the
  `deps` block from the initial commit — a fence whose first line was the comment `# mix.exs`,
  so it announced itself as a copy — and by then listed `dialyxir`, which #69 removed, omitted
  `surfex`, which #64 added, and pinned `ex_doc` three minor versions behind. The list is now
  `PACKAGE_SURFACE.md`; what stays in the section is what a list cannot say, and the two
  claims that carry weight — zero required runtime dependencies, and dev/test dependencies are
  not transitive — are pinned by tests rather than trusted.

- **One `surface-drift` job for every golden.** `tla-coverage-drift` is renamed and runs both
  `mix tla.coverage --check` and `mix tla.api_surface --check`; the goldens #270 still owes
  join it rather than each minting a job. The three-outcome check — current, drifted, missing —
  is now TLA.Surface's `check!/4`, shared by both tasks, so there is one definition of "drifted".
  `TLA_COVERAGE.md`'s header names the new gate and was regenerated.

- **CI's compiled dependencies come from the depdep store alone** (#251, closes #250). depdep
  v0.4.0 never keyed `surfex`, a leaf git dependency, so #247 kept the `mix.lock`-keyed
  `deps`/`_build` cache beside the store to supply it — two sources of truth for one thing.
  v0.5.0 keys it (depdep#70) and hands `--compile-deps` only misses this env is known to build
  (depdep#83); the bump's own pipeline read `pulled 7, skipped 0, not for this env 6` in a job
  with nothing on disk, `surfex` included. The cache is gone; what stays cached is
  `tlc-corpus`'s tla2tools jar, a checksum-verified download.

- **A predicate that returns a non-boolean is refused, not counted as holding** (#235,
  closes #192). Every consumer of an `invariant`, `terminal`, `action_property` or temporal
  state predicate tested its result for truthiness. Elixir's `and`/`or` return their last
  operand, so `invariant :i do n >= 0 and status end` evaluated to `status` and *held* in
  every state where `status` was anything but `nil` or `false` — a run in which it never
  took the value the author meant reported `:ok`. The compiled predicate now raises
  `TLA.Spec.PredicateError`, naming the declaration and the value, wherever it is
  evaluated: the checker, trace replay, coverage, and the ledger. A spec that relied on a
  truthy return passed before and fails loudly now; that is the intended change, and the
  fix is the comparison that was missing.

- **CI restores compiled dependencies from the shared depdep store** (#246, for #245). Every
  job ran `mix deps.get` and compiled the dependency tree from source, with a `mix.lock`-keyed
  cache as the only reuse — per-project, per-runner, and a cold compile of the whole tree on
  any lock change. `scripts/depdep.exs --pull --mix-get --compile-deps` (depdep v0.4.0) now
  stands in for `mix deps.get`: restore what the store has, fetch only what it lacked, decide
  again over the git dependency once its source is on disk, compile exactly the misses; and
  `compile` pushes what it built. Inert until the store credentials exist (#247): with no
  `DEPDEP_*` variables depdep says so, still runs `deps.get`, and exits 0.

- **`mix tla.check --format json` schema 3: `coverage.terminals`** (#256, closes #202). How many
  successor-less states each `terminal` admitted. Additive, and bumped anyway — the policy
  recorded beside the version is that additive changes bump so a reader can refuse a shape it
  does not know; `mix tla.replay --trace` refuses a v2 document naming both versions.

### Fixed

- **Layer 3 process hygiene** (#269, closes #213). The runtime's per-process spec cache matched
  on the module name alone, so a server that outlived a recompile of its spec kept the
  structure it first loaded — an invariant added to the spec was never checked by a running
  server; the cache is keyed on the module's md5. `TLA.Simulation` stopped every server with a
  bare `:kill`, skipping `terminate/2`; it stops as a supervisor would (`:shutdown`, a bounded
  wait, then `:kill`), while failure injection stays a `:kill` because a crash runs no
  `terminate/2`. `run/2` said it stopped at the first finding and ran every trace; it stops.
  And the `constants:` option is gone: the server under test resolves constants from
  application config, and a generator on any other assignment drove it against a different
  specification.

- **Trace rendering and counting edges** (#268, closes #212). `Trace.length` meant three things
  — states, states minus one, action count — and is the number of states everywhere now, the
  lasso splice sharing the cycle head once. A lasso's closing duplicate was labelled
  `[VIOLATION]` like a safety trace's last state; it is labelled as the return to the cycle
  head. The explorer hid an all-error row under `changed_only` while printing its warnings,
  and reported a non-function expression as one runtime error per state; the row is shown and
  the expression refused once. `unreached_params` was computed and surfaced nowhere; an
  enabled action's never-drawn bindings are a warning, and under symmetry the universe is left
  unknown rather than compared against a reduced visit. And the profile's run bracket closed
  after the liveness pass, charging the states it materialized to a denominator whose doc says
  "the window is the search"; it closes before, and the coordinator clears its counters.

- **Four DSL front-end edges are diagnostics, not crashes or silences** (#264, closes #210).
  A `let` could shadow a `params:` name (or `old`/`new`): §1.3 said locals shadow nothing and
  two of three cases were enforced. A variable inside a temporal quantifier's literal list
  killed the compiler with a `FunctionClauseError` from a rewrite mode nothing handled; it is
  the §5.1 diagnostic now. `defmodule __MODULE__.Spec` crashed the hash scanner from inside a
  consumer's compile; a computed name now has no version and `check_stamp!` says why. And
  `params: [k: [1, 1, 2]]` drew three bindings per state and inflated the action's coverage;
  each distinct value is drawn once and a visible repeat warns.

- **Three boundaries that accepted what they should have refused** (#265, closes #211).
  `Trace.from_json!/1` read no structure: `"type": "ok"` became `:ok` through
  `String.to_existing_atom/1` and `format/1` failed later, a non-string type was a raw
  `ArgumentError`, and two states with no actions built a trace nothing could render honestly;
  it now checks the type against the three it knows and the alignment before building
  anything, and `mix tla.replay` refuses an entry with no `violation` key by name instead of a
  `CaseClauseError`. `domain/1` raised `BadMapError` on a list `at/2` applies as a function;
  it answers `1..Len`. `for_each/2` built a function over a list, deduplicating silently; it
  ranges over a set or a range and refuses a sequence or a map by name.

- **The trace reader said "the spec was verified" about a bounded run** (#261, closes #205).
  `mix tla.replay --trace` and `mix tla.explore` matched `"violation" => nil` and said
  verified without reading the `status` beside it, so a `max_states_reached` or `constrained`
  document read as a proof. It now says what the status says — bounded at N states by the
  limit, held back by the constraint, or the status by name — and only `ok` is verified.

- **A raise in one simulation trace orphaned every in-flight server** (#262, closes #206).
  `TLA.Simulation` started each server linked, unlinked it at once, and stopped it only on
  the normal return, so a message generator that raised once took the run down and left
  every started server alive — eight `Impl.Conforming` processes after one failed run. Each
  trace now runs in a process that owns its server: linked for the trace's whole life and
  trapping exits, so a raise anywhere in the trace takes the server with it and a server's
  own crash still arrives as an outcome. `init/1` returning `:ignore` or `{:error, _}` is an
  `:error` outcome naming it, not a `MatchError`.

- **Five small regressions left by recent fixes** (#263, closes #209). `init` was the one
  options-taking macro with no option check, so `init desc: "x", do: …` compiled with the
  keyword dropped (and the `do … end` spelling was an "undefined function init/2" from the
  compiler rather than a diagnostic) — it now takes no options and says so. The liveness-skip
  warning counted declared temporals rather than the selection, so `temporals: [:one]` with
  three declared said three were not checked. The accepted-options comment still said
  `temporal` reads no options. `TLA.Conformance`'s `@type finding` lacked `:nothing_observed`.
  And the liveness-shape fixture tests asserted only `status == :violation`, so a fairness
  regression reporting the unfair cycle would have passed; the cycles are pinned.

- **`Trace.validate/3` accepted a stutter at a live state** (#259, closes #203). A one-state
  cycle with no actions validated `:ok` at a state with enabled steps — and `format/1` then
  rendered it "has no successors: the behaviour stutters there forever" — and a `:deadlock`
  trace whose last state had successors validated too. `validate/3` is the oracle the
  generated-model tests rest on, so a liveness bug producing a stutter in the wrong place
  passed it. Both now require no enabled step at that state, per §5.3, and name the enabled
  action otherwise.

- **`Trace.format/1` truncated a misaligned trace and marked the wrong state** (#260, closes
  #204). `to_diffs/1` zipped states, actions and bindings and stopped at the shortest list:
  one action short — the shape the simulation's restart branch produced — it printed three
  states of four and put `[VIOLATION]` on the wrong one, and a JSON file lacking `bindings`
  rendered as a single-state trace. The alignment invariant `validate/3` already reports is
  now checked in `to_diffs/1`, so `format/1` and every programmatic consumer refuse a trace
  that cannot describe one behaviour, naming the three counts.

- **A liveness pass skipped by the state budget or a safety counterexample is named** (#257,
  closes #208). #167 named the deadlock skip and the constraint skip and left these two
  silent: `check_liveness: true, max_states: 3` on a spec with a temporal reported the bound
  and nothing about the property, and `mix tla.check --allow-incomplete` turned that into
  exit 0 with the property unmentioned. Both now put the same "N temporal properties were not
  checked" warning in the result, with the reason and what to do; a spec with no temporal
  gets no such warning.

- **A stepped range type honours its step** (#258, closes #196). `variable :x, type: 0..10//2`
  compiled and `resolve!` dropped the step to a plain range, so `x = 1` passed `type_ok` —
  while `params: [k: 0..10//2]` evaluates the same literal as Elixir does and never drew a 1.
  Two consumers of one syntax disagreed, and §1.5 had no `//` at all. The step is now honoured
  (a `^constant` step and a negative step included), a zero step is a compile error naming the
  grammar, and §1.5 says so.

- **The ledger enumerated three of five declaration kinds** (#256, closes #202). Under a header
  promising "every item each TLA.Spec declares", `action_property` and `terminal` had no rows
  at all — the kind list was written by hand. It is now `TLA.Spec.Hash.kinds/0`, so a kind
  added to the DSL is a row on the day it is added or a loud failure, never an absence. Fifteen
  rows join `TLA_COVERAGE.md`. Their evidence rests on what the run recorded: an action
  property on the transitions it was checked against (`lock_not_stolen` on 76), a terminal on
  the end states it admitted (`term_bound_exhausted` admitted 655) — and a terminal that
  admitted none reads `NOTHING`, because the run would have reported the same deadlocks without
  it.

- **`Driver.call/3` raised for a dead registered name where a dead pid reported `:stopped`**
  (#255, closes #254). #252 made the `:DOWN` match shape-independent and left the send
  shape-dependent: `send/2` to an atom no longer registered raises `invalid destination`,
  where the same send to a dead pid is a no-op answered by the monitor's `:noproc`. Found by
  the #252 test itself racing on the 2-core runner, which killed the server before the send
  every time and turned `main`'s `test` job red. The server is now resolved once with
  `GenServer.whereis/1` and every `GenServer.server()` shape — pid, name, `{name, node}` — is
  the pid path by construction; a test enumerates the shapes and holds each outcome identical.

- **`Replay.counterexample/3` with `server: <registered name>` reported `:not_followed` instead
  of the violation the server raised** (#252, closes #207). `TLA.GenServer.Driver.call/3`
  matched the `:DOWN` on the server the caller passed; a monitor on a registered name delivers
  `{name, node}` there, never the bare atom, so neither clause matched and the call waited out
  its timeout — 5 seconds, then delivery blamed for a finding that had been made and thrown
  away. The `:DOWN` is now matched on the monitor reference alone, which is unique to the call,
  and a pid and a name give the same outcome.

- **A profile floor over too few evaluations is marked, not presented as reproducible** (#249,
  closes #248). The report's footer said the cost "is exactly reproducible"; for a declaration
  evaluated once it is the one sample, excursion included. `TLA.ProfileTest`'s fixture has
  such an item — `reset` fires in exactly one state — and its "floor" read 2 reductions on a
  quiet machine and 29 under load on three CI pipelines, each costing a retry. An entry now
  carries `settled: false` below four evaluations, its row says `floor over N evaluations,
  not settled`, the footer qualifies its claim, and the stability tests compare settled floors
  and assert the marking rather than silently skipping the item.



- **Nested temporal quantifiers collapsed their vacuity probes onto the last outer
  instance** (#240, closes #200). Coverage rebuilt the instance set with a walk of its own and
  keyed each probe by the innermost binding alone, so for `Enum.all?(^xs, fn x ->
  Enum.all?(^ys, fn y -> P ~> Q end) end)` every `x` landed on the same key and only the last
  survived. An outer instance whose antecedent never held anywhere reported `vacuous == []`
  — while the liveness checker, expanding correctly, checked it as its own property. The two
  now share one expansion, `TLA.Spec.Compiled.temporal_instances/2`, and a probe is keyed by
  the full binding path. `vacuity.binding` is that path (`[:b, :a]`), `[]` for an unquantified
  property, where it was a bare value or `nil`.

- **The ledger's `Version` column was file-scoped, so same-named items shared one hash**
  (#241, closes #201). `TLA.Spec.Version` scanned the whole file and keyed by `{kind, name}`,
  so the seven `tick` actions in `test/support/specs.ex` all showed the last one's hash —
  editing `Broken.tick` moved nothing, editing the last `tick` moved seven rows. The golden
  was stable while wrong, which is the exact failure a drift-gated golden is meant to make
  impossible; nothing cross-checked the two hash modules because `HashTest` compared
  `definition_hash/1`, not the scan. `TLA.Spec.Version` is removed and the ledger reads
  `TLA.Spec.Hash.item_versions/1`, which is module-scoped: one implementation rather than a
  test proving two agree. Nine rows in `TLA_COVERAGE.md` change hash — six `tick`s, a
  `taint`, a `reset`, an `eventually_done` — each to the hash of its own definition.

- **`subseq/3` wrapped on a zero index where `at/2` raises, and crashed on an empty result**
  (#242, closes #197). It was `Enum.slice(seq, m - 1, n - m + 1)`, which has Elixir's index
  semantics: `subseq([1, 2, 3], 0, 1)` returned `[3]`, a negative start counted from the end,
  `subseq([], 2, 0)` was a `FunctionClauseError` where TLC returns `<<>>`, and a `MapSet` was
  accepted where `len/1`, `head/1` and `at/2` all refuse one. An off-by-one in a spec produced
  a valid sequence that was not the one the author wrote, silently — the exact shape `at/2`
  refuses for the same slip. It now follows TLC's `SubSeq`: `n < m` is `[]`, any other bound
  outside `1..Len(s)` is a `DomainError` naming the index and the length, and a property test
  holds `subseq/3` and `at/2` to the same answer on every out-of-domain index.

- **A non-UTF-8 binary in state crashed `--format json` and discarded the counterexample**
  (#244, closes #198). §6 permits binaries; `TLA.State.Json` handed every one to
  `Jason.encode!/1` as a string, which raises `invalid byte 0xFF` on anything that is not
  valid UTF-8. A spec holding `<<255, 0>>` found a real violation, then `mix tla.check
  --format json` exited with a stack trace from the report writer and no document. Such a
  binary now travels as base64 under its own `"b64"` tag; valid UTF-8 keeps `"b"`, so every
  existing trace still decodes. And `TLA.State.validate!/1` now refuses a bitstring that is
  not whole bytes (`<<1::3>>`), which the wire format has no form for — what `validate!`
  admits and what `Json.encode` encodes are the same set.

- **The verification ledger now model-checks temporal properties** (#234, closes #191). The
  ledger ran the checker with `check_liveness: false`, then wrote `checked` in the `:temporal`
  rows anyway — every temporal property in `TLA_COVERAGE.md` was labelled verified on the
  strength of a safety run that never evaluated it. Raft's `eventually_elect_leader`, which
  the differential corpus records TLC *violating*, sat in the golden as `checked`. That is the
  precise over-claim Principle 6 forbids, in the document whose one job is to not make it.

  The ledger now runs one liveness check per temporal (`temporals: [name]`), because the
  checker halts at the first refutation and a single run can only ever produce one verdict
  for a whole spec. Each row carries its own result: `checked` when the property held,
  **REFUTED** when the checker found a counterexample, and the checker's own reason when it
  could not evaluate it (deadlock, incomplete graph). Four rows in the golden flipped to
  REFUTED — Raft's `eventually_elect_leader` (now agreeing with TLC), `Idling.never_two`,
  `IdlingUnfair.eventually_two` and `Stalls.eventually_done`, each a property the fixture
  *intends* to fail. The cost is a ledger run of ~35s instead of ~15s, measured; that is what
  actually checking costs, and the alternative was a column that meant nothing.

- **`always(x = 1)` is now the compile error `x = 1` already was** (#235, closes #192). The
  #150 fix rejected an assignment to a declared variable only when it was a whole statement
  of the block. In a temporal the top level is nearly always `always`, `eventually` or `~>`,
  so the check fired for the one shape nobody writes and `always(status = :done)` compiled
  into a formula the checker reported as holding. `invariant :i do n >= 0 and (status =
  :done) end` compiled too. The rationale for stopping — that a nested `=` is legal Elixir an
  author might mean — was wrong: the check fires only for `=` on a *declared* variable, which
  §1.2 forbids outside `init`/`action` at any depth. The walk is now the whole expression,
  from the one function both paths share.

- **A constants config key naming no constant is refused, not dropped** (#236, closes
  #193). `config :extla, Spec, constants: %{maxx: 100}` against `constant :max, default: 3`
  resolved to `%{max: 3, maxx: 100}`: the override the author wrote was read by nothing,
  the run used the default, and nothing said so. It is the selection defect of #166 through
  the one door that fix did not cover. `Spec.Compiled.resolve_constants/1` now raises,
  naming the key and the declared constants — in the resolver rather than at a call site,
  because `mix tla.check`, `mix tla.simulate`, Layer 3 conformance, the guides and the
  ledger all resolve there and each would otherwise need the rule separately.

- **The module version now moves on every declaration, not only the items** (#237, closes
  #194). Changing an `init` value, a variable's `type:`, a constant's `default:`, or weak to
  strong fairness produced the *identical* `spec_version`; only an action-body edit moved
  it. So a stamp — whose error message asks the author to "confirm that each variable and
  action it names still means what it did" — stayed fresh across a new variable the mapping's
  `abstract/1` could not produce, and the ledger's `Fresh` column with it. The reasoning in
  the code ("not independently verified, so there is nothing for a verdict to go stale
  against") mistook what the number is for: a stamp names the *specification*, not a verdict.

  `fairness` is included, and it was the one to argue: it changes liveness verdicts and
  nothing a mapping reads. But one number names one specification, and a spec under strong
  fairness admits different behaviours from the same spec under weak; a second
  "liveness-relevant" version would be a second stamp nobody maintains.

  Found on the way: `mix tla.stamp` derived the module version by its own copy of the
  formula, so widening it in `TLA.Spec.Hash` alone would have made every stamp stale in the
  task while the compile-time check called it fresh. Both now call
  `Hash.module_version/2`. The one live stamp in the corpus is regenerated; a test enumerates
  the DSL's macros against `kinds/0 ++ declarations/0`, so a declaration added to the DSL and
  to neither is a failing test, not a blind spot.

- **A temporal quantifier named after a state variable is a compile error, not a silent
  misread** (#238, closes #195). With `variable :p` declared, `Enum.all?(^procs, fn p ->
  eventually(pc[p] == :b) end)` compiled — and the body's `p` resolved to the *state
  variable* in every instance, because the rewriter consults declared variables before bound
  names. The instance for `p = 2` came out true on a state where `pc[2]` was wrong, and the
  only mark was a compiler "unused variable" warning. §1.3's rule that a `let` may shadow
  nothing was always a rule about what a bare name means; it now applies to every binder,
  and the quantifier gets the same diagnostic, naming both the local and the declaration.

- **The profile's share under `--workers` counted the workers in the numerator and left them
  out of the denominator** (#239, closes #199). Declaration costs were collected per worker and
  summed; `run_reductions` was the coordinator's own `Process.info(:reductions)`, and under
  `workers: n` the coordinator does almost none of the work. The same spec read 12% at one
  worker and 91% at eight — the bounded-buffer corpus entry 8% against 170%, a share over the
  whole — and `advice/1`'s verdict inverted. The guarding test ran at one worker, where the
  two brackets coincide. Each worker now brackets its own batch and the coordinator's bracket
  is added to the sum rather than replacing it; the new test runs the same spec at one worker
  and four and asks for the same answer.

- **Two tests that could not fail, and the guard for the class** (#175). The test named "one
  restricted to a callback is not checked in the others" did not discriminate on `callbacks:`
  at all — making the restriction a no-op left it green. Its apparent discrimination came from
  declaration *order*: the unrestricted invariant was declared first and raised first, so the
  restricted one never got a chance either way. The new test declares the restricted one
  first, so honouring the option and ignoring it report different violations.

  And **nothing in the repository read `.gitlab-ci.yml`**. No test asserted that the set of
  jobs covers the test tree, so a directory reached by no job was undetectable by
  construction. There is now one that fails when a directory is unreachable.

  Worth stating precisely, because the obvious claim would be wrong: this does *not* catch the
  guide slug cross-check that has never run. That test **is** run by the `test` job; its
  problem is that it needs a built `doc/` and only another job builds one. A coverage check
  cannot see "needs an artifact another job produces". #156 fixes that one by moving it.
- **Half the temporal fragment was refuted by nothing, and the Emerson–Lei strong split was
  dead under test** (#174). Nulling the refutation clauses for a bare predicate, for
  `always(eventually(P))` and for `eventually(always(P))` — so the checker answers "holds" to
  all three — left the whole suite green. `eventually(always(P))` appeared in no spec anywhere
  in the project; `always(eventually(P))` appeared once and was only ever verified.

  Replacing the strong-fairness branch with `[]` was likewise green: the only strong-fairness
  fixture is verified, and `[]` also yields success, so the test named "strong fairness is not
  weak fairness" passed for the wrong reason and never exercised the subset search.

  Four models now refute the four. The fairness one needs the split to find its refutation at
  all: its component is unfair as a whole, and only restricting to the states where the
  constrained action is disabled leaves a fair cycle. Each is small enough to check by
  reading, and each carries a companion assertion that the model is otherwise sound, so the
  refutation is evidence about the property rather than about a broken spec.
- **`--verify-symmetry` did nothing without `symmetry:`, and blamed the declaration when it
  did run** (#170). The one flag whose stated purpose is catching an unsound reduction failed
  in both directions.

  `mix tla.check` dropped both keys when no `symmetry:` was configured, so the flag never
  reached the checker's own guard — the one that exists to refuse exactly this — and a
  misspelled or missing declaration produced `— verified`, exit 0. The task was routing
  around its own refusal.

  And the comparison read a truncation as a verdict difference. The compared fields exclude
  counts but include `status` and `never_enabled`, both bound-sensitive, while both runs get
  the same `max_states` and the reduction's whole purpose is that the unreduced run is
  bigger. So on any model large enough to need symmetry, the unreduced run hit the bound
  first and a **sound** declaration drew a maximally confident accusation. A bounded
  comparison is now refused with a reason rather than answered, which is how
  `TLA.Conformance` already treats a bounded graph.

  The first version of that refusal appended the reason to `warnings` and left the status
  `:ok` — so `mix tla.check` printed `— verified` and exited 0 with "could not be verified"
  as a trailing line. A run that asked for the check came back looking verified to anything
  reading the exit code, which is the defect this fix exists to close. An inconclusive
  verification now carries the bounded run's status and exits 2, and a test reads the exit
  code rather than the warning text.

- **A found violation could be discarded, and a skipped liveness pass said nothing** (#167).
  Four defects in the step that turns a completed search into a reported verdict.

  A **deadlock** silently suppressed liveness checking. The same spec reported a refuted
  temporal property with `check_deadlock: false` and never mentioned it with the default,
  `warnings: []` both times. Skipping is right — a liveness question about a spec with a
  safety failure answers the wrong question — but the run now says so and names the flag that
  asks anyway.

  **`check_liveness:` with `state_constraint:`** crashed with `ArgumentError` *after* the
  search, discarding a safety result that was valid for what it covered. The pairing is only
  conditionally bad: a constraint that never holds a state back leaves a complete graph. So
  the run consults `TLA.ModelChecker.Liveness.answerable?/1` and declines with a reason,
  rather than being refused up front like symmetry and workers, which are unconditionally
  incompatible.

  A **configured** state constraint discarded a lasso the liveness pass had already found,
  because `:constrained` is set whenever a constraint exists rather than when it bound the
  run. Bounded-ness is carried by `coverage.bounded_by`, so the refutation now wins.

  The **parallel merge** kept the first non-`:ok` outcome, so a worker reporting
  `:max_states_reached` before the worker carrying the violation dropped the counterexample —
  roughly 1 run in 80, and never at `workers: 1`, so the verdict was order-dependent. Both
  outcomes occur in the same level because the budget test reads the shared count.
- **A name or flag that matched nothing was accepted, and the check it named never ran**
  (#166). Three places, all verified by running code.

  A **selection** naming a declaration the spec does not have checked nothing and reported
  success — `invariants: [:capp]` for `:cap` gave `status: :ok, warnings: []` where the
  correct name gives `:violation`. That reaches further than a hand-typed config: the TLC
  differential corpus drives its selections from names in `expected.json`, and D-9 makes
  agreement with TLC the acceptance gate, so a misspelled fixture name made the gate pass
  having compared nothing. The corpus was audited after the fix and every name resolves.

  A **`callbacks:` value** naming a callback that does not exist deleted the declaration:
  `invariant :never_negative, callbacks: [:handle_cal]` let a balance reach `-899`. Naming a
  real callback the module does not define now warns instead of failing, since adding it in a
  later edit is legitimate — but silence is not.

  Three tasks parsed argv **leniently** and dropped what they could not parse. Two are CI
  gates: `mix tla.coverage --chek` printed the ledger and exited 0, which is the advisory
  gate on a verification artifact D-10 forbids. All eight now parse strictly, asserted by a
  test that **enumerates** the tasks rather than listing them, so one added later is covered
  on the day it is added.
- **`TLA.Conformance.against_graph/3` passed on a behaviour it never examined** (#168). A
  one-state behaviour has no pairs, so the fold returned its `:ok` seed and `explain/1`
  reported that every observed state is in the graph — about a state that was not in it.
  Reachable in practice: a simulation trace whose first message times out yields one state.

  A single state is now checked on its own, and an empty behaviour is `:nothing_observed`
  rather than a success. This is the module that already refuses a *bounded* graph outright
  rather than report absence from it; the same discipline was missing at the other end of
  the input.

- **Five mix tasks had flags the specification did not mention, `mix tla.simulate` all eight
  of them** (#163). Its section carried usage examples and no option list, so
  `--inject-failures` and `--unrestricted` — two substantial Layer 3 capabilities, crash
  recovery and testing that an implementation refuses what the spec forbids — were
  undiscoverable from the documentation. `mix tla.stamp` had no section anywhere,
  `mix tla.explore` no option list, and `tla.replay` and `tla.visualize` were each missing
  one.

  The gate that would have caught this has existed since #134 and covered one task, because
  the accessor it reads was added to that task and nothing generalised it. All six are now
  held to their documented lists, across both spec files.

  One flag is documented as **not currently read**: `mix tla.replay --init-arg` is accepted
  and ignored, so `TLA.Replay`'s `:server`, `:init_arg` and `:timeout` are unreachable from
  the command line (#165). Stating that is less tidy than omitting it and more useful.

- **The API reference's front page and the specification index both said the library was
  unbuilt** (#148). `TLA`'s moduledoc read "Phase 1 is in progress ... the model checker
  that consumes it does not exist yet", untouched since the third commit of the project, and
  `spec/README.md` said "No implementation exists yet". `TLA` sorts first in ExDoc's sidebar,
  so that was the landing page for anyone asking what the API is, four phases out of date.

  Neither gets a corrected status line, because a second copy is what produced this:
  `06-architecture.md` §Implementation Phases is the only place build status is recorded, and
  both pages now point at it. `TLA`'s moduledoc is rewritten as what it should have been —
  the three layers, a specification that a reader can recognise, and the warning that the DSL
  looks like Elixir and is not — with resolvable links to the getting-started guide and the
  normative semantics rather than the bare paths it carried before.

- **An unknown option on a spec DSL declaration was discarded rather than refused, and
  `temporal` dropped its description** (#160). `variable :n, type: :nat, bogus: 1` compiled.
  Each macro popped the key it wanted and either stored the remainder unread or threw it
  away, so a typo was indistinguishable from an option nobody wrote.

  The accepted set is now per macro and records **what is consumed**, not what looks
  plausible: `constant` takes `default:`, `variable` takes `type:`, `action` takes `params:`,
  and `invariant`, `terminal`, `action_property` and `temporal` take `desc:`.

  `temporal` is the one that changed rather than merely gained a check. It discarded its
  options entirely, so `desc:` there was accepted and silently dropped — the corpus's
  `no_starvation` carried one and nothing kept it. It is now stored the way the other
  predicate forms store theirs, which is what makes accepting it honest.

- **`TLA.Spec.DSL`'s option helper reported every failure as one diagnostic** (#160). It
  wrapped a `case` whose two branches were identical in a bare `rescue _`, so any error
  inside became "options must be a literal keyword list" — in the DSL compiler's own error
  path, where a wrong message costs an author the most. It now asks `Keyword.keyword?/1`
  directly, which answers the question exactly and lets a real bug surface as itself.

- **An unknown option on a Layer 1 declaration was stored and ignored rather than refused**
  (#149). `callbaks: [:handle_cast]` compiled, and the invariant applied to every callback.
  The cause is the one above, one step subtler: options were consulted by name with
  `Keyword.get/3` defaults, so a key nobody reads and a key nobody wrote are the same thing.

  The accepted set is now per declaration kind, and the message names the offending key and
  what that kind takes. `callbacks:` is included for `invariant` and `action_property` and
  **excluded for `precondition` and `postcondition`**, which never consulted it — they are
  emitted from `__tla_conditions__/1` and do not reach the wrapper's `applicable/2`. Accepted
  and ignored is the same defect as unknown, so it is refused rather than documented.

- **`enabled:` on a Layer 1 declaration only ever worked for a literal `false`, so the
  documented way to compile out an expensive check did nothing** (#149). `03-layer1-invariants.md`
  §162 specifies the option as evaluated at compile time, and §634 gives the idiom:

  ```elixir
  invariant :expensive_check, enabled: Mix.env() == :test do
    deep_structural_audit(state)
  end
  ```

  Declaration options are stored with `Macro.escape/1` and read back as literals, which is
  right for `desc:` and `callbacks:`. It is wrong for this one: `Mix.env() == :test` was kept
  as a `{:==, _, _}` tuple, and the filter that decides emission keeps everything but `false`
  and `nil`. A tuple is truthy, so **every expression enabled the declaration**, whatever it
  evaluated to. The option worked for the one input that makes it pointless, since a literal
  `false` is indistinguishable from deleting the declaration.

  **A stock production release was not affected** — `MIX_ENV=prod` resolves the whole layer to
  `:disabled`, so lever 3 saved what lever 1 did not. What paid for it was `:dev`, which is
  `:enabled` by default and is where "compile this out except in test" most obviously means
  something, and any deployment setting `mode:` explicitly, `:log_only` in staging being the
  documented case.

  `enabled:` is now evaluated in the caller at its compile time, so `Mix.env()`, a module
  attribute and `Application.compile_env/3` all work — the last of which also registers its
  recompilation dependency properly, which evaluating it by hand would not. A value that is
  not a boolean is refused naming the declaration rather than accepted as truthy. The option
  covers all four declaration kinds, three of which had no test for it at all.

  **This changes behaviour for existing code.** A declaration carrying
  `enabled: <any expression>` was being emitted regardless and now is not, if the expression
  is false where the module compiles. That is the point, and it is worth checking against any
  suite that was passing because a check it thought disabled was in fact running.

- **A `temporal` block accepted an assignment, so one mistyped `==` produced a property that
  always passed** (#150). `02-dsl-semantics.md` §1.2 makes `=` on a declared variable a compile
  error outside `init` and `action`, and that rule was enforced for `invariant`, `terminal` and
  `action_property` — all three reach it through `TLA.Spec.Block.desugar_predicate!/2`.
  `temporal` does not desugar; it goes to `TLA.Spec.Temporal.parse!/2`, which never saw the
  check. So `temporal :no_starvation do waiting = [] end` compiled.

  **It is the one declaration whose failure is silent.** An invariant that never fires shows up
  in the coverage report as never enabled. A temporal formula built from an assignment is not
  refutable, so the search reports that the property *holds* — a green verdict for a property
  that checked nothing, which is Design Principle 6 defeated by one character, underneath the
  vacuity detection that exists to catch exactly this one layer down.

  The rule now lives in one place, `TLA.Spec.Block.reject_assignment!/2`, called from both
  paths, so the two forms cannot drift into two dialects again. Neither path descends into
  nested expressions — `always(x = 1)` is still accepted — and that limit is now shared rather
  than differing between them; widening it is a separate decision, since `=` inside a call is
  legal Elixir a spec author could conceivably mean.

## [0.3.20] — 2026-09-09

**A minor line, and the patch number does not start at zero.** Two of the changes below move
the public surface in ways a patch number promises not to: `TLA.Coverage`'s `observe_action/5`
is gone, replaced by `observe_enabled/3` and `observe_generated/4`; and a `schema_version: 1`
JSON document, which `mix tla.check` wrote under v0.2.0, is now refused rather than read. Three
more are additions — `TLA.Trace.explore/3`, `mix tla.explore`, and `TLA.Profile` with
`mix tla.check --profile`. `RELEASING.md`'s bar is whether someone decides the public surface
moved, and it moved on five counts.

The `20` is the commit count since the last of those five landed (#135, `bf14e81`), not since
`v0.2.0`. Everything after it — #137 through #147 — is fixes and CI work that a patch number
describes correctly, so the version says both things at once: the line opened there, and twenty
commits of patch-level work followed. `v0.3.0` is tagged at `bf14e81` to mark the opening;
`RELEASING.md` §*The base tag is a marker* says why that tag has to exist.

### Added

- **`TLA.Trace.explore/3` — evaluate your own named expressions at every state of a
  counterexample** (#115, #120). A trace is nineteen raw variable dumps and the reader does the
  arithmetic; this puts named expressions down the rows and states across the columns, so the
  question a reader actually has ("when did quorum form?") is answered by looking rather than by
  counting.

  ```elixir
  TLA.Trace.explore(trace,
    waiting: &length(&1.waiting),
    holder:  & &1.holder,
    quorum?: &(map_size(&1.votes) * 2 > 3)
  )
  ```

  Three arguments rather than two, deliberately: options live in `opts`, so an expression named
  `:changed_only` stays representable and cannot silently become a flag. Rows render in the order
  given — the caller's order is information, so it is not sorted.

  **Columns are chunked to a width budget** (`width: 68`, matching `format/1`'s banners) with the
  name column repeated in each chunk, because the trace that motivated the feature does not fit on
  one screen and `changed_only: true` cannot be relied on to narrow it — an expression that moves
  at every step is exactly the case that stays wide.

  An expression that raises is reported **at the state it raised in**, carrying
  `Exception.message/1`; the rest of the table still renders. A failure that is displayed and
  attributed beats one swallowed into a blank cell. Lassos go through `to_behavior/1`, so the
  repeating columns are marked, and a `cycle: nil` lasso is not given a fabricated cycle.

- **`mix tla.explore` — the same table from the command line, over a saved counterexample**
  (#115, #121).

  ```
  mix tla.explore Specs.DistributedLock --trace counterexample.json \
    --expr "waiting: length(state.waiting)" \
    --expr "quorum?: map_size(state.votes) * 2 > 3" \
    --changed-only
  ```

  An expression is a function and cannot be written on a command line, so `--expr` is repeatable
  and each one is compiled with the state's variables in scope — the TLA+ Toolbox's approach, and
  it needs no DSL macro. Dropping the `name:` prefix uses the expression text as the row label. An
  `--expr` that does not compile fails with the text, the reason, and **which** of several `--expr`
  flags it was, rather than a bare `CompileError` from inside the task.

  It reads what `mix tla.check --format json` writes, in either shape — the whole document or a
  single trace lifted out of it — and lassos work. The `<module>` argument is required because
  `Trace.from_json!/1` resolves atoms through `String.to_existing_atom/1`, so the spec module has
  to be loaded before a saved trace can decode.

  Note the word: this explores a **saved counterexample**, not the state space.
  `TLA.ModelChecker.explore/2` is the other thing, and the task name is the one place `explore`
  appears unqualified.

- `TLA.Profile` and `mix tla.check --profile` — what each of *your* declarations cost, per
  invariant, action guard, transition, action property and terminal (#116, #130). `TLA.Coverage`
  says how often the checker asked; this says what the answer cost, which is the half a spec
  author can act on.

  **Measured in reductions, not milliseconds.** Every performance number this project had was
  caveated by a CPU model and a load average — `bench/search_profile.baseline.md` records a
  `raft` run swinging from 23.4 s to 30.5 s on machine load alone — and a ranking that changes
  with the load average is not a finding. Under 32 competing processes the same fixed workload
  spread 100.3% in wall time and not at all in reductions.

  The cost reported is the per-evaluation **floor** times the evaluations, not the accumulated
  total: accumulating gave spreads of 26.7% and 47.8% between identical runs, while every
  declaration's floor came back a single value across eight loaded runs. Anything above the floor
  in one evaluation is the scheduler, not the predicate. A predicate whose cost genuinely varies
  with the state is the one thing a floor cannot see, so it is flagged rather than averaged away.

  Off by default, and free when off — the closures `TLA.Spec.Compiled` already holds are wrapped
  only when a profile is asked for, so no macro work and no recompilation is involved.

  Correct under `--workers` (#131): reductions are per-process, so each task collects its own
  contribution and `TLA.ModelChecker.Parallel.merge/2` sums them beside `TLA.Coverage.merge/2`.
  Per-declaration evaluation counts under `--workers 8` are identical to the single-worker
  counts, which is the property a merge can silently break while leaving the totals plausible.

### Fixed

- **The profile counted counterexample regeneration and liveness evaluation as if they were
  search work, so per-declaration transition counts were too high** (#133). **The numbers change**
  — a profile taken before this version is not comparable with one taken after it, and the
  direction is always downward.

  Two paths, and the larger was not the one that raised the issue. A **refuted** run replays its
  counterexample to turn a path back into states, which applied each transition once more per
  appearance in the trace: `audit_log` reported `record` 4 times against a search that applied it
  twice. A **`check_liveness: true`** run rebuilds *every* state to evaluate predicates over it,
  which inflated by roughly a whole extra search — 10 against 5 on a six-state spec — with no
  violation and no counterexample involved.

  The cause was one value doing two jobs: the instrumented spec was handed both to the search and
  to `TLA.StateGraph`, and everything that consults the graph's spec runs *after* the search has
  stopped. The graph now keeps the uninstrumented copy. Only `{:transition, _}` entries were ever
  affected — replay applies transitions and nothing else, so guards, invariants and action
  properties were always right.

  Guarded by an identity rather than by fixtures (#139): for a profiled run the sum of transition
  evaluations equals `result.transitions`, since the graph's counter is incremented on the line
  after each application. Asserted across eleven configurations, including `--workers` and
  `verify_symmetry`.

- **`coverage.bounded_by` said the counts were partial when a completed search merely found a
  deadlock** (#136). A deadlock is detected after the frontier empties, so such a run has counted
  everything — but it reached the same `:violation` as a run that stopped mid-expansion on an
  invariant, and `TLA_COVERAGE.md` marked its sections `LOWER BOUNDS` with a `≥` on every count
  that was in fact exact. The value is now derived from the search's own outcome rather than
  from the verdict it produced, so a completed search reports `:none` whatever it found.

  No new value and no schema change: the field means *are these counts complete, and if not why*,
  and `status: :violation` with `bounded_by: :none` is the correct pair — a problem was found,
  and everything was searched. Four of the ten `LOWER BOUNDS` sections in the golden lose the
  marking; the six that were genuinely truncated keep it.

- **A run that halted mid-expansion reported the offending action as never enabled** (#128). A
  counterexample would name `compact` in its trace while the coverage report in the same result
  called it never enabled and warned that its guard was broken. `TLA.Coverage.observe_action/5`
  is replaced by `observe_enabled/3` and `observe_generated/4`, because *was this action enabled
  here* and *how many states did it generate* are different facts known at different moments:
  enablement is now recorded when the guard admits a binding, which is true whether or not the
  expansion finishes.

  It was an off-by-one for as long as the checker has existed and became a false claim only when
  the true count is one — `die_hard`'s actions are enabled in eleven or twelve states, so losing
  one left eleven and looked like nothing. `TLA_COVERAGE.md` moves accordingly: one action per
  violating spec gains the occurrence it had been losing.

  `--strict-coverage` no longer fails a build on an action that was never enabled in a run
  bounded by `max_states` or a `state_constraint`: such a run cannot tell an action whose guard
  is never true from one whose states it never reached. A **complete** run still accuses.

### Changed

- **`spec/04-layer2-model-checker.md` now documents `mix tla.check`'s options correctly** (#132,
  #134). The spec denied that `--workers` was a flag — it has been one since Phase 4, and the same
  file documents `workers:` nine hundred lines earlier, so it disagreed with the code and with
  itself. Four of the nine switches were missing from the option lists (`--format`, `--max-states`,
  `--safety-only`, `--workers`), and the Usage block demonstrated two that have never existed
  (`--graph`, `--output`; `mix tla.visualize` is the task that draws graphs).

  No behaviour changes here — this is documentation catching up with the task. It is recorded
  because an example that cannot be run is worse than an absent one: a reader tries it and gets
  `OptionParser` refusing a flag the specification just showed them.

- **`mix tla.check --format json` is now `schema_version: 2`**, gaining a `profile` key that is
  `null` unless the run was profiled. Purely additive, and it bumps anyway: "additive changes do
  not count" is the reasoning that makes a version stop meaning anything, and this one exists so
  a reader can refuse a shape it does not know rather than misread it. `TLA.Mix.TraceFile`
  refuses a version-1 document naming both versions, and re-running `mix tla.check --format json`
  regenerates it.

## [0.2.0] — 2026-09-04

The documentation release. A getting-started guide and an eleven-page tutorial, with every
code block compiled from the page itself and every claimed verdict — status, property,
counterexample length, state count, never-enabled actions — asserted by the test suite, so a
guide that drifts from the tool fails the build. The gate came first and a throwaway guide
proved it went red, because nobody retrofits a gate to prose that already passes.

Two library changes travel with it. `TLA.Spec.Deps` records each block's read and write
variable sets at compile time — the foundation property-directed slicing needs (#87), and
sound by widening rather than by narrowing. And `TLA.Trace.validate/3` now requires a
**safety** trace to refute the property it names, a stricter contract than v0.1.0's and the
check that would have caught #112.

Still pre-1.0: the public surface may still move, and `spec/06-architecture.md` §Deferred is
written in terms of "past v1". Still not on Hex — that remains a separate decision.

### Changed

- `guides/tutorial/06-layer1.md` now covers what a team needs in order to adopt Layer 1: the
  smallest useful step (one invariant on a server you already have, no specification at all), a
  plain invariant violation, the three modes as real per-environment configuration and what
  `:disabled` actually means, `enabled:`/`callbacks:` for cost, `TLA.Invariant.Test` — including
  `refute_invariant`, because an invariant never seen false is indistinguishable from `true` —
  telemetry, and the other OTP behaviours including why an `Agent`'s checks cannot be compiled
  away (#104, #109).

- `guides/tutorial/03-invariants.md` now teaches writing properties, not only reading the report:
  a method for choosing what to assert, `desc:`, `action_property` as a section of its own with a
  step no invariant could catch — and **deadlock and `terminal`**, which is the first failure a
  reader meets and had two dismissive sentences in the whole tutorial. A one-shot lock that
  finishes its work is shown refuted as a DEADLOCK, fixed by declaring its end state at the same
  fifteen states, and then with a `terminal` broad enough to admit a live state (#104, #108).

- The tutorial's pages carry subheadings throughout, so every one has sidebar sub-entries and can
  be scanned; `05-symmetry.md` and `06-layer1.md` had none. `assert_spec` moves off the symmetry
  page — it is how a specification stays true as code changes, which nobody looks for under
  symmetry reduction — and the brittle "Part N of 8" headers are gone: a page states its
  predecessor, so adding one no longer renumbers the rest (#107).

### Added

- `guides/tutorial/09-when-it-explodes.md` — what to do when a run does not come back, every lever
  measured on one specification: reading a bounded run, shrinking constants (1,331 states to 64),
  symmetry (1,331 to 286), `--workers` and when it costs more than it saves, `--safety-only`,
  `state_constraint` with the two lessons people miss — a constraint that excludes little buys nothing, and one that restricts the
  variables your property is about buys a green run that means nothing — and fingerprint width.
- `guides/tutorial/10-in-your-project.md` — where specifications live, `assert_spec` with
  `strict_coverage`, what to run in CI and why a slow gate belongs outside `mix test`,
  `mix tla.visualize` with a real graph, `TLA.PropertyTest`, and `mix tla.replay --captured` for
  after an incident (#104, #111).

- `guides/tutorial/08-modelling.md` — deriving a specification from a system, on a job runner the
  tutorial has not already solved: which fields are state and which are derivable (with the
  measurement that a derivable field costs no states but buys an obligation, and a counterexample
  about your own bookkeeping when you get it wrong), constants against bounds, what is abstracted
  away and what that costs, how big to make it — 64 states at two jobs, 512 at three — and what
  was left out entirely (#104, #110).

- A gate over the **built** documentation: every internal link in `doc/*.html` must resolve, and a
  `docs` CI job builds the docs so it actually runs. It found ExDoc's sidebar home link 404ing on
  all 84 generated pages, and the README's `LICENSE` link 404ing on the front page — neither
  visible to a gate over source markdown, because the generator writes those links itself
  (#102, #103).
- `guides/tutorial/01-mathematics.md` — states, behaviours and actions; the specification formula
  and stuttering; safety versus liveness and why their counterexamples have different shapes;
  ENABLED and the two fairness strengths; refinement as implication; how a model check verifies an
  algorithm, and what a green run, a counterexample and a bounded run each claim — with the
  bounded run demonstrated rather than described. Plus what the method is and is not useful for
  (#101).
- The guide harness takes `max_states=` and `expect=incomplete`, so a page teaching that a bounded
  run is not a verdict must produce one (#101).
- `guides/tutorial/00-introduction.md` — the history and purpose of formal verification, TLA and
  TLA+ and where they come from, a survey of the other tool families and of the Elixir/Erlang work,
  and where ExTLA sits in both. It summarises and links `spec/00-prior-art.md` rather than copying
  it, and `research/tla-plus-primer.md` now ships and renders so its citations resolve (#100).
- The tutorial is a multi-page guide under `guides/tutorial/`, read in order, and guides are
  checked in sorted path order — a page may use a module an earlier page compiled, and the
  numbering is that dependency (#99).
- Every relative link in a guide is checked: the file exists and the anchor is a heading it has,
  using ExDoc's own slug. The check #96 and #97 ran by hand, made a test — it caught eleven links
  the split had broken before anyone read the page (#99).
- `guides/getting-started.md` — installation to a deliberate invariant violation, read action
  by action — and the tutorial: the DSL in practice, the coverage report, weak against
  strong fairness on one spec, symmetry and `--verify-symmetry`, Layer 1 on a GenServer, and
  Layer 3 conformance through simulation and replay. Every code block in a guide is compiled
  from the page itself and its claimed verdict — status, property, counterexample length,
  state count, never-enabled actions, an unsound symmetry, a simulation finding, a raise — is
  asserted by the test suite, so a guide that drifts from the tool fails the build (#95, #96,
  #97). Both ship in the package and render under `mix docs` in a Guides group.
- `TLA.Spec.Deps` — each action's read and write variable sets, and each invariant's read set,
  derived from the block AST at compile time and carried on the compiled spec. Widening is the
  default: a read set is `:all` unless every node is recognised (#91).
- `bin/check-stream-data-fallbacks.exs`, run by CI's `consumer-compile` job: the three
  `stream_data` fallback functions now execute on every pipeline and are asserted to raise with
  a message naming the missing dependency. They had never been run anywhere (#90).
- CI records the memory ceiling, host memory, load and core count in every job log (#86, #88).

### Fixed

- An `action_property` counterexample pointed at the wrong step. The trace was built from the
  post-state's graph id, so when that state had already been discovered by a shorter route the
  parent pointers described *that* route: the offending step was absent and the step the trace
  marked could satisfy the property it was offered as a refutation of. It is now built from the
  pre-state's path with the offending step appended. Invariant and deadlock traces are unchanged
  and correctly so — those are claims about a state, where any path reaching it is a fair
  counterexample (#112, #113).
- `TLA.Trace.validate/3` now requires a **safety** trace to refute the property it names — an
  invariant false in the final state, an action property false over the final step. It previously
  checked only that a trace was a legal path from an initial state, which a fabricated
  counterexample passes; that is how the defect above went unnoticed. The docstring's
  "deliberately does not check" section is corrected to say the exclusion is liveness-only, where
  `TLA.TemporalCheck` is an independent implementation (#112, #113).

- The near-miss column's documentation. `getting-started.md` called it opt-in and said an
  invariant "declares what a near miss would be"; it is **derived** from the invariant's shape —
  a top-level `or` yields a probe and anything else reports `nil`, meaning *not measured*. The
  guide now says which shape produces one, `spec/04` no longer contradicts itself about the
  atomic-bound case, and that case is recorded as deferred rather than described as though it
  worked. `near_miss/1`'s two outcomes are pinned by doctests (#105, #106).

- The documentation's home link. `README.md` and `spec/README.md` both derived the id `readme`,
  ExDoc disambiguated them to `readme-1`/`readme-2`, and `main: "readme"` went on naming a page no
  build produced. The spec index is now `spec-readme` with a real sidebar title, leaving `readme`
  to the page that should own it; `LICENSE` ships as an extra so the README's link to it resolves
  (#102, #103).

- The coverage task's drift and missing-file branches are tested; both had never executed (#84).
- `README.md`, the phase-4 handoff and `.gitlab-ci.yml`'s header each asserted something no
  longer true. Phase status now lives only in `spec/06-architecture.md` §Implementation Phases
  (#80).
- Test artifacts under `tmp/` are untracked and ignored (#81).

### Infrastructure

- CI fetches the `surfex` dependency over the CI job token; it had been declared over SSH, which
  the runner image cannot use, leaving `main` red for five merges with all three `verify` gates
  reporting `skipped` rather than `success` (#71).
- Merges now require a passing pipeline, and a **skipped** pipeline does not count (#72).

## [0.1.0] — 2026-09-02

The first tagged release. Four implementation phases, complete on the terms
`spec/06-architecture.md` set for each.

Pre-1.0 deliberately: the public surface may still move, and `spec/06-architecture.md`
§Deferred is written in terms of "past v1". This tag is a reference point, not a
compatibility promise.

### Added

- **Phase 1 — the DSL and safety checking.** Specifications written as Elixir
  (`TLA.Spec`), exhaustive breadth-first model checking (`TLA.ModelChecker`), the implicit
  `type_ok` invariant, shortest-counterexample traces, and `TLA.Coverage` reporting what a
  run actually exercised. `mix tla.check`.
- **Phase 2 — liveness.** Temporal properties and weak/strong per-binding fairness over an
  SCC-based liveness graph, lasso counterexamples, and symmetry reduction with
  `verify_symmetry:` to make an unsound declaration detectable.
- **Phase 3 — Layer 1 and the conformance bridge.** Invariants on running processes
  (`TLA.GenServer`, `TLA.Invariant`), `TLA.Refinement`, and checking an implementation
  against a spec: `mix tla.simulate` and `mix tla.replay`.
- **Phase 4 — scale and ecosystem.** Level-synchronous parallel exploration
  (`TLA.ModelChecker.Parallel`, **5.40x at 8 workers**), `TLA.PropertyTest`, and
  `mix tla.visualize` (DOT).
- **The verification ledger.** `TLA_COVERAGE.md`, a drift-gated record of every spec item
  and the evidence covering it, with per-item content versions and a `spec_version:` stamp
  that makes a stale refinement mapping a compile error.
- **Measured gates.** `mix tla.mutants` and a 13-mutant catalogue, `TLA.Trace.validate/3`,
  `TLA.GraphAudit`, `TLA.Conformance.against_graph/3`, and generated models via
  `TLA.SpecGenerator`.

### Verified against

- **TLC, on every entry of the differential corpus** — `die_hard`, `two_phase_commit`,
  `distributed_lock`, `raft_election`, `bounded_buffer` and `paxos` — agreeing on distinct
  states, depth, where the search stops, every invariant, every temporal property, and the
  shortest counterexample where one exists. `expected.json` is regenerated from TLC on every
  pipeline, so these are measurements rather than fixtures. This is the project's acceptance
  criterion (`spec/08-decisions.md` D-9), not a follow-up to it.

### Performance

- `raft_election` went from 23.4 s to 1.65 s during Phase 4 — 2.65x from validating each
  state once at discovery (D-26), then 5.40x from the workers (D-27) — with the corpus
  agreeing with TLC at 1, 2, 4 and 8 workers throughout.

### Not included

- No Hex release. This tag marks a point in history; publishing is a separate decision.
- `Mix.Tasks.Tla.Gen.Test`, HTML/D3 visualisation, `TLA.Supervisor.Spec` and view
  abstraction are deferred past v1 — see `spec/06-architecture.md` §Deferred for why each.

[Unreleased]: https://gitlab.conet.yarina.org/dco-tek/extla/-/compare/v0.4.0...main
[0.4.0]: https://gitlab.conet.yarina.org/dco-tek/extla/-/tags/v0.4.0
[0.3.20]: https://gitlab.conet.yarina.org/dco-tek/extla/-/tags/v0.3.20
[0.2.0]: https://gitlab.conet.yarina.org/dco-tek/extla/-/tags/v0.2.0
[0.1.0]: https://gitlab.conet.yarina.org/dco-tek/extla/-/tags/v0.1.0
