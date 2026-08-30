# Layer 3: Specification-to-Implementation Conformance Bridge

Connects TLA.Spec specifications to actual GenServer implementations, enabling automated verification that code conforms to its formal model.

---

## Overview

Layer 3 answers the question: **"Does my GenServer implementation actually behave like
its TLA+ specification says it should?"**

It provides:

1. **`TLA.GenServer`** — a macro that links a GenServer to a `TLA.Spec` and checks every
   transition the implementation makes against the spec
2. **`TLA.Refinement`** — the refinement mapping: the formal bridge between abstract spec
   states and concrete implementation states
3. **`TLA.Simulation`** — random-walk simulation that runs the real GenServer through
   randomized scenarios and checks conformance
4. **`TLA.Replay`** — drives the real GenServer through a spec-level behavior: a
   model-checker counterexample, or a captured production trace
5. **`TLA.PropertyTest`** — generation of property-based tests from specifications
6. **`TLA.Supervisor.Spec`** — specification of supervision trees and fault tolerance

---

## What conformance means here

An earlier draft of this layer checked, after each callback, that the abstract
post-state satisfied the spec's **invariants** and that the abstract step satisfied its
**action properties**. It computed which spec action the message corresponded to — and
then never used it.

That is not refinement checking. Under it, an implementation may take a transition **no
spec action permits**, and as long as the resulting state happens to satisfy the
invariants, ExTLA reports conformance. Every interesting implementation bug — the
transition the design never sanctioned — passes.

Refinement is the temporal formula `Spec => [][Next]_vars` interpreted through the
mapping: every step the implementation takes, viewed abstractly, must be **a legal step
of the specification** or a **stuttering step**. Layer 3 checks exactly that:

| Check | Question |
|---|---|
| **Step legality** (new) | Is `post_abstract` what the named spec action produces from `pre_abstract`? |
| **Stuttering** (new) | If the message maps to no action, did the abstract state stay put? |
| Invariants | Does `post_abstract` satisfy the spec's invariants? |
| Action properties | Does the abstract step satisfy the spec's action properties? |
| Temporal | Does the accumulated abstract behavior satisfy the temporal properties? |

Step legality is what makes the other rows worth having, and it is affordable: because
an action body is a pure deterministic function of `(pre_state, params)`
(`02-dsl-semantics.md` §3), checking it is *one* function application and one
comparison per callback — cheaper than evaluating the invariants beside it.

---

## Module: `TLA.GenServer`

### Usage

```elixir
defmodule MyApp.TransferServer do
  use GenServer
  use TLA.GenServer,
    spec: Specs.TransferProtocol,
    refinement: __MODULE__.Refinement

  # ── Refinement Mapping ─────────────────────────────────────────
  # Maps concrete GenServer state to abstract spec state.
  # This is the key bridge: it defines what the spec variables
  # "mean" in terms of the actual implementation state.

  defmodule Refinement do
    use TLA.Refinement

    @doc """
    Map concrete state → abstract state.
    Called after every state transition to verify conformance.
    """
    def abstract(%{
      accounts: accounts,
      transfer_queue: queue,
      phase: phase,
      audit_log: log
    }) do
      %{
        balances: Map.new(accounts, fn {id, acct} -> {id, acct.balance} end),
        status: map_phase(phase),
        pending: MapSet.new(Enum.map(queue, fn t -> {t.to, t.amount} end)),
        # Exactly the spec's shape — same keys, same order. The implementation
        # prepends to `audit_log` while the spec appends, and an earlier draft
        # added a `time:` key the spec does not have; either is a `:diverged` on
        # the first completed transfer.
        log: log |> Enum.reverse() |> Enum.map(&%{to: &1.recipient, amount: &1.amount})
      }
    end

    defp map_phase(:ready), do: :idle
    defp map_phase(:in_progress), do: :transferring
    defp map_phase(:complete), do: :done
    defp map_phase(:failed), do: :error

    @doc """
    Map concrete message → abstract action name + params.
    Used to identify which spec action corresponds to a GenServer call/cast.
    """
    def abstract_action({:transfer, from, to, amount}),
      do: {:begin_transfer, %{from: from, to: to, amount: amount}}
    # PARTIAL params. `complete_transfer` draws `t` from the pre-state's
    # `pending`, and the implementation resolves that choice itself (it pops
    # its own queue), so `t` is not recoverable from the message.
    # `check_step!/5` searches the unbound params for a binding that reproduces
    # the post-state (§`TLA.GenServer.Runtime`).
    def abstract_action(:process_next),
      do: {:complete_transfer, %{}}
    def abstract_action(:fail),
      do: {:fail_transfer, %{}}
    def abstract_action(:reset),
      do: {:reset, %{}}

    # Total by construction. A message with no spec counterpart is a positive
    # claim that it must not move the abstract state, and is checked as one.
    def abstract_action(_),
      do: :unmapped

    @doc """
    Map abstract action + params → the concrete message that causes it.
    The inverse of `abstract_action/1`. This is what lets a model-checker
    counterexample be replayed against the running server (`TLA.Replay`).
    """
    def concrete_message(:begin_transfer, %{from: f, to: t, amount: a}),
      do: {:transfer, f, t, a}
    def concrete_message(:complete_transfer, _), do: :process_next
    def concrete_message(:fail_transfer, _),     do: :fail
    def concrete_message(:reset, _),             do: :reset
  end

  # ── Implementation ─────────────────────────────────────────────

  def init(args) do
    {:ok, %{
      accounts: Map.new(args.accounts, fn id ->
        {id, %{balance: args.initial_balance, holder: id}}
      end),
      transfer_queue: :queue.new(),
      phase: :ready,
      audit_log: []
    }}
  end

  def handle_call({:transfer, from, to, amount}, _from, state) do
    new_state = %{state |
      accounts: Map.update!(state.accounts, from,
        fn acct -> %{acct | balance: acct.balance - amount} end),
      transfer_queue: :queue.in(%{to: to, amount: amount}, state.transfer_queue),
      phase: :in_progress
    }
    {:reply, :ok, new_state}
  end

  def handle_cast(:process_next, state) do
    case :queue.out(state.transfer_queue) do
      {{:value, %{to: to, amount: amount}}, rest} ->
        new_state = %{state |
          accounts: Map.update!(state.accounts, to,
            fn acct -> %{acct | balance: acct.balance + amount} end),
          transfer_queue: rest,
          phase: if(:queue.is_empty(rest), do: :complete, else: :in_progress),
          audit_log: [%{recipient: to, amount: amount, at: DateTime.utc_now()} | state.audit_log]
        }
        {:noreply, new_state}

      {:empty, _} ->
        {:noreply, state}
    end
  end

  def handle_cast(:reset, state) do
    {:noreply, %{state | phase: :ready}}
  end
end
```

### Macro Specification

```elixir
defmodule TLA.GenServer do
  @moduledoc """
  Bridges a GenServer implementation to a TLA.Spec specification.

  When `use TLA.GenServer` is applied, each callback is wrapped (via
  `defoverridable`/`super`, like Layer 1) so that every transition:

  1. maps the pre- and post-state through the refinement mapping;
  2. is checked for STEP LEGALITY against the named spec action — the guard
     must have held, and the spec's transition must reproduce the post-state
     exactly (or, for an `:unmapped` message, the abstract state must not have
     moved);
  3. is checked against the spec's invariants and action properties; and
  4. is appended to a bounded per-process behavior trace, for temporal checking
     at the end of a simulation run.

  Step 2 is the refinement check. Without it the layer verifies only that a
  projection of the state satisfies some predicates, which is a much weaker
  claim than conformance — see §What conformance means here.

  `validate!/2` runs on the refinement module at compile time, so a mapping that
  does not cover the spec's variables or actions fails the build rather than
  producing misleading passes at runtime.
  """

  defmacro __using__(opts) do
    spec_module = Keyword.fetch!(opts, :spec)
    refinement_module = Keyword.fetch!(opts, :refinement)

    quote do
      use TLA.Invariant  # Layer 1 is built-in

      @tla_spec unquote(spec_module)
      @tla_refinement unquote(refinement_module)

      Module.register_attribute(__MODULE__, :tla_action_mappings, accumulate: true)

      @before_compile TLA.GenServer
    end
  end
end
```

### Compile-Time Transformation

Like Layer 1, the wrapper is emitted with `defoverridable` and `super/1` rather than by
renaming the original callback (`03-layer1-invariants.md` §Compile-Time Transformation),
and nothing at all is emitted when `TLA.Config.mode/0` resolves to `:disabled`.

```elixir
defoverridable handle_call: 3

def handle_call(msg, from, state) do
  pre_abstract = @tla_refinement.abstract(state)

  result = super(msg, from, state)
  post_concrete = TLA.Invariant.Runtime.extract_state(result, state)
  post_abstract = @tla_refinement.abstract(post_concrete)

  # THE REFINEMENT CHECK. `abstract_action/1` names the spec action this message
  # is supposed to be; the spec is then applied and its result compared. This is
  # what makes the layer a conformance check rather than an invariant check on a
  # projection.
  case @tla_refinement.abstract_action(msg) do
    {action, params} ->
      TLA.GenServer.Runtime.check_step!(
        @tla_spec, action, params, pre_abstract, post_abstract
      )

    :unmapped ->
      # A message with no spec counterpart must not move the abstract state.
      TLA.GenServer.Runtime.check_stuttering!(@tla_spec, pre_abstract, post_abstract)
  end

  TLA.GenServer.Runtime.check_spec_invariants!(@tla_spec, post_abstract)
  TLA.GenServer.Runtime.check_action_properties!(@tla_spec, pre_abstract, post_abstract)
  TLA.GenServer.Runtime.record_transition!(@tla_spec, msg, pre_abstract, post_abstract)

  result
end
```

`check_step!/5` fails in three distinguishable ways, and the error says which:

| Failure | Meaning |
|---|---|
| `:not_enabled` | The action's guard was false on `pre_abstract` — the implementation did something the spec forbids in that state |
| `:diverged` | The guard held under some binding of the params, but no binding reproduces the implementation's post-state. The error diffs the closest one variable by variable |
| `:unmapped_but_moved` | No action was claimed, yet the abstract state changed — either a missing `abstract_action/1` clause or an unmodeled transition |

`:diverged` is the common one in practice, and it is usually the **refinement mapping**
being wrong rather than the implementation. That is still a finding worth having: a
mapping that does not track the implementation invalidates every other check in this
layer.

---

## Module: `TLA.Refinement`

```elixir
defmodule TLA.Refinement do
  @moduledoc """
  Defines the formal relationship between an abstract specification and a
  concrete implementation.

  A refinement mapping is a function from concrete states to abstract states
  such that the abstract behaviors obtained by mapping each concrete state
  satisfy the abstract spec. It is the mathematical content of implementation
  verification — but only when the STEPS are checked against the spec's actions,
  not merely the states against its invariants (see §What conformance means
  here).
  """

  @doc "Concrete state -> abstract state. Must be pure."
  @callback abstract(concrete_state :: map()) :: TLA.State.t()

  @doc """
  Concrete message -> the spec action it is meant to be, or `:unmapped`.

  Required, not optional: without it there is no named action to check the step
  against, and the layer degrades to invariant checking on a projection.
  `:unmapped` is a positive claim that the message must NOT move the abstract
  state, and it is checked as such.
  """
  @callback abstract_action(message :: term()) :: {atom(), map()} | :unmapped

  @doc """
  Abstract action + params -> a concrete message that should cause it.

  The inverse of `abstract_action/1`, and what lets a spec-level behavior drive
  the real implementation: `TLA.Replay` uses it to run a model-checker
  counterexample against the running GenServer, and `TLA.PropertyTest` uses it
  to turn generated action sequences into messages.

  Optional. Without it the implementation can still be CHECKED as it runs, but
  it cannot be DRIVEN from the spec, which forgoes most of what Layer 3 is for.
  """
  @callback concrete_message(action :: atom(), params :: map()) :: term()

  @optional_callbacks [concrete_message: 2]

  defmacro __using__(_opts) do
    quote do
      @behaviour TLA.Refinement
    end
  end

  @doc """
  Verify that a refinement mapping is well-formed. Checks, in order:

  1. `abstract/1` returns a map whose keys are exactly the spec's variables.
     Any missing or extra key is an error naming it.
  2. Every value it returns is a permitted state term
     (`02-dsl-semantics.md` §6).
  3. `abstract_action/1` is total — it has a catch-all clause, so an
     unanticipated message produces `:unmapped` rather than a FunctionClauseError
     inside a callback wrapper.
  4. Where `concrete_message/2` is defined, it round-trips modulo partial params:
     for every action and every params combination reachable in the spec,
     `abstract_action(concrete_message(a, p))` is `{a, p'}` with `p'` agreeing
     with `p` on every key `p'` has. A mapping that names a param must name it
     correctly; one that omits it is deferring to the search in `check_step!/5`.
  5. Every spec action is named by at least one `abstract_action/1` clause.
     An action the mapping can never produce is dead in this implementation, and
     is reported the way `TLA.Coverage` reports a never-enabled action.

  It does NOT attempt to verify that `abstract/1` is pure. An earlier draft
  claimed it did; that is not decidable, and a validator that claims a guarantee
  it cannot deliver is worse than one that states its limits. Purity is a
  documented obligation on the author, and a violation of it surfaces as a
  `:diverged` step failure.
  """
  @spec validate!(module(), module()) :: :ok | no_return()
  def validate!(refinement_module, spec_module)
end
```

---

## Module: `TLA.Replay`

Drives the real GenServer through a **spec-level** behavior. Where `TLA.Simulation`
generates random messages and checks what happens, `TLA.Replay` starts from a sequence
of abstract actions and makes the implementation follow it.

Two sources of such a sequence, and both matter:

```elixir
defmodule TLA.Replay do
  @moduledoc """
  Run a spec-level behavior against a real implementation, via
  `TLA.Refinement.concrete_message/2`.
  """

  @doc """
  Replay a model-checker counterexample against the implementation.

  This closes the loop that makes the three layers one tool rather than three:
  Layer 2 finds a design bug and produces a trace; this runs that exact trace
  against the code and shows whether the implementation reproduces it. A
  counterexample the implementation cannot follow is itself informative — it
  means the spec permits a behavior the code does not, so one of the two is
  wrong.
  """
  @spec counterexample(module(), TLA.Trace.t(), keyword()) :: result()
  def counterexample(genserver_module, trace, opts \\ [])

  @doc """
  Check a CAPTURED trace — from staging, from production, from a recorded test
  run — against the spec.

  Trace validation is the highest-value use of a specification that most teams
  never reach, because in a conventional TLA+ setup the spec lives outside the
  system and there is no path from a log line to a spec action. ExTLA runs
  inside the BEAM, so the path is short: the trace is a list of
  `{message, concrete_state}` pairs, `abstract/1` projects each state, and every
  consecutive pair is checked with the same `check_step!/5` the runtime wrapper
  uses.

  Nothing needs to be running: this is a pure function over recorded data, so it
  can be run in CI against a fixture, or offline against a captured incident.
  """
  @spec trace(module(), [{message :: term(), concrete_state :: map()}], keyword()) :: result()
  def trace(genserver_module, captured, opts \\ [])

  @type result :: %{
    status: :ok | :violation,
    steps_checked: non_neg_integer(),
    violation: %{
      step: non_neg_integer(),
      kind: :not_enabled | :diverged | :unmapped_but_moved
            | :invariant | :action_property,
      detail: String.t()
    } | nil
  }
end
```

---

## Module: `TLA.Simulation`

Random-walk simulation of GenServer processes to check conformance over realistic execution traces.

```elixir
defmodule TLA.Simulation do
  @moduledoc """
  Runs the actual GenServer through randomized scenarios, recording
  the abstract behavior trace, and checking it against the spec's
  temporal properties.

  Unlike the model checker (Layer 2) which explores ALL states
  exhaustively, simulation runs the REAL implementation through
  RANDOM traces. This catches:
  - Refinement mapping errors
  - Implementation bugs not in the abstract model
  - Timing-dependent issues (with process scheduling variation)
  """

  @type config :: %{
    # How many random traces to generate
    traces: pos_integer(),

    # Maximum steps per trace
    max_steps: pos_integer(),

    # Constant assignments for the spec
    constants: map(),

    # How to generate random messages
    message_generator: (TLA.State.t() -> term()),

    # Whether to inject failures (kill/restart processes)
    inject_failures: boolean(),

    # Random seed for reproducibility
    seed: integer() | nil,

    # Number of concurrent simulations
    concurrency: pos_integer()
  }

  @type result :: %{
    status: :ok | :violation,
    traces_run: non_neg_integer(),
    total_steps: non_neg_integer(),
    violation: TLA.Trace.t() | nil,
    duration_ms: non_neg_integer(),
    coverage: coverage_report()
  }

  @type coverage_report :: %{
    actions_hit: %{atom() => non_neg_integer()},
    states_visited: non_neg_integer(),
    invariants_checked: non_neg_integer(),
    branches_covered: float()
  }

  @doc """
  Run simulation against a TLA.GenServer module.

  ## Example

      TLA.Simulation.run(MyApp.TransferServer, %{
        traces: 1000,
        max_steps: 50,
        constants: %{accounts: [:alice, :bob], max_balance: 100},
        message_generator: &TransferServer.Generators.random_message/1,
        inject_failures: true,
        seed: 42
      })
  """
  @spec run(module(), config()) :: result()
  def run(genserver_module, config)

  @doc """
  Run a single trace and return the full abstract behavior.
  Useful for debugging specific scenarios.
  """
  @spec run_trace(module(), config()) :: {result(), TLA.State.behavior()}
  def run_trace(genserver_module, config)

  @doc """
  Replay a specific trace (from a seed or explicit message sequence).
  Useful for reproducing and debugging failures.
  """
  @spec replay(module(), [term()], config()) :: result()
  def replay(genserver_module, messages, config)
end
```

### Message Generation

```elixir
defmodule TLA.Simulation.Generator do
  @moduledoc """
  Automatically generates random messages from a TLA.Spec's action definitions.
  The spec's action params define the domain of possible messages.
  """

  @doc """
  Create a message generator from a spec module.
  Returns a function that, given the current abstract state,
  produces a random valid message.
  """
  @spec from_spec(module(), map()) :: (TLA.State.t() -> term())
  def from_spec(spec_module, constants)

  @doc """
  Create a message generator that only produces messages
  corresponding to currently ENABLED actions.
  More efficient — avoids generating messages that will be rejected.
  """
  @spec enabled_only(module(), map()) :: (TLA.State.t() -> term())
  def enabled_only(spec_module, constants)
end
```

---

## Module: `TLA.PropertyTest`

Automatic generation of property-based tests from specifications.

```elixir
defmodule TLA.PropertyTest do
  @moduledoc """
  Generates StreamData-based property tests from TLA.Spec definitions.
  Bridges the gap between formal specs and Elixir's property testing ecosystem.
  """

  @doc """
  Generate a StreamData generator for valid initial states.
  Derived from the spec's `init` block.
  """
  @spec init_states(module(), map()) :: StreamData.t(map())
  def init_states(spec_module, constants)

  @doc """
  Generate a StreamData generator for valid action sequences.
  Each generated sequence is a list of {action_name, params} tuples
  that form a valid behavior from an initial state.
  """
  @spec action_sequences(module(), map(), max_length :: pos_integer()) ::
    StreamData.t([{atom(), map()}])
  def action_sequences(spec_module, constants, max_length \\ 20)

  @doc """
  Generate a complete property test module for a spec.
  Writes an ExUnit test file that:
  1. Generates random valid action sequences
  2. Applies them to the GenServer
  3. Checks refinement at every step
  """
  @spec generate_test_module(module(), module(), map()) :: String.t()
  def generate_test_module(spec_module, genserver_module, constants)
end

# Usage in tests:
defmodule MyApp.TransferServerPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  property "transfer server conforms to spec under random action sequences" do
    constants = %{accounts: [:alice, :bob], max_balance: 10}

    check all actions <- TLA.PropertyTest.action_sequences(
                           Specs.TransferProtocol, constants, 30
                         ),
              max_runs: 500 do

      {:ok, pid} = GenServer.start_link(MyApp.TransferServer, %{
        accounts: [:alice, :bob],
        initial_balance: 10
      })

      for {action_name, params} <- actions do
        msg = MyApp.TransferServer.Refinement.concrete_message(action_name, params)
        GenServer.call(pid, msg)

        abstract_state = MyApp.TransferServer.Refinement.abstract(:sys.get_state(pid))
        assert TLA.ModelChecker.Safety.check_invariants(
          TLA.Spec.Compiled.from_module(Specs.TransferProtocol),
          abstract_state
        ) == :ok
      end

      GenServer.stop(pid)
    end
  end
end
```

---

## Module: `TLA.Supervisor.Spec`

> **Status: deferred past v1** (`06-architecture.md` §Implementation Phases).
>
> Modeling OTP restart semantics faithfully — restart intensity windows, the
> distinction between what a `:permanent` and a `:transient` child preserve,
> `one_for_all` cascades, state that survives in ETS or a database versus state
> that does not — is a research-scale problem in its own right, and none of it is
> needed for the layers below to be useful. It is specified here so the design is
> not painted into a corner, and it is not built until the checker and the
> refinement bridge are real.
>
> The sketch below is therefore **indicative, not normative**. Where it conflicts
> with `02-dsl-semantics.md`, the semantics file wins.

Formal specification of supervision trees and crash/recovery behavior.

```elixir
defmodule TLA.Supervisor.Spec do
  @moduledoc """
  Extends TLA.Spec to model OTP supervision trees.

  Supervision trees introduce crash/recovery semantics that are
  critical for distributed system correctness. This module lets you
  specify and verify:
  - Which processes can crash
  - What state is preserved across restarts
  - How the supervision strategy affects system invariants
  - That the system recovers to a valid state after crashes
  """

  @doc """
  Declare a supervised process in the spec.
  """
  defmacro supervised(name, opts \\ [])

  @doc """
  Declare supervision strategy and its properties.
  """
  defmacro supervision_strategy(strategy, opts \\ [])

  @doc """
  Declare crash/recovery action.
  Automatically generated for each supervised process.
  """
  defmacro crash_action(process_name, opts \\ [])
end
```

### Example: Supervised Transfer System

```elixir
defmodule Specs.SupervisedTransfer do
  use TLA.Spec
  use TLA.Supervisor.Spec

  # ── Supervision Structure ──────────────────────────────────────

  supervision_strategy :one_for_one,
    max_restarts: 3,
    max_seconds: 5

  supervised :coordinator,
    restart: :permanent,
    initial_state: fn -> %{phase: :ready, pending: set()} end

  supervised :worker,
    count: :num_workers,    # one per constant value
    restart: :transient,
    initial_state: fn -> %{task: nil, status: :idle} end

  # ── Variables (includes process-level state) ───────────────────

  variable :coordinator_state, type: :supervised_state
  variable :worker_states, type: [:workers ~> :supervised_state]
  variable :alive, type: :set     # set of currently alive processes

  # ── Crash Actions (auto-generated, but can be customized) ──────

  # This is automatically available for each supervised process:
  # action :crash_coordinator — kills coordinator, supervisor restarts it
  # action :crash_worker(w)   — kills worker w

  # Custom crash behavior:
  crash_action :coordinator,
    preserves: [:accounts],      # these persist across restart (e.g., ETS/DB)
    resets: [:pending, :phase]   # these reset to initial values

  # ── Safety Properties ──────────────────────────────────────────

  invariant :crash_recovery_preserves_balances do
    # Even after crashes, no money is lost
    # (relies on :accounts being in persistent storage)
    sum(values(accounts)) == initial_total()
  end

  invariant :bounded_restarts do
    # Supervisor hasn't exceeded restart intensity
    restart_count(:coordinator) <= 3
  end

  # ── Liveness Properties ────────────────────────────────────────

  temporal :recovery, desc: "after any crash, the system eventually returns to ready" do
    always(
      (not alive?(:coordinator)) ~> (alive?(:coordinator) and coordinator_state.phase == :ready)
    )
  end

  temporal :crash_doesnt_block_progress, desc: "even if workers crash, transfers complete" do
    always(
      (coordinator_state.phase == :in_progress) ~> (coordinator_state.phase in [:complete, :ready])
    )
  end
end
```

---

## Module: `TLA.GenServer.Runtime`

Runtime engine for Layer 3 (not used directly by developers).

```elixir
defmodule TLA.GenServer.Runtime do
  @moduledoc """
  Runtime conformance checking between implementation and spec.
  """

  @doc """
  THE refinement check. Applies the named spec action to `pre_abstract` and
  compares the result with what the implementation produced.

  `params` may be PARTIAL. An implementation frequently resolves the spec's
  nondeterminism itself — it pops its own queue, picks its own message — so the
  binding is not in the message and `abstract_action/1` cannot supply it. For
  each param the mapping leaves unbound, the generator is evaluated on
  `pre_abstract` (02-dsl-semantics.md §3) and the step is legal if ANY resulting
  binding reproduces `post_abstract`. That is still refinement — the spec
  permits the step via that binding — and it is what makes `validate!/2`'s
  round-trip rule satisfiable. The search is bounded by the params' generators,
  which are small by construction; a fully-bound params map is one application.

  Fails with `:not_enabled` if the guard is false on `pre_abstract` under every
  candidate binding, or `:diverged` if some binding is enabled but none
  reproduces the post-state. A `:diverged` error carries a variable-by-variable
  diff against the closest candidate — that message is the layer's primary
  output, and it is worth the effort to make it precise.
  """
  @spec check_step!(module(), atom(), map(), TLA.State.t(), TLA.State.t()) ::
    :ok | no_return()
  def check_step!(spec_module, action, params, pre_abstract, post_abstract)

  @doc """
  Assert that an `:unmapped` message left the abstract state unchanged.
  Fails with `:unmapped_but_moved`, which means either a missing
  `abstract_action/1` clause or a transition the spec does not model.
  """
  @spec check_stuttering!(module(), TLA.State.t(), TLA.State.t()) :: :ok | no_return()
  def check_stuttering!(spec_module, pre_abstract, post_abstract)

  @doc "Check spec invariants against an abstract state."
  @spec check_spec_invariants!(module(), TLA.State.t()) :: :ok | no_return()
  def check_spec_invariants!(spec_module, abstract_state)

  @doc "Check spec action properties against an abstract transition."
  @spec check_action_properties!(module(), TLA.State.t(), TLA.State.t()) :: :ok | no_return()
  def check_action_properties!(spec_module, pre_abstract, post_abstract)

  @doc """
  Record a transition in the CALLING process's behavior trace.

  There is no pid argument. An earlier draft took one and specified storage in
  the process dictionary — but a process dictionary is writable only by its own
  process, so that signature could not be implemented as described. The wrapper
  runs inside the GenServer, so recording is always a self-write and the pid was
  never needed.

  The buffer is bounded (`config :extla, trace_buffer: n`, default 1000) and
  drops oldest-first. An unbounded per-process trace is a memory leak in any
  long-lived GenServer, which is most of them.
  """
  @spec record_transition!(module(), term(), TLA.State.t(), TLA.State.t()) :: :ok
  def record_transition!(spec_module, message, pre, post)

  @doc """
  Retrieve a process's accumulated behavior trace.

  Sends the process a `:sys`-level request rather than reaching into its
  dictionary, for the same reason: only the owning process can read it.
  """
  @spec get_trace(pid()) :: TLA.State.behavior()
  def get_trace(pid)

  @doc """
  Check temporal properties against an accumulated trace. Called at the end of a
  simulation run, not per transition.

  A finite trace can refute `always(P)` and can satisfy `eventually(P)`, but it
  can neither satisfy `always(P)` nor refute `eventually(P)` outright. The result
  distinguishes `:holds`, `:violated` and `:inconclusive` rather than collapsing
  the third into the first — the same honesty rule as `max_states_reached`
  in Layer 2.
  """
  @spec check_temporal_properties(module(), TLA.State.behavior()) ::
    %{atom() => :holds | :violated | :inconclusive}
  def check_temporal_properties(spec_module, behavior)
end
```

---

## Conformance Checking Modes

| Mode | When | What it does |
|------|------|--------------|
| **Runtime** | Every transition in dev/test | Step legality + stuttering + invariants + action properties, via the refinement mapping |
| **Simulation** | `mix tla.simulate`, or in tests | Random walks over the real implementation, all property types including temporal |
| **Replay** | `mix tla.replay`, or in tests | Drives the implementation through a model-checker counterexample or a captured trace |
| **Exhaustive** | `mix tla.check` | Model checks the spec itself (Layer 2) |
| **Proof** | Non-goal | ExTLA does not prove refinement; it checks it on observed behaviors |

### Full verification pipeline

```bash
# 1. Model check the spec — design bugs, before any code exists
mix tla.check Specs.TransferProtocol

# 2. Check the implementation conforms, over random traces
mix tla.simulate MyApp.TransferServer --traces 10000

# 3. Replay the counterexample from step 1 against the real code
mix tla.replay MyApp.TransferServer --trace counterexample.json

# 4. Check a captured production trace against the spec
mix tla.replay MyApp.TransferServer --captured incident-2026-08-14.json

# 5. Property tests in CI, ongoing
mix test --only property
```

Steps 3 and 4 are what the earlier draft could not do, because they need
`concrete_message/2` and a step-legality check. They are also the two that most
change what the tool is worth: step 3 turns a design-level counterexample into an
executable reproduction, and step 4 lets a specification say something about the
system that is actually running.

---

## Mix Tasks

### `mix tla.simulate`

```elixir
defmodule Mix.Tasks.Tla.Simulate do
  @moduledoc """
  Run simulation of a TLA.GenServer against its spec.

  ## Usage

      mix tla.simulate MyApp.TransferServer
      mix tla.simulate MyApp.TransferServer --traces 5000 --steps 100
      mix tla.simulate MyApp.TransferServer --inject-failures --seed 42
  """
  use Mix.Task

  @impl Mix.Task
  def run(args)
end
```

### `mix tla.replay`

```elixir
defmodule Mix.Tasks.Tla.Replay do
  @moduledoc """
  Drive a TLA.GenServer through a spec-level behavior.

  ## Usage

      # Replay a model-checker counterexample (from `mix tla.check --format json`)
      mix tla.replay MyApp.TransferServer --trace counterexample.json

      # Check a captured trace from a running system
      mix tla.replay MyApp.TransferServer --captured incident.json

  Requires `concrete_message/2` on the refinement module for `--trace`;
  `--captured` needs only `abstract/1` and `abstract_action/1`.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args)
end
```

### `mix tla.gen.test`

```elixir
defmodule Mix.Tasks.Tla.Gen.Test do
  @moduledoc """
  Generate property-based tests from a TLA.Spec.

  ## Usage

      mix tla.gen.test Specs.TransferProtocol --server MyApp.TransferServer
  """
  use Mix.Task

  @impl Mix.Task
  def run(args)
end
```

### `mix tla.visualize`

```elixir
defmodule Mix.Tasks.Tla.Visualize do
  @moduledoc """
  Generate a visualization of the state graph.

  ## Usage

      # DOT format (for Graphviz)
      mix tla.visualize Specs.TransferProtocol --format dot

      # Interactive HTML (using D3.js)
      mix tla.visualize Specs.TransferProtocol --format html

      # Mermaid diagram
      mix tla.visualize Specs.TransferProtocol --format mermaid
  """
  use Mix.Task

  @impl Mix.Task
  def run(args)
end
```
