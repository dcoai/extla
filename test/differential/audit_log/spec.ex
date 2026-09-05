defmodule TLA.Differential.AuditLog do
  @moduledoc """
  `AuditLog.tla`, in the ExTLA DSL — the corpus's first entry with an
  `action_property` TLC actually checks (#114).

  Every other entry compares invariants and temporal properties. This one exists
  because `action_property` is a first-class declaration — `TLA.Spec.Hash`'s own
  `@kinds` lists it — whose counterexample TLC had never been asked about, which
  is how #112 lived for as long as the feature did.

  It is the smallest model here on purpose. `compact` empties the log, so the
  post-state of the offending step **is** the initial state: a checker that walks
  parent pointers back from the post-state reports a one-state trace with no
  violation in it, while a correct one reports four states ending in `compact`.
  That difference in length is the only thing distinguishing the two answers, and
  a second variable would erase it by making the post-state distinct from `init`.
  """
  use TLA.Spec

  constant :max_entries, default: 2

  # Elements only, matching `TypeOK` in the module. The length bound is
  # `:bounded_log` on both sides rather than part of the type on either.
  variable :log, type: seq(1..^max_entries)

  init do
    log = seq()
  end

  action :record do
    require len(log) < ^max_entries

    log = append(log, len(log) + 1)
  end

  action :compact do
    require len(log) == ^max_entries

    log = seq()
  end

  invariant :bounded_log do
    len(log) <= ^max_entries
  end

  # Refuted by design, and by `compact` — the step this entry exists to make TLC
  # report on. `old`/`new` rather than a bare variable is what makes it an action
  # property (`02-dsl-semantics.md` §4); the TLA+ counterpart is `[][P]_vars`.
  action_property :log_only_grows do
    len(new.log) >= len(old.log)
  end
end
