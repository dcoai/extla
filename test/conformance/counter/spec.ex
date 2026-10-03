defmodule ExTLA.Conformance.Counter.Spec do
  @moduledoc """
  `spec/07-examples.md` Example 4's `Specs.Counter`, verbatim.

  Verbatim is the point: the conformance corpus checks the documentation rather than a
  paraphrase of it, which is the rule the differential corpus was built by. Example 4 is
  where the project explains what Layer 3's step check buys, and it comes with the bug it
  is meant to catch already written down.
  """
  use ExTLA.Spec

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

defmodule ExTLA.Conformance.Counter.BuggySpec do
  @moduledoc """
  The same counter with a design bug in it: `increment` may run up to `max_val`, and the
  invariant says the count never exceeds two. Nothing about the implementation is wrong —
  the specification contradicts itself, and `mix tla.check` finds it before any code
  exists.

  This entry is what `ExTLA.Replay.counterexample/3` is measured on. A counterexample is
  only worth having if it can be run against the code, and a spec whose invariant no
  behaviour violates cannot produce one.
  """
  use ExTLA.Spec

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

  invariant :at_most_two do
    count <= 2
  end
end
