# Layer 2: Specification DSL + Model Checker

A TLA+-style specification language embedded in Elixir, with an exhaustive state-space model checker.

---

## Overview

Layer 2 provides:

1. **`TLA.Spec`** — a DSL for defining state machines: variables, initial states,
   actions, invariants, and temporal properties
2. **`TLA.ModelChecker`** — an exhaustive BFS state explorer that verifies specs
   against all reachable states
3. **`TLA.Trace`** — counterexample trace generation when violations are found
4. **`TLA.Coverage`** — what the run actually exercised, and what it did not

This is the Elixir equivalent of writing a `.tla` file and running TLC.

> **The DSL's semantics are normative in [`02-dsl-semantics.md`](02-dsl-semantics.md).**
> How a name resolves, why an action block is a conjunction rather than a sequence,
> where nondeterminism comes from, and what the compiler rejects are all specified
> there, with a full worked example in its §8. This file specifies the *checker*.
> Where the two disagree, the semantics file wins.

The three rules from that file that shape everything here:

- **Constants are pinned (`^name`), variables are bare.** No atom is ever a constant.
- **An action body is a simultaneous assignment**, not a sequence: every RHS reads the
  pre-state, every LHS writes the post-state, unassigned variables are `UNCHANGED`.
- **Nondeterminism lives only in `params:`**, which may draw from a constant, a literal
  range or list, or a function of the pre-state. An action body is therefore a pure
  deterministic function of `(pre_state, params)` — the property this checker, the
  symmetry reduction, and Layer 3's refinement check all rely on.

### DSL Macro Reference

```elixir
defmodule TLA.Spec do
  defmacro __using__(_opts) do
    quote do
      import TLA.Spec.DSL

      Module.register_attribute(__MODULE__, :tla_constants, accumulate: true)
      Module.register_attribute(__MODULE__, :tla_variables, accumulate: true)
      Module.register_attribute(__MODULE__, :tla_inits, accumulate: true)
      Module.register_attribute(__MODULE__, :tla_actions, accumulate: true)
      Module.register_attribute(__MODULE__, :tla_invariants, accumulate: true)
      Module.register_attribute(__MODULE__, :tla_action_properties, accumulate: true)
      Module.register_attribute(__MODULE__, :tla_temporals, accumulate: true)
      Module.register_attribute(__MODULE__, :tla_fairness, accumulate: true)

      @before_compile TLA.Spec
    end
  end
end
```

```elixir
defmodule TLA.Spec.DSL do
  @moduledoc """
  The macros that form the specification DSL.
  """

  @doc """
  Declare a constant parameter. Value assigned at model-check time.
  Referenced in blocks as `^name`.
  """
  defmacro constant(name, opts \\ [])

  @doc """
  Declare a state variable with optional type annotation.
  Referenced in blocks as a bare `name`.

  Type annotations are used for:
  1. Documentation
  2. Bounding the state space during model checking
  3. Deriving StreamData generators (Layer 3)

  ## Type Syntax
  - Literal values: `:idle`, `0`, `"hello"`
  - Ranges: `0..100`
  - Sets: `[:a, :b, :c]` — value must be one of these
  - Function type: `[domain ~> range]` — map from domain set to range
  - Set type: `:set` — a MapSet
  - Sequence type: `:seq` — an ordered list
  - Reference to a constant: `^name`
  """
  defmacro variable(name, opts \\ [])

  @doc """
  Define an initial state. Variables are assigned with `=`.
  Multiple init blocks are disjuncted (nondeterministic choice of start state).
  """
  defmacro init(do: block)

  @doc """
  Define a named action (state transition).

  ## Options
  - `params:` — the action's ONLY source of nondeterminism. Each entry draws from a
    constant (`^accounts`), a literal range or list (`1..10`), or a **function of the
    pre-state** (`fn s -> s.pending end`). The checker generates one successor per
    combination.

  Inside the block:
  - `require expr` — an enabling condition, evaluated on the pre-state
  - `let pat = expr` — an ordinary local binding
  - `variable = expr` — the next-state value; RHS reads the pre-state
  - Variables not assigned are implicitly UNCHANGED

  See `02-dsl-semantics.md` §2-3 for the full semantics.
  """
  defmacro action(name, opts \\ [], do: block)

  @doc """
  Define a state invariant (safety property).
  The block is a bare boolean expression over variables and `^constants`.
  Checked in every reachable state.
  """
  defmacro invariant(name, description \\ "", do: block)

  @doc """
  Define an action property (transition constraint).
  The block is a bare boolean expression; `old` and `new` are implicitly bound.
  A bare variable name is a compile error here — see `02-dsl-semantics.md` §4.
  """
  defmacro action_property(name, description \\ "", do: block)

  @doc """
  Define a temporal property (liveness).

  The supported fragment is bounded and is defined in
  `02-dsl-semantics.md` §5.1:

      formula ::= always(formula) | eventually(formula) | pred ~> pred | pred

  There is no negation, conjunction or disjunction OF FORMULAS. A formula outside the
  fragment is a compile error naming the unsupported operator — never a silently
  weaker check.
  """
  defmacro temporal(name, opts \\ [], do: block)

  @doc """
  Declare fairness constraints on actions.
  - `:weak` — action must fire if continuously enabled
  - `:strong` — action must fire if repeatedly enabled

  Naming an action that does not exist is a compile error.
  """
  defmacro fairness(type, action_names) when type in [:weak, :strong]
end
```

### There is no `spec do ... end` block

An earlier draft ended each spec with:

```elixir
spec do
  init()
  always(next())
  fair()
end
```

meant to echo TLA+'s `Spec == Init /\ [][Next]_vars /\ Fairness`. It was never given a
meaning, and it cannot usefully have one: `Init` is the `init` blocks, `Next` is the
disjunction of the declared actions, and `Fairness` is the `fairness` declarations. The
block could only restate what is already declared, and a construct that can only agree
with its surroundings is ceremony — with the standing risk that someone writes one that
*disagrees*, and then it must either be ignored or mean something no one specified.

The specification formula is implicit and fixed. If a future need arises to vary it —
a spec with no fairness, or a refinement of another spec — that is a new declaration
with defined semantics, added to `02-dsl-semantics.md` first.

### Helper Functions Available in DSL Blocks

```elixir
defmodule TLA.Spec.Helpers do
  @moduledoc """
  Functions available inside `action`, `init`, and `invariant` blocks.
  """

  # ── Set Operations ──
  def set(), do: MapSet.new()
  def set(elements), do: MapSet.new(elements)
  def put(set, elem), do: MapSet.put(set, elem)
  def delete(set, elem), do: MapSet.delete(set, elem)
  def member?(set, elem), do: MapSet.member?(set, elem)
  def size(set), do: MapSet.size(set)
  def is_set(term), do: is_struct(term, MapSet)
  def union(a, b), do: MapSet.union(a, b)
  def intersection(a, b), do: MapSet.intersection(a, b)
  def difference(a, b), do: MapSet.difference(a, b)
  def subset?(a, b), do: MapSet.subset?(a, b)

  # ── Sequence Operations ──
  def seq(), do: []
  def seq(elements), do: elements
  def append(seq, elem), do: seq ++ [elem]
  def head(seq), do: hd(seq)
  def tail(seq), do: tl(seq)
  def len(seq), do: length(seq)
  def subseq(seq, m, n), do: Enum.slice(seq, m - 1, n - m + 1)

  # ── Function (Map) Operations ──
  def for_each(domain, f), do: Map.new(domain, fn k -> {k, f.(k)} end)
  def update(map, key, f), do: Map.update!(map, key, f)
  def values(map), do: Map.values(map)
  def keys(map), do: Map.keys(map)
  def domain(map), do: MapSet.new(Map.keys(map))

  # ── Arithmetic ──
  def sum(enum), do: Enum.sum(enum)
  def sum(enum, f), do: Enum.map(enum, f) |> Enum.sum()

  # ── Deterministic choice ──
  @doc """
  CHOOSE: deterministically select an element satisfying the predicate.
  Returns the same element for the same set and predicate; raises if none
  satisfies it. This is TLA+'s `CHOOSE` (Hilbert choice).

  It does NOT branch. Nondeterminism comes from `params:` only
  (`02-dsl-semantics.md` §3) — an earlier draft gave this function
  branching semantics, which both contradicts the TLA+ operator it is
  named for and cannot be implemented: a function returning one element
  cannot produce several successors.
  """
  def choose(set, predicate \\ fn _ -> true end)
end
```

---

## Module: `TLA.Spec.Compiled`

The `@before_compile` hook transforms DSL declarations into a compiled specification data structure:

```elixir
defmodule TLA.Spec.Compiled do
  @moduledoc """
  The compiled representation of a TLA.Spec module.
  This is what the model checker operates on.
  """

  @type t :: %__MODULE__{
    module: module(),
    constants: [constant_def()],
    variables: [variable_def()],
    init: [init_fn()],
    actions: [action_def()],
    invariants: [invariant_def()],
    action_properties: [action_property_def()],
    temporals: [temporal_def()],
    fairness: %{weak: [atom()], strong: [atom()]}
  }

  @type constant_def :: %{
    name: atom(),
    opts: keyword()
  }

  @type variable_def :: %{
    name: atom(),
    type: type_expr(),
    opts: keyword()
  }

  @type type_expr ::
    atom()                          # :set, :seq, literal atom
    | Range.t()                     # 0..100
    | [term()]                      # enumeration
    | {atom(), type_expr(), type_expr()}  # {:function, domain, range}

  @type init_fn :: (constants :: map() -> TLA.State.t())

  @type action_def :: %{
    name: atom(),

    # Each param is a function of (constants, pre_state) returning the set to
    # draw from — this is what lets a param depend on the pre-state and so be
    # the DSL's single nondeterminism mechanism
    # (02-dsl-semantics.md §3).
    # Ordered. Each entry is a function of (constants, pre_state, params_bound_so_far)
    # returning the set to draw from — so a later param can be constrained by an
    # earlier one, and nondeterminism has exactly one home
    # (02-dsl-semantics.md §3).
    params: [{atom(), (map(), TLA.State.t(), map() -> Enumerable.t())}],

    guard: (TLA.State.t(), params :: map() -> boolean()),

    # Pure and deterministic in (pre_state, params). This is the property the
    # checker, symmetry canonicalization and Layer 3's refinement check all
    # depend on; nothing in an action body may violate it.
    transition: (TLA.State.t(), params :: map() -> TLA.State.t())
  }

  @type invariant_def :: %{
    name: atom(),
    description: String.t(),
    predicate: (TLA.State.t() -> boolean())
  }

  @type action_property_def :: %{
    name: atom(),
    predicate: (TLA.State.t(), TLA.State.t() -> boolean())
  }

  @type temporal_def :: %{
    name: atom(),
    formula: temporal_formula(),
    opts: keyword()
  }

  # The bounded fragment of 02-dsl-semantics.md §5.1. Deliberately not full
  # LTL: no negation, conjunction or disjunction OF FORMULAS. This fragment is
  # checkable by SCC analysis without building a Buchi automaton, and covers the
  # properties people write. Widening it is a change to §5.1 first.
  @type temporal_formula ::
    {:always, temporal_formula()}
    | {:eventually, temporal_formula()}
    | {:leads_to, predicate(), predicate()}
    | {:predicate, (TLA.State.t() -> boolean())}

  @doc """
  Extract the compiled spec from a module.
  """
  @spec from_module(module()) :: t()
  def from_module(module)
end
```

---

## Module: `TLA.ModelChecker`

The core model checking engine. Performs breadth-first exhaustive exploration of the state space.

### Architecture

```
                    ┌──────────────┐
                    │  TLA.Spec    │
                    │  (compiled)  │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │ ModelChecker  │
                    │   .run/2     │
                    └──────┬───────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
       ┌──────▼──────┐ ┌──▼──────┐ ┌───▼────────┐
       │ StateGraph   │ │ Safety  │ │ Liveness   │
       │ (BFS expand) │ │ Checker │ │ Checker    │
       └──────────────┘ └─────────┘ └────────────┘
              │            │            │
              └────────────┼────────────┘
                           │
                    ┌──────▼───────┐
                    │  TLA.Trace   │
                    │  (if error)  │
                    └──────────────┘
```

### API

```elixir
defmodule TLA.ModelChecker do
  @moduledoc """
  Exhaustive state-space model checker for TLA.Spec modules.
  Analogous to TLC for TLA+.
  """

  @type config :: %{
    constants: map(),                  # constant assignments
    max_states: pos_integer(),         # state limit (default: 1_000_000)
    workers: pos_integer(),            # parallel workers (default: schedulers)
    check_deadlock: boolean(),         # check for states with no successors (default: true)
    check_liveness: boolean(),         # check temporal properties (default: true)
    symmetry: [atom()] | nil,          # symmetric CONSTANT names (see §Symmetry)
    state_constraint: (TLA.State.t() -> boolean()) | nil, # see §State constraints
    fingerprint_bits: 64 | 128         # state identity width (default: 64)
  }

  @type result :: %{
    status: :ok | :violation | :max_states_reached | :error,
    states_found: non_neg_integer(),
    distinct_states: non_neg_integer(),
    transitions: non_neg_integer(),
    duration_ms: non_neg_integer(),
    violation: TLA.Trace.t() | nil,
    warnings: [String.t()],

    # What the run actually exercised (see §Coverage and Vacuity).
    coverage: TLA.Coverage.t(),

    # Soundness margin: expected states lost to fingerprint collisions at the
    # configured width, by the birthday bound. Reported, never assumed.
    fingerprint_bits: pos_integer(),
    collision_estimate: float()
  }

  @doc """
  Run the model checker on a spec module with the given configuration.

  ## Example

      TLA.ModelChecker.run(Specs.TransferProtocol, %{
        constants: %{
          accounts: MapSet.new([:alice, :bob, :carol]),
          max_balance: 5
        },
        max_states: 500_000,
        workers: 4,
        check_liveness: true
      })
  """
  @spec run(module(), config()) :: result()
  def run(spec_module, config)

  @doc """
  Run only safety checking (invariants + action properties).
  Faster than full check — use for rapid iteration.
  """
  @spec check_safety(module(), config()) :: result()
  def check_safety(spec_module, config)

  @doc """
  Run only liveness checking (temporal properties).
  Requires the full state graph to be built first.
  """
  @spec check_liveness(module(), config()) :: result()
  def check_liveness(spec_module, config)

  @doc """
  Run the model checker and return the full state graph.
  Useful for visualization and debugging.
  """
  @spec explore(module(), config()) :: {result(), TLA.StateGraph.t()}
  def explore(spec_module, config)
end
```

### State Graph

```elixir
defmodule TLA.StateGraph do
  @moduledoc """
  The state graph built during model checking. Nodes are states, edges are
  labeled transitions.

  ## Memory model: fingerprints and parent pointers, not states

  The graph does NOT retain the states it has explored. Each visited state
  contributes one fixed-size record:

      fingerprint => {state_id, parent_id, action_name, params}

  A state is materialized only while its successors are being computed, and
  then discarded. When a trace is needed — once, on violation — the path is
  walked back to an initial state through the parent pointers and the states
  are REGENERATED by replaying the recorded actions forward from Init.

  An earlier draft stored `states: %{state_id => TLA.State.t()}` for the whole
  run. At the 10M-state target and roughly 1KB per state that is about 10GB of
  RAM, which puts the checker out of reach of the machines people actually
  have. The record above is on the order of 64 bytes regardless of how large a
  state is, so memory becomes a function of the state COUNT rather than of
  state size — and trace generation, which happens at most once per run, pays
  the replay cost instead. This is the same trade TLC makes.

  The consequence to be aware of: a spec whose actions are expensive to apply
  pays that cost twice on the failing path. That is the right place for the
  cost to fall.
  """

  @type state_id :: non_neg_integer()

  @type node_record :: %{
    parent: state_id() | nil,          # nil for an initial state
    action: atom() | nil,
    params: map() | nil
  }

  @type t :: %__MODULE__{
    nodes: %{state_id() => node_record()},        # ETS-backed; see 06-architecture.md
    fingerprints: %{TLA.Fingerprint.t() => state_id()},
    initial_states: MapSet.t(state_id()),
    deadlocked: MapSet.t(state_id()),
    state_count: non_neg_integer(),
    transition_count: non_neg_integer()
  }

  @doc """
  Register a state by fingerprint, returning its ID and whether it is new.
  The state itself is not retained.
  """
  @spec add_state(t(), TLA.State.t(), parent :: state_id() | nil, atom(), map()) ::
    {t(), state_id(), :new | :existing}
  def add_state(graph, state, parent, action, params)

  @doc "Successor IDs of a state (derived from the parent index)."
  @spec successors(t(), state_id()) :: [{atom(), state_id()}]
  def successors(graph, state_id)

  @doc """
  The action path from an initial state to the target, walked through parent
  pointers. `TLA.Trace` replays this to regenerate the states themselves.
  """
  @spec path_to(t(), state_id()) :: [{atom(), map()}]
  def path_to(graph, target)

  @doc "All strongly connected components (used for liveness checking)."
  @spec sccs(t()) :: [[state_id()]]
  def sccs(graph)

  @doc "Export as DOT for Graphviz. Regenerates states for node labels."
  @spec to_dot(t(), keyword()) :: String.t()
  def to_dot(graph, opts \\ [])

  @doc "Export as JSON for tooling and editor integration."
  @spec to_json(t()) :: String.t()
  def to_json(graph)
end
```

---

## State-space reduction

Without reduction, specs of the size people actually write do not finish. Three
mechanisms, in order of cost to implement and value delivered.

### State constraints

`config.state_constraint` is a predicate on states; a state that fails it is not
expanded. This bounds an otherwise-unbounded variable (a growing sequence, an
unbounded counter) without changing the spec:

```elixir
state_constraint: fn s -> length(s.log) <= 5 end
```

A constrained run is **not** an exhaustive one, and the result says so: the status
carries `:constrained` and the coverage report names the constraint. A tool that
lets a bound quietly masquerade as a proof is worse than no tool.

### Symmetry

`config.symmetry` names **constants** whose elements are interchangeable — process
IDs, account names, replica IDs. For a symmetric constant set of size *n*, states
that differ only by a permutation of those elements are the same state, so the
reachable space shrinks by up to a factor of *n!*. This is the difference between
tractable and not for exactly the specs ExTLA is for.

The mechanism: before fingerprinting, the state is put in a **canonical form** by
choosing the permutation of each symmetric set that minimizes the state's canonical
binary encoding (`TLA.Fingerprint.canonical/1`). Two symmetric states then share a
fingerprint by construction.

Symmetry is **unsound in the presence of a spec that can distinguish the elements**
— an invariant mentioning `^accounts |> Enum.at(0)`, or a constant used as an
ordering key. The compiler rejects a symmetry declaration when any declared
constant in the set is used in an order-dependent position, rather than silently
under-exploring.

### View abstraction

`config.view` (optional) is a function from a state to the projection that
determines its identity, so states differing only outside the projection collapse.
TLC's `VIEW`. Powerful and easy to get wrong: an unsound view silently drops
distinctions the properties depend on. Specified here, but deferred past v1
(`06-architecture.md` §Implementation Phases).

**Partial order reduction is a non-goal.** It is where most of the research
complexity in this space lives, and Concuerror already does it at the level where
it pays off (`00-prior-art.md`).

---

## Module: `TLA.ModelChecker.Safety`

```elixir
defmodule TLA.ModelChecker.Safety do
  @moduledoc """
  Safety property checking: invariants and action properties.
  Checked incrementally during state exploration.
  """

  @doc """
  Check all invariants against a single state.
  Returns {:ok, state} or {:violation, invariant_name, state}.
  """
  @spec check_invariants(TLA.Spec.Compiled.t(), TLA.State.t()) ::
    :ok | {:violation, atom(), TLA.State.t()}
  def check_invariants(spec, state)

  @doc """
  Check all action properties against a transition.
  """
  @spec check_action_properties(TLA.Spec.Compiled.t(), TLA.State.t(), TLA.State.t()) ::
    :ok | {:violation, atom(), TLA.State.t(), TLA.State.t()}
  def check_action_properties(spec, old_state, new_state)

  @doc """
  Check for deadlock: a non-terminal state with no enabled actions.
  """
  @spec check_deadlock(TLA.Spec.Compiled.t(), TLA.State.t()) :: :ok | :deadlocked
  def check_deadlock(spec, state)
end
```

---

## Module: `TLA.ModelChecker.Liveness`

```elixir
defmodule TLA.ModelChecker.Liveness do
  @moduledoc """
  Liveness property checking using the state graph.

  Liveness violations manifest as "bad cycles" — strongly connected
  components in the state graph where a required condition never holds.
  This implements a variant of the Emerson-Lei algorithm.

  Liveness checking is significantly more expensive than safety checking.
  """

  @doc """
  Check all temporal properties against the completed state graph.
  Returns :ok or a lasso-shaped counterexample (prefix + cycle).
  """
  @spec check(TLA.Spec.Compiled.t(), TLA.StateGraph.t()) ::
    :ok | {:violation, atom(), TLA.Trace.lasso()}
  def check(spec, graph)

  @doc """
  Check weak fairness constraints.
  An action with weak fairness must not be continuously enabled
  without being taken in any SCC.
  """
  @spec check_weak_fairness(TLA.Spec.Compiled.t(), TLA.StateGraph.t(), atom()) ::
    :ok | {:violation, TLA.Trace.lasso()}
  def check_weak_fairness(spec, graph, action_name)

  @doc """
  Check strong fairness constraints.
  An action with strong fairness must not be infinitely often enabled
  without being taken in any SCC.
  """
  @spec check_strong_fairness(TLA.Spec.Compiled.t(), TLA.StateGraph.t(), atom()) ::
    :ok | {:violation, TLA.Trace.lasso()}
  def check_strong_fairness(spec, graph, action_name)
end
```

---

## Module: `TLA.Coverage` — what the run actually exercised

A green check mark is only as good as what was behind it. Three ways a run can
report success while having verified almost nothing:

- **An action that was never enabled.** A typo in a guard (`status == :Idle`)
  turns an action off entirely. The spec still model-checks — it is simply a
  *weaker* spec now, and a weaker spec passes more easily.
- **A property satisfied vacuously.** `always(P ~> Q)` where `P` never holds in
  any reachable state is trivially true and says nothing about `Q`.
- **An invariant that was never at risk.** An invariant no reachable state ever
  came close to falsifying is indistinguishable from `true`.

None of these are exotic; they are the routine failure mode of specification
work, and every one is a cheap read off the state graph the checker already
built. Reporting them is not a nice-to-have — it is the difference between a
verdict and a claim.

```elixir
defmodule TLA.Coverage do
  @moduledoc """
  What a model-checking run exercised. Computed from the completed state graph;
  no additional exploration.
  """

  @type t :: %__MODULE__{
    # Per action: how many states it generated, and how many were new.
    # A zero entry is an action never enabled in any reachable state.
    actions: %{atom() => %{enabled_in: non_neg_integer(),
                           states_generated: non_neg_integer(),
                           distinct_generated: non_neg_integer()}},

    # Actions with `enabled_in: 0`. Almost always a guard bug.
    never_enabled: [atom()],

    # Per invariant: states in which it was evaluated, and states in which it
    # was "close" — its top-level conjunction had at least one false conjunct
    # without the whole being false. A never-close invariant is suspect.
    invariants: %{atom() => %{evaluated_in: non_neg_integer(),
                              near_misses: non_neg_integer()}},

    # Temporal properties whose antecedent never held anywhere.
    vacuous: [%{property: atom(), reason: :antecedent_never_held
                                        | :consequent_always_held}],

    # Params combinations that no reachable state ever admitted.
    unreached_params: %{atom() => [map()]},

    # Set when `state_constraint` or `max_states` bounded the run — the
    # coverage numbers are then a lower bound, not a census.
    bounded_by: :none | :state_constraint | :max_states
  }

  @doc "Compute coverage from a completed run."
  @spec compute(TLA.Spec.Compiled.t(), TLA.StateGraph.t()) :: t()
  def compute(spec, graph)

  @doc """
  Render for terminal output. Silent when everything was exercised; loud about
  never-enabled actions and vacuous properties, which are warnings by default
  and errors under `--strict-coverage`.
  """
  @spec format(t()) :: String.t()
  def format(coverage)
end
```

### Example coverage output

```
--- COVERAGE: Specs.TransferProtocol -------------------------------

Actions            enabled in      states     distinct
  begin_transfer          1,204      3,612        3,612
  complete_transfer       3,612      3,612        2,408
  fail_transfer           3,612      3,612          802
  reset                   1,204      1,204            1
  cancel_transfer             0          0            0   <-- NEVER ENABLED

Invariants                evaluated   near-miss
  type_ok                     8,431           0   <-- never at risk
  conservation_of_money       8,431         802
  no_negative_balance         8,431         119

Properties
  no_stuck_pending          checked
  error_recovery            VACUOUS: `status == :error` never held

2 warnings. Re-run with --strict-coverage to fail on these.
--------------------------------------------------------------------
```

`cancel_transfer` never firing is the bug this report exists to find: the spec
verified, and it verified a system with no cancellation in it.

---

## Module: `TLA.Trace`

Counterexample trace generation.

```elixir
defmodule TLA.Trace do
  @moduledoc """
  When the model checker finds a violation, it produces a trace:
  the shortest sequence of states from Init to the violating state.

  For liveness violations, the trace is a "lasso": a prefix leading
  to a cycle, plus the cycle itself.
  """

  @type t :: %__MODULE__{
    type: :safety | :liveness | :deadlock,
    property: atom(),
    message: String.t(),
    states: [TLA.State.t()],
    actions: [atom()],               # action taken at each step
    length: non_neg_integer()
  }

  @type lasso :: %{
    prefix: t(),
    cycle: t()
  }

  @doc "Generate the shortest trace from an initial state to the target."
  @spec generate(TLA.StateGraph.t(), TLA.StateGraph.state_id()) :: t()
  def generate(graph, target_state_id)

  @doc "Generate a lasso trace for a liveness violation."
  @spec generate_lasso(TLA.StateGraph.t(), [TLA.StateGraph.state_id()]) :: lasso()
  def generate_lasso(graph, scc)

  @doc """
  Pretty-print a trace for terminal output.
  Shows each state with changed variables highlighted.
  """
  @spec format(t() | lasso()) :: String.t()
  def format(trace)

  @doc """
  Export trace as a sequence of state diffs (for programmatic consumption).
  """
  @spec to_diffs(t()) :: [%{action: atom(), changed: map(), full_state: map()}]
  def to_diffs(trace)
end
```

### Example Trace Output

```
═══ INVARIANT VIOLATION: conservation_of_money ════════════════════

State 1 (Init):
  balances = %{alice: 5, bob: 5}
  status   = :idle
  pending  = #MapSet<[]>
  log      = []

── begin_transfer(from: alice, to: bob, amount: 3) ──────────────

State 2:
  balances = %{alice: 2, bob: 5}        ← changed
  status   = :transferring              ← changed
  pending  = #MapSet<[{:bob, 3}]>       ← changed
  log      = []

── fail_transfer ────────────────────────────────────────────────

State 3 [VIOLATION]:
  balances = %{alice: 2, bob: 5}
  status   = :error                     ← changed
  pending  = #MapSet<[]>                ← changed  ⚠ money lost!
  log      = []

  conservation_of_money: expected total = 10, got 7
═══════════════════════════════════════════════════════════════════
```

---

## Module: `TLA.ModelChecker.Parallel`

Parallel state exploration using BEAM concurrency.

```elixir
defmodule TLA.ModelChecker.Parallel do
  @moduledoc """
  Distributes state exploration across multiple BEAM processes.
  Uses a shared ETS table for the state graph and a work-stealing
  queue for BFS frontier management.
  """

  @doc """
  Run parallel BFS exploration.

  Architecture:
  - 1 coordinator process manages the frontier queue
  - N worker processes pull states, compute successors, check safety
  - State graph stored in ETS (concurrent read/write)
  - Fingerprint table in ETS for O(1) duplicate detection
  - Workers report violations immediately; coordinator halts all workers
  """
  @spec explore(TLA.Spec.Compiled.t(), TLA.ModelChecker.config()) ::
    {TLA.ModelChecker.result(), TLA.StateGraph.t()}
  def explore(spec, config)
end
```

---

## Mix Integration

### Mix Task: `mix tla.check`

```elixir
defmodule Mix.Tasks.Tla.Check do
  @moduledoc """
  Run model checking on TLA.Spec modules.

  ## Usage

      mix tla.check                                 # every spec in the project
      mix tla.check Specs.TransferProtocol
      mix tla.check Specs.TransferProtocol --max-states 100000 --workers 8
      mix tla.check Specs.TransferProtocol --safety-only
      mix tla.check Specs.TransferProtocol --graph dot --output transfer.dot

  ## Options affecting the VERDICT

      --strict-coverage    Treat a never-enabled action or a vacuous property
                           as a failure rather than a warning.
      --allow-incomplete   Exit 0 even if the state limit was reached.
                           Off by default: see below.
      --fingerprint-bits   64 (default) or 128.

  ## Exit codes

      0  verified
      1  violation (a counterexample was printed)
      2  incomplete — the state limit or a state constraint bounded the run,
         so the spec was NOT verified
      3  coverage failure (with --strict-coverage)

  Exit code 2 exists because "we ran out of budget" is not "it holds", and a
  tool that returns them as the same number teaches its users to believe
  something false.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args)
end
```

Machine-readable output (`--format json`) carries the full result, coverage
report and counterexample, so editors and the reporting tooling read structured
data rather than parsing the human rendering.

### ExUnit Integration

```elixir
defmodule TLA.Spec.Test do
  @moduledoc """
  ExUnit helpers for model checking in tests.
  """

  @doc """
  Assert that a spec passes model checking with the given constants.

  ## Options
  - `allow_incomplete: true` — pass even if the state limit was reached.
    Default `false`.
  - `strict_coverage: true` — fail on a never-enabled action or a vacuous
    property. Default `false` (they are reported, not fatal).
  """
  defmacro assert_spec(spec_module, config) do
    quote do
      result = TLA.ModelChecker.run(unquote(spec_module), unquote(config))

      case result.status do
        :ok ->
          TLA.Coverage.warn_unless_clean(result.coverage, unquote(config))
          :ok

        :violation ->
          flunk("""
          Model checking violation in #{inspect(unquote(spec_module))}:

          #{TLA.Trace.format(result.violation)}
          """)

        :max_states_reached ->
          # NOT a pass. An earlier draft warned here and let the test proceed,
          # which is how a suite goes green on a spec that was never verified —
          # the single most misleading thing this library could do.
          flunk("""
          Model checking did NOT complete for #{inspect(unquote(spec_module))}.

          Explored #{result.distinct_states} distinct states and hit the limit
          of #{result.states_found}. The spec is UNVERIFIED, not verified.

          Reduce the constants, add a :state_constraint, raise :max_states, or
          pass `allow_incomplete: true` to accept a bounded run deliberately.
          """)
      end
    end
  end
end

# Usage in tests:
defmodule Specs.TransferProtocolTest do
  use ExUnit.Case
  import TLA.Spec.Test

  @tag timeout: 60_000
  test "transfer protocol satisfies all properties" do
    assert_spec Specs.TransferProtocol, %{
      constants: %{accounts: MapSet.new([:alice, :bob]), max_balance: 3},
      check_liveness: true,
      strict_coverage: true
    }
  end

  @tag timeout: 120_000
  test "transfer protocol scales to 3 accounts" do
    assert_spec Specs.TransferProtocol, %{
      constants: %{accounts: MapSet.new([:alice, :bob, :carol]), max_balance: 2},
      symmetry: [:accounts],     # 3! fewer states; see §Symmetry
      check_liveness: false
    }
  end
end
```

---

## Differential testing against TLC

A model checker with no oracle cannot be trusted, and ExTLA has one available for
free: TLC, plus the classic specs everyone has already written.

The acceptance criterion for the checker is that for each spec in a corpus
maintained under `test/differential/` — die hard, two-phase commit, the
distributed lock and Raft election from `07-examples.md`, Paxos — ExTLA and TLC agree
on:

1. the number of **distinct reachable states**,
2. whether each invariant holds, and
3. the **length** of the shortest counterexample where one exists.

A disagreement on (1) means ExTLA's successor generation or state identity is
wrong, and it is the single most valuable signal available during development —
far more so than any unit test of the BFS loop. This is a v1 deliverable, not a
later nicety (`06-architecture.md` §Implementation Phases).
