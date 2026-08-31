defmodule TLA.Conformance.Counter.Spec do
  @moduledoc """
  `spec/07-examples.md` Example 4's `Specs.Counter`, verbatim.

  Verbatim is the point: the conformance corpus checks the documentation rather than a
  paraphrase of it, which is the rule the differential corpus was built by. Example 4 is
  where the project explains what Layer 3's step check buys, and it comes with the bug it
  is meant to catch already written down.
  """
  use TLA.Spec

  constant :max_val, default: 5

  variable :count, type: 0..^max_val
  variable :status, type: [:ready, :incrementing]

  init do
    count = 0
    status = :ready
  end

  action :increment do
    require status == :ready
    require count < ^max_val

    count = count + 1
    status = :incrementing
  end

  action :done do
    require status == :incrementing
    status = :ready
  end

  action :reset do
    require status == :ready
    count = 0
  end

  invariant :in_bounds do
    count >= 0 and count <= ^max_val
  end

  temporal :always_returns_to_ready do
    (status == :incrementing) ~> (status == :ready)
  end

  fairness(:weak, [:done])
end
