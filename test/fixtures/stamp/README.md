# `mix tla.stamp` fixture tree

A tree carrying the two stamp statuses this project's own sources cannot produce
(#308, for #173).

## Why it is here and not in the corpus

`:stale` and `:unverifiable` had **never executed**. The real corpus holds only fresh and
unstamped mappings, so collapsing both into `:fresh` stayed green and the coverage gate did
not move, because the golden records `stale 0`. Dead with them: both `detail/1` clauses, the
"N stale, re-read each mapping" report, and the documented stale-wins-over-fresh precedence.

They cannot be produced there, either. A genuinely stale stamp in a compiled tree is a
**compile error** — that is what the mechanism is for — so the corpus cannot hold one.

So this tree is deliberately **outside every path `Mix.Tasks.Tla.Stamp.roots/0` scans**, and
outside `elixirc_paths` in every environment:

* nothing here is compiled, so the stale stamps are inert;
* the repository's own `mix tla.stamp` does not see them, so its report stays a report about
  the repository. Once #311 makes the task gate CI, a stale stamp inside a scanned tree
  would fail every build.

`run/2`, `states/1`, `sources/1` and `module_index/1` take the roots as an argument for
exactly this. It is a seam, said to be one — a `--root` flag would be CLI surface added for
a test.

## What is here

The tests pass **two** roots, `["test/fixtures/stamp", "test/conformance"]`, because a
mapping's status depends on finding its spec's source: with only this directory every entry
is `:unverifiable` for want of the spec, which is a fact about the roots rather than about
the mappings. The conformance corpus supplies the spec, and with it the other two statuses.

| Source | Status | Why |
|---|---|---|
| `stale.ex` | `:stale` ×2 | two mappings, one file, **one shared stamp** — the `--restamp` crash (#310) |
| `stale_distinct.ex` | `:stale` ×2 | two mappings, two different stamps — the case that already worked, kept so a fix cannot be "rewrite once per file" |
| `unstamped.ex` | `:unstamped` | no `spec_version:`; the stamp is opt-in |
| `unverifiable.ex` | `:unverifiable` | its `spec:` is a literal alias whose **source is not in the index**, so the hash cannot be computed |
| `dropped.ex` | *none* | its `spec:` is `@spec_module`, not a literal alias, so `mappings/1` rejects it and it gets no status at all — #173's defect 4, fixed by #310 |
| `test/conformance/counter/impl.ex` | `:fresh`, `:unstamped` | the real corpus, unchanged |

The stale stamps are `00000000`, `11111111`, `22222222` and `33333333` — not hashes of
anything, so none can become current by accident when the spec moves.

**A test that restamps this tree must work on a copy.** `--restamp` rewrites source in
place, and a test that let it rewrite these files would pass once and then test a tree with
no stale stamp in it.

## `dropped.ex` is not `unverifiable.ex`

They look alike and are different defects, which is why both are here.

`unverifiable.ex` **reaches `state/2`** and is given a status: its `spec:` resolves to a
module name, and nothing under the roots declares that module, so `current_version/2`
answers `nil` and the status is `:unverifiable` — the documented meaning, "the spec's
hash could not be computed".

`dropped.ex` never gets that far. `spec_of/1` returns `nil` for a `spec:` that is not a
literal alias, and `mappings/1` rejects the entry — so the mapping is **silently
dropped** and the task can go on to say "no refinement mappings found" about a file it
read and could not understand. `test/mix/tla_stamp_test.exs` pins that, so #310 changing
it is deliberate.
