defmodule StampFixture.Unstamped do
  @moduledoc "No `spec_version:` at all. The stamp is opt-in, and this is what opting out looks like."
  use GenServer

  use ExTLA.GenServer,
    spec: ExTLA.Conformance.Counter.Spec,
    refinement: ExTLA.Conformance.Counter.Refinement

  def init(arg), do: {:ok, arg}
end
