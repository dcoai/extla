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
`TLA.Spec.Deps` as a new public module and tightened `TLA.Trace.validate/3` so that a trace
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

If the change genuinely has nothing to say to anyone outside the repository — a pure refactor,
an internal rename — answer the check instead of obeying it, with a trailer in a commit message:

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
- **Publishing to Hex.** Out of every release so far, and still undecided. Publishing claims
  the `extla` name on hex.pm permanently — unpublish is possible only within an hour — so it
  is a decision about being a public library, not about marking a point in history.
  `MIX_ENV=prod mix hex.build` stops at `Missing metadata fields: links`, and that gap is left
  unfixed **on purpose**: fixing it would look like preparing for a decision nobody has made.
  Ask before acting on it.

## A release, end to end

```bash
elixir ~/Projects/claude-tools/release.exs               # says v0.2.<n>, checks the gates
elixir ~/Projects/claude-tools/release.exs --prepare     # then MR that commit and merge it
elixir ~/Projects/claude-tools/release.exs --tag         # on main, at the merge commit
elixir ~/Projects/claude-tools/release.exs --post-bump   # then MR that commit too
```

Opening a new minor line is the same sequence with `--minor` on every invocation.

## History

- **v0.1.0** — 2026-09-02. The first tag, across 142 commits and four completed phases (#82,
  #83).
- **v0.2.0** — 2026-09-04. The documentation release; also the first cut under the derived
  scheme, and the release that established it (#118, #119).
