# HANDOFF — 2026-08-30 — CI setup, then Phase 1 implementation

> **SUPERSEDED by `HANDOFF-2026-08-30-phase1-components.md`.** Everything below
> was done: the ssh blocker was agent forwarding and is gone, both MRs landed,
> and Phase 1's components are built. Kept as the record of what the session
> looked like before any of that.

Written mid-session so work can resume after fixing ssh-agent forwarding and
restarting Claude. Read this first; it is self-contained.

---

## THE BLOCKER (why the session stopped)

`git push` fails. There is **no SSH private key on this machine**:
`~/.ssh/` contains only `authorized_keys`, `known_hosts`, `config`.

`~/.ssh/config` says:

```
Host gitlab.conet.yarina.org
  Port 2022
  IdentityFile ~/.ssh/dco_gitlab_ed      # <-- this file does not exist
```

Push error:

```
no such identity: /home/dco/.ssh/dco_gitlab_ed: No such file or directory
git@gitlab.conet.yarina.org: Permission denied (publickey).
```

`ssh-reagent` was tried: it is not defined on this machine (not a function,
alias, or on PATH). Its job — find a live forwarded agent — was done manually
instead. **All three agent sockets under `/tmp/ssh-*/agent.*` are stale**
(`communication with agent failed`), including the one `SSH_AUTH_SOCK` points
at. `ps` shows only the sshd listener, no live session, so agent forwarding
from a previous connection has died.

**Fix:** reconnect to this box with agent forwarding (`ssh -A`, or
`ForwardAgent yes` for this host) with the GitLab key loaded on the laptop
(`ssh-add -l` there should list it). That creates a fresh live socket and the
push works despite the missing `IdentityFile` — ssh falls back to agent keys.

**Verify after reconnecting:**

```bash
ssh-add -l                                   # must list a key
ssh -T git@gitlab.conet.yarina.org           # expect a GitLab welcome
```

Rejected alternatives (still available if forwarding is not wanted):
- generate an ed25519 key at `~/.ssh/dco_gitlab_ed` and upload the public half
  via `glab api --method POST user/keys` (adds a key to the GitLab account)
- push over HTTPS with the existing glab token (scope `api`, expires
  2027-08-30) — writes a plaintext token to a credential store

---

## STATE OF THE REPO

Branch **`chore/toolchain-and-ci`**, one commit ahead of `origin/main`:

```
5ec4656 Add Elixir project skeleton, toolchain pins, and CI
```

That commit adds: `mix.exs`, `mix.lock`, `.formatter.exs` (with the spec DSL's
`locals_without_parens`), `.tool-versions`, `.gitlab-ci.yml`, `LICENSE` (MIT),
`lib/tla.ex` (stub), `test/test_helper.exs`, `test/differential/README.md`,
`bin/install-erlang-deps.sh`, and a `.gitignore` guard for editor backups.

**UNCOMMITTED, DO NOT LOSE — 10 files, +660/-178:**

```
README.md  spec/README.md  spec/01..08-*.md
```

These are the spec review fixes (see below). They are deliberately unstaged and
destined for a **second MR** after the CI MR lands. `git stash` them only if you
must switch branches; prefer leaving them in the working tree.

---

## TOOLCHAIN (done, verified)

- **asdf v0.20.0** at `~/.local/bin/asdf`; `~/.bashrc` exports
  `~/.local/bin`, `ASDF_DATA_DIR=~/.asdf`, and `~/.asdf/shims` onto PATH.
- **erlang 29.0.5** built from source (OTP 29, ERTS 17.0.5). jinterface was
  skipped — no Java compiler at build time. Irrelevant for Elixir work.
- **elixir 1.20.4-otp-29** (precompiled).
- Both set in `~/.tool-versions` and pinned per-project in `.tool-versions`.
- Debian build deps for Erlang were installed by the user via
  `bin/install-erlang-deps.sh`.
- `java` 21 present (`javac` absent) — enough to run TLC later.

Local verification, all green: `mix deps.get`, `mix compile --warnings-as-errors`,
`mix test` (no tests yet), `mix format --check-formatted`.

---

## CI (written and server-validated, NOT yet pushed)

`.gitlab-ci.yml` validated against the server:

```bash
glab api --method POST projects/178/ci/lint \
  --header "Content-Type: application/json" --input <json {"content": ...}>
# => valid: true, errors: [], warnings: []
```

Shape copied from the sibling project `eesidai` (project 177), whose Elixir
pipeline demonstrably passes on this instance:

- runner tag **`DCOTek`** — instance runner id 3, docker executor, linux/amd64,
  runner 18.5.0, `run_untagged=true`. (Runner id 4 is tag `dind`, privileged,
  `run_untagged=false` — for image builds only; ExTLA does not need it.)
- image `hexpm/elixir:1.20.4-erlang-29.0.5-debian-bookworm-20260824-slim`
  (tag existence confirmed on Docker Hub), matching `.tool-versions` exactly
- cache keyed on `mix.lock`, paths `deps` + `_build`
- one `check` stage: `format`, `compile --force --warnings-as-errors`, `test`
- **runner job timeout is 30 minutes** — keep jobs under it

A `verify` stage running the TLC differential corpus is deliberately absent
until the first corpus entry exists; a job that pulls a JDK to echo a message
is not a gate.

---

## GITLAB

- host `gitlab.conet.yarina.org`, `glab` v1.115.0 authenticated as `dco`
- project **`dco-tek/extla` = id 178**, default branch `main`, jobs enabled
- open issue **#1** — "Verification ledger: drift-gated coverage golden +
  spec-version stamps", label `Proposal`, mirrored locally at
  `pm/pm-1-verification-ledger.md`

**Process (from the project's labels):**

```
Proposal -> Accepted -> Planned (work item) -> In-Progress -> Review (MR) -> merge
```

| Label | Meaning |
|---|---|
| `Proposal` | Cross-project change request |
| `Research` | Working proposal / idea collection, not ready to implement |
| `Accepted` | Proposal evaluated and approved |
| `Planned` | Work item queued for implementation |
| `In-Progress` | Work item actively being implemented |
| `Review` | Code complete, MR under review |
| `External` | Relates to a third-party dependency |
| `Blocked` | (exists on agentronic, not yet on extla) |

Sibling project `agentronic` (id 174, `/home/dco/Projects/agentronic`) is the
reference for conventions — see its `spec/conventions-0*.md` and `pm/` layout,
including `pm/HANDOFF-*.md` which this file imitates.

---

## WHAT THE SPEC REVIEW CHANGED (the uncommitted diff)

A full review of the ~7k-line spec found the design settled at the level of
syntax and API surface but not at the level of checking algorithms. Five
blocking gaps, all now resolved in the documents Phase 1 builds from, plus
eight concrete bugs. New decisions **D-15..D-19** were added and **D-5, D-6,
D-12** amended.

| # | Problem | Resolution |
|---|---|---|
| 1 | Parent-pointer graph is a spanning tree — acyclic, so SCC-based liveness could never find a violation, and fairness needs `ENABLED` per state after states are discarded | Opt-in **liveness graph**: under `check_liveness: true` also record out-edges + one ENABLED bit per fairness constraint while the state is materialized. `successors/2` reads the edge table, raises otherwise. D-5 amended |
| 2 | Fairness was per-action only; every starvation property in the corpus was unprovable | **Per-binding fairness** `fairness :strong, acquire_lock: [:p]` = `\A p : SF(Acquire(p))`. New §5.2, D-15 |
| 3 | No way to declare a legitimate terminal state; two corpus specs self-reported as deadlocks | **`terminal :name do pred end`**. New §5.3, D-16 |
| 4 | `check_step!/5` needed params the refinement mapping cannot recover (implementation resolves the nondeterminism itself) | Params may be **partial**; search unbound generators for a binding reproducing the post-state. D-6 amended |
| 5 | Compile-time symmetry-soundness check was undecidable and over-promised | Author obligation + **`verify_symmetry: true`** dynamic cross-check; `n!` canonicalization cost now stated. D-17 |

Concrete bugs fixed: README's headline counter example deadlocked and violated
its own temporal property (missing `done`/`reset`); `mutual_exclusion` in
Example 1 was a tautology of the model's type (now stated over `pc`, with
`{:holding, r}`); `near_misses` was defined as something impossible; the Layer 3
transfer example diverged on a phantom `time:` key and reversed log order;
`invariant/4`'s two trailing optional positionals were ambiguous (now `desc:`
everywhere, D-18); `TLA.Config.mode/0` had `compile_env` in the macro body
(moved inside the `quote`) and `function_exported?(Mix, :env, 0)` (now
`Code.ensure_loaded?`); Runtime signatures didn't match the emitted wrapper;
`type_expr` could not express the corpus's constant-dependent types (now
`Macro.t()`, resolved at check time, grammar in new §1.5, D-19). Plus the
dangling `§Coverage and Vacuity` heading, "work-stealing" -> work sharing,
duplicate `TLA.State.trace`, and `Fingerprint.t` width.

Two corpus consequences worth knowing: Raft's `eventually_elect_leader` is
genuinely refuted by the term bound (recorded as an expected violation with a
`terminal` and a test asserting where it ends), and BoundedBuffer's
`no_consumer_starvation` now excepts the drained end state.

---

## RESUME HERE — exact next steps

1. **Confirm auth works** (see THE BLOCKER above).

2. **Push the CI branch and open MR 1.**
   ```bash
   cd /home/dco/Projects/extla
   git push -u origin chore/toolchain-and-ci
   glab mr create --title "Add Elixir project skeleton, toolchain pins, and CI" \
     --description "..." --remove-source-branch --yes
   glab ci status        # or: glab ci view
   ```
   Watch the pipeline actually go green — that is the point of this MR. Then
   merge it.

3. **MR 2: the spec review fixes.** Branch off updated `main`, commit the 10
   uncommitted files, push, open MR, merge. Suggested subject:
   `Fix spec gaps found in review: liveness graph, per-binding fairness, terminal states`.

4. **Then Phase 1, via Proposal -> WI -> MR -> merge.** Build order is
   `spec/06-architecture.md` §Implementation Phases:
   `TLA.State` + `TLA.Config` + `TLA.Fingerprint` -> `TLA.Set`/`TLA.Function`
   -> `TLA.Spec` DSL + the §7 compile-time validator (the genuinely unproven
   part) -> single-threaded BFS + `TLA.StateGraph` -> `TLA.Trace` replay ->
   `TLA.Coverage` -> `mix tla.check`.

   Before the checker exists, land the **TLC oracle**: download `tla2tools.jar`
   and add the first differential corpus entry (die hard — tiny, known
   counterexample of known length). Per D-9 the corpus is the Phase 1
   acceptance criterion, so having it runnable first means every piece is
   checked against truth from day one. Layout is in
   `test/differential/README.md`. Add the `verify` CI stage with that entry.

   pm-1 items scoped to Phase 1 (`TLA.Spec.version/1`, the coverage golden,
   the JSON schema) slot in near the end.

The user asked for this to run **as autonomously as possible**.
