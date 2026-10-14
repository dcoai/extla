# Releasing ExTLA

How a release is cut, and why the steps are shaped the way they are.

This is a maintainer document. It is deliberately **not** in `docs: extras:`, not in the
package `files:` list, and not linked from `README.md` — the README ships in the package and
renders as the docs front page, so a link to a file that does not ship would 404 in the
published docs, which is the defect the built-docs gate (#103) exists to catch.

The tool is `~/Projects/claude-tools/release.exs`, and `release.exs --help` carries this same
model in short form. It is project-agnostic; nothing in it is specific to ExTLA.

## Two kinds of release, and only one is automated

**Minor** — `v0.2.0`, `v0.3.0`. A judgement call: someone decides the public surface moved.
Always explicit, via `--minor`.

The judgement is about the surface, not the size of the diff. v0.2.0 is the worked example:
it was asked for as `v0.1.1` and was almost entirely documentation, but it added
`ExTLA.Spec.Deps` as a new public module and tightened `ExTLA.Trace.validate/3` so that a trace
which returned `:ok` under v0.1.0 can now return `{:error, _}`. A patch number promises
backwards-compatible fixes only, which was false on both counts.

**Patch** — `v0.2.7`. Not a judgement call at all. The number is a function of the history,
so nobody has to remember what the last one was and two people cannot pick the same one.

## Where the patch number comes from

```
git describe --match 'v[0-9]*.[0-9]*.0' --long   →   v0.2.0-17-gabc1234
                                                               │
                                                         patch = 17  →  v0.2.17
```

`n` is the commit count since the **minor base tag**. The `--match` glob is the whole point:
it selects only `.0` tags.

### The base tag is a marker, and it need not be a release

`v0.3.0` is the first case where the minor line opened at a commit that was **not** itself
released. The five surface-moving changes of the 0.3 line all landed by `bf14e81` (#135), and
twenty commits of fixes and CI work followed before anyone cut a release — so the first tag on
the line is `v0.3.20`, and `v0.3.0` was tagged retroactively at `bf14e81` to mark where the
surface moved.

That tag is doing a job, not claiming a release. `bf14e81`'s own `mix.exs` reads `0.2.1-dev`
and it has no section in the CHANGELOG, because nothing was published from it.

**It is not decoration — without it the numbering goes backwards.** `v0.3.20` does not match
`v[0-9]*.[0-9]*.0`, so `git describe` would skip it and keep counting from `v0.2.0`:

| tags present | `describe --match` | next patch |
|---|---|---|
| `v0.2.0`, `v0.3.20` | `v0.2.0-49-g…` | `v0.2.49` ❌ **below the release just cut** |
| `v0.2.0`, `v0.3.0`, `v0.3.20` | `v0.3.0-25-g…` | `v0.3.25` ✅ |

This is the same trap as the one above, reached through the other door: there, the count reset
at a patch tag; here, it never re-bases because the line has no `.0` to re-base onto. The rule
that falls out of both: **opening a minor line means tagging its `.0`, whether or not anything
was released from that commit.**

### The trap it avoids

Plain `git describe` counts from the **last** tag, so the count resets at every patch tag:

| history | `git describe` | naive reading |
|---|---|---|
| tag `v0.2.0`, then 5 commits | `v0.2.0-5-g…` | `v0.2.5` ✅ |
| tag `v0.2.5`, then 3 commits | `v0.2.5-3-g…` | `v0.2.3` ❌ **backwards** |

Matching only `.0` tags pins the count to `v0.2.0` however many patch tags sit in between,
and re-bases by itself when `v0.3.0` is opened. `release_test.exs` pins this as a regression:
it builds exactly that history and asserts the tool says `v0.2.8` where `git describe` says
`v0.2.5-3-g…`.

### What the numbering promises

- **Monotonic and unique.** Guaranteed.
- **Not dense.** Merge commits count. Every work item lands through a merge request and
  GitLab's merge-commit method adds a commit of its own, so a single-commit work item
  advances `n` by two and patch numbers skip. Across v0.1.0…v0.2.0: 46 commits, 23 of them
  merges, 23 work items.
- **Not an invariant of the tagged commit.** The release commit lands *after* the count is
  taken, so `git rev-list --count <base>..<tag>` reads one or two higher than the patch
  number in the tag. Monotonicity is the property that matters; density is not.

Counting `--no-merges` would give a denser number and is deliberately not done: it would no
longer match what `git describe` reports, and `git describe` is what someone types by hand.
A tool and a command that disagree about `n` is a worse trap than a number that skips.

## The lifecycle

Between releases `mix.exs` reads `X.Y.Z-dev`. The suffix is what keeps a commit from claiming
to be the release it merely follows.

| Step | What happens | How it lands |
|---|---|---|
| *(work)* | Work items merge to `main` as usual | MR + green pipeline (#72) |
| `release.exs` | Dry run: the version it would cut and every gate. Acts on nothing. | — |
| `--prepare` | Writes the version into `mix.exs`, closes `[Unreleased]` → `[X.Y.Z] — date`, commits | MR |
| `--tag` | Annotated tag on the merged commit, pushes it, creates the GitLab release | direct |
| `--post-bump` | `mix.exs` → `X.Y.(Z+1)-dev`, reopens `[Unreleased]` | MR |

### Why `--prepare` and `--tag` are separate

This looks like ceremony and is not. The tag must point at a commit that **carries** the
version — a tag on a tree still reading `-dev` is worse than no tag, which is what #83
settled. But `main` is protected behind the merge gate, so that version commit cannot be
pushed to it directly. Hence: commit → merge → tag the merge commit. One tool invocation
cannot span a merge request.

### Tag the commit whose own pipeline is green

Both tags so far cite the pipeline of the commit they tag, and the `--tag` gate enforces it
by asking the GitLab API for the newest pipeline on `HEAD`'s sha. A tag that cannot say its
own commit was green is worth less than one that can — the same distinction between presence
and evidence that `TLA_COVERAGE.md` draws one layer down.

## The gates

All six are reported together rather than failing at the first, so one dry run lists
everything that needs fixing:

```
[PASS] working tree clean
[PASS] patch number is not zero
[PASS] tag v0.2.7 does not exist
[FAIL] HEAD pipeline is green          ← via the GitLab API, on HEAD's sha
[PASS] CHANGELOG has a release entry   ← [Unreleased], or [X.Y.Z] after --prepare
[PASS] mix.exs carries @version
```

`--tag` additionally prompts before acting, because a tag is permanent. The escapes are
`--no-ci-check`, `--no-changelog`, `--no-push` and `--yes`.

## When an entry gets written: at the change, not at the release

**A merge that touches `lib/` writes its `[Unreleased]` entry in the same merge request.** CI
enforces it — the `changelog` job in the `check` stage runs `bin/changelog_guard.exs`, which
compares the merge base against the branch and fails when `lib/` moved and `CHANGELOG.md` did
not.

**An entry is for someone who uses ExTLA.** The CHANGELOG ships, and HexDocs renders it, so it
records what a user can observe: a new feature, option or flag, a behaviour change, a fix to a
wrong verdict, a crash or a misleading message, a change to what the docs teach. Work that only
the repository sees gets no entry: CI, the surface goldens, the relation log, the mutation
harness, test tooling, benchmarks, refactors and maintenance of `spec/` and the decision log.
Its record is the commit, the merge request and the issue. Entries before 0.5.1 were condensed
to this rule in #406; the full text is the `CHANGELOG.md` at the `v0.5.0` tag.

If a change under `lib/` genuinely has nothing to say to anyone outside the repository — a pure
refactor, an internal rename, a change only the tests can see — answer the check instead of
obeying it, with a trailer in a commit message:

```
Changelog-none: internal rename, no behaviour or API change
```

The reason is required. It goes in the commit message rather than a label or a CI variable so
that it lands in the history beside the diff, where a reviewer reads it: answering has to cost
the same visibility as complying, or the hatch becomes a bypass and the gate becomes theatre.

Why a gate rather than a note in a checklist: #124 read the history as a habit that broke, and
#142 found there had never been a habit. The eighteen consecutive work items that appeared to
establish one were the documentation milestones — fourteen touched no `lib/` at all, and wrote
entries because writing prose *was* the work — while `issue-91-dependency-sets`, in the same
era, changed three files under `lib/` and wrote nothing. No issue, skill or `CLAUDE.md` section
has ever mentioned the CHANGELOG. So this rule is new, and the gate is what makes it a rule.

## What stays a human decision

- **The CHANGELOG content.** The tool closes a section; it never writes one, and an empty
  entry is refused. What changed and why it matters is not derivable from the diff — which is
  the whole argument for writing the entry while the work is in hand, and the reason the gate
  above sits at the change rather than at the release.
- **Minor versus patch.** `--minor` is always explicit.
- **A minor's tag message.** v0.1.0 and v0.2.0 are hand-written prose. Patch tags take the
  changelog section automatically.
- **Publishing to Hex.** Out of every release so far. It is decided in principle, to follow
  the documentation review after v0.5.0, but each publish still needs an explicit go.
  Publishing claims the `extla` name on hex.pm permanently (unpublish is possible only within
  an hour). `MIX_ENV=prod mix hex.build` now passes its metadata check. Before running
  `mix hex.publish`, push the release's commit and tag to GitHub (above), so the package's
  `source_url` and source links resolve.

## A release, end to end

```bash
elixir ~/Projects/claude-tools/release.exs                                  # says v0.2.<n>, checks the gates
elixir ~/Projects/claude-tools/release.exs --prepare --link-remote github   # then MR that commit and merge it
elixir ~/Projects/claude-tools/release.exs --tag                            # on main, at the merge commit
elixir ~/Projects/claude-tools/release.exs --post-bump --link-remote github # then MR that commit too
```

**GitHub is the public home, and GitLab is where the work happens.** `--link-remote github`
writes `CHANGELOG.md`'s version links against the `github` remote
(`git@github.com:dcoai/extla.git`), because the CHANGELOG ships and a reader can't reach the
GitLab instance. Without it the links point at `origin`. Add the remote once with
`git remote add github git@github.com:dcoai/extla.git`.

GitHub is pushed by hand; there is no mirror. After `--tag`, and always before a Hex publish,
send `main` and the new tag there:

```bash
git push github main
git push github v<version>
```

Work branches stay on GitLab. Between releases GitHub's `main` lags GitLab's, which is
accepted: the public install pins a tag. The GitLab release page is created by `--tag`.
GitHub shows the tag, and has no release page unless one is made there.

**The `--prepare` commit also moves the install requirement.** The `tla:deps` blocks in
`README.md` and `guides/getting-started.md` install from Hex with `{:extla, "~> X.Y.0"}`, and
the guide harness fails the build unless that requirement admits `CHANGELOG.md`'s newest
release and names its minor line (#424; before that, a `tag:` held to the same record).
`--prepare` closes the section that makes it stale, so on a minor release the same commit
edits the requirement to the line being cut. A patch release leaves it alone, because
`~> X.Y.0` already admits it. `release.exs` is project-agnostic and doesn't know the pages
exist. v0.4.0's release MR found this the slow way: its pipeline went red on the gate.

Opening a new minor line is the same sequence with `--minor` on the dry run, `--prepare` and
`--tag`, but **not** on `--post-bump`. Once `vX.Y.0` exists, `--minor` names the *next* line,
so `--minor --post-bump` after v0.4.0 wrote `0.5.1-dev`. Run `--post-bump --version X.Y.0`
instead, which writes `X.Y.1-dev`. v0.4.0's post-bump caught this before it merged.

## History

- **v0.1.0** — 2026-09-02. The first tag, across 142 commits and four completed phases (#82,
  #83).
- **v0.2.0** — 2026-09-04. The documentation release; also the first cut under the derived
  scheme, and the release that established it (#118, #119).
