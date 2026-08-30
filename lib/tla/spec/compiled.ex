defmodule TLA.Spec.Compiled do
  @moduledoc """
  The compiled representation of a `TLA.Spec` module.
  This is what the model checker operates on.

  Every function in here is closed over nothing but its arguments, and every one
  takes the constant assignments as its first argument. An action's `guard` and
  `transition` are pure functions of `(constants, pre_state, params)`, and each
  param generator is a pure function of `(constants, pre_state, params bound so
  far)` — the property that makes successor generation, symmetry canonicalization
  and Layer 3's refinement check all straightforward (`02-dsl-semantics.md` §3).

  ## Why constants are an argument

  An earlier draft of this type gave `init_fn` and the param generators the
  constants but gave guards, transitions and predicates only the state. Every
  block may reference `^constants` (§1.1) — the worked example's
  `conservation_of_money` compares against `^max_balance` — so those functions
  had no way to evaluate what the DSL lets an author write. Threading constants
  uniformly is the smallest fix that keeps them out of the state, where they
  would be fingerprinted and would inflate the state space by a value that never
  changes.
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
          terminals: [terminal_def()],
          fairness: [fairness_def()]
        }

  defstruct module: nil,
            constants: [],
            variables: [],
            init: [],
            actions: [],
            invariants: [],
            action_properties: [],
            temporals: [],
            terminals: [],
            fairness: []

  @type terminal_def :: %{name: atom(), predicate: predicate()}

  # `per: []` is whole-action fairness. `per: [:p]` is one constraint per binding
  # of `p`, expanded once the constants are known (02-dsl-semantics.md §5.2).
  @type fairness_def :: %{kind: :weak | :strong, action: atom(), per: [atom()]}

  @type constant_def :: %{name: atom(), opts: keyword()}

  @type variable_def :: %{name: atom(), type: type_expr(), opts: keyword()}

  # Stored QUOTED and resolved at model-check time against the constant
  # assignments: nearly every real type mentions a constant (`0..^max_val`,
  # `[^servers ~> :set]`) that has no value when the module compiles. The grammar
  # is 02-dsl-semantics.md §1.5; the resolved type is checked as the implicit
  # invariant `:type_ok`.
  @type type_expr :: Macro.t()

  @type constants :: map()

  @type init_fn :: (constants() -> TLA.State.t())

  # Where a param's set comes from. Recorded because §5.2's per-binding fairness
  # may only quantify over a param drawn from a constant or a literal — the set a
  # state function returns changes from state to state, so there is no fixed
  # collection of bindings to attach one constraint each to. Without this field
  # the §7 diagnostic "fairness over a state-drawn param" cannot be produced.
  @type param_source :: :constant | :literal | :state

  @type action_def :: %{
          name: atom(),

          # Ordered. Each entry is a function of (constants, pre_state,
          # params_bound_so_far) returning the set to draw from — so a later param
          # can be constrained by an earlier one, and nondeterminism has exactly
          # one home (02-dsl-semantics.md §3).
          params: [{atom(), (constants(), TLA.State.t(), map() -> Enumerable.t())}],
          param_sources: [{atom(), param_source()}],
          guard: (constants(), TLA.State.t(), params :: map() -> boolean()),

          # Pure and deterministic in (pre_state, params). This is the property the
          # checker, symmetry canonicalization and Layer 3's refinement check all
          # depend on; nothing in an action body may violate it.
          transition: (constants(), TLA.State.t(), params :: map() -> TLA.State.t())
        }

  @type invariant_def :: %{
          name: atom(),
          description: String.t(),
          predicate: predicate()
        }

  @type action_property_def :: %{
          name: atom(),
          description: String.t(),
          predicate: (constants(), old :: TLA.State.t(), new :: TLA.State.t() -> boolean())
        }

  # The formula is a function OF THE CONSTANTS, not a value: a `for_all` ranges
  # over a constant set and every predicate inside it may mention `^constants`,
  # neither of which has a value until a run assigns one.
  @type temporal_def :: %{
          name: atom(),
          formula: (constants() -> temporal_formula()),
          opts: keyword()
        }

  @type predicate :: (constants(), TLA.State.t() -> boolean())

  # The bounded fragment of 02-dsl-semantics.md §5.1. Deliberately not full LTL:
  # no negation, conjunction or disjunction OF FORMULAS. This fragment is
  # checkable by SCC analysis without building a Buchi automaton, and covers the
  # properties people write. Widening it is a change to §5.1 first.
  @type temporal_formula ::
          {:always, temporal_formula()}
          | {:eventually, temporal_formula()}
          | {:leads_to, predicate(), predicate()}
          | {:predicate, predicate()}
          # ∀ over a constant: the set is resolved at check time, the body
          # instantiated once per element, and each instance checked independently.
          | {:for_all, (constants() -> Enumerable.t()), (term() -> temporal_formula())}

  @doc """
  Extract the compiled spec from a module.

  Raises `ArgumentError` for a module that is not a spec, rather than letting an
  `UndefinedFunctionError` surface from three frames down.
  """
  @spec from_module(module()) :: t()
  def from_module(module) do
    Code.ensure_loaded(module)

    if function_exported?(module, :__tla_spec__, 0) do
      module.__tla_spec__()
    else
      raise ArgumentError,
            "#{inspect(module)} is not a TLA spec: it does not `use TLA.Spec`."
    end
  end

  @doc """
  The declared variable names, in declaration order.
  """
  @spec variable_names(t()) :: [atom()]
  def variable_names(%__MODULE__{variables: variables}), do: Enum.map(variables, & &1.name)

  @doc """
  The declared constant names, in declaration order.
  """
  @spec constant_names(t()) :: [atom()]
  def constant_names(%__MODULE__{constants: constants}), do: Enum.map(constants, & &1.name)

  @doc """
  The action with the given name, or `nil`.
  """
  @spec action(t(), atom()) :: action_def() | nil
  def action(%__MODULE__{actions: actions}, name), do: Enum.find(actions, &(&1.name == name))
end
