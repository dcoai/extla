# Contributing to ExTLA

This is for working **on** ExTLA. `usage-rules.md` is for projects that use it, and
`RELEASING.md` covers cutting a release.

## Every merge request

- `mix format`, `mix compile --warnings-as-errors` and `mix test` pass.
- A change under `lib/` carries a `CHANGELOG.md` entry. The `changelog` job checks the
  committed state, so add the entry before pushing.
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

| You changed | Then |
|---|---|
| Behaviour, test first | write the test and tag it `@tag verifies: "<section id>"`; `mix test` (red); `mix surfex.suggest --accept --note "…"`; write the code; `mix test && mix surfex.confirm --evidence` |
| Code only, a pure refactor | `mix test && mix surfex.confirm --evidence` |
| A spec/04 section's wording, not its meaning | `mix surfex.confirm TEST SECTION --type verifies --note "why the reword changes nothing"` |
| A test's name, or split a test module | `mix surfex.suggest --accept --note "…"`, which carries the moved tests' records |
| A spec/04 heading | `mix surfex.suggest` proposes the section move; or `mix surfex.move OLD NEW --note "…"` |
| Something removed | `mix surfex.retire FROM TO --type T --note "…"` |

Then commit `.surfex/` with the change.

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
