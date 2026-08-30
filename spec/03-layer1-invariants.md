# Layer 1: Runtime Invariant Checking

Design-by-contract for OTP behaviors. Invariants and action properties are checked at every state transition during development and testing.

---

## Overview

Layer 1 instruments GenServer (and other OTP behaviors) to automatically verify:

- **Type invariants** — the state stays within expected shapes/ranges
- **Application invariants** — domain-specific rules that must always hold
- **Action properties** — constraints on how state transitions occur
- **Preconditions** — conditions that must hold before an action executes
- **Postconditions** — conditions that must hold after an action completes

Checking is controlled by `TLA.Config.mode/0` and compiles away entirely in `:disabled` mode.

---

## Module: `TLA.Invariant`

The primary macro module for annotating GenServer modules with invariants.

### Usage

```elixir
defmodule BankAccount do
  use GenServer
  use TLA.Invariant

  # ── Type Invariant ──────────────────────────────────────────────
  # Checked after every state transition. Defines the "shape" of
  # valid states. Analogous to TLA+ TypeOK.
  #
  # The block is a BARE BOOLEAN EXPRESSION, not a `fn` — the same shape
  # `TLA.Spec` invariants have (02-dsl-semantics.md §5). `state` is
  # implicitly bound.
  #
  # Layer 1 qualifies with `state.` where Layer 2 writes variables bare.
  # That is not an inconsistency: Layer 2 has `variable` declarations to
  # resolve a bare name against, and Layer 1 — instrumenting an arbitrary
  # GenServer — has none, so bare-name rewriting there would be guessing.

  invariant :type_ok,
    desc: "balance is a non-negative integer, owner a string, status a known atom" do
    is_integer(state.balance) and state.balance >= 0 and
      is_binary(state.owner) and
      state.status in [:active, :frozen, :closed]
  end

  # ── Application Invariant ──────────────────────────────────────
  # Domain rules that must always hold.

  invariant :frozen_means_no_pending do
    state.status != :frozen or state.pending_transactions == []
  end

  # ── Action Property ────────────────────────────────────────────
  # Constrains transitions. `old` and `new` are implicitly bound.
  # Analogous to TLA+ [][P]_vars.

  action_property :balance_audit_trail do
    # Balance can only change if there's a corresponding transaction
    old.balance == new.balance or
      length(new.transactions) > length(old.transactions)
  end

  action_property :no_overdraft_transition do
    new.balance >= 0
  end

  # ── Preconditions ──────────────────────────────────────────────
  # Checked before the matching callback runs.
  #
  # The action is identified by a PATTERN on the message, not by an atom
  # tag. The pattern is what the generated wrapper dispatches on anyway,
  # and it binds the arguments for free — an earlier draft named the
  # action with a bare atom and never said how a message mapped to it.

  precondition {:withdraw, amount}, desc: "cannot withdraw from a frozen or closed account" do
    state.status == :active and
      is_integer(amount) and amount > 0 and
      state.balance >= amount
  end

  # ── Postcondition ──────────────────────────────────────────────
  # Checked after the matching callback returns. `old`, `new` and the
  # pattern's bindings are all in scope.

  postcondition {:withdraw, amount} do
    new.balance == old.balance - amount
  end

  # ── Implementation ─────────────────────────────────────────────

  def init(args) do
    {:ok, %{
      balance: args[:initial_balance] || 0,
      owner: args[:owner],
      status: :active,
      transactions: [],
      pending_transactions: []
    }}
  end

  def handle_call({:withdraw, amount}, _from, state) do
    new_state = %{state |
      balance: state.balance - amount,
      transactions: [{:withdraw, amount, DateTime.utc_now()} | state.transactions]
    }
    {:reply, {:ok, new_state.balance}, new_state}
  end

  def handle_call(:get_balance, _from, state) do
    {:reply, state.balance, state}
  end
end
```

### Macro Specification

```elixir
defmodule TLA.Invariant do
  @moduledoc """
  Provides macros for annotating OTP behaviors with formal invariants
  and action properties. Wraps callbacks to check properties at every
  state transition.
  """

  defmacro __using__(_opts) do
    quote do
      import TLA.Invariant, only: [
        invariant: 2, invariant: 3,
        action_property: 2, action_property: 3,
        precondition: 2, precondition: 3,
        postcondition: 2, postcondition: 3
      ]

      Module.register_attribute(__MODULE__, :tla_invariants, accumulate: true)
      Module.register_attribute(__MODULE__, :tla_action_properties, accumulate: true)
      Module.register_attribute(__MODULE__, :tla_preconditions, accumulate: true)
      Module.register_attribute(__MODULE__, :tla_postconditions, accumulate: true)

      @before_compile TLA.Invariant
    end
  end

  @doc """
  Define a state invariant. Checked after every state transition.

  The block is a bare boolean expression with `state` implicitly bound.

  ## Parameters
  - `name` — atom identifying this invariant
  - `opts` — see below
  - `block` — a boolean expression

  ## Options
  - `desc: String.t()` — human-readable description, carried into the
    violation message.
  - `enabled: boolean()` — evaluated at COMPILE time; a false value emits
    no code for this invariant at all. Use for checks too costly to run
    outside of test.
  - `callbacks: [atom()]` — restrict checking to specific callbacks
    (default: all). Reduces cost on hot paths.

  The description is an option, not a positional argument. An earlier draft had
  `invariant(name, description \\ "", opts \\ [], do: block)`, under which
  `invariant :x, callbacks: [:handle_cast] do ... end` resolves to the 3-arity
  clause and binds the keyword list to `description` — two trailing optional
  positionals cannot be told apart. Every declaration macro in ExTLA, in both
  Layer 1 and Layer 2, takes `desc:` for the same reason (08-decisions.md D-18).
  """
  defmacro invariant(name, opts \\ [], do: block)

  @doc """
  Define an action property. Checked on every state transition.
  `old` and `new` are implicitly bound. Same options as `invariant/3`.
  """
  defmacro action_property(name, opts \\ [], do: block)

  @doc """
  Define a precondition, checked before the matching callback runs.

  ## Parameters
  - `pattern` — a PATTERN matched against the incoming message. Its
    bindings are in scope in the block.
  - `opts` — `desc:` only
  - `block` — a boolean expression; `state` and the pattern's bindings
    are in scope
  """
  defmacro precondition(pattern, opts \\ [], do: block)

  @doc """
  Define a postcondition, checked after the matching callback returns.
  `old`, `new` and the pattern's bindings are in scope.
  """
  defmacro postcondition(pattern, opts \\ [], do: block)
end
```

### Compile-Time Transformation

The `@before_compile` hook wraps the module's callbacks using **`defoverridable` and
`super/1`** — not by renaming the originals.

An earlier draft called a generated `__original_handle_call__/3`. That approach breaks
on the thing every real GenServer has: multiple `handle_call/3` clauses with guards.
Renaming would have to reproduce every clause head and its guards correctly, and any
mistake silently changes dispatch. `defoverridable` has none of that problem — it keeps
all the original clauses intact as the superseded definition, and `super` dispatches to
them with the original pattern matching:

```elixir
# Emitted by @before_compile, once per instrumented callback:
defoverridable handle_call: 3

def handle_call(msg, from, state) do
  # 1. Preconditions whose PATTERN matches this message
  TLA.Invariant.Runtime.check_preconditions!(__MODULE__, :handle_call, msg, state)

  # 2. The developer's own clauses, with their own guards and matching
  result = super(msg, from, state)

  # 3. Extract the post-state from the return tuple
  new_state = TLA.Invariant.Runtime.extract_state(result, state)

  # 4. Postconditions whose pattern matches
  TLA.Invariant.Runtime.check_postconditions!(__MODULE__, :handle_call, msg, state, new_state)

  # 5. Invariants on the post-state
  TLA.Invariant.Runtime.check_invariants!(__MODULE__, new_state)

  # 6. Action properties on the transition
  TLA.Invariant.Runtime.check_action_properties!(__MODULE__, state, new_state)

  result
end
```

Two consequences worth stating:

- A callback that does not change state still runs the invariant checks. That is
  correct — a stuttering step must preserve invariants — but it is also why
  `callbacks:` exists as an option (§Macro Specification) for hot paths.
- `extract_state/2` takes the pre-state as a fallback, because not every return tuple
  carries one (`{:stop, reason, reply, state}` does; a bare `{:stop, reason}` from
  `handle_info` does not).

### `:disabled` emits nothing

When `TLA.Config.mode/0` resolves to `:disabled` at compile time, `@before_compile`
emits **no wrapper and no `defoverridable`**. The module compiles exactly as written.

This is why `TLA.Config.mode/0` is a `compile_env` macro rather than a runtime
`get_env` lookup (`01-foundation.md` §Configuration). A runtime lookup could not remove
the wrapper — it would leave an `Application.get_env/2` call plus a branch on every
callback, which by itself would exceed the Layer 1 per-check budget. "Zero production
cost" means no emitted code, not cheap emitted code.

---

## Module: `TLA.Invariant.Runtime`

Runtime checking engine (not used directly by developers).

```elixir
defmodule TLA.Invariant.Runtime do
  @moduledoc """
  Runtime engine for invariant and property checking.
  Behavior depends on TLA.Config.mode/0.
  """

  @doc """
  Check all registered invariants against the given state.
  """
  @spec check_invariants!(module(), TLA.State.t()) :: :ok | no_return()
  def check_invariants!(module, state)

  @doc """
  Check all registered action properties against a state transition.
  """
  @spec check_action_properties!(module(), TLA.State.t(), TLA.State.t()) :: :ok | no_return()
  def check_action_properties!(module, old_state, new_state)

  @doc """
  Check every precondition whose pattern matches `message`, for the given
  callback. A message no pattern matches has no preconditions and passes.
  """
  @spec check_preconditions!(module(), callback :: atom(), message :: term(), TLA.State.t()) ::
    :ok | no_return()
  def check_preconditions!(module, callback, message, state)

  @doc """
  Check every postcondition whose pattern matches `message`.
  """
  @spec check_postconditions!(module(), callback :: atom(), message :: term(), TLA.State.t(), TLA.State.t()) ::
    :ok | no_return()
  def check_postconditions!(module, callback, message, old_state, new_state)

  @doc """
  Extract the post-state from a GenServer callback return value.
  Handles `{:reply, _, state}`, `{:noreply, state}`, `{:stop, _, state}`,
  `{:stop, _, _, state}` and the `{..., state, timeout | :hibernate | {:continue, _}}`
  forms. A return that carries no state (`{:stop, reason}` from `handle_info`)
  yields `pre_state` — the wrapper text above explains why the fallback is needed.
  """
  @spec extract_state(callback_result :: term(), pre_state :: TLA.State.t()) :: TLA.State.t()
  def extract_state(callback_result, pre_state)
end
```

### Violation Handling

```elixir
defmodule TLA.Invariant.Violation do
  @moduledoc """
  Handles invariant violations according to the configured mode.
  """

  defexception [:type, :name, :module, :message, :state, :old_state, :args]

  @type t :: %__MODULE__{
    type: :invariant | :action_property | :precondition | :postcondition,
    name: atom(),
    module: module(),
    message: String.t(),
    state: map(),
    old_state: map() | nil,
    args: tuple() | nil
  }

  @doc """
  Report a violation. Behavior depends on mode:
  - :enabled  → raise TLA.Invariant.Violation
  - :log_only → Logger.error with structured metadata
  - :disabled → no-op (but this function should never be called in :disabled)
  """
  @spec report!(t()) :: :ok | no_return()
  def report!(violation)
end
```

---

## Supported OTP Behaviors

Layer 1 supports invariant checking for:

| Behavior | Callbacks Wrapped | Notes |
|----------|------------------|-------|
| `GenServer` | `init/1`, `handle_call/3`, `handle_cast/2`, `handle_info/2`, `handle_continue/2` | Primary target |
| `GenStateMachine` | `handle_event/4` | State + data checked |
| `:gen_statem` | `handle_event/4` | Erlang behavior support |
| `Agent` | `fun` passed to `Agent.update/get` | Via wrapper |

### GenStateMachine Integration

```elixir
defmodule TrafficLight do
  use GenStateMachine
  use TLA.Invariant

  # For state machines the implicit binding is a {state_name, data} tuple,
  # so destructure it with `let`-free ordinary matching in the expression.

  invariant :valid_state do
    {name, data} = state
    name in [:red, :yellow, :green] and
      is_integer(data.cycle_count) and data.cycle_count >= 0
  end

  action_property :valid_transitions do
    {old_name, _} = old
    {new_name, _} = new

    case {old_name, new_name} do
      {:red, :green}    -> true
      {:green, :yellow} -> true
      {:yellow, :red}   -> true
      {same, same}      -> true   # stuttering
      _                 -> false
    end
  end
end
```

---

## Testing Integration

```elixir
defmodule TLA.Invariant.Test do
  @moduledoc """
  ExUnit helpers for testing invariants in isolation.
  """

  @doc """
  Assert that a state satisfies all invariants of a module.
  On failure, names every invariant that failed — not just the first.
  """
  defmacro assert_invariants(module, state)

  @doc """
  Assert that a transition satisfies all action properties of a module.
  """
  defmacro assert_action_properties(module, old_state, new_state)

  @doc """
  Assert that a state VIOLATES a named invariant. The negative test that
  proves an invariant can actually fail — an invariant no test has ever
  seen return false is indistinguishable from `true`, and is exactly the
  vacuity problem `mix tla.check` reports at Layer 2
  (`04-layer2-model-checker.md` §Coverage and Vacuity).
  """
  defmacro refute_invariant(module, name, state)

  @doc """
  Generate a StreamData generator that only produces states satisfying
  the module's named type invariant. Used for property-based testing.
  """
  @spec valid_states(module(), atom(), StreamData.t(map())) :: StreamData.t(map())
  def valid_states(module, type_invariant_name, base_generator)
end
```

### Example Test

```elixir
defmodule BankAccountTest do
  use ExUnit.Case
  use TLA.Invariant.Test

  test "withdrawal maintains invariants" do
    state = %{balance: 100, owner: "Alice", status: :active,
              transactions: [], pending_transactions: []}

    new_state = %{state |
      balance: 50,
      transactions: [{:withdraw, 50, ~U[2026-01-01 00:00:00Z]}]
    }

    assert_invariants(BankAccount, new_state)
    assert_action_properties(BankAccount, state, new_state)
  end

  # Property-based: random states always satisfy type invariant after init
  property "init always produces valid state" do
    check all owner <- string(:alphanumeric, min_length: 1),
              balance <- non_negative_integer() do
      {:ok, pid} = GenServer.start_link(BankAccount, %{owner: owner, initial_balance: balance})
      state = :sys.get_state(pid)
      assert_invariants(BankAccount, state)
      GenServer.stop(pid)
    end
  end
end
```

---

## Telemetry Integration

Layer 1 emits telemetry for observability:

```elixir
# Always emitted:
[:extla, :invariant, :violated]        # metadata: %{module: m, name: n, violation: v}
[:extla, :action_property, :violated]
[:extla, :precondition, :violated]
[:extla, :postcondition, :violated]

# Emitted only when `config :extla, telemetry: :verbose`:
[:extla, :invariant, :checked]         # metadata: %{module: m, name: n, duration: d}
[:extla, :action_property, :checked]
[:extla, :precondition, :checked]
[:extla, :postcondition, :checked]
```

**Success events are opt-in, and off by default.** `:telemetry.execute/3` costs on the
order of a microsecond even with no handlers attached, and a single transition can fire
four of them — which would consume the entire per-check budget in the Performance table
below on instrumentation for events that, in the overwhelmingly common case, say
"nothing happened". Violations are rare and worth their cost; successes are the hot
path.

Like `mode`, the `telemetry` setting is read with `compile_env`, so `:verbose` is not
merely unfired but unemitted.

---

## Performance Considerations

| Mode | Overhead | Notes |
|------|----------|-------|
| `:disabled` | **None** | No wrapper is emitted; the module compiles as written |
| `:enabled` | ~1-5 microseconds per transition | Dominated by the predicates themselves |
| `:log_only` | ~1-5 microseconds per transition | Same, minus the raise path |

The budget is *per transition*, not per check, and it is a target rather than a
guarantee — a predicate that walks a 10,000-element list costs what it costs. The
library's obligation is to add negligible overhead of its own; the invariant's cost is
the author's.

Three levers when checking is too expensive for a given environment:

```elixir
# 1. Compile the check out entirely, per invariant
invariant :expensive_check, enabled: Mix.env() == :test do
  deep_structural_audit(state)
end

# 2. Restrict to specific callbacks
invariant :queue_bounded, callbacks: [:handle_cast] do
  length(state.queue) <= 1000
end

# 3. Turn the whole layer off for the environment
config :extla, mode: :disabled
```
