defmodule TLA.Conformance.Counter.Impl do
  @moduledoc """
  Example 4's implementations: the GenServer that refines `Specs.Counter`, and the step
  mutants that do not.

  The mapping mutants in `refinements.ex` are faults in the *mapping*; these are faults in
  the *implementation*, and they are the ones `TLA.GenServer.Runtime.check_step!/5` exists
  for. `CollapsesTwoSteps` is the entry that justifies the layer: every invariant of the
  spec still holds in its post-state, so a Layer 3 that checked only invariants and action
  properties would report conformance on a server that took a step the design never
  sanctioned.
  """

  defmodule Conforming do
    @moduledoc "One callback per spec action, and each one exactly the spec's transition."
    use GenServer

    use TLA.GenServer,
      spec: TLA.Conformance.Counter.Spec,
      refinement: TLA.Conformance.Counter.Refinement

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
    loop `TLA.Replay.counterexample/3` closes: a design bug found before the code existed,
    run against the code.
    """
    use GenServer

    use TLA.GenServer,
      spec: TLA.Conformance.Counter.BuggySpec,
      refinement: TLA.Conformance.Counter.Refinement

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

    use TLA.GenServer,
      spec: TLA.Conformance.Counter.Spec,
      refinement: TLA.Conformance.Counter.Refinement

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

    use TLA.GenServer,
      spec: TLA.Conformance.Counter.Spec,
      refinement: TLA.Conformance.Counter.Mutants.Undrivable

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

    use TLA.GenServer,
      spec: TLA.Conformance.Counter.Spec,
      refinement: TLA.Conformance.Counter.Refinement

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts), do: {:ok, %{value: 0, status: :ready}}

    @impl true
    def handle_call(:increment, _from, state) do
      {:reply, :ok, %{state | value: state.value + 1, status: :ready}}
    end

    def handle_call(:done, _from, state), do: {:reply, :ok, %{state | status: :ready}}
  end

  defmodule MovesWhileUnmapped do
    @moduledoc """
    `:get` has no spec counterpart, and changes the abstract state anyway. Either the
    mapping is missing a clause or the implementation makes a transition the spec does not
    model; `:unmapped` is a claim that neither is the case.
    """
    use GenServer

    use TLA.GenServer,
      spec: TLA.Conformance.Counter.Spec,
      refinement: TLA.Conformance.Counter.Refinement

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

    use TLA.GenServer,
      spec: TLA.Conformance.Counter.Spec,
      refinement: TLA.Conformance.Counter.Refinement

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts), do: {:ok, %{value: 0, status: :incrementing}}

    @impl true
    def handle_call(:increment, _from, state) do
      {:reply, :ok, %{state | value: state.value + 1, status: :incrementing}}
    end
  end
end
