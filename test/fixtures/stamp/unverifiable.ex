defmodule StampFixture.Unverifiable do
  @moduledoc """
  Its `spec:` is a literal alias, and the spec's **source is not in the index** — nothing
  under the scanned roots declares `StampFixture.NoSuchSpec` — so its hash cannot be
  computed.

  That is what `:unverifiable` means in `spec/05-layer3-conformance.md`'s table: "the spec's
  hash could not be computed". It had never executed, because the real corpus's specs are
  all where the corpus is.

  Folding it into `:unstamped` would report a stamp that cannot be checked as an absence;
  folding it into `:fresh` would report it as **verified**, which the task's own comment
  says in as many words.
  """
  use GenServer

  use TLA.GenServer,
    spec: StampFixture.NoSuchSpec,
    refinement: TLA.Conformance.Counter.Refinement,
    spec_version: "33333333"

  def init(arg), do: {:ok, arg}
end
