defmodule TLA do
  @moduledoc """
  TLA+-inspired formal verification for Elixir/OTP systems.

  The specification lives under `spec/`; the build order is
  `spec/06-architecture.md` §Implementation Phases. Phase 1 is in progress.

  Written so far: the foundation (`TLA.State`, `TLA.Config`, `TLA.Fingerprint`,
  `TLA.Set`, `TLA.Function`) and the specification DSL (`TLA.Spec`, which
  compiles a spec module into a `TLA.Spec.Compiled`). The model checker that
  consumes it does not exist yet.
  """
end
