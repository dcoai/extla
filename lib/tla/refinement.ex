defmodule TLA.Refinement do
  @moduledoc """
  The formal relationship between an abstract specification and a concrete implementation.

  A refinement mapping is a function from concrete states to abstract states such that the
  abstract behaviour obtained by mapping each concrete state satisfies the abstract spec.
  It is the mathematical content of implementation verification — but only when the
  **steps** are checked against the spec's actions, not merely the states against its
  invariants (`05-layer3-conformance.md` §What conformance means here).

  ## The three callbacks

      abstract(concrete_state)            what the spec's variables mean here
      abstract_action(message)            which spec action a message is meant to be
      concrete_message(action, params)    the inverse: what message causes that action

  `abstract_action/1` is required rather than optional. Without a named action there is
  nothing to check the step against, and the layer degrades to invariant checking on a
  projection — which passes every implementation bug that reaches a legal-looking state by
  an illegal route. `:unmapped` is a positive claim that the message must **not** move the
  abstract state, and it is checked as one.

  `concrete_message/2` is optional. Without it an implementation can still be *checked* as
  it runs, but it cannot be *driven* from the spec, which forgoes `TLA.Replay` and most of
  what Layer 3 is for.

  ## What `validate!/2` establishes, and what it does not

  §05 lists five rules. Three are decidable where `validate!/2` runs and two are not, and
  saying which is which is the point — a validator that claims a check it cannot perform
  is worse than one that states its limits (the same shape as `08-decisions.md` D-17).

  Decided at compile time:

  - `abstract_action/1` is **total**, established by probe: a term the implementation
    cannot have anticipated must come back `:unmapped` rather than raising inside a
    callback wrapper.
  - `concrete_message/2` **round-trips**, where it is defined and the constants are known.
  - every spec action is **named** by some clause — but only where `concrete_message/2`
    exists to enumerate them with. Elsewhere it is left to `TLA.Coverage`'s account of
    what a run actually exercised, which is where "this action never happened" belongs.

  Left to runtime, because there is no concrete state at compile time to map:

  - `abstract/1` returns exactly the spec's variables, and
  - every value it returns is a permitted state term (`02-dsl-semantics.md` §6).

  `abstract!/2` checks both on every mapping. It is a `Map.keys` comparison and a
  `TLA.State.validate!/1`, cheaper than the invariants evaluated beside it.

  Purity of `abstract/1` is **not** checked. An earlier draft of §05 claimed it was; that
  is not decidable, and an impure mapping surfaces as a `:diverged` step instead. It is a
  documented obligation on the author.
  """

  alias TLA.{Spec, State}

  @doc "Concrete state -> abstract state. Must be pure."
  @callback abstract(concrete_state :: map()) :: State.t()

  @doc """
  Concrete message -> the spec action it is meant to be, or `:unmapped`.
  """
  @callback abstract_action(message :: term()) :: {atom(), map()} | :unmapped

  @doc """
  Abstract action and params -> a concrete message that should cause it.
  """
  @callback concrete_message(action :: atom(), params :: map()) :: term()

  @optional_callbacks [concrete_message: 2]

  defmodule Error do
    @moduledoc """
    A refinement mapping that does not hold up: at compile time from `validate!/2`, or at
    runtime from `abstract!/2` when a mapping produces something that is not a state of
    the spec.
    """
    defexception [:message]
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour TLA.Refinement
    end
  end

  @doc """
  Verify that a refinement mapping is well-formed against a spec.

  Returns the rules it could not decide, so a caller can say so rather than imply
  everything was checked. Raises `TLA.Refinement.Error` on anything it can decide and
  finds wrong.
  """
  @spec validate!(module(), module() | Spec.Compiled.t(), map() | nil) ::
          {:ok, deferred :: [String.t()]} | no_return()
  def validate!(refinement, spec, constants \\ nil)

  def validate!(refinement, spec_module, constants) when is_atom(spec_module) do
    validate!(refinement, Spec.Compiled.from_module(spec_module), constants)
  end

  def validate!(refinement, %Spec.Compiled{} = spec, constants) do
    Code.ensure_compiled!(refinement)
    required_callbacks!(refinement)

    total!(refinement)

    constants = constants || Spec.Compiled.default_constants(spec)

    deferred =
      [
        "`abstract/1` returns exactly #{inspect(Enum.map(spec.variables, & &1.name))}",
        "every mapped value is a permitted state term (02-dsl-semantics.md §6)"
      ]

    if function_exported?(refinement, :concrete_message, 2) do
      # Named first: "no message produces this action" is a more useful thing to be told
      # than "this action does not round-trip", and it is the same fault.
      names_every_action!(refinement, spec, constants)
      round_trips!(refinement, spec, constants)
      {:ok, deferred}
    else
      {:ok,
       deferred ++
         [
           "every spec action is named by an `abstract_action/1` clause — no " <>
             "`concrete_message/2` to enumerate them with, so coverage reports it instead"
         ]}
    end
  end

  @doc """
  Map a concrete state, checking the two rules that need a state to check.

  The keys must be exactly the spec's variables: a missing one leaves the abstract state
  short of a variable every predicate reads, and an extra one is a key the spec never
  declared, which would make the state unequal to anything an action produces and turn
  every step into a `:diverged`. Both are named here rather than diagnosed three frames
  later.
  """
  @spec abstract!(module(), Spec.Compiled.t(), map()) :: State.t() | no_return()
  def abstract!(refinement, spec, concrete) do
    abstract = refinement.abstract(concrete)

    unless is_map(abstract) do
      raise Error,
        message:
          "#{inspect(refinement)}.abstract/1 returned #{inspect(abstract)}. A refinement " <>
            "mapping produces a state, which is a map of the spec's variables."
    end

    declared = MapSet.new(spec.variables, & &1.name)
    actual = MapSet.new(Map.keys(abstract))
    missing = MapSet.difference(declared, actual)
    extra = MapSet.difference(actual, declared)

    if MapSet.size(missing) == 0 and MapSet.size(extra) == 0 do
      State.validate!(abstract)
    else
      raise Error,
        message:
          "#{inspect(refinement)}.abstract/1 does not produce the spec's variables." <>
            missing_line(missing) <>
            extra_line(extra) <>
            "\n\nThe abstract state has to have exactly the variables the spec declares: " <>
            "one short and every predicate reading it fails, one extra and it is unequal " <>
            "to anything an action produces, so every step diverges."
    end
  end

  defp missing_line(missing) do
    if MapSet.size(missing) == 0,
      do: "",
      else: "\n  missing: #{inspect(Enum.sort(missing))}"
  end

  defp extra_line(extra) do
    if MapSet.size(extra) == 0,
      do: "",
      else: "\n  extra:   #{inspect(Enum.sort(extra))}"
  end

  # ── Compile-time rules ──────────────────────────────────────────────────────

  defp required_callbacks!(refinement) do
    missing =
      for {name, arity} <- [abstract: 1, abstract_action: 1],
          not function_exported?(refinement, name, arity),
          do: "#{name}/#{arity}"

    if missing != [] do
      raise Error,
        message:
          "#{inspect(refinement)} is a refinement mapping and does not define " <>
            "#{Enum.join(missing, " or ")}. `abstract_action/1` is required rather than " <>
            "optional: without a named action there is no step to check, and the layer " <>
            "degrades to invariant checking on a projection."
    end
  end

  # A probe, not a proof. A mapping without a catch-all clause raises inside a callback
  # wrapper on the first message nobody thought of, which is a crash in the user's
  # process rather than a diagnosis — so it is worth finding at compile time even by a
  # method that cannot be exhaustive.
  # Deliberately something no implementation would pattern-match on.
  @probe {:__tla_refinement_probe__, :no_clause_should_match_this}

  defp total!(refinement) do
    case refinement.abstract_action(@probe) do
      :unmapped ->
        :ok

      other ->
        raise Error,
          message:
            "#{inspect(refinement)}.abstract_action/1 mapped a probe term to " <>
              "#{inspect(other)}. A catch-all clause must return `:unmapped`, which is " <>
              "the claim that the message does not move the abstract state."
    end
  rescue
    FunctionClauseError ->
      reraise Error,
              [
                message:
                  "#{inspect(refinement)}.abstract_action/1 is not total: it raised on a " <>
                    "term it had no clause for. Add `def abstract_action(_), do: " <>
                    ":unmapped`. Without it the first unanticipated message crashes inside " <>
                    "a callback wrapper instead of being reported as a message the spec " <>
                    "does not model."
              ],
              __STACKTRACE__
  end

  defp round_trips!(refinement, spec, constants) do
    for action <- spec.actions, params <- sample_params(spec, action, constants) do
      expected = action.name
      message = refinement.concrete_message(expected, params)

      case refinement.abstract_action(message) do
        # `names_every_action!/3` owns this one, and has already run.
        :unmapped ->
          :ok

        {^expected, mapped} ->
          disagreements =
            for {key, value} <- mapped, Map.has_key?(params, key), params[key] != value, do: key

          if disagreements != [] do
            raise Error,
              message:
                "#{inspect(refinement)} does not round-trip #{action.name}: " <>
                  "`concrete_message(#{inspect(action.name)}, #{inspect(params)})` is " <>
                  "#{inspect(message)}, which maps back with " <>
                  "#{inspect(Enum.sort(disagreements))} disagreeing. A mapping that names " <>
                  "a param must name it correctly; one that omits it is deferring to the " <>
                  "search in `check_step!/5`, which is allowed."
          end

        other ->
          raise Error,
            message:
              "#{inspect(refinement)} does not round-trip #{action.name}: " <>
                "`concrete_message(#{inspect(action.name)}, #{inspect(params)})` is " <>
                "#{inspect(message)}, which `abstract_action/1` maps to #{inspect(other)}."
      end
    end

    :ok
  end

  defp names_every_action!(refinement, spec, constants) do
    unnamed =
      for action <- spec.actions,
          params <- Enum.take(sample_params(spec, action, constants), 1),
          refinement.abstract_action(refinement.concrete_message(action.name, params)) ==
            :unmapped,
          do: action.name

    if unnamed != [] do
      raise Error,
        message:
          "#{inspect(refinement)} names no message for " <>
            "#{inspect(Enum.sort(unnamed))}. An action the mapping can never produce is " <>
            "dead in this implementation: either the spec models something the code does " <>
            "not do, or a clause is missing."
    end

    :ok
  end

  # One binding per action, drawn on an initial state — enough to round-trip a mapping
  # without exploring the state space, which is `mix tla.check`'s job and not this one's.
  defp sample_params(spec, action, constants) do
    case initial_state(spec, constants) do
      nil ->
        [%{}]

      state ->
        case TLA.ModelChecker.bindings(action, constants, state) do
          [] -> [%{}]
          bound -> Enum.take(bound, 3)
        end
    end
  end

  # One initial state, for drawing sample bindings from. `nil` when the spec has a
  # constant this call was given no value for — a mapping can still be validated on the
  # empty binding, and saying less is better than guessing a value the spec never had.
  defp initial_state(spec, constants) do
    if spec.init != [] and
         Enum.all?(Spec.Compiled.constant_names(spec), &is_map_key(constants, &1)) do
      spec.init |> hd() |> apply([constants])
    end
  end
end
