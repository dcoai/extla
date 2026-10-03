defmodule ExTLA.Conformance.Counter.Refinement do
  @moduledoc """
  Example 4's mapping, which conforms. The implementation's `%{value:, status:, max:}`
  becomes the spec's `%{count:, status:}` — `max` is a constant on the spec side and so
  is not a variable of the abstract state.
  """
  use ExTLA.Refinement

  def abstract(%{value: v, status: s}), do: %{count: v, status: s}

  def abstract_action(:increment), do: {:increment, %{}}
  def abstract_action(:done), do: {:done, %{}}
  def abstract_action(:reset), do: {:reset, %{}}
  def abstract_action(_), do: :unmapped

  def concrete_message(:increment, _params), do: :increment
  def concrete_message(:done, _params), do: :done
  def concrete_message(:reset, _params), do: :reset
end

defmodule ExTLA.Conformance.Counter.Mutants do
  @moduledoc """
  Refinement mappings that are wrong, each in one way, and the verdict each must produce.

  These are the corpus's oracle. Phases 1 and 2 measured theirs against TLC; there is no
  TLC for "does this mapping hold up", so these verdicts are *authored* — and the corpus
  is worth having anyway for the reason `raft_election`'s `eventually_elect_leader` was:
  an entry that must fail is what distinguishes a working check from one that says yes to
  everything.

  Every mutant here is a *mapping* fault, which is what `ExTLA.Refinement.validate!/3` can
  decide. The *step* faults — Example 4's own bug, where the implementation collapses two
  abstract steps into one callback — need the runtime engine of slice 3, and are recorded
  in `test/conformance/README.md` until there is something to check them with.
  """

  defmodule Undrivable do
    @moduledoc """
    A mapping that is correct and defines no `concrete_message/2`. Not a fault: the
    callback is optional, and such an implementation can be *checked* as it runs. It
    cannot be *driven*, and `ExTLA.Replay` has to say so by name rather than fail with an
    undefined function.
    """
    use ExTLA.Refinement

    def abstract(%{value: v, status: s}), do: %{count: v, status: s}

    def abstract_action(:increment), do: {:increment, %{}}
    def abstract_action(:done), do: {:done, %{}}
    def abstract_action(:reset), do: {:reset, %{}}
    def abstract_action(_), do: :unmapped
  end

  defmodule MissingVariable do
    @moduledoc "Maps `count` and forgets `status`. Caught by `abstract!/3`, at runtime."
    use ExTLA.Refinement

    def abstract(%{value: v}), do: %{count: v}
    def abstract_action(:increment), do: {:increment, %{}}
    def abstract_action(_), do: :unmapped
  end

  defmodule ExtraVariable do
    @moduledoc "Maps a key the spec never declared. Caught by `abstract!/3`, at runtime."
    use ExTLA.Refinement

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
    use ExTLA.Refinement

    def abstract(%{value: v, status: s}), do: %{count: v, status: s}

    def abstract_action(:increment), do: {:increment, %{}}
    def abstract_action(:done), do: {:done, %{}}
    def abstract_action(:reset), do: {:reset, %{}}
  end

  defmodule PartialHelper do
    @moduledoc """
    Total — it *has* the catch-all — but the helper that catch-all calls is not. Not a
    mutant of the mapping so much as a mutant of the diagnosis: the totality probe used to
    be scoped to the whole of the private `total!/1` in `ExTLA.Refinement`, so a
    `FunctionClauseError` from anywhere beneath it came back as "`abstract_action/1` is not
    total; add `def abstract_action(_), do: :unmapped`" — advice to add a clause this
    mapping already has, about a partial helper the message never named (#315).
    """
    use ExTLA.Refinement

    def abstract(%{value: v, status: s}), do: %{count: v, status: s}

    def abstract_action(:increment), do: {:increment, %{}}
    def abstract_action(:done), do: {:done, %{}}
    def abstract_action(:reset), do: {:reset, %{}}
    def abstract_action(other), do: classify(other)

    def concrete_message(:increment, _params), do: :increment
    def concrete_message(:done, _params), do: :done
    def concrete_message(:reset, _params), do: :reset

    # The fault: no clause for anything else, the probe included.
    defp classify(:ignored), do: :unmapped
  end

  defmodule WrongWayRound do
    @moduledoc """
    `concrete_message/2` and `abstract_action/1` disagree: the message for `increment`
    maps back as `done`. A mapping whose two directions do not compose cannot drive the
    implementation from the spec, so `ExTLA.Replay` would run the wrong scenario and report
    on it as though it were the right one.
    """
    use ExTLA.Refinement

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
    use ExTLA.Refinement

    def abstract(%{value: v, status: s}), do: %{count: v, status: s}

    def abstract_action(:increment), do: {:increment, %{}}
    def abstract_action(:done), do: {:done, %{}}
    def abstract_action(_), do: :unmapped

    def concrete_message(:increment, _params), do: :increment
    def concrete_message(:done, _params), do: :done
    def concrete_message(:reset, _params), do: :nothing_maps_to_this
  end

  defmodule NoClauseForAction do
    @moduledoc """
    `concrete_message/2` has no clause for `reset` **at all** — where `ActionNeverNamed`,
    one door over, has a clause that returns a message nothing maps back.

    The two were collapsed into one, and only the second was ever exercised: `validate!/3`
    answered "does this mapping name every action" by calling the callback for each one, so
    the missing-clause shape raised `FunctionClauseError` from inside the validator rather
    than the error naming the action (#299). That is the likelier of the two mistakes for
    someone writing a mapping by hand, and the corpus had no entry for it.
    """
    use ExTLA.Refinement

    def abstract(%{value: v, status: s}), do: %{count: v, status: s}

    def abstract_action(:increment), do: {:increment, %{}}
    def abstract_action(:done), do: {:done, %{}}
    def abstract_action(:reset), do: {:reset, %{}}
    def abstract_action(_), do: :unmapped

    # The fault: two of the spec's three actions.
    def concrete_message(:increment, _params), do: :increment
    def concrete_message(:done, _params), do: :done
  end

  defmodule NoAbstractAction do
    @moduledoc """
    A mapping with no `abstract_action/1` at all — the shape an earlier draft of §05 made
    optional, under which Layer 3 checks invariants on a projection and calls it
    conformance.

    It deliberately does not `use ExTLA.Refinement`. With the behaviour declared the
    compiler already warns, so the case worth catching is the module that was passed as
    `refinement:` without ever claiming to be one.
    """

    def abstract(%{value: v, status: s}), do: %{count: v, status: s}
  end
end

defmodule ExTLA.Conformance.Counter.CastRefinement do
  @moduledoc """
  The conforming mapping, naming how each message is delivered (#306, for #172).

  `spec/05-layer3-conformance.md`'s own canonical refinement maps `:complete_transfer` and
  `:reset` to `handle_cast/2` clauses, and until D-36 a mapping could not say so: the driver
  sent `{:"$gen_call", …}` for everything. Every entry in this corpus is `handle_call`-only,
  which is why the gap survived — a corpus that cannot express a case cannot find a bug in it.

  So this is the same mapping as `ExTLA.Conformance.Counter.Refinement`, with `:done` taken by
  cast and `:reset` by info. `:increment` stays a bare term, which is the assertion that a
  mapping written before D-36 still means what it meant.
  """
  use ExTLA.Refinement

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
