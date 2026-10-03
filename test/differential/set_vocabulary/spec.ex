defmodule ExTLA.Differential.SetVocabulary do
  @moduledoc """
  `SetVocabulary.tla`, in the ExTLA DSL — the seventh corpus entry, and the only one whose
  subject is the **vocabulary** rather than an algorithm (#319, for #183).

  `01-foundation.md` specifies the set-theoretic and function operators as the foundation
  everything else builds on, and until #319 a spec body could not reach most of them: an
  author had to write `ExTLA.Set.powerset/1` in full, and exactly one spec in the repository
  did. A unit test would have shown that the operators still work. It would not have shown
  that a spec *using* them means what TLA+ means — that `exists?(powerset(^nodes), …)` is
  `\\E q \\in SUBSET Nodes : …`, reachable state for reachable state.

  So every operator here is called the way an author writes one: unqualified, in an action
  body or an invariant, against a TLC oracle.

  | ExTLA | TLA+ | reachable since |
  |---|---|---|
  | `powerset/1` | `SUBSET S` | #319 |
  | `exists?/2` | `\\E x \\in S : P(x)` | #319 |
  | `for_all?/2` | `\\A x \\in S : P(x)` | #319 |
  | `union/2` | `S \\cup T` | always |
  | `subset?/2` | `S \\subseteq T` | always |
  | `size/1` | `Cardinality(S)` | always |
  | `for_each/2` | `[x \\in S |-> e]` | always; one implementation since #319 |
  | `update/3` | `[f EXCEPT ![k] = v]` | always; one implementation since #319 |
  """
  use ExTLA.Spec

  constant :nodes, default: MapSet.new([:n1, :n2, :n3])

  variable :acked, type: set(^nodes)
  variable :votes, type: [^nodes ~> 0..1]
  variable :committed, type: [true, false]

  init do
    acked = set()
    votes = for_each(^nodes, fn _ -> 0 end)
    committed = false
  end

  action :ack, params: [n: ^nodes] do
    require not member?(acked, n)

    acked = union(acked, set([n]))
    votes = update(votes, n, fn _ -> 1 end)
  end

  # The guard quantifies over a SUBSET of the nodes rather than testing `size(acked)`
  # directly. The two are equivalent, which is the point: the equivalent form is the one
  # that exercises `powerset/1` and `exists?/2`, and `committed_needs_quorum` below states
  # the cardinality form — so a disagreement between them is a red invariant rather than a
  # silently different state count.
  #
  # Not guarded on `not committed`: a repeated commit is a self-loop rather than a new
  # state, and it keeps the final state from being a deadlock, which this entry is not
  # about.
  action :commit do
    require exists?(powerset(^nodes), fn q ->
              size(q) * 2 > size(^nodes) and subset?(q, acked)
            end)

    committed = true
  end

  invariant :committed_needs_quorum do
    not committed or size(acked) * 2 > size(^nodes)
  end

  invariant :votes_match_acks do
    for_all?(^nodes, fn n -> member?(acked, n) == (votes[n] == 1) end)
  end
end
