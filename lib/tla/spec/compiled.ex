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

  @doc """
  The constant assignments declared with `default:`, for a run that was given
  none of its own.
  """
  def default_constants(%__MODULE__{constants: constants}) do
    for %{name: name, opts: opts} <- constants,
        Keyword.has_key?(opts, :default),
        into: %{},
        do: {name, Keyword.fetch!(opts, :default)}
  end

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
          predicate: predicate(),

          # A state in which the invariant held only through its non-trivial
          # branch — the left disjunct of a top-level `or` was false, so the
          # right one had to carry it. `nil` when the invariant has no such
          # shape, which the coverage report renders as "not measured" rather
          # than as zero: zero near misses is a finding, and not having looked
          # is not.
          near_miss: predicate() | nil
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
  # A temporal formula's predicates take only the state: the constants were captured when
  # `temporal_def.formula` was applied to them, which is what makes a formula a function
  # of the constants in the first place. An invariant's `predicate()` takes both, because
  # an invariant is not rebuilt per run.
  @type state_predicate :: (TLA.State.t() -> boolean())

  @type temporal_formula ::
          {:always, temporal_formula()}
          | {:eventually, temporal_formula()}
          | {:leads_to, state_predicate(), state_predicate()}
          | {:predicate, state_predicate()}
          # ∀ over a constant: the set is resolved at check time, the body
          # instantiated once per element, and each instance checked independently.
          | {:for_all, (constants() -> Enumerable.t()), (term() -> temporal_formula())}

  @doc """
  Extract the compiled spec from a module.

  Raises `ArgumentError` for a module that is not a spec, rather than letting an
  `UndefinedFunctionError` surface from three frames down.
  """
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
  The constant assignments for a run, from application config over the declared defaults.

  `{:error, missing}` names the constants nothing assigned, rather than letting a run
  proceed on a spec with holes in it. Both `mix tla.check` and Layer 3's conformance
  checking resolve constants HERE rather than each their own way: a specification model
  checked with one assignment and an implementation checked against another are two
  different specifications, and a verdict from each is not a verdict about the same thing.

  A configured key the spec does not declare **raises** rather than being merged and
  ignored. `constants: %{maxx: 100}` against `constant :max, default: 3` used to resolve
  to `%{max: 3, maxx: 100}`: the override the author wrote was dropped, the run used the
  default, and nothing said so (#193) — the same defect as a selection naming a
  declaration that does not exist, through the one door that fix did not cover. It is a
  raise and not a second `{:error, _}` shape because a missing assignment is a legitimate
  state of a spec (one meant to be configured per run), while a key naming nothing is a
  defect in the configuration, and every caller should refuse it the same way.
  """
  def resolve_constants(%__MODULE__{} = spec) do
    configured =
      :extla
      |> Application.get_env(spec.module, [])
      |> Keyword.get(:constants, %{})
      |> Map.new()

    declared = constant_names(spec)
    reject_undeclared!(spec, Map.keys(configured) -- declared, declared)

    constants = Map.merge(default_constants(spec), configured)

    case declared -- Map.keys(constants) do
      [] -> {:ok, constants}
      missing -> {:error, missing}
    end
  end

  defp reject_undeclared!(_spec, [], _declared), do: :ok

  defp reject_undeclared!(spec, undeclared, declared) do
    raise ArgumentError, """
    config for #{inspect(spec.module)} assigns #{Enum.map_join(undeclared, ", ", &inspect/1)}, \
    which the spec does not declare as a constant.

    Declared: #{declared |> Enum.sort() |> Enum.map_join(", ", &inspect/1)}.

    An assignment to a name the spec does not have is read by nothing: the run would
    proceed on the declared default, or refuse for want of an assignment, while the config
    says otherwise. Check the spelling in
    `config :extla, #{inspect(spec.module)}, constants: %{…}`.
    """
  end

  @doc """
  The declared variable names, in declaration order.
  """
  def variable_names(%__MODULE__{variables: variables}), do: Enum.map(variables, & &1.name)

  @doc """
  The declared constant names, in declaration order.
  """
  def constant_names(%__MODULE__{constants: constants}), do: Enum.map(constants, & &1.name)

  @doc """
  The action with the given name, or `nil`.
  """
  def action(%__MODULE__{actions: actions}, name), do: Enum.find(actions, &(&1.name == name))
end
