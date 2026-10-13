# Contributing to ExTLA

This is for working **on** ExTLA. `usage-rules.md` is for projects that use it, and
`RELEASING.md` covers cutting a release.

## Every merge request

- `mix format`, `mix compile --warnings-as-errors` and `mix test` pass.
- A change under `lib/` carries a `CHANGELOG.md` entry. The `changelog` job
  (`bin/changelog_guard.exs`) checks the committed state, so add the entry before pushing.
  The CHANGELOG is the record of what is built; nothing else restates it.
- The six surface goldens are current. Run them as CI does, under the test environment.
  In dev the specs under `test/` aren't compiled, and `mix extla.coverage --check` fails
  even on a clean `main`:

  ```sh
  for t in coverage api_surface cli_surface diagnostics package_surface examples; do
    MIX_ENV=test mix extla.$t --check
  done
  ```

  A golden that drifts is regenerated from source (`--write`), never edited by hand.

## spec/04 and its relation log

`spec/04-layer2-model-checker.md` is tied to the tests that verify it and to the code those
tests exercise by surfex's relation log (#336): `.surfex.exs` is the configuration, and
`.surfex/` is the log, committed and merged by git's union merge. When code, a test or a
section of spec/04 changes, its relations dangle, and `mix surfex.status` says which and
why.

`test/test_helper.exs` records every test run's results in `_build/surfex/evidence.jsonl`,
so the evidence for the commands below is whatever `mix test` last ran.

A `verifies` tag combines as ExUnit merges tags: a test's own `@tag verifies:` replaces its
`@describetag` and `@moduletag`. So a test with its own tag lists every section it verifies,
inherited ones included. Leave one out and `mix surfex.status` reports the relation as
Undeclared.

To run a section's tests, use `mix surfex.test "<section id>"`, adding `--within` for the
sections under it. Don't rely on `mix test --only verifies:<id>`: ExUnit compares a list tag
as one string, so a test tagged `verifies: ["a", "b"]` matches neither `--only verifies:a` nor
`verifies:b`. A list is still the honest tag for a test that verifies several sections.
`mix surfex.status` counts the tests `--only` can't select (66 at surfex 0.7.1), and for
`mix extla.check`'s section, `--only` runs 29 of its 39 tests.

| You changed | Then |
|---|---|
| Behaviour, test first | write the test and tag it `@tag verifies: "<section id>"`; `mix test` (red); `mix surfex.suggest --accept --note "…"`; write the code; `mix test && mix surfex.confirm --evidence` |
| Code only, a pure refactor | `mix test && mix surfex.confirm --evidence` |
| A spec/04 section's wording, not its meaning | `mix surfex.confirm TEST SECTION --type verifies --note "why the reword changes nothing"` |
| A test's name, or split a test module | `mix surfex.suggest --accept --note "…"`, which carries the moved tests' records |
| A spec/04 heading | `mix surfex.suggest` proposes the section move; or `mix surfex.move OLD NEW --note "…"` |
| Something removed | `mix surfex.retire FROM TO --type T --note "…"` |
| A section implemented by code its verifying tests reach through an entry point | relate the code that does the work (`implements`) and `mix test && mix surfex.confirm --evidence`: since surfex 0.7.0 a test is credited for what the code it calls calls; then review it with `mix surfex.validate TEST SECTION --code ITEM --note "…"`, naming the reached code you read (since surfex 0.7.1 a review credits only what the test calls directly, plus the code you name). Since surfex 0.8.0 reach goes on through a Mix task's `run/1`, provided the test calls the task by name (`Explore.run(args)`, not `module.run(args)`). **Except** through a `@moduledoc false` module such as `ExTLA.Mix.TraceFile`: surfex skips it, so reach stops there (surfex#219). For code reached only that way, relate the caller to it with `mix surfex.relate CALLER ITEM --type depends_on --note "…"` |

Then `mix surfex.goldens --write` and commit `.surfex/` and `RELATIONS.md` with the change.

CI's `relation-status-drift` job is the gate, and a HARD one since the baseline (#354). It
runs `mix surfex.status --verify` (the log, and every relation current), `mix surfex.goldens`
(`RELATIONS.md` is up to date) and `mix surfex.status --evidence` against the `test` job's
evidence (every relation confirmed by evidence still holds in that run).

A section id is the heading path, such as
`spec/04-layer2-model-checker.md#Layer 2: Specification DSL + Model Checker/State-space reduction/Symmetry`.
spec/04 carries no `{#id}` heading anchors: the spec files are ex_doc extras, where an anchor
renders as literal text and moves the heading's slug, which `test/docs/slug_model_test.exs`
checks.

Each relation is judged one at a time, against both its ends. Never script confirmations or
bulk-accept to turn the status green, and never confirm an `implements` relation by hand: it
needs evidence or a review. Don't hand-edit `.surfex/`. If `RELATIONS.md` conflicts in a
merge, regenerate it with `mix surfex.goldens --write`.

Reading `mix surfex.status`: each group names what changed and the usual fix. `mix
surfex.info status` explains the groups, and `mix surfex.info` lists the rest.
