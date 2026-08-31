# Foundation: Core Types & Operators

The foundation layer provides the primitive building blocks that all higher layers depend on. These modules translate TLA+ mathematical concepts into Elixir idioms.

---

## Module: `TLA.State`

Represents a snapshot of all variables at a single point in time, and transitions between states.

### Types

```elixir
defmodule TLA.State do
  @moduledoc """
  A state is an immutable snapshot of all specification variables.
  A step is a pair of consecutive states (pre-state and post-state).
  A behavior is a (possibly infinite) sequence of states.
  """

  @type variable_name :: atom()
  @type value :: term()

  @type t :: %{variable_name() => value()}

  @type step :: {pre :: t(), post :: t()}

  @type behavior :: [t(), ...]

  # A counterexample is `TLA.Trace.t()` (04-layer2-model-checker.md §TLA.Trace).
  # An earlier draft defined a second `trace` type here; one concept, one type.
end
```

### Core Functions

```elixir
@doc """
Create a new state from a keyword list or map of variable assignments.
"""
@spec new(Enumerable.t()) :: t()
def new(assignments)

@doc """
Return the value of a variable in the given state.
"""
@spec get(t(), variable_name()) :: value()
def get(state, var)

@doc """
Return a new state with the given variable updated.
Analogous to TLA+ primed variable assignment: x' = value.
"""
@spec prime(t(), variable_name(), value()) :: t()
def prime(state, var, value)

@doc """
Return a new state with multiple variables updated.
"""
@spec prime_many(t(), %{variable_name() => value()}) :: t()
def prime_many(state, assignments)

@doc """
Check if two states are identical (stuttering step).
"""
@spec stuttering?(step()) :: boolean()
def stuttering?({pre, post})

@doc """
Return the set of variables that changed between states.
"""
@spec changed_vars(step()) :: MapSet.t(variable_name())
def changed_vars({pre, post})

@doc """
Assert that specified variables did NOT change between states.
Analogous to TLA+ UNCHANGED <<x, y, z>>.
"""
@spec unchanged?(step(), [variable_name()]) :: boolean()
def unchanged?({pre, post}, vars)

@doc """
Assert that every value in the state is deterministically serializable, per
`02-dsl-semantics.md` §6. Returns the state; raises `TLA.State.InvalidTermError`
naming the variable and the position inside it.
"""
@spec validate!(t()) :: t() | no_return()
def validate!(state)
```

### Reading a variable that is not there

`get/2`, `unchanged?/2` and `prime/3` raise rather than defaulting. So does `f[x]`
inside a spec block, for the same reason and by the same argument
(`02-dsl-semantics.md` §1.6, D-20). This is not
defensiveness; it is the difference between a bug and a wrong answer. A misspelled
variable read through `Map.get/2` returns `nil`, `nil` compares unequal to whatever the
guard expected, the action looks disabled, and the checker explores a smaller state
space and reports success — with nothing in the output distinguishing that run from a
sound one. `prime/3` is the same argument in the other direction: a spec's variable set
is fixed by its `Init`, so priming a variable the state does not have is a typo, and one
the fingerprint would then faithfully preserve as a distinct state.

---

## Module: `TLA.Temporal`

Temporal logic operators for reasoning about behaviors (sequences of states).

### Operators

```elixir
defmodule TLA.Temporal do
  @moduledoc """
  Temporal logic operators over finite behaviors (traces).

  These implement the finite-trace semantics of TLA temporal operators.
  For model checking, behaviors are finite but may include a "lasso"
  (back-loop) to represent infinite cyclic behaviors.
  """

  @type predicate :: (TLA.State.t() -> boolean())
  @type action_predicate :: (TLA.State.t(), TLA.State.t() -> boolean())
  @type behavior :: TLA.State.behavior()

  @doc """
  □P (always/box): P holds in every state of the behavior.
  TLA+ equivalent: []P
  """
  @spec always(behavior(), predicate()) :: boolean()
  def always(behavior, predicate)

  @doc """
  ◇P (eventually/diamond): P holds in at least one state.
  TLA+ equivalent: <>P
  """
  @spec eventually(behavior(), predicate()) :: boolean()
  def eventually(behavior, predicate)

  @doc """
  ◇□P (eventually always): P becomes true and stays true forever.
  TLA+ equivalent: <>[]P
  """
  @spec eventually_always(behavior(), predicate()) :: boolean()
  def eventually_always(behavior, predicate)

  @doc """
  □◇P (always eventually): P is true infinitely often.
  For finite traces with a lasso, checks that P occurs in the cycle.
  TLA+ equivalent: []<>P
  """
  @spec always_eventually(behavior(), predicate(), lasso_start :: non_neg_integer() | nil) :: boolean()
  def always_eventually(behavior, predicate, lasso_start \\ nil)

  @doc """
  P ⇝ Q (leads-to): whenever P is true, Q eventually becomes true.
  TLA+ equivalent: P ~> Q
  """
  @spec leads_to(behavior(), predicate(), predicate()) :: boolean()
  def leads_to(behavior, p, q)

  @doc """
  □[A]_v (box-action): every step either satisfies action A or is a
  stuttering step (variables v don't change).
  TLA+ equivalent: [][A]_vars
  """
  @spec box_action(behavior(), action_predicate(), [atom()]) :: boolean()
  def box_action(behavior, action, vars)

  @doc """
  ◇⟨A⟩_v (diamond-action): some step satisfies action A and changes
  at least one variable in v.
  TLA+ equivalent: <><A>_vars
  """
  @spec diamond_action(behavior(), action_predicate(), [atom()]) :: boolean()
  def diamond_action(behavior, action, vars)

  @doc """
  ENABLED: true if the action has at least one legal successor from this state —
  some params combination for which every param generator is non-empty and the
  guard holds (02-dsl-semantics.md §2.1, §3).

  Enabledness is a function of the action's params and guard alone. It does NOT
  consult the state graph — an earlier draft took a `state_graph` argument, but
  the graph records reachable successors, not enabledness, and a parent-pointer
  graph (04-layer2-model-checker.md §State Graph) records no successors at all.
  The liveness checker records the result of this function per state, as a bit
  per fairness constraint, while the state is materialized during expansion.

  `binding` restricts the check to one binding of the leading params, for
  per-binding fairness (02-dsl-semantics.md §5.2); `%{}` means any binding.
  TLA+ equivalent: ENABLED Action, or ENABLED Action(p) with a binding.
  """
  @spec enabled?(TLA.State.t(), TLA.Spec.Compiled.action_def(), constants :: map(), binding :: map()) :: boolean()
  def enabled?(state, action, constants, binding \\ %{})
end
```

### Fairness

```elixir
defmodule TLA.Temporal.Fairness do
  @moduledoc """
  Weak and strong fairness constraints.

  Fairness prevents trivial satisfaction of liveness properties
  by forbidding infinite stuttering when progress is possible.
  """

  @doc """
  Weak fairness: if an action is continuously enabled from some point on,
  it must eventually be taken.

  WF_vars(A) ≡ □◇¬(ENABLED ⟨A⟩_vars) ∨ □◇⟨A⟩_vars

  Use when: once enabled, the action stays enabled until taken.
  Example: a process ready to run without contention.
  """
  @spec weak_fairness(TLA.State.behavior(), TLA.Temporal.action_predicate(), [atom()]) :: boolean()
  def weak_fairness(behavior, action, vars)

  @doc """
  Strong fairness: if an action is repeatedly enabled (even intermittently),
  it must eventually be taken.

  SF_vars(A) ≡ ◇□¬(ENABLED ⟨A⟩_vars) ∨ □◇⟨A⟩_vars

  Use when: the action may be enabled and disabled repeatedly.
  Example: acquiring a contested lock.
  """
  @spec strong_fairness(TLA.State.behavior(), TLA.Temporal.action_predicate(), [atom()]) :: boolean()
  def strong_fairness(behavior, action, vars)
end
```

---

## Module: `TLA.Set`

Extended set operations matching TLA+ built-in set operators.

```elixir
defmodule TLA.Set do
  @moduledoc """
  Set operations corresponding to TLA+ set theory operators.
  Builds on Elixir's MapSet with additional TLA+ operations.
  """

  @doc """
  SUBSET S — the power set (set of all subsets).
  TLA+ equivalent: SUBSET S
  Warning: exponential in |S|. Use with small sets only.
  """
  @spec powerset(MapSet.t()) :: MapSet.t(MapSet.t())
  def powerset(set)

  @doc """
  S1 \\X S2 — Cartesian product.
  Returns set of all tuples {a, b} where a ∈ S1 and b ∈ S2.
  TLA+ equivalent: S1 \\X S2
  """
  @spec cross(MapSet.t(), MapSet.t()) :: MapSet.t(tuple())
  def cross(s1, s2)

  @doc """
  N-ary Cartesian product.
  TLA+ equivalent: S1 \\X S2 \\X ... \\X Sn

  The product of NO sets is the set containing the empty tuple, not the empty set.
  That is the answer the DSL needs when an action has no parameters: one binding,
  binding nothing. The empty set would mean the action can never fire.
  """
  @spec cross_many([MapSet.t()]) :: MapSet.t(tuple())
  def cross_many(sets)

  @doc """
  UNION S — distributed union. Flattens a set of sets.
  TLA+ equivalent: UNION S
  """
  @spec distributed_union(MapSet.t(MapSet.t())) :: MapSet.t()
  def distributed_union(set_of_sets)

  @doc """
  Set mapping: {f(x) : x ∈ S}
  TLA+ equivalent: {expr : x \\in S}
  """
  @spec map(MapSet.t(), (term() -> term())) :: MapSet.t()
  def map(set, fun)

  @doc """
  Set filtering: {x ∈ S : P(x)}
  TLA+ equivalent: {x \\in S : predicate}
  """
  @spec filter(MapSet.t(), (term() -> boolean())) :: MapSet.t()
  def filter(set, predicate)

  @doc """
  CHOOSE x ∈ S : P(x) — deterministic selection.

  Returns the LEAST satisfying element in Erlang term order. TLA+ requires only
  that CHOOSE be a function of its arguments, not that it pick any particular
  element, so any total order will do — but it must be an order that does not
  depend on how the set was built or which OTP release is running. Enumeration
  order is not such an order, and a CHOOSE that varied between runs would make the
  reachable state graph vary between runs, defeating the differential corpus.

  Raises if no element satisfies the predicate: CHOOSE is undefined there, and
  returning nil would put an unspecified value into a state variable.
  TLA+ equivalent: CHOOSE x \\in S : P(x)
  """
  @spec choose(MapSet.t(), (term() -> boolean())) :: term()
  def choose(set, predicate \\ fn _ -> true end)

  @doc """
  Check if predicate holds for all elements.
  TLA+ equivalent: \\A x \\in S : P(x)
  """
  @spec for_all?(MapSet.t(), (term() -> boolean())) :: boolean()
  def for_all?(set, predicate)

  @doc """
  Check if predicate holds for at least one element.
  TLA+ equivalent: \\E x \\in S : P(x)
  """
  @spec exists?(MapSet.t(), (term() -> boolean())) :: boolean()
  def exists?(set, predicate)

  @doc """
  Integer range as a MapSet.
  TLA+ equivalent: a..b
  """
  @spec range(integer(), integer()) :: MapSet.t(integer())
  def range(a, b)
end
```

---

## Module: `TLA.Function`

TLA+ function operations (functions as total maps from domain to range).

```elixir
defmodule TLA.Function do
  @moduledoc """
  TLA+ function operations. In TLA+, a function maps every element
  of its domain to a value. Elixir maps serve as the implementation.
  """

  @doc """
  Construct a function: [x ∈ S ↦ expr(x)]
  TLA+ equivalent: [x \\in S |-> expr]
  """
  @spec construct(MapSet.t(), (term() -> term())) :: map()
  def construct(domain, mapping)

  @doc """
  Function set: [S → T] — all TOTAL functions from S to T.
  TLA+ equivalent: [S -> T]
  Warning: |T|^|S| elements — a function fixes a value for each element of the
  DOMAIN, so the domain is the exponent. (An earlier draft had this backwards.)
  Use with small sets.

  Two edge cases that differ: an empty DOMAIN gives exactly one function, the
  empty one; an empty RANGE with a non-empty domain gives none, since no total
  function into an empty set exists.
  """
  @spec function_set(MapSet.t(), MapSet.t()) :: MapSet.t(map())
  def function_set(domain, range)

  @doc """
  DOMAIN f — the domain of a function.
  TLA+ equivalent: DOMAIN f
  """
  @spec domain(map()) :: MapSet.t()
  def domain(f)

  @doc """
  EXCEPT — update a function at specific points.
  TLA+ equivalent: [f EXCEPT ![a] = v, ![b] = w]

  Raises on a point outside the domain. [f EXCEPT ![a] = v] where a ∉ DOMAIN f is
  undefined in TLA+, and quietly extending the domain would produce a state no
  reachable behavior can produce — while still fingerprinting it as if it were one.
  Same for except_with/3.
  """
  @spec except(map(), [{term(), term()}]) :: map()
  def except(f, updates)

  @doc """
  EXCEPT with self-reference — update using the old value.
  TLA+ equivalent: [f EXCEPT ![a] = @ + 1]
  """
  @spec except_with(map(), term(), (term() -> term())) :: map()
  def except_with(f, key, update_fn)

  @doc """
  Record set: [field1: S1, field2: S2] — all records with fields
  drawn from respective sets.
  TLA+ equivalent: [field1: S1, field2: S2]
  """
  @spec record_set(keyword(MapSet.t())) :: MapSet.t(map())
  def record_set(field_specs)
end
```

---

## Module: `TLA.Fingerprint`

State identity. Every state the checker visits is reduced to a fingerprint; two states
with the same fingerprint are treated as the same state and only one is explored.

**This module decides whether the checker's answers can be trusted.** A fingerprint
collision silently drops an unexplored state, and the run then reports success over a
state space it never visited — the worst failure mode a verification tool has. It is
specified here, in the foundation, rather than left as an implementation detail.

```elixir
defmodule TLA.Fingerprint do
  @moduledoc """
  Canonical, collision-resistant state identity.

  A fingerprint is the truncated SHA-256 of the state's canonical binary encoding.
  """

  @type t :: <<_::64>> | <<_::128>>

  @doc """
  Canonical binary encoding of a state.

  Uses `:erlang.term_to_binary/2` with the `:deterministic` option, which fixes map
  and MapSet key ordering in the external term format. The plain 1-arity call is NOT
  used: its output for maps is not a guaranteed canonical encoding across OTP
  versions, so two equal states could encode differently and be explored twice — or,
  worse, a stored fingerprint could stop matching after an OTP upgrade.
  """
  @spec canonical(TLA.State.t()) :: binary()
  def canonical(state), do: :erlang.term_to_binary(state, [:deterministic])

  @doc """
  Fingerprint a state. 64 bits by default; `bits: 128` for very large runs.
  """
  @spec compute(TLA.State.t(), keyword()) :: t()
  def compute(state, opts \\ [])

  @doc """
  Expected number of distinct states silently lost to collisions, by the birthday
  bound: n^2 / 2^(bits+1). Reported in every `TLA.ModelChecker.result()` so a run's
  soundness margin is visible rather than assumed.
  """
  @spec collision_estimate(non_neg_integer(), pos_integer()) :: float()
  def collision_estimate(distinct_states, bits)
end
```

### Why not `:erlang.phash2/1`

An earlier draft specified `:erlang.phash2` for its speed (<1 microsecond). Its default
range is 2^27 - 1 (134,217,727), and `phash2/2` caps at 2^32. Applying the birthday
bound to the state counts ExTLA targets:

| Distinct states | Expected collisions, `phash2` default (2^27) | 64-bit |
|---|---|---|
| 100,000 | ~37 | ~2.7 x 10^-10 |
| 1,000,000 | ~3,700 | ~2.7 x 10^-8 |
| 10,000,000 | ~372,000 | ~2.7 x 10^-6 |

At the 10M-state target the checker would silently skip on the order of 372,000 states
and report success. Even a modest 100K-state run loses about 37. SHA-256 truncated to 64
bits costs perhaps 1-2 microseconds more per state and removes the failure class; TLC
uses 64-bit fingerprints for exactly this reason. Speed is not worth an unsound answer.

`phash2` remains appropriate for ETS bucket selection, where a collision costs a
comparison rather than a dropped state.

### Permitted state terms

`canonical/1` requires deterministic serialization, which constrains what a spec
variable may hold. See `02-dsl-semantics.md` §6: pids, references, ports, funs and
floats are forbidden in spec state, and assigning one raises from the checker naming the
variable rather than silently mis-fingerprinting.

---

## Configuration

```elixir
defmodule TLA.Config do
  @moduledoc """
  Global configuration for ExTLA behavior.
  """

  @type mode :: :enabled | :log_only | :disabled

  @doc """
  Checking mode, resolved at COMPILE time.

  - :enabled   — raise on violation (default in dev/test)
  - :log_only  — log violation but continue (useful for staging)
  - :disabled  — emit no checking code at all (default in prod)

  This is `compile_env`, not `get_env`, for two reasons:

  1. **`:disabled` must be genuinely free.** The `@before_compile` hooks in Layers 1
     and 3 read this value and, when it is `:disabled`, emit no wrapper at all. A
     runtime `get_env` lookup could not do that — it would leave an
     `Application.get_env/2` call on every callback, which alone consumes most of the
     Layer 1 per-check budget.
  2. **`Mix` does not exist in a release.** An earlier draft defaulted via
     `Mix.env()` evaluated at runtime, which raises `UndefinedFunctionError` in any
     assembled release. Compile-time resolution removes the dependency entirely.

  Changing the mode changes what the instrumented modules compile to, and Mix knows
  it: `compile_env` registers a compile-time dependency on the config key in the
  CALLING module, so a `config :extla, mode: ...` edit recompiles exactly those
  modules. That is the intended trade: the production default is zero code, not
  cheap code.

  The `compile_env` call is inside the `quote`, not in the macro body. In the body
  it would run once, while ExTLA itself compiles — baking the value into the
  dependency's build and attaching the config dependency to `TLA.Config` instead of
  to the user's module. Inside the quote it expands in the caller, which is where
  both the value and the dependency belong.

  Consequently `mode/0` may only be called from a MODULE BODY: `compile_env/3`
  raises "cannot be called inside functions". The `@before_compile` hooks in Layers
  1 and 3 therefore resolve it into a module attribute
  (`@tla_mode TLA.Config.mode()`) and branch on the attribute when emitting each
  wrapper. That is the correct shape anyway — the point of compile-time resolution
  is that `:disabled` emits no wrapper, which is a decision made while the module
  body is being expanded, not inside a function that has already been emitted.
  """
  defmacro mode do
    default = default_mode()

    quote do
      Application.compile_env(:extla, :mode, unquote(default))
    end
  end

  # Runs while the CALLER compiles (a macro body executes at expansion time), where
  # Mix is normally present. `Code.ensure_loaded?/1`, not `function_exported?/3`:
  # the latter answers false for a module that exists but is not loaded yet, which
  # would silently select :enabled in a fresh VM.
  defp default_mode do
    if Code.ensure_loaded?(Mix) and Mix.env() == :prod, do: :disabled, else: :enabled
  end

  @doc """
  Maximum states to explore during model checking before aborting.
  Prevents runaway exploration.
  """
  @spec max_states() :: pos_integer()
  def max_states do
    Application.get_env(:extla, :max_states, 1_000_000)
  end

  @doc """
  Number of workers for parallel state exploration.
  """
  @spec workers() :: pos_integer()
  def workers do
    Application.get_env(:extla, :workers, System.schedulers_online())
  end
end
```
