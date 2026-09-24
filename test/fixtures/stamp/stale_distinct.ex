defmodule StampFixture.StaleDistinct do
  @moduledoc """
  Two stale mappings in one file carrying DIFFERENT stamps.

  The case `--restamp` already handles, kept beside the shared-stamp one so a fix for that
  cannot be a fix that only ever rewrites once per file.
  """

  defmodule First do
    use GenServer

    use TLA.GenServer,
      spec: TLA.Conformance.Counter.Spec,
      refinement: TLA.Conformance.Counter.Refinement,
      spec_version: "11111111"

    def init(arg), do: {:ok, arg}
  end

  defmodule Second do
    use GenServer

    use TLA.GenServer,
      spec: TLA.Conformance.Counter.Spec,
      refinement: TLA.Conformance.Counter.Refinement,
      spec_version: "22222222"

    def init(arg), do: {:ok, arg}
  end
end
