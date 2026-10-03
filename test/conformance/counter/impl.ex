defmodule ExTLA.Conformance.Counter.Impl do
  @moduledoc """
  Example 4's implementations: the GenServer that refines `Specs.Counter`, and the step
  mutants that do not.

  The mapping mutants in `refinements.ex` are faults in the *mapping*; these are faults in
  the *implementation*, and they are the ones `ExTLA.GenServer.Runtime.check_step!/5` exists
  for. `CollapsesTwoSteps` is the entry that justifies the layer: every invariant of the
  spec still holds in its post-state, so a Layer 3 that checked only invariants and action
  properties would report conformance on a server that took a step the design never
  sanctioned.
  """

  defmodule Conforming do
    @moduledoc "One callback per spec action, and each one exactly the spec's transition."
    use GenServer

    # #67: the conforming mapping carries a `spec_version:` stamp, so the corpus exercises the
    # mechanism rather than merely offering it. Edit `Spec`'s actions or invariants and this
    # module stops compiling until someone re-reads the mapping — which is the whole point.
    #
    # Its siblings below are deliberately left unstamped: the stamp is opt-in, and a corpus in
    # which every mapping is stamped could not show that an unstamped one still compiles.
    use ExTLA.GenServer,
      spec: ExTLA.Conformance.Counter.Spec,
      refinement: ExTLA.Conformance.Counter.Refinement,
      spec_version: "0ad20b7a"

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts), do: {:ok, %{value: 0, status: :ready}}

    @impl true
    def handle_call(:increment, _from, state) do
      {:reply, :ok, %{state | value: state.value + 1, status: :incrementing}}
    end

    def handle_call(:done, _from, state), do: {:reply, :ok, %{state | status: :ready}}
    def handle_call(:reset, _from, state), do: {:reply, :ok, %{state | value: 0}}

    # No spec counterpart, and it moves nothing — which is what `:unmapped` claims.
    def handle_call(:get, _from, state), do: {:reply, state.value, state}
  end

  defmodule FaithfulToABuggySpec do
    @moduledoc """
    Refines `BuggySpec` exactly — and `BuggySpec` contradicts itself, so the trace the
    model checker produces from it is a behaviour this server really performs. That is the
    loop `ExTLA.Replay.counterexample/3` closes: a design bug found before the code existed,
    run against the code.
    """
    use GenServer

    use ExTLA.GenServer,
      spec: ExTLA.Conformance.Counter.BuggySpec,
      refinement: ExTLA.Conformance.Counter.Refinement

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts), do: {:ok, %{value: 0, status: :ready}}

    @impl true
    def handle_call(:increment, _from, state) do
      {:reply, :ok, %{state | value: state.value + 1, status: :incrementing}}
    end

    def handle_call(:done, _from, state), do: {:reply, :ok, %{state | status: :ready}}
  end

  defmodule RefusesDone do
    @moduledoc """
    Conforms as far as it goes, and has no clause for `:done`. A counterexample that calls
    for one cannot be followed — which is a finding about the pair rather than a
    conformance violation, and is reported as `:not_followed`.
    """
    use GenServer

    use ExTLA.GenServer,
      spec: ExTLA.Conformance.Counter.Spec,
      refinement: ExTLA.Conformance.Counter.Refinement

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts), do: {:ok, %{value: 0, status: :ready}}

    @impl true
    def handle_call(:increment, _from, state) do
      {:reply, :ok, %{state | value: state.value + 1, status: :incrementing}}
    end
  end

  defmodule Undrivable do
    @moduledoc "Correct, and its mapping defines no `concrete_message/2`."
    use GenServer

    use ExTLA.GenServer,
      spec: ExTLA.Conformance.Counter.Spec,
      refinement: ExTLA.Conformance.Counter.Mutants.Undrivable

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts), do: {:ok, %{value: 0, status: :ready}}

    @impl true
    def handle_call(:increment, _from, state) do
      {:reply, :ok, %{state | value: state.value + 1, status: :incrementing}}
    end
  end

  defmodule CollapsesTwoSteps do
    @moduledoc """
    Example 4's bug. `increment` also does `done`'s work, so two abstract steps happen in
    one callback and the abstract behaviour skips a state the spec requires it to pass
    through.

    `in_bounds` holds in the post-state. So does every other invariant. Only the step
    check refuses it, and it must name `status`.
    """
    use GenServer

    use ExTLA.GenServer,
      spec: ExTLA.Conformance.Counter.Spec,
      refinement: ExTLA.Conformance.Counter.Refinement

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts), do: {:ok, %{value: 0, status: :ready}}

    @impl true
    def handle_call(:increment, _from, state) do
      {:reply, :ok, %{state | value: state.value + 1, status: :ready}}
    end

    def handle_call(:done, _from, state), do: {:reply, :ok, %{state | status: :ready}}
    def handle_call(:reset, _from, state), do: {:reply, :ok, %{state | value: 0}}
  end

  defmodule MovesWhileUnmapped do
    @moduledoc """
    `:get` has no spec counterpart, and changes the abstract state anyway. Either the
    mapping is missing a clause or the implementation makes a transition the spec does not
    model; `:unmapped` is a claim that neither is the case.
    """
    use GenServer

    use ExTLA.GenServer,
      spec: ExTLA.Conformance.Counter.Spec,
      refinement: ExTLA.Conformance.Counter.Refinement

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts), do: {:ok, %{value: 0, status: :ready}}

    @impl true
    def handle_call(:get, _from, state) do
      {:reply, state.value, %{state | value: state.value + 1}}
    end
  end

  defmodule IgnoresTheGuard do
    @moduledoc """
    Increments from `status: :incrementing`, which the spec's `increment` guard forbids.
    The post-state is one the spec could have reached by another route, which is exactly
    why the *step* is what has to be checked.
    """
    use GenServer

    use ExTLA.GenServer,
      spec: ExTLA.Conformance.Counter.Spec,
      refinement: ExTLA.Conformance.Counter.Refinement

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts), do: {:ok, %{value: 0, status: :incrementing}}

    @impl true
    def handle_call(:increment, _from, state) do
      {:reply, :ok, %{state | value: state.value + 1, status: :incrementing}}
    end
  end

  defmodule HandlesACast do
    @moduledoc """
    Correct, and it takes two of the spec's three actions by routes that are not a call:
    `done` in `handle_cast/2` and `reset` in `handle_info/2` (#306, for #172).

    It is the first entry in this corpus that is not `handle_call`-only, and that is its
    reason for existing. `spec/05`'s canonical refinement has mapped actions to
    `handle_cast/2` clauses since it was written, and Layer 3 could check such a server and
    not drive one — a gap no corpus entry could reach, because every entry avoided it.

    `increment` stays a call, from a bare term, so this entry also carries the claim that
    D-36 changed nothing for a mapping written before it.
    """
    use GenServer

    use ExTLA.GenServer,
      spec: ExTLA.Conformance.Counter.Spec,
      refinement: ExTLA.Conformance.Counter.CastRefinement

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts), do: {:ok, %{value: 0, status: :ready}}

    @impl true
    def handle_call(:increment, _from, state) do
      {:reply, :ok, %{state | value: state.value + 1, status: :incrementing}}
    end

    @impl true
    def handle_cast(:done, state), do: {:noreply, %{state | status: :ready}}

    @impl true
    def handle_info(:reset, state), do: {:noreply, %{state | value: 0}}
  end
end
