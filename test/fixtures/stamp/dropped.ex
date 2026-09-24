defmodule StampFixture.Dropped do
  @moduledoc """
  Its `spec:` is not a literal alias, so `spec_of/1` returns `nil` and `mappings/1` rejects
  the entry entirely — **the mapping is silently dropped**.

  This is not `:unverifiable`; it never reaches `state/2` to be given a status. It is the
  second half of #173's defect 4: the task can go on to report "no refinement mappings
  found" for a file it did see and could not read, collapsing *cannot be checked* into
  *absent*, which the four-status design exists to prevent.

  **#310 fixes it.** Until then `test/mix/tla_stamp_test.exs` asserts the drop, so the
  behaviour is recorded rather than merely happening — and that assertion is what will fail
  when #310 lands, which is where the reader is sent.
  """
  use GenServer

  @spec_module TLA.Conformance.Counter.Spec

  use TLA.GenServer,
    spec: @spec_module,
    refinement: TLA.Conformance.Counter.Refinement,
    spec_version: "44444444"

  def init(arg), do: {:ok, arg}
end
