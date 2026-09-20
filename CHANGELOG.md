# Changelog

All notable changes to ExTLA are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**What is built** — module by module, phase by phase — lives in
[`spec/06-architecture.md` §Implementation Phases](spec/06-architecture.md#implementation-phases),
which is the single source of truth for that. This file records what *changed* and when, and
does not restate it.

## [Unreleased]

`mix.exs` reads `0.3.21-dev`: the `-dev` suffix is what keeps a commit from claiming to be the
release it merely follows.

### C### Changed

- **CI's compiled dependencies come from the depdep store alone** (#251, closes #250). depdep
  v0.4.0 never keyed `surfex`, a leaf git dependency, so #247 kept the `mix.lock`-keyed
  `deps`/`_build` cache beside the store to supply it — two sources of truth for one thing.
  v0.5.0 keys it (depdep#70) and hands `--compile-deps` only misses this env is known to build
  (depdep#83); the bump's own pipeline read `pulled 7, skipped 0, not for this env 6` in a job
  with nothing on disk, `surfex` included. The cache is gone; what stays cached is
  `tlc-corpus`'s tla2tools jar, a checksum-verified download.

hanged

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

### Fixed

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

[Unreleased]: https://gitlab.conet.yarina.org/dco-tek/extla/-/compare/v0.3.20...main
[0.3.20]: https://gitlab.conet.yarina.org/dco-tek/extla/-/tags/v0.3.20
[0.2.0]: https://gitlab.conet.yarina.org/dco-tek/extla/-/tags/v0.2.0
[0.1.0]: https://gitlab.conet.yarina.org/dco-tek/extla/-/tags/v0.1.0
