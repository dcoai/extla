defmodule StampFixture.Unstamped do
  @moduledoc "No `spec_version:` at all. The stamp is opt-in, and this is what opting out looks like."
  use GenServer

  use TLA.GenServer,
    spec: TLA.Conformance.Counter.Spec,
    refinement: TLA.Conformance.Counter.Refinement

  def init(arg), do: {:ok, arg}
end
