# Changelog

All notable changes to ExTLA are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file is the record of what is built: each release's entry says what changed, and nothing
else restates it. It is written for people who use ExTLA, so work only the repository sees —
CI, test tooling, internal refactors — is left to the commit history. Entries up to 0.5.0 were
condensed to that rule; the full text is
[the CHANGELOG at v0.5.0](https://github.com/dcoai/extla/blob/v0.5.0/CHANGELOG.md).

## [Unreleased]

`mix.exs` reads `0.5.1-dev`: the `-dev` suffix is what keeps a commit from claiming to be the
release it merely follows.

### Changed

- **The repository's public home is GitHub, and everything that ships says so** (#402, for
  #396). The install instruction reads `git: "https://github.com/dcoai/extla.git"`, so a
  reader who can't reach the GitLab instance where work happens can still install. `mix.exs`
  declares `source_url` and `homepage_url`, so the docs' "View source" links work and point
  at the release tag, and the package declares its links (GitHub, Changelog). The version
  links at the end of this file point at GitHub. The guide harness's `tla:deps` check now
  holds the install URL to `source_url`, as it already held the tag to the release record.
- **The README is a short front door** (#403, for #395). It says what ExTLA does in one
  line, then why it matters when an LLM writes your concurrent code, then installation, one
  example, the task list and links to everything else. The package description and the
  `ExTLA` module docs open with the same line. The TLC agreement tables and benchmarks that
  filled half the old README now sit beside the corpus they measure, in
  `test/differential/README.md`.
- **The docs publish only what a user needs** (#404, for #397). Of `spec/`, HexDocs now
  carries the DSL reference and the examples, and both have lost their history paragraphs.
  The rest of the specification is design material, linked on GitHub where a page needs it.
  A new guide page, `guides/reference.md`, holds the user-facing facts that lived only in
  the departing files: how `mix extla.check` and `ExTLA.ModelChecker.run/2` differ on
  liveness, what state constraints, symmetry and `--workers` each cost and refuse, how to
  read the coverage report, the JSON result schema, what conformance checks, Layer 1's
  test helpers, telemetry and overhead, and what ExTLA is not. The `ExTLA` module docs and
  this file now agree that the changelog is the record of what is built.
- **The API docs group modules by what you do with them** (#405, for #397): specifications,
  model checking, Layer 1, Layer 3, and Internals last for the engine modules a user never
  calls, such as `ExTLA.Invariant.Runtime`. `ExTLA` heads the list.
- **The module docs and usage rules say what the code does, and list the options** (#407, for
  #399). `ExTLA.ModelChecker.run/2` and `ExTLA.Simulation.run/2` document every option with
  its default; before, they were only in typespec comments. `usage-rules.md` no longer shows
  a `--check-liveness` flag that does not exist. It now says the CLI skips liveness with a
  warning under symmetry or `--workers`, while the API raises. It also names the right
  diagnostic for assigning a variable twice, and covers `config :extla`, `use` ordering and
  the optional `jason`. `assert_spec/2` says liveness is off unless asked for, and
  `mix extla.check` documents per-spec `symmetry:`. `mix extla.simulate` says how its
  server starts, and `mix extla.replay` describes its trace file correctly and lists
  `--format`. Stale `TLA.` names and arities are fixed.
- **The module docs are about the library, not its history** (#408, for #399). About 40
  modules carried how a behaviour was found and fixed: issue numbers, test paths, CI, the
  differential corpus, mutation testing, decision-log numbers, and pointers into
  specification files the docs no longer publish. Each is rewritten to say what the code
  does and why. Where a doc pointed at an unpublished reason, it now states the reason or
  links the reference guide.
- **The output shown in the guides is the output the tool prints** (#409, for #398). Every
  block of `mix extla.*` output in getting-started and the tutorial is now compared with the
  command's real output when the guides are tested. A block that shows only part of the
  output says so, and its lines must still appear in order. Twenty-five blocks that had
  drifted are regenerated. They were missing trace banners, used an old lasso rendering,
  had a coverage count one off, and dropped transition counts. Page 10's DOT example now
  comes from a spec shown on the page.
- **Getting started and the tutorial say what the tool does, and where each option applies**
  (#410, for #398). The pages now say which options are for `ExTLA.ModelChecker.run/2` and
  `assert_spec/2` only (`state_constraint:`, `check_deadlock:`, `check_liveness:`). They
  say that `mix extla.check` checks liveness on its own, and where the CLI reads constants
  and symmetry from. Wrong claims are corrected: an invariant's `desc:` is not printed in a
  counterexample, `--strict-coverage` never fails on a live terminal, and
  `mix extla.visualize` refuses with "more than N". The pages gain the optional `jason` and
  `telemetry` dependencies, the sequence operations, `mix extla.replay`'s exit code 3 and
  driving flags, the `:state_functions` limit of Layer 1, and
  `ExTLA.PropertyTest.action_sequences/3`. Passages about how ExTLA itself is tested are
  gone.
- **This changelog is written for users** (#406, for #397). Entries for CI, test tooling and
  other work only the repository sees are gone, and the remaining entries are shorter.

### Fixed

- **`ExTLA.ModelChecker.run/2` honours a constant's `default:`** (#417, for #415). A spec
  that declares `constant :max, default: 3` checked under `mix extla.check` but raised from
  `run/2`, `check_safety/2`, `explore/2` and `ExTLA.Spec.Test.assert_spec/2`: "the type of :n
  refers to ^max, which this run did not assign". Declared defaults now fill in what
  `constants:` leaves out, and an explicit constant still wins. Application config is still
  read only by the Mix tasks.
- **`--verify-symmetry`'s report lists its differences in a fixed order** (#410). The
  lines naming what differed with and without the reduction came out in an order that
  could change from one run to the next. They now always read status, deadlock, refuted,
  never enabled.
- **Layer 1 refuses a predicate that returns a non-boolean, as Layer 2 does** (#418, for
  #401). An `invariant`, `action_property`, `precondition` or `postcondition` returning a
  truthy non-boolean used to count as holding. A common way to get one is
  `n >= 0 and status`, which evaluates to `status`. The model checker already refused the
  same predicate. It is now reported through the configured mode, naming the value
  ("returned :ok, which is not a boolean"): `:enabled` raises `ExTLA.Invariant.Violation`
  and `:log_only` logs it. **This can surface reports in code that passed before.** Add the
  missing comparison so the predicate returns `true` or `false`.

## [0.5.0] — 2026-10-13

**A minor line, opened by `mix extla.replay`.** It gains `--server` and `--timeout`, and
`--init-arg`, which was accepted and then dropped, now reaches the server (#165). Nothing is
removed or renamed: a 0.4.0 project upgrades by changing the tag. Two fixes reach spec
authors: a function capture (`&abs/1`) in a spec body compiles (#369), and
`ExTLA.Invariant.Test.valid_states/3` says when a base generator is too broad to filter
(#348).

### Added

- **`mix extla.replay` passes `--init-arg`, `--server` and `--timeout` through** (#165).
  `--init-arg` was accepted and then silently dropped, and `ExTLA.Replay`'s documented
  `:server` and `:timeout` were unreachable from the command line. Now, with `--trace`:
  - `--init-arg` is the argument the server starts with, as a literal Elixir term only
    (`[start: 0]`; an expression is refused, never run);
  - `--server` drives a running registered process instead of starting one, and leaves it
    running;
  - `--timeout` bounds each reply.

  Combinations that would otherwise be ignored are refused by name: `--init-arg` with
  `--server`, an unregistered name or a printed pid, a non-positive timeout, and any of the
  three with `--captured`, which drives nothing.

### Fixed

- **A function capture in a spec body compiles** (#369, for #359). `&abs/1`, `&+/2` or
  `&member?/2` in any block was refused as "undeclared variable: abs", with advice to declare
  `variable :abs`. A capture now names a function, even where a declared variable shares the
  name (`variable :size` beside `&size/1`); a capture of a function that doesn't exist is
  still refused, by Elixir's compiler, naming it.
- **`ExTLA.Invariant.Test.valid_states/3` says what a broad base generator costs** (#348, for
  #344). It filters the base generator through the type invariant, and StreamData raises
  `FilterTooNarrowError` after 25 rejections in a row; at about 30% acceptance a property can
  pass locally and fail on a rare seed. The docstring now says the base generator should have
  the type's shape and be accepted at least about half the time, with a good and a bad
  example. There is no new `max_consecutive_failures:` option.

## [0.4.0] — 2026-10-03

Every module moved from `TLA` to `ExTLA`, and every Mix task from `mix tla.*` to
`mix extla.*` (#337). `TLA` is a namespace ExTLA doesn't own; the change is breaking and
mechanical, and it is why this is 0.4.0 rather than 0.3.21. The application (`:extla`),
telemetry, configuration and every spec you have written are unchanged. Several other changes
also move the surface: `mix extla.check --format json` is schema 3; predicates that return a
non-boolean are refused rather than counted as holding; a temporal formula outside the supported
fragment is refused at compile time; and unknown options, names and flags are refused instead
of being dropped.

Entries written before the rename use the old names (`TLA.*`, `mix tla.*`); read them through
the migration below.

### Migrating to 0.4.0

0.4.0 moves every module from `TLA` to `ExTLA` (#337). It is a breaking change, and it is
mechanical.

- **Modules:** `TLA` → `ExTLA` and `TLA.<Name>` → `ExTLA.<Name>`, everywhere a module is
  named: `use TLA.Spec` → `use ExTLA.Spec`, `use TLA.Refinement`, `use TLA.GenServer`,
  `import TLA.Spec.Test`, `alias TLA.{ModelChecker, Trace}`, `%TLA.Trace{}`, and
  `TLA.ModelChecker.run/2`-style calls. One rewrite covers it, as long as it leaves `TLA+` and
  prose alone: for example, replace `TLA` with `ExTLA` where it is followed by `.` and a
  letter or `{`, and is not preceded by a letter, digit, `.` or `:`. Then fix any bare `TLA`
  module reference by hand. There are no `TLA.*` compatibility modules.
- **Mix tasks:** `mix tla.<task>` → `mix extla.<task>` for `check`, `explore`, `replay`,
  `simulate`, `stamp` and `visualize`, in scripts, CI files, Makefiles and aliases. A module
  that calls a task directly moves from `Mix.Tasks.Tla.*` to `Mix.Tasks.Extla.*`. Switches,
  arguments, output and exit codes are unchanged.
- **Unchanged:** the application name `:extla` (your `deps` entry), telemetry event names
  (already `[:extla, …]`), configuration keys, and every spec you have written. A spec module
  is yours; only the `use` line names ExTLA.

### Added

- **`mix tla.stamp --check` exits 1 on a stamp nothing verifies** (#311, closes #173). The
  task used to exit 0 whatever it found. With `--check` it exits 1 on a `:stale` stamp or an
  `:unverifiable` one whose spec source is not on disk; `:fresh`, `:unstamped`, and a `spec:`
  that is not a literal alias (which the compiler verifies at `use TLA.GenServer`) exit 0. It
  is a flag, not the default, so scripts that run the task for its report keep working.
- **`TLA.StateGraph.delete/1` releases a graph's ETS tables** (#316, for #182). The graph
  returned by `explore/2` is owned by the caller, ETS tables included; `delete/1` frees them
  and is a no-op on a graph already gone.
- **The failure-injection probability is configurable as `failure_rate:`** (#317, closes
  #182). It was a fixed ten percent; it defaults to `0.1`.
- **`usage-rules.md` ships with the package** (#292, for #181). It covers where the DSL looks
  like Elixir but is not: assignment is a next-state relation, `^name` is a constant rather
  than a pin, `require` is an enabling condition, and guard order decides between a disabled
  action and a raised `DomainError`. It is in `files:`, so `mix usage_rules.sync` can pull it
  into your project.
- **Every compile diagnostic carries a `kind`** (#273). `TLA.Spec.CompileError` now has a `kind`
  identifier, and the diagnostics table in `02-dsl-semantics.md` §7 is keyed by it and lists
  every kind the DSL raises, where it was previously twenty-eight kinds short.

### Changed

- **The Mix tasks are `mix extla.*`** (#339, for #337). The six user tasks move to
  `Mix.Tasks.Extla.*`, so `mix tla.check` becomes `mix extla.check` and so on. The guides and
  README use the new names.
- **Every module lives under `ExTLA`** (#338, for #337). Two libraries that define the same
  module name cannot both be used, and `TLA` is the name any other TLA+ library would reach
  for first. There are no `TLA.*` compatibility modules; see **Migrating to 0.4.0**.
- **The whole `TLA.Set` / `TLA.Function` vocabulary is callable unqualified from a spec
  body** (#319, for #183). `powerset`, `cross`, `cross_many`, `distributed_union`, `set_map`,
  `set_filter`, `for_all?`, `exists?`, `range`, `function_set`, `except` and `record_set` now
  work without qualification in `action`, `init`, `invariant`, `terminal` and
  `action_property` blocks. `map/2` and `filter/2` are exposed as `set_map/2` and
  `set_filter/2`, so they do not read as `Enum.map/2`.
- **`TLA.Function.construct/2` and `domain/1` refuse what they used to get wrong** (#319, for
  #183). `construct/2` now refuses a sequence by name instead of silently deduplicating it.
  `domain/1` reads a sequence as the function on `1..Len(s)` and refuses a set by name; it
  used to raise `BadMapError` on a sequence and return a `MapSet`'s own field names.
- **The guides teach set and function operations** (#320, closes #183). The tutorial's DSL
  page gains §Operations on sets and functions: a TLA+-to-DSL table, a worked `Tutorial.Quorum`
  spec, and the common traps. `usage-rules.md` gains a rule on the same traps: `set_map/2` and
  `set_filter/2` naming, `for_each/2` refusing a sequence, and `domain/1` of a sequence being
  its indices.
- **Every declaration kind reads a non-boolean the same way** (#317, closes #182). A
  precondition or postcondition returning `nil` used to kill the server with a
  `CaseClauseError` on a generated function, and `:verbose` treated a truthy non-boolean as a
  violation, so telemetry could change a verdict. All six check paths now use Elixir's
  truthiness.
- **`TLA.Config.max_states/0` and `TLA.Profile.calibration_samples/0` are removed** (#317,
  closes #182). Neither was used; the state limit default lives in `TLA.ModelChecker`.
- **`mix tla.stamp` scans the project's own `elixirc_paths`** (#308). It used to scan
  `lib`, `test` and `ledger` unconditionally, so a consumer got their whole `test` tree (and a
  `ledger` directory that belongs to this repository) scanned.
- **A recorded GenServer trace reports what its buffer dropped** (#278, for #177). `trace/0`
  and `get_trace/1` now return `%{states: [...], dropped: n}`, and
  `check_temporal_properties/2` refuses a bare list. A server past its buffer read the oldest
  retained state as the first one, so it could report a bare predicate such as `n == 0` as
  violated about a behaviour that satisfies it. Only the bare predicate is affected:
  `always(P)` can still be violated, and `eventually(P)` still hold, from retained states.
- **A predicate that returns a non-boolean is refused, not counted as holding** (#235, #192).
  An `invariant`, `terminal`, `action_property` or temporal state predicate returning a truthy
  non-boolean (e.g. `n >= 0 and status`, which evaluates to `status`) used to hold. It now raises
  `TLA.Spec.PredicateError` naming the declaration and the value, in the checker, trace replay
  and coverage. A spec that relied on a truthy return now fails; add the missing comparison.
- **`mix tla.check --format json` schema 3 adds `coverage.terminals`** (#256, #202). It reports
  how many successor-less states each `terminal` admitted. `mix tla.replay --trace` refuses a v2
  document, naming both versions.

### Fixed

- **A refinement mapping missing a `concrete_message/2` clause is named, not crashed on**
  (#321, closes #299). `TLA.Refinement.validate!/3` raised `FunctionClauseError` from inside
  the validator; it now raises `TLA.Refinement.Error` naming the actions the mapping does not
  cover. The check also runs for actions with params and no constant values, which it used to
  skip. Defining no clauses is reported as an undecided rule, and a clause whose first
  argument is a variable covers every action.
- **A module with only preconditions no longer warns about `tla_new_state`** (#317, closes
  #182). The wrapper bound the variable unconditionally, producing an unused-variable warning
  about generated code and an extra extraction call per transition.
- **`TLA.ModelChecker.run/2` no longer leaks ETS tables** (#316, for #182). Each run left two
  tables per call for the calling process's lifetime, which accumulated in long-lived
  processes such as `mix tla.check A B C` or `TLA.Spec.Test`. `run/2` now searches in its own
  process and frees them on exit, including on a raise; the exception is re-raised in the
  caller with its stack, after one crash report on stderr.
- **`TLA.Replay` stops the server it started** (#316, for #182). It used to leave a live
  `GenServer` per replay; a caller-supplied `:server` is left alone.
- **The refinement totality probe no longer misreports a failing helper** (#315, for #182).
  A `FunctionClauseError` from a helper called by the mapping's catch-all was reported as
  "`abstract_action/1` is not total", advising a clause the mapping already had. Other
  failures are now re-raised untouched.
- **`mix tla.explore` refuses an undefined remote call once** (#315, for #182). A call such as
  `Enum.no_such_thing(count)` used to fill a cell per state; it is now refused once, like a
  `CompileError`.
- **`--fingerprint-bits` with an unsupported width is refused at the flag** (#314, closes #180).
  `--fingerprint-bits 7` used to start the run and then raise an `ArgumentError` from inside
  `TLA.Fingerprint` mid-search, with a stack trace, as though the library had failed. It is
  now refused up front, like `--workers`, and the accepted widths come from `TLA.Fingerprint`.
- **`mix tla.simulate --against-graph` runs one suite under the options it was given** (#313,
  for #180). It ran the whole simulation and then another `--traces` simulations, so
  `--traces 10000 --against-graph` ran twenty thousand traces, and the second suite dropped
  `--unrestricted`, `--inject-failures` and `--concurrency`, used a different step default
  and derived seeds differently, so a reported seed did not reproduce its trace. The graph
  is now built once and each trace is checked against it as it finishes. Leaving the graph
  is its own outcome, `:left_the_graph`, not a conformance violation, and `--format json`
  now produces a parseable file that carries it.
- **`mix tla.visualize --max-states` bounds the search, and never draws a partial graph**
  (#312, for #180). The flag only gated rendering, so the search ran to a million states
  and, where that default was reached, drew a truncated graph with no note and exit 0. It
  now limits how many states are explored, as in `mix tla.check`, and a graph that is drawn
  is complete. A graph too large to draw exits 2 and says "more than N" states.
- **`mix tla.stamp --restamp` handles two stale mappings in one file, and reports mappings it
  cannot read** (#310, for #173). Two mappings sharing a stale stamp made the task tell the
  user to hand-edit something already fixed and abort before processing other files. It now
  rewrites once per stamp and refuses where mappings in a group resolve to different spec
  versions. A mapping whose `spec:` is not a literal alias is reported as `:unverifiable`
  with the reason, instead of being dropped so the task said "no refinement mappings found".
- **A bounded run no longer claims that nothing satisfied a predicate, and
  `--strict-coverage` fails only on what it should** (#307, closes #167).
  `:antecedent_never_held`, `:consequent_always_held` and an invariant with zero near
  misses now carry the same bounded-run qualifier `never_enabled` already had. An exhaustive
  run whose `state_constraint` never excluded a state is no longer reported as
  `:constrained`, exit 2, failing `assert_spec`. `--strict-coverage` no longer fails on
  `terminal_but_live` or zero near misses, and the footer's warning count matches what
  fails.
- **A Layer 3 driver can deliver actions the server handles by cast or info** (#306, closes
  #172). `TLA.GenServer.Driver` always sent a call, so a mapping to a `handle_cast/2` clause
  crashed a correct server and replay reported `:not_followed`. The mapping may now return
  `{:call, msg}`, `{:cast, msg}` or `{:info, msg}` (a bare term is still a call), a cast
  that never completes is reported as `{:timeout, ms}`, and compile-time validation no longer
  reports a routed action as unmapped.
- **`TLA.Replay` replays liveness counterexamples and simulation traces correctly** (#304,
  closes #168). Every genuine liveness counterexample replayed as `:not_followed` because the
  cycle was misaligned with its actions. Traces from `TLA.Simulation` crashed replay with a
  `FunctionClauseError` on `:unmapped` and `:restart` steps: `:unmapped` steps are now
  skipped and listed in `skipped` (human report and `--format json`), and `:restart` is
  reproduced by killing and restarting the server. With `:server`, a restart cannot be
  reproduced and the replay returns the new `:not_replayable` status; `mix tla.replay` exits
  3.
- **Behaviour traces are well formed wherever they are produced** (#303, for #168).
  `TLA.Trace.well_formed/1` is now public and every trace is checked where it is built.
  `TLA.Simulation` recorded a successful restart without its action, and
  `TLA.GenServer.Runtime.record_initial!/3` recorded the first state twice, so every recorded
  behaviour began with a step that never happened and `TLA.Conformance.against_graph/3`
  classified it as forbidden.
- **A GenServer with no author-written `init/1` compiles** (#300, #301, closes #171). It
  failed with `cannot make function init/1 overridable because it was not defined`, naming
  neither the library nor the cause: under Layer 1 for any invariant applying to `init`, and
  under `use TLA.GenServer` always. The front-page examples of `TLA.Invariant` and
  `TLA.GenServer` hit it; both compile now.
- **`use TLA.GenServer` reports the refinement rules it could not check** (#297, for #169).
  `TLA.Refinement.validate!/3` returned them but nothing showed them, so a mapping without
  `concrete_message/2`, whose action coverage was never checked, gave no sign. Rules
  deferred for that particular mapping are now printed at compile time as a message, not a
  warning, so `--warnings-as-errors` builds are unaffected. Validation also now uses
  constants assigned through `config :extla, MySpec, constants: %{…}` instead of the empty
  assignment.
- **The compile-time refinement probe draws every binding it can, and only where one exists**
  (#286, closes #284; #298, closes #169). With unassigned constants, `concrete_message/2`
  was called with `%{}`, so a mapping for an action with params raised `FunctionClauseError`
  from inside the validator and the conformance examples in the specification did not
  compile. Actions it cannot bind are now not probed and are returned among the rules
  `validate!` could not decide. The probe now draws every binding every `init` block yields,
  not three from the first.
- **`assert_invariants/2` and `assert_action_properties/3` no longer pass when nothing is
  checked** (#295, closes #175). With every invariant compiled out by `enabled: false` they
  passed for every state, so a release test asserted nothing. They now raise and name
  `enabled:` as the usual cause, as `refute_invariant/3` already did.
- **`[:extla, :precondition, :checked]` and `[:extla, :postcondition, :checked]` fire under
  `telemetry: :verbose`** (#279, for #177). Two of the four documented success events were
  never emitted. They now carry `module`, `name` and `duration`; a declaration whose pattern
  does not match the message fires nothing.
- **A temporal formula outside the supported fragment is a compile error** (#277, for #177).
  A nested formula such as `always(always(P))` compiled, then raised an `ArgumentError` with
  no module, declaration or line under `check_liveness: true`, passed as `:ok` under the
  default configuration, and died as a `FunctionClauseError` under `mix tla.simulate` and in
  coverage. `TLA.Spec.Temporal` now refuses it at the declaration. A quantifier over a
  constant with a boolean body, such as `always(Enum.all?(^procs, fn p -> done[p] end))`, is
  an ordinary state predicate and now compiles and checks.
- **Counterexamples show the property's description and the finding's message** (#276, for
  #176). `temporal :x, desc: "…"` was accepted and then dropped; a refutation now quotes it.
  `TLA.Trace.format/1` also dropped every finding's `message` (invariant and action-property
  violation text, the deadlock's pointer at `terminal :name do`, liveness refutations),
  which only reached `to_json/1`; it now prints it.
- **The guides, README and primer route readers correctly** (#287, closes #154; #288, #289,
  closes #155; #293, closes #181). The install snippet in `guides/getting-started.md` pinned
  `tag: "v0.1.0"`, which lacked features the tutorial teaches; it now names the current
  release. The README links the guides and lists all six packaged `mix tla.*` tasks; the
  tutorial's `Next:` chain runs through all eleven pages; and the TLA+ primer says which
  parts of TLA+ ExTLA implements. `usage-rules.md` is now a published docs page, and the
  usage rules no longer link the unshipped `DIAGNOSTICS.md`.
- **The specification's API and examples match the code** (#164, closes #153; #280, for
  #178; #291, closes #156). `spec/01–05` published seventeen signatures and seven type
  shapes the code does not have; they are corrected and `result()` gains `:deadlock`,
  `diameter` and `profile`. `spec/07`'s examples declared types the checker was not given
  and now carry the real ones. Unresolved references that rendered as plain code instead of
  links in the published docs are fixed.
- **The published docs describe the library as built and list only what the package ships**
  (#274, #148). The API reference no longer lists eleven modules a consumer cannot call, such as
  TLA.Ledger and mix tla.coverage. `TLA`'s moduledoc, the landing page, no longer says the model
  checker does not exist; it now describes the three layers, warns that the DSL looks like
  Elixir and is not, and links to the getting-started guide and the normative semantics.
- **Every `mix tla.*` task's flags are documented** (#163). `mix tla.simulate` had no option
  list, so `--inject-failures` and `--unrestricted` were undiscoverable; `mix tla.stamp` had no
  section, and `mix tla.explore`, `tla.replay` and `tla.visualize` were missing options. `mix
  tla.replay --init-arg` is documented as accepted but not currently read (#165).
- **Layer 3 process hygiene** (#269, #213). A running server whose spec was recompiled kept the
  old structure, so a newly added invariant was never checked; the spec cache is now keyed on
  the module's md5. `TLA.Simulation` stops servers as a supervisor would (`:shutdown`, a bounded
  wait, then `:kill`) so `terminate/2` runs, and `run/2` now really stops at the first finding.
  The `constants:` option is removed: the server under test resolves constants from application
  config, so any other assignment drove it against a different specification.
- **Trace rendering and counting edges** (#268, #212). `Trace.length` is now the number of states
  everywhere. A lasso's closing state is labelled as the return to the cycle head, not
  `[VIOLATION]`. The explorer shows an all-error row under `changed_only` and refuses a
  non-function expression once instead of once per state. An enabled action's never-drawn
  `params:` bindings are now a warning, and the profile's run bracket no longer includes the
  liveness pass.
- **Four DSL edges are diagnostics, not crashes or silences** (#264, #210). A `let` may not
  shadow a `params:` name, `old` or `new`. A variable in a temporal quantifier's literal list is
  the temporal-fragment diagnostic instead of a `FunctionClauseError`. `defmodule __MODULE__.Spec` no longer
  crashes the consumer's compile; `check_stamp!` explains that a computed name has no version.
  Duplicate values in `params:` are drawn once, with a warning.
- **Three boundaries refuse bad input up front** (#265, #211). `Trace.from_json!/1` validates the
  trace type and alignment before building anything, and `mix tla.replay` names a missing
  `violation` key instead of raising `CaseClauseError`. `domain/1` on a list answers `1..Len`
  instead of raising `BadMapError`. `for_each/2` ranges over a set or range and refuses a
  sequence or map by name instead of silently deduplicating.
- **`mix tla.replay --trace` and `mix tla.explore` no longer call a bounded run verified** (#261,
  #205). A `max_states_reached` or `constrained` document now reads as bounded at N states or
  held back by the constraint; only `ok` is reported as verified.
- **A raise in one simulation trace no longer orphans every running server** (#262, #206). Each
  `TLA.Simulation` trace runs in a process that owns its server, so a raise anywhere in the
  trace takes the server with it, and a server crash still arrives as an outcome. `init/1`
  returning `:ignore` or `{:error, _}` is an `:error` outcome naming it, not a `MatchError`.
- **Small regressions from earlier fixes** (#263, #209). `init` takes no options and says so
  (`init desc: "x"` used to compile with the keyword dropped). The liveness-skip warning counts
  the selected temporals, not every declared one. `TLA.Conformance`'s `@type finding` includes
  `:nothing_observed`.
- **`Trace.validate/3` rejects a stutter or deadlock at a live state** (#259, #203). A one-state
  cycle with no actions, or a `:deadlock` trace whose last state has successors, validated
  `:ok`. Both now require no enabled step at that state and name the enabled action otherwise.
- **`Trace.format/1` refuses a misaligned trace instead of truncating it** (#260, #204). A trace
  one action short printed too few states with `[VIOLATION]` on the wrong one, and a JSON file
  without `bindings` rendered as a single state. `to_diffs/1` now checks alignment, so
  `format/1` and other consumers refuse such a trace, naming the three counts.
- **A liveness pass skipped by the state budget or a safety counterexample is reported** (#257,
  #208). `check_liveness: true` with a `max_states` bound (or with `mix tla.check
  --allow-incomplete`) said nothing about the unchecked temporals. The result now carries an
  "N temporal properties were not checked" warning with the reason and what to do.
- **A stepped range type honours its step** (#258, #196). `variable :x, type: 0..10//2` dropped
  the step, so `x = 1` passed `type_ok`. The step is honoured (including a `^constant` or
  negative step), a zero step is a compile error, and §1.5 documents `//`.
- **`Replay.counterexample/3` with a registered-name server reports the violation** (#252, #207;
  #255, #254). With `server: <name>`, `TLA.GenServer.Driver.call/3` waited out its 5-second
  timeout and reported `:not_followed`, and a dead registered name raised `invalid destination`
  where a dead pid reported `:stopped`. A pid, a name and `{name, node}` now give the same
  outcome.
- **Profile floors over too few evaluations are marked unsettled** (#249, #248). An entry
  evaluated fewer than four times carries `settled: false`, its row says `floor over N
  evaluations, not settled`, and the footer no longer claims every cost is exactly
  reproducible.
- **The profile's share is correct under `--workers`** (#239, #199). Worker costs were summed
  against only the coordinator's reductions, so the same spec read 12% at one worker and 91% at
  eight and `advice/1`'s verdict inverted. Each worker's bracket now counts in the denominator.
- **Nested temporal quantifiers report vacuity per instance** (#240, #200). Probes were keyed by
  the innermost binding, so an outer instance whose antecedent never held could report
  `vacuous == []`. Coverage and the liveness checker now share
  `TLA.Spec.Compiled.temporal_instances/2`; `vacuity.binding` is the full binding path
  (`[:b, :a]`), or `[]` for an unquantified property, instead of a bare value or `nil`.
- **`subseq/3` follows TLC's `SubSeq`** (#242, #197). A zero or negative index used to wrap
  (`subseq([1, 2, 3], 0, 1)` returned `[3]`), an empty result crashed, and a `MapSet` was
  accepted. Now `n < m` is `[]`, any other out-of-range bound is a `DomainError` naming the
  index and length, matching `at/2`.
- **A non-UTF-8 binary in state no longer crashes `--format json`** (#244, #198). `mix tla.check
  --format json` exited with a stack trace and no document, discarding the counterexample. Such
  binaries are now encoded as base64 under a `"b64"` tag (valid UTF-8 keeps `"b"`, so existing
  traces decode), and `TLA.State.validate!/1` refuses a bitstring that is not whole bytes.
- **An assignment inside a temporal or predicate is a compile error at any depth** (#150; #235,
  #192). `temporal :no_starvation do waiting = [] end` compiled into a property that always
  held. `=` on a declared variable is now rejected in `temporal` as in the other predicate forms,
  and inside nested expressions too, so `always(status = :done)` and `n >= 0 and (status =
  :done)` no longer compile.
- **A constants config key naming no constant is refused** (#236, #193). `config :extla, Spec,
  constants: %{maxx: 100}` against `constant :max` silently ran with the default.
  `Spec.Compiled.resolve_constants/1` now raises, naming the key and the declared constants,
  for `mix tla.check`, `mix tla.simulate` and Layer 3 conformance alike.
- **The spec version changes on every declaration edit** (#237, #194). Changing an `init` value,
  a variable's `type:`, a constant's `default:`, or weak to strong fairness left `spec_version`
  identical, so a stamp stayed fresh. These now move it, and `mix tla.stamp` and the
  compile-time check compute it the same way.
- **A temporal quantifier named after a state variable is a compile error** (#238, #195). With
  `variable :p`, `Enum.all?(^procs, fn p -> eventually(pc[p] == :b) end)` read `p` as the state
  variable in every instance. The quantifier now gets the shadowing diagnostic, naming both the
  local and the declaration.
- **`--verify-symmetry` works without `symmetry:` and no longer accuses a sound declaration**
  (#170). With no `symmetry:` configured, `mix tla.check` reported verified, exit 0; it is now
  refused. A comparison where the unreduced run hit `max_states` is refused with a reason
  instead of reported as a verdict difference, and an inconclusive verification exits 2.
- **Found violations are no longer discarded, and skipped liveness passes are reported** (#167).
  A deadlock that suppresses liveness checking now says so and names the flag that checks
  anyway. `check_liveness:` with `state_constraint:` declines with a reason instead of crashing
  after the search. A configured but non-binding constraint no longer discards a found lasso,
  and the parallel merge no longer drops a counterexample when another worker hit the bound.
- **Names and flags that match nothing are refused** (#166). A selection such as
  `invariants: [:capp]` naming no declaration checked nothing and reported success; it is now
  refused. A `callbacks:` value naming a nonexistent callback warns instead of silently
  disabling the declaration. All `mix tla.*` tasks parse argv strictly.
- **`TLA.Conformance.against_graph/3` checks a one-state behaviour** (#168). It used to pass
  without examining it. A single state is now checked on its own, and an empty behaviour is
  `:nothing_observed` rather than a success.
- **Unknown options on spec DSL declarations are refused** (#160). `variable :n, type: :nat,
  bogus: 1` compiled. Each macro now accepts only what it consumes: `constant` takes `default:`,
  `variable` `type:`, `action` `params:`, and the predicate forms `desc:`. `temporal` now keeps
  its `desc:` instead of dropping it.
- **The DSL's option-list error no longer masks other errors** (#160). Every failure in the
  option helper was reported as "options must be a literal keyword list"; it now reports only
  that case and lets other errors surface as themselves.
- **Unknown options on Layer 1 declarations are refused** (#149). `callbaks: [:handle_cast]`
  compiled and the invariant applied to every callback. The message names the key and what the
  declaration takes; `callbacks:` is refused on `precondition` and `postcondition`, which never
  read it.
- **Layer 1 `enabled:` evaluates its expression** (#149). Any expression, such as `enabled:
  Mix.env() == :test`, enabled the declaration; only a literal `false` worked. It is now
  evaluated at the caller's compile time (`Mix.env()`, module attributes and
  `Application.compile_env/3` work), a non-boolean is refused, and all four declaration kinds
  honour it. Declarations you thought disabled may stop running; check suites that relied on
  them. A stock `MIX_ENV=prod` release was not affected.

## [0.3.20] — 2026-09-09

A minor line: the public surface moved on five counts, two of them breaking. `TLA.Coverage`'s
`observe_action/5` is replaced by `observe_enabled/3` and `observe_generated/4`, and a
`schema_version: 1` JSON document from v0.2.0 is now refused. The additions are
`TLA.Trace.explore/3`, `mix tla.explore`, and `TLA.Profile` with `mix tla.check --profile`; the
patch number counts the fix-level commits that followed (`v0.3.0` marks where the line opened).

### Added

- **`TLA.Trace.explore/3` evaluates your own named expressions at every state of a
  counterexample** (#115, #120). Expressions run down the rows and states across the columns,
  in the order given, so "when did quorum form?" is answered by looking. Columns are chunked to
  a width budget (`width: 68`), an expression that raises is reported at the state it raised in,
  and lasso cycles are marked.
- **`mix tla.explore` shows the same table from the command line over a saved
  counterexample** (#115, #121). `--expr "name: expr"` is repeatable and compiled with the
  state's variables in scope; `--changed-only` narrows the table. It reads what
  `mix tla.check --format json` writes (whole document or a single trace, lassos included); the
  `<module>` argument is required, and a bad `--expr` is reported with its text, the reason and
  which flag it was.
- **`TLA.Profile` and `mix tla.check --profile` report what each of your declarations
  cost** (#116, #130, #131). Per invariant, action guard, transition, action property and
  terminal, measured in reductions (a per-evaluation floor times the evaluations), so the
  ranking does not move with machine load; a predicate whose cost varies with the state is
  flagged. Off by default and free when off, and correct under `--workers`.

### Fixed

- **Profiles over-counted transitions on refuted and `check_liveness: true` runs** (#133,
  #139). Counterexample replay and liveness evaluation were counted as search work. Numbers
  change, always downward, so profiles from before this version are not comparable; guards,
  invariants and action properties were never affected.
- **`coverage.bounded_by` called the counts partial when a completed search found a
  deadlock** (#136). A completed search now reports `:none` whatever it found, so
  `status: :violation` with `bounded_by: :none` means a problem was found and everything was
  searched.
- **A run that halted mid-expansion reported the offending action as never enabled** (#128).
  Enablement is now recorded when the guard admits a binding, via the new
  `TLA.Coverage.observe_enabled/3` and `observe_generated/4` (replacing `observe_action/5`).
  `--strict-coverage` no longer fails on a never-enabled action in a run bounded by
  `max_states` or a `state_constraint`; a complete run still does.

### Changed

- **`mix tla.check --format json` is now `schema_version: 2`**, with a `profile` key that is
  `null` unless the run was profiled. `TLA.Mix.TraceFile` refuses a version-1 document, naming
  both versions; re-running `mix tla.check --format json` regenerates it.

## [0.2.0] — 2026-09-04

The documentation release: a getting-started guide and a multi-page tutorial whose code blocks
and claimed verdicts are checked by the test suite, so they stay true to the tool. It also adds
`TLA.Spec.Deps` and makes `TLA.Trace.validate/3` stricter for safety traces. Still pre-1.0: the
public surface may still move.

### Added

- **A getting-started guide and an eleven-page tutorial** (#95, #96, #97, #99, #100, #101, #104,
  #107, #108, #109, #110, #111). `guides/getting-started.md` goes from installation to a
  deliberate invariant violation; the tutorial under `guides/tutorial/`, read in order, covers
  formal-verification background and the mathematics, the DSL, writing invariants and action
  properties (including deadlock and `terminal`), fairness, symmetry, adopting Layer 1 and
  `TLA.Invariant.Test`, Layer 3 simulation and replay, modelling a real system, what to do when
  a run explodes, and using ExTLA in your project and CI. Both ship in the package under a
  Guides group in `mix docs`.
- **`TLA.Spec.Deps` records each action's read and write variable sets, and each invariant's
  read set, at compile time** (#91). They are carried on the compiled spec; a read set widens to
  `:all` unless every node is recognised.

### Fixed

- **An `action_property` counterexample pointed at the wrong step** (#112, #113). When the
  post-state had been reached by a shorter route, the trace followed that route, omitting the
  offending step. It is now the pre-state's path with the offending step appended; invariant and
  deadlock traces are unchanged.
- **`TLA.Trace.validate/3` now requires a safety trace to refute the property it names**
  (#112, #113). An invariant must be false in the final state, or an action property false over
  the final step; previously any legal path passed. Liveness traces are still not checked here.
- **Documentation corrections: the near-miss column and the docs home link** (#102, #103, #105,
  #106). The guide now says the near-miss probe is derived from the invariant's shape (a
  top-level `or`) and `nil` means not measured; the HexDocs home link and the README's `LICENSE`
  link no longer 404.

## [0.1.0] — 2026-09-02

The first tagged release, completing four implementation phases. Pre-1.0 deliberately: the
public surface may still move, and this tag is a reference point, not a compatibility promise.

### Added

- **The DSL and safety checking.** Specifications written as Elixir (`TLA.Spec`), exhaustive
  breadth-first model checking (`TLA.ModelChecker`), the implicit `type_ok` invariant,
  shortest-counterexample traces, `TLA.Coverage` reporting what a run exercised, and
  `mix tla.check`.
- **Liveness.** Temporal properties, weak/strong per-binding fairness, lasso counterexamples,
  and symmetry reduction with `verify_symmetry:` to detect an unsound declaration.
- **Layer 1 and the conformance bridge.** Invariants on running processes (`TLA.Invariant`),
  `TLA.GenServer` and `TLA.Refinement`, and checking an implementation against a spec with
  `mix tla.simulate` and `mix tla.replay`.
- **Scale and ecosystem.** Parallel exploration (`TLA.ModelChecker.Parallel`), `TLA.PropertyTest`,
  and `mix tla.visualize` (DOT).
- **Verification aids.** `TLA.Trace.validate/3`, `TLA.Conformance.against_graph/3`, and a
  `spec_version:` stamp on refinement mappings that makes a stale mapping a compile error.

### Verified against

- **TLC, on every spec of the differential corpus** (`die_hard`, `two_phase_commit`,
  `distributed_lock`, `raft_election`, `bounded_buffer`, `paxos`), agreeing on distinct states,
  depth, every invariant and temporal property, and the shortest counterexample.

### Performance

- `raft_election` went from 23.4 s to 1.65 s (5.40x from 8 workers on top of a 2.65x gain),
  with the corpus agreeing with TLC at 1, 2, 4 and 8 workers.

### Not included

- No Hex release. This tag marks a point in history; publishing is a separate decision.
- `Mix.Tasks.Tla.Gen.Test`, HTML/D3 visualisation, `TLA.Supervisor.Spec` and view abstraction
  are deferred past v1 — see `spec/06-architecture.md` §Deferred for why each.

[Unreleased]: https://github.com/dcoai/extla/compare/v0.5.0...main
[0.5.0]: https://github.com/dcoai/extla/releases/tag/v0.5.0
[0.4.0]: https://github.com/dcoai/extla/releases/tag/v0.4.0
[0.3.20]: https://github.com/dcoai/extla/releases/tag/v0.3.20
[0.2.0]: https://github.com/dcoai/extla/releases/tag/v0.2.0
[0.1.0]: https://github.com/dcoai/extla/releases/tag/v0.1.0
