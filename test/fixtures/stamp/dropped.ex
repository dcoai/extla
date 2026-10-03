defmodule StampFixture.Dropped do
  @moduledoc """
  Its `spec:` is not a literal alias, so it cannot be resolved without compiling — which
  this task deliberately does not do, since a stale stamp means the project may not compile.

  It used to be **silently dropped**: `spec_of/1` returned `nil` and `mappings/1` rejected
  the entry, so the task could go on to report "no refinement mappings found" about a file
  it had read and could not understand — collapsing *cannot be checked* into *absent*, which
  is the one thing the four-status design exists to prevent (#173's defect 4).

  Since #310 it is `:unverifiable`, with a detail that says which of the two reasons it is.
  The name stays: it is what this fixture was written to document.
  """
  use GenServer

  @spec_module ExTLA.Conformance.Counter.Spec

  use ExTLA.GenServer,
    spec: @spec_module,
    refinement: ExTLA.Conformance.Counter.Refinement,
    spec_version: "44444444"

  def init(arg), do: {:ok, arg}
end
