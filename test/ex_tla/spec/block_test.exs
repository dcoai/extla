defmodule ExTLA.Spec.BlockTest do
  @moduledoc """
  `near_miss/1`'s two outcomes, pinned (#105, #106).

  The near-miss column is *derived* from an invariant's shape and declared nowhere — which two
  documents said otherwise until #106. The doctests below are what makes that story assertable:
  an implication yields a probe, a bare comparison yields `nil`, and the atomic-bound probe that
  would measure the second is deferred (`06-architecture.md` §Deferred past v1). Building it has to
  change the test that records its absence.
  """
  use ExUnit.Case, async: true

  doctest ExTLA.Spec.Block, only: [near_miss: 1]
end
