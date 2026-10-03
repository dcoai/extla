defmodule ExTLA.Differential.DieHard do
  @moduledoc """
  `DieHard.tla`, in the ExTLA DSL. The two are checked against each other by
  `test/differential/differential_test.exs`; `expected.json` is what TLC said.

  Kept as close to the TLA+ module as the two languages allow, so a
  disagreement points at the checker rather than at a translation choice.
  """
  use ExTLA.Spec

  # TypeOK in DieHard.tla is `small \in 0..3 /\ big \in 0..5`. Here it is the
  # declaration itself: types are checked as the implicit `:type_ok` invariant in
  # every reachable state (02-dsl-semantics.md §1.5), which is the same check
  # written once.
  variable :small, type: 0..3
  variable :big, type: 0..5

  init do
    small = 0
    big = 0
  end

  action :fill_small do
    small = 3
  end

  action :fill_big do
    big = 5
  end

  action :empty_small do
    small = 0
  end

  action :empty_big do
    big = 0
  end

  action :small_to_big do
    let poured = if(big + small > 5, do: 5 - big, else: small)
    big = big + poured
    small = small - poured
  end

  action :big_to_small do
    let poured = if(big + small > 3, do: 3 - small, else: big)
    big = big - poured
    small = small + poured
  end

  # Refuted by design. TLC's counterexample is the solution to the puzzle, which
  # is what makes the shortest-counterexample comparison meaningful: a checker
  # that reports a longer trace has not searched breadth-first.
  invariant :not_solved do
    big != 4
  end
end
