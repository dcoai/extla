defmodule StampFixture.Stale do
  @moduledoc """
  Two mappings in one file sharing one stale stamp — the `--restamp` case (#310).

  They share a spec and therefore a resolution, so `String.replace/3` fixes both on the
  first rewrite and the second finds nothing to replace. `rewrite!/1` then raises, telling
  the user to hand-edit something already done, and aborts before any other file.

  `00000000` is not a hash of anything, which is the point: it can never accidentally be
  current.
  """

  defmodule First do
    use GenServer

    use ExTLA.GenServer,
      spec: ExTLA.Conformance.Counter.Spec,
      refinement: ExTLA.Conformance.Counter.Refinement,
      spec_version: "00000000"

    def init(arg), do: {:ok, arg}
  end

  defmodule Second do
    use GenServer

    use ExTLA.GenServer,
      spec: ExTLA.Conformance.Counter.Spec,
      refinement: ExTLA.Conformance.Counter.Refinement,
      spec_version: "00000000"

    def init(arg), do: {:ok, arg}
  end
end
