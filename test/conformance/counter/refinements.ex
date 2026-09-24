defmodule TLA.Conformance.Counter.Refinement do
  @moduledoc """
  Example 4's mapping, which conforms. The implementation's `%{value:, status:, max:}`
  becomes the spec's `%{count:, status:}` — `max` is a constant on the spec side and so
  is not a variable of the abstract state.
  """
  use TLA.Refinement

  def abstract(%{value: v, status: s}), do: %{count: v, status: s}

  def abstract_action(:increment), do: {:increment, %{}}
  def abstract_action(:done), do: {:done, %{}}
  def abstract_action(:reset), do: {:reset, %{}}
  def abstract_action(_), do: :unmapped

  def concrete_message(:increment, _params), do: :increment
  def concrete_message(:done, _params), do: :done
  def concrete_message(:reset, _params), do: :reset
end

defmodule TLA.Conformance.Counter.Mutants do
  @moduledoc """
  Refinement mappings that are wrong, each in one way, and the verdict each must produce.

  These are the corpus's oracle. Phases 1 and 2 measured theirs against TLC; there is no
  TLC for "does this mapping hold up", so these verdicts are *authored* — and the corpus
  is worth having anyway for the reason `raft_election`'s `eventually_elect_leader` was:
  an entry that must fail is what distinguishes a working check from one that says yes to
  everything.

  Every mutant here is a *mapping* fault, which is what `TLA.Refinement.validate!/3` can
  decide. The *step* faults — Example 4's own bug, where the implementation collapses two
  abstract steps into one callback — need the runtime engine of slice 3, and are recorded
  in `test/conformance/README.md` until there is something to check them with.
  """

  defmodule Undrivable do
    @moduledoc """
    A mapping that is correct and defines no `concrete_message/2`. Not a fault: the
    callback is optional, and such an implementation can be *checked* as it runs. It
    cannot be *driven*, and `TLA.Replay` has to say so by name rather than fail with an
    undefined function.
    """
    use TLA.Refinement

    def abstract(%{value: v, status: s}), do: %{count: v, status: s}

    def abstract_action(:increment), do: {:increment, %{}}
    def abstract_action(:done), do: {:done, %{}}
    def abstract_action(:reset), do: {:reset, %{}}
    def abstract_action(_), do: :unmapped
  end

  defmodule MissingVariable do
    @moduledoc "Maps `count` and forgets `status`. Caught by `abstract!/3`, at runtime."
    use TLA.Refinement

    def abstract(%{value: v}), do: %{count: v}
    def abstract_action(:increment), do: {:increment, %{}}
    def abstract_action(_), do: :unmapped
  end

  defmodule ExtraVariable do
    @moduledoc "Maps a key the spec never declared. Caught by `abstract!/3`, at runtime."
    use TLA.Refinement

    def abstract(%{value: v, status: s}), do: %{count: v, status: s, max: 5}
    def abstract_action(:increment), do: {:increment, %{}}
    def abstract_action(_), do: :unmapped
  end

  defmodule NotTotal do
    @moduledoc """
    No catch-all clause. Without one the first message nobody anticipated raises inside a
    callback wrapper — a crash in the user's process rather than "the spec does not model
    this message".
    """
    use TLA.Refinement

    def abstract(%{value: v, status: s}), do: %{count: v, status: s}

    def abstract_action(:increment), do: {:increment, %{}}
    def abstract_action(:done), do: {:done, %{}}
    def abstract_action(:reset), do: {:reset, %{}}
  end

  defmodule WrongWayRound do
    @moduledoc """
    `concrete_message/2` and `abstract_action/1` disagree: the message for `increment`
    maps back as `done`. A mapping whose two directions do not compose cannot drive the
    implementation from the spec, so `TLA.Replay` would run the wrong scenario and report
    on it as though it were the right one.
    """
    use TLA.Refinement

    def abstract(%{value: v, status: s}), do: %{count: v, status: s}

    def abstract_action(:increment), do: {:done, %{}}
    def abstract_action(:done), do: {:done, %{}}
    def abstract_action(:reset), do: {:reset, %{}}
    def abstract_action(_), do: :unmapped

    def concrete_message(:increment, _params), do: :increment
    def concrete_message(:done, _params), do: :done
    def concrete_message(:reset, _params), do: :reset
  end

  defmodule ActionNeverNamed do
    @moduledoc """
    `reset` has no message. The action is dead in this implementation: either the spec
    models something the code does not do, or a clause is missing — and either way a run
    that never exercises it is not evidence about it.
    """
    use TLA.Refinement

    def abstract(%{value: v, status: s}), do: %{count: v, status: s}

    def abstract_action(:increment), do: {:increment, %{}}
    def abstract_action(:done), do: {:done, %{}}
    def abstract_action(_), do: :unmapped

    def concrete_message(:increment, _params), do: :increment
    def concrete_message(:done, _params), do: :done
    def concrete_message(:reset, _params), do: :nothing_maps_to_this
  end

  defmodule NoAbstractAction do
    @moduledoc """
    A mapping with no `abstract_action/1` at all — the shape an earlier draft of §05 made
    optional, under which Layer 3 checks invariants on a projection and calls it
    conformance.

    It deliberately does not `use TLA.Refinement`. With the behaviour declared the
    compiler already warns, so the case worth catching is the module that was passed as
    `refinement:` without ever claiming to be one.
    """

    def abstract(%{value: v, status: s}), do: %{count: v, status: s}
  end
end

defmodule TLA.Conformance.Counter.CastRefinement do
  @moduledoc """
  The conforming mapping, naming how each message is delivered (#306, for #172).

  `spec/05-layer3-conformance.md`'s own canonical refinement maps `:complete_transfer` and
  `:reset` to `handle_cast/2` clauses, and until D-36 a mapping could not say so: the driver
  sent `{:"$gen_call", …}` for everything. Every entry in this corpus is `handle_call`-only,
  which is why the gap survived — a corpus that cannot express a case cannot find a bug in it.

  So this is the same mapping as `TLA.Conformance.Counter.Refinement`, with `:done` taken by
  cast and `:reset` by info. `:increment` stays a bare term, which is the assertion that a
  mapping written before D-36 still means what it meant.
  """
  use TLA.Refinement

  def abstract(%{value: v, status: s}), do: %{count: v, status: s}

  def abstract_action(:increment), do: {:increment, %{}}
  def abstract_action(:done), do: {:done, %{}}
  def abstract_action(:reset), do: {:reset, %{}}
  def abstract_action(_), do: :unmapped

  # A bare term: a call, as it has always been.
  def concrete_message(:increment, _params), do: :increment
  def concrete_message(:done, _params), do: {:cast, :done}
  def concrete_message(:reset, _params), do: {:info, :reset}
end
