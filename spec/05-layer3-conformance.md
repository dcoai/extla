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

      @before_compile TLA.GenServer
    end
  end
end
```

An earlier draft of this macro also registered `:tla_action_mappings`. Nothing
accumulates into it: the mappings live in the refinement module, which is where
`abstract_action/1` is defined, and the attribute was a leftover from a design in which
they were declared in the server. Dropped rather than carried.

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
  # The dispatch is a call rather than a `case` HERE -- see below.
  TLA.GenServer.Runtime.check_transition!(
    @tla_spec, @tla_refinement, msg, pre_abstract, post_abstract
  )

  TLA.GenServer.Runtime.check_spec_invariants!(@tla_spec, post_abstract)
  TLA.GenServer.Runtime.check_action_properties!(@tla_spec, pre_abstract, post_abstract)
  TLA.GenServer.Runtime.record_transition!(@tla_spec, msg, pre_abstract, post_abstract)

  result
end
```

**The `case` on `abstract_action/1` lives in `Runtime.check_transition!/5`, not in the
emitted code.** In a module whose messages the compiler can enumerate — a server with one
callback clause, which is most conformance mutants and some real servers — the call has a
known return type and one arm of the `case` is provably unreachable. Elixir reports that
as a warning, in the user's module, about code the user did not write. Behind a `module()`
argument there is nothing to infer. `init/1`'s `{:ok, state} | :none` tag test is in
`Runtime.record_initial!/3` for exactly the same reason
(`03-layer1-invariants.md` §Compile-Time Transformation).

**`init/1` is wrapped too**, for the trace and the spec's invariants. Its result is the
first abstract state, so there is no step to check — but the state has to be recorded: a
temporal property over a behaviour that begins at the *second* state is a property of a
different behaviour.

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
  def trace(genserver_module, captured, opts \\ [])

  @type result :: %{
    # `:not_followed` is a third outcome, and it is not a conformance failure.
    # The implementation would not take a step the trace calls for -- it has no
    # clause for the message, it stopped, it timed out, or it took a DIFFERENT
    # legal step and landed elsewhere. Each says the spec permits a behaviour
    # the code does not, which is a finding about the pair rather than about the
    # implementation, and collapsing it into `:violation` would report the code
    # as wrong when the specification may be.
    status: :ok | :violation | :not_followed,
    steps_checked: non_neg_integer(),
    violation: %{
      step: non_neg_integer(),
      kind: :not_enabled | :diverged | :unmapped_but_moved
            | :invariant | :action_property,
      action: atom() | nil,
      message: term(),
      detail: String.t()
    } | nil,

    # Why a `:not_followed` was not followed. `nil` otherwise.
    detail: String.t() | nil
  }
end
```

### Every check has a reporting form beside its raising one

`TLA.GenServer.Runtime` gains `check_transition/5`, `check_step/5`, `check_stuttering/3`,
`check_spec_invariants/2` and `check_action_properties/3`, each returning
`:ok | {:violation, TLA.GenServer.Violation.t()}`; the `!` forms raise what they return.

A replay reports **which step** failed and goes on being a value. That cannot be built out
of the exception the wrapper raises without catching it, and the pair is the honest shape
anyway: the wrapper needs a raise, the report needs a value, and neither is derived from
the other.

### The trace's own states are checked, not only the steps' legality

An implementation may take a legal step that is not the step the counterexample took —
where an action is nondeterministic, `concrete_message/2` cannot always name the binding
the trace chose. A replay that only asked "was each step legal" would call that a
reproduction. After each message the implementation's abstract state is compared with the
trace's, and a mismatch is `:not_followed` with both states in the detail.

### Replaying a lasso

`counterexample/3` accepts a `TLA.Trace.lasso()` and replays the prefix followed by **one
pass** of the cycle. A lasso describes a behaviour that repeats forever; one pass is what
can be executed, and the liveness claim it stands for is not something a finite run can
reproduce.

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

    # There is deliberately no `constants:`. The server under test resolves its
    # constants from application config (§The compiled spec and the constants
    # are memoized per process), and a generator built on any other assignment
    # would drive it against a different specification. Passing one is refused.

    # How to generate random messages
    message_generator: (TLA.State.t() -> term()),

    # Whether to inject failures (kill/restart processes)
    inject_failures: boolean(),

    # Random seed for reproducibility
    seed: integer() | nil,

    # Number of concurrent simulations
    concurrency: pos_integer(),

    # What `init/1` is given when a trace starts its server, and again when
    # `--inject-failures` restarts one — the argument a supervisor would pass.
    init_arg: term(),

    # How long a single delivery may take before the trace reports that the
    # server stopped answering, which is an `:error` outcome rather than a
    # conformance finding.
    timeout: timeout()
  }

  @type result :: %{
    # `:error` is a third outcome: the server stopped, or stopped answering,
    # without a conformance finding. Nothing about conformance was decided after
    # that point, and reporting it as `:ok` would say the traces passed.
    status: :ok | :violation | :error,
    traces_run: non_neg_integer(),
    total_steps: non_neg_integer(),
    violation: TLA.Trace.t() | nil,
    detail: String.t() | nil,
    duration_ms: non_neg_integer(),

    # ALWAYS present, generated when the config gave none. A random run that
    # finds something and cannot be run again has found nothing anybody can act
    # on. One seed per trace is derived from it and the trace's index, so trace
    # 37 of a 1000-trace run can be re-run on its own.
    seed: integer(),
    restarts: non_neg_integer(),
    coverage: coverage_report()
  }

  @type coverage_report :: %{
    actions_hit: %{atom() => non_neg_integer()},
    states_visited: non_neg_integer(),
    invariants_checked: non_neg_integer(),

    # Amended from `branches_covered`, which had no definition anywhere in the
    # project -- nothing else names a branch. This is the fraction of the spec's
    # actions a run exercised at least once, which is the number the report was
    # reaching for and one that can be computed from what happened.
    actions_covered: float()
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

  A `message_generator` may return a bare message, as here, or the
  `{action, params, message}` the built-in generators return. The second form is
  what lets a counterexample name its actions.

  ## Failure injection

  A crash is not a step of the specification -- nothing in the DSL models one -- so
  a restart is NOT checked as a transition. What is checked is where recovery
  lands: the spec's invariants must hold of the recovered abstract state. A server
  that comes back in a state its own specification forbids is a finding whatever
  the spec says about crashing.
  """
  def run(genserver_module, config)

  @doc """
  Run a single trace and return the full abstract behavior.
  Useful for debugging specific scenarios.
  """
  def run_trace(genserver_module, config)

  @doc """
  Replay a specific trace (from a seed or explicit message sequence).
  Useful for reproducing and debugging failures.
  """
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
  Create a message generator from a spec module and a refinement mapping.

  Returns a function that, given the current abstract state, produces a random
  valid `{action, params, message}`.

  It takes the REFINEMENT as well as the spec, which an earlier draft did not. A
  specification has no notion of a message -- that is what `concrete_message/2`
  exists for -- so a generator returning one needs the mapping; returning
  `{action, params}` and mapping in the caller would put half the generator
  outside it. The action and binding travel beside the message so that a
  counterexample built from a simulation names its actions the way a
  model-checker counterexample does.
  """
  def from_spec(spec_module, refinement, constants)

  @doc """
  Create a message generator that only produces messages corresponding to
  currently ENABLED actions. More efficient — it avoids generating messages that
  will be rejected.

  **This is the default** `message_generator`. The unrestricted one asks a
  different question -- does the implementation REFUSE what the spec forbids in
  this state -- and most servers are not written to: a `handle_call` clause with
  no guard of its own accepts the message, and `:not_enabled` is the correct
  finding about that pair. It is also a finding about nearly every server ever
  written, so hunting it is opt-in (`mix tla.simulate --unrestricted`).
  """
  def enabled_only(spec_module, refinement, constants)
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
  def init_states(spec_module, constants)

  @doc """
  Generate a StreamData generator for valid action sequences.
  Each generated sequence is a list of {action_name, params} tuples
  that form a valid behavior from an initial state.
  """
  def action_sequences(spec_module, constants, max_length \\ 20)

  # Both are compiled behind `Code.ensure_loaded?(StreamData)`. `stream_data` is a
  # dev/test-only dependency of ExTLA (§06 §Dependencies keeps runtime dependencies at
  # zero), so a consumer who wants generators declares it themselves, and the functions
  # have a body only where it is loaded. This is the shape `TLA.Invariant.Test` already
  # uses for `valid_states/3`.
  #
  # The choices in a sequence come from `TLA.ModelChecker.enabled_steps/3` — the checker's
  # own enumeration, the one the differential corpus compares against TLC — rather than
  # from a second implementation of what may happen next. Note the deliberate difference
  # from `TLA.Simulation.Generator`, which takes a refinement and returns a concrete
  # message: a sequence of actions is spec-level, and the mapping belongs in the
  # consumer's own test body, as the example below shows.

  @doc """
  > **Status: deferred past v1** (`06-architecture.md` §Implementation Phases).
  >
  > Generated test *files* are deferred with `mix tla.gen.test`, and for the reason
  > §Deferred gives: "`mix tla.gen.test` writes code someone then has to maintain; the
  > property helpers give most of the value without that." The two generators above are
  > those helpers, and the usage example below is what they are for — a `check all` the
  > consumer owns, rather than a file ExTLA writes and they inherit.
  >
  > Specified here so the design is not painted into a corner, and not built.

  Generate a complete property test module for a spec.
  Writes an ExUnit test file that:
  1. Generates random valid action sequences
  2. Applies them to the GenServer
  3. Checks refinement at every step
  """
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
  def check_step!(spec_module, action, params, pre_abstract, post_abstract)

  @doc """
  Assert that an `:unmapped` message left the abstract state unchanged.
  Fails with `:unmapped_but_moved`, which means either a missing
  `abstract_action/1` clause or a transition the spec does not model.
  """
  def check_stuttering!(spec_module, pre_abstract, post_abstract)

  @doc "Check spec invariants against an abstract state."
  def check_spec_invariants!(spec_module, abstract_state)

  @doc "Check spec action properties against an abstract transition."
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
  def record_transition!(spec_module, message, pre, post)

  @doc """
  Retrieve a process's accumulated behavior trace.

  Sends the process a `:sys`-level request rather than reaching into its
  dictionary, for the same reason: only the owning process can read it.
  """
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
  def check_temporal_properties(spec_module, behavior)

  @doc """
  One transition, checked: the step against the action the mapping names, or the
  stuttering claim `:unmapped` makes. The wrapper calls this rather than
  `check_step!/5` and `check_stuttering!/3` directly — see §Compile-Time
  Transformation for why the `case` cannot be emitted.
  """
  def check_transition!(spec_module, refinement, message, pre, post)

  @doc """
  The first abstract state: mapped, checked against the spec's invariants, and
  recorded. Takes the raw `init/1` return, because `:ignore` and a bare
  `{:stop, reason}` produce no state at all.
  """
  def record_initial!(spec_module, refinement, result)

  @doc """
  The refinement mapping applied against the memoized compiled spec.
  `TLA.Refinement.abstract!/3` needs the compiled struct; the wrapper has only the
  module.
  """
  def abstract!(spec_module, refinement, concrete)

  @doc "The behaviour recorded by THIS process, oldest state first."
  def trace()
end
```

### The compiled spec and the constants are memoized per process

Both are needed on every transition: `__tla_spec__/0` builds its struct on each call, and
the constants come from application config. They are resolved once per process and kept in
the process dictionary beside the trace, which is where a GenServer's per-process state
belongs — and the wrapper always runs inside the server. The entry is keyed on the spec
module's `module_info(:md5)`, so a server that outlives a recompile of its spec picks the
new one up on its next callback rather than keeping the structure it first loaded.

When a simulation stops a server it does so as a supervisor would: `exit(:shutdown)`, so a
server that traps exits runs its `terminate/2`, with a bounded wait before a `:kill`. Failure
injection is a crash, and a crash runs no `terminate/2`; that one is a `:kill` on purpose.
`TLA.Simulation.run/2` stops at the first finding; `traces_run` counts the traces that ran.

**The constants are resolved by `TLA.Spec.Compiled.resolve_constants/1`, the same function
`mix tla.check` uses.** A specification model checked under one assignment and an
implementation checked against another are two different specifications, and a verdict
from each is not a verdict about the same thing.

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
      mix tla.simulate MyApp.TransferServer --against-graph

  ## Options

      --traces           How many traces to run (default: 100).
      --steps            Maximum steps per trace (default: 25).
      --seed             Seed the run. One seed per trace is derived from it and
                         the trace's index, so a reported trace is reproducible.
      --concurrency      How many traces to run at once (default: 1).
      --inject-failures  Kill and restart the server mid-trace, and check that
                         recovery lands in a state the spec's invariants admit.
      --unrestricted     Also generate messages for actions the spec DISABLES in
                         the current state, which asks whether the implementation
                         refuses what the spec forbids.
      --against-graph    Also check each trace against the spec's own state
                         graph, one trace at a time (§Conformance).
      --format           `human` (default) or `json`.

  ## Exit codes

  `0` conformant, `1` a divergence was found, `2` the run could not be set up --
  no such module, no refinement mapping, a spec that does not compile.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args)
end
```

#### `--against-graph`: Layer 2 and Layer 3 checked against each other

Layers 2 and 3 compute over the same specification and never look at one another. Layer 2
says which states are reachable; Layer 3 runs a real GenServer and observes behaviour
through a refinement mapping. A trace the implementation produces that is **not a path in
the checker's graph** means one of three things, and only two are ever considered:

1. the implementation is wrong — the finding Layer 3 exists for;
2. the refinement mapping is wrong — §Simulation's own stated catch;
3. **the search missed a state** — a checker defect, and the only one no other gate can
   find. TLC agreement covers the differential corpus's models; a running server explores
   paths driven by real OTP scheduling rather than by the traversal code under test.

`TLA.Conformance.against_graph/3` requires every observed state to be a node and every
observed step to be an edge, and classifies each divergence:

| finding | when |
|---|---|
| `:checker` | the spec **permits** the step and the graph lacks it — the search missed something |
| `:absent_state` | a state the graph never registered at all |
| `:not_a_step_of_the_spec` | no action of the spec permits the step |

**The third row is a pair, not a verdict, and deliberately.** An observed step the spec
forbids means the implementation did something wrong *or* the mapping described the step
wrongly, and one step of evidence cannot separate them. `test/conformance/README.md` states
the same position for the mirror case, `:not_followed`: "one of the two is wrong, and which
one is not something the checker can decide." Layer 3's own `check_step/5` runs during the
simulation and reports its reading; this adds the containment view beside it rather than
overruling it.

**A run that could not build the full graph declines to classify.** Past `max_states`, or
under a `state_constraint`, absence from the graph is a fact about the bound rather than
about the search — so the run's status is a required argument and a bounded one is refused.
Reporting a bound as a checker finding is the false positive that would get this turned off.

Off by default, and it runs traces one at a time: containment is a question about each
*behaviour*, and `TLA.Simulation.run/2` returns a verdict.

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

  ## Options

      --trace      A model-checker counterexample to replay (see below).
      --captured   A captured trace from a running system (see below).
      --format     `human` (default) or `json`.
      --init-arg   Accepted and NOT currently read (#165). `TLA.Replay`'s
                   `:server`, `:init_arg` and `:timeout` options are unreachable
                   from this task, which passes none of them; the server is
                   started with `[]`. Documented rather than omitted because it
                   is in the task's `@switches` and `OptionParser` accepts it,
                   so a user can pass it today and be silently ignored.

  ## The file formats

  `--trace` takes what `mix tla.check --format json` writes -- either the whole
  document, an object keyed by spec module, or a single trace object lifted out
  of it.

  `--captured` takes an array of `{"message": …, "state": …}`, oldest first, where
  `state` is the CONCRETE state the implementation was in AFTER that message.

  Both are `TLA.State.Json` encodings, so a state is written the way the checker
  writes one and there is no second format to learn. Atom names are resolved
  against the atoms the system already has: a trace belonging to a different
  specification fails with the name that did not resolve, rather than decoding
  into something else, and no file can grow the atom table.

  ## Exit codes

      0  the behaviour was reproduced, or the capture conforms
      1  a conformance violation
      2  the implementation could not follow the trace -- NOT a conformance
         failure, since the spec permits a behaviour the code does not take and
         which of the two is wrong is not something this can decide
  """
  use Mix.Task

  @impl Mix.Task
  def run(args)
end
```

### `mix tla.gen.test`

> **Status: deferred past v1** (`06-architecture.md` §Implementation Phases).
>
> §Deferred gives the reason: "`mix tla.gen.test` writes code someone then has to maintain;
> the property helpers give most of the value without that." `TLA.PropertyTest`'s two
> generators are those helpers, and they are built. Specified here so the design is not
> painted into a corner, and not built.

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

### `mix tla.stamp`

Reports and updates the `spec_version:` stamps that `use TLA.GenServer` carries. A stamp
records which version of a spec a refinement mapping was written against, and a stale one is
a **compile error** — so the task that reports and repairs them is part of the layer's
surface, not a convenience.

It reads `.ex` source directly rather than loading modules, because a stale stamp means the
project may not compile, and a tool for that situation cannot require the situation not to
exist.

```elixir
defmodule Mix.Tasks.Tla.Stamp do
  @moduledoc """
  Report or update `spec_version:` stamps on refinement mappings.

  ## Usage

      mix tla.stamp             # report every mapping's status
      mix tla.stamp --restamp   # rewrite stale stamps in place

  Each mapping is reported as one of four statuses:

  | Status | Meaning |
  |---|---|
  | `:fresh` | the stamp matches the spec's current hash |
  | `:stale` | the spec changed since the mapping was written |
  | `:unstamped` | no `spec_version:` was given |
  | `:unverifiable` | the spec's hash could not be computed |

  ## Options

      --restamp   Rewrite stale stamps to the spec's current hash.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args)
end
```

`--restamp` **records a judgement rather than performing one.** A stale stamp means the spec
moved and somebody has to decide whether the mapping still holds; the flag writes down that
the decision was taken. It is deliberately not the default and deliberately not offered in the
compile error's message — "an error message offering a one-key fix trains people to take the
fix, and a stamp applied without reading is worse than no stamp, because it manufactures
assurance."

**What the version covers.** The module version is one number naming one specification, so
it is computed over **every** declaration the DSL has — `variable`, `constant`, `init` and
`fairness` as well as the item kinds (`action`, `invariant`, `temporal`, `action_property`,
`terminal`). An earlier version hashed the items alone, so changing an `init` value, a
constant's `default:`, a variable's `type:` or the fairness kind left the version unmoved
and a stamp fresh across a change to the reachable set it was a claim about. `fairness` is
in deliberately: it moves liveness verdicts and nothing a mapping reads, but a spec under
strong fairness admits a different set of behaviours from the same spec under weak, and a
"mapping-relevant" version distinct from a "liveness-relevant" one would be two stamps
where the second is maintained by nobody. The compile-time check and `mix tla.stamp`
compute the version from **one** function, `TLA.Spec.Hash.module_version/2`; a version the
two derive separately is not a version. Not covered: `@moduledoc`, `use TLA.Spec`, and
ordinary `def`s in the module, so a documentation edit does not restamp every mapping.

> The stamp mechanism itself — the `spec_version:` option, `TLA.Spec.Hash`, and the
> compile-time check — is otherwise unspecified. This section covers the task's surface so it
> is gated against drift; the feature's semantics need their own section, which is tracked
> separately.

---

### `mix tla.visualize`

> **DOT only.** This section advertised `--format html` and `--format mermaid` until
> `mix tla.visualize` was built. `06-architecture.md` §Phase 4 says "DOT only" and
> §Deferred defers the HTML/D3 visualizer explicitly — "DOT is enough, and a bespoke
> viewer is a maintenance sink" — so §06 wins and this is corrected to agree. Both
> formats are **refused** by the task with a message naming that decision, rather than
> quietly ignored. Graphviz renders whatever else is wanted: `dot -Tsvg`, `-Tpng`, `-Tpdf`.

```elixir
defmodule Mix.Tasks.Tla.Visualize do
  @moduledoc """
  Render a spec's state graph as DOT, for Graphviz.

  ## Usage

      mix tla.visualize Specs.TransferProtocol
      mix tla.visualize Specs.TransferProtocol --output graph.dot
      mix tla.visualize Specs.TransferProtocol --max-states 2000

  ## Options

      --output       Write here instead of to stdout.
      --max-states   Refuse past this many states, naming the true count
                     (default: 500).
      --format       dot, and only dot.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args)
end
```

It builds the graph with `liveness_graph: true`, because the edge table is what a
rendering needs — parent pointers are a spanning tree, and `TLA.StateGraph.to_dot/2`
refuses to draw one as though it were the transition relation
(`04-layer2-model-checker.md` §State Graph). A spec whose invariant is refuted is drawn
with its counterexample emphasised, and the task says that the graph covers only what the
search reached before stopping.
