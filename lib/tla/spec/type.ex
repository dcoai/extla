defmodule TLA.Spec.Type do
  @moduledoc """
  The `type:` annotation grammar of `02-dsl-semantics.md` §1.5.

  Type expressions are a small language of their own, distinct from the block
  DSL, and they are **stored quoted**: nearly every useful type mentions a
  constant (`0..^max_val`, `[^servers ~> :set]`) that has no value when the
  module compiles (D-19). This module checks the shape at compile time so an
  ill-formed type is a diagnostic rather than a crash halfway through a
  model-checking run; resolution against the constant assignments happens later,
  in the checker, where the implicit `:type_ok` invariant is evaluated.

  | Form | Meaning |
  |---|---|
  | `:atom`, `0`, `"s"` | Exactly that literal |
  | `[:a, :b]` | One of the listed literals |
  | `a..b` | An integer in the range; either bound may be `^const`, and either may be negative |
  | `^name` | Any element of the constant (which must be a set) |
  | `t1 \\| t2` | Union — a value of either type |
  | `{t1, t2, …}` | A tuple of that arity, element-wise |
  | `[dom ~> rng]` | A map whose keys are exactly `dom` and whose values are in `rng` |
  | `:set`, `:seq` | Any `MapSet` / any list |
  | `:int`, `:nat` | Any integer / any non-negative integer |
  """

  alias TLA.Spec.CompileError

  @doc """
  Check that `type` is in the §1.5 grammar. Returns the expression unchanged —
  it is stored quoted — or raises `TLA.Spec.CompileError`.

  `constants` is the set of declared constant names; a `^name` naming something
  else is reported here rather than at check time.
  """
  @spec validate!(Macro.t(), MapSet.t(atom()), keyword()) :: Macro.t()
  def validate!(type, constants, opts) do
    check!(type, constants, opts)
    type
  end

  # `:set` / `:seq` shadow the literal atoms of the same name. Saying so is
  # cheaper than a variable whose type silently means something else.
  defp check!(atom, _constants, _opts) when is_atom(atom) and atom not in [true, false, nil],
    do: :ok

  defp check!(literal, _constants, _opts)
       when is_integer(literal) or is_binary(literal) or is_boolean(literal),
       do: :ok

  # `^name` — any element of a constant set.
  defp check!({:^, meta, [{name, _, ctx}]}, constants, opts)
       when is_atom(name) and is_atom(ctx) do
    unless MapSet.member?(constants, name) do
      bad!(opts, meta, "the type refers to ^#{name}, which is not a declared constant",
        hint: "Add `constant :#{name}` above this variable declaration."
      )
    end

    :ok
  end

  # `t1 | t2` — union.
  defp check!({:|, _meta, [left, right]}, constants, opts) do
    check!(left, constants, opts)
    check!(right, constants, opts)
  end

  # `a..b` and `a..b//step` — an integer range. A bound may be `^const` or negative.
  defp check!({:.., _meta, [lo, hi]}, constants, opts) do
    check_bound!(lo, constants, opts)
    check_bound!(hi, constants, opts)
  end

  defp check!({:..//, _meta, [lo, hi, _step]}, constants, opts) do
    check_bound!(lo, constants, opts)
    check_bound!(hi, constants, opts)
  end

  # `{t1, t2, ...}` — a tuple, element-wise. Two-element tuples are their own AST
  # node in Elixir, which is why they are matched separately.
  defp check!({a, b}, constants, opts) do
    check!(a, constants, opts)
    check!(b, constants, opts)
  end

  defp check!({:{}, _meta, elements}, constants, opts) when is_list(elements) do
    Enum.each(elements, &check!(&1, constants, opts))
  end

  # `[dom ~> rng]` — a function (map). A one-element list whose element is `~>`.
  defp check!([{:~>, _meta, [dom, rng]}], constants, opts) do
    check!(dom, constants, opts)
    check!(rng, constants, opts)
  end

  # `[:a, :b]` — one of the listed literals.
  defp check!(list, constants, opts) when is_list(list) do
    Enum.each(list, fn element ->
      unless literal?(element) do
        bad!(
          opts,
          nil,
          "a list type may only list literals, got: #{Macro.to_string(element)}",
          hint:
            "`[:a, :b]` means \"one of these literals\". For a map type write " <>
              "`[domain ~> range]`; for a union of richer types write `t1 | t2`."
        )
      end

      check!(element, constants, opts)
    end)
  end

  defp check!(other, _constants, opts) do
    bad!(opts, meta_of(other), "ill-formed type: #{Macro.to_string(other)}",
      hint: """
      The type grammar (02-dsl-semantics.md §1.5) is:

          :atom | 0 | "s"       a literal
          [:a, :b]              one of the listed literals
          a..b                  an integer range; a bound may be ^const or negative
          ^name                 any element of a constant set
          t1 | t2               union
          {t1, t2}              a tuple, element-wise
          [dom ~> rng]          a map with keys exactly dom and values in rng
          :set | :seq           any MapSet / any list\
      """
    )
  end

  defp check_bound!({:^, _, [{name, _, ctx}]} = pinned, constants, opts)
       when is_atom(name) and is_atom(ctx),
       do: check!(pinned, constants, opts)

  defp check_bound!(bound, _constants, _opts) when is_integer(bound), do: :ok

  # `-1` is not an integer literal in the AST: Elixir parses it as unary minus
  # applied to 1. A range whose low bound is negative is ordinary enough --
  # Paxos's `maxBal` is `-1` until the acceptor promises something -- that
  # rejecting it would be rejecting the type the spec actually has.
  defp check_bound!({:-, _meta, [bound]}, _constants, _opts) when is_integer(bound), do: :ok

  defp check_bound!(other, _constants, opts) do
    bad!(
      opts,
      meta_of(other),
      "a range bound must be an integer or ^constant, got: " <>
        Macro.to_string(other)
    )
  end

  defp literal?(term) when is_atom(term) or is_integer(term) or is_binary(term), do: true
  defp literal?(_), do: false

  defp meta_of({_, meta, _}) when is_list(meta), do: meta
  defp meta_of(_), do: nil

  defp bad!(opts, meta, problem, extra \\ []) do
    CompileError.raise!(
      module: Keyword.fetch!(opts, :module),
      declaration: Keyword.fetch!(opts, :declaration),
      line: line_of(meta) || Keyword.get(opts, :line),
      problem: problem,
      hint: Keyword.get(extra, :hint)
    )
  end

  defp line_of(meta) when is_list(meta), do: Keyword.get(meta, :line)
  defp line_of(_), do: nil

  # ── Resolution ──────────────────────────────────────────────────────────────

  @typedoc """
  A type expression with its constants substituted, ready to test values against.
  """
  @type resolved ::
          {:literal, term()}
          | {:one_of, [term()]}
          | {:range, integer(), integer()}
          | {:element_of, MapSet.t()}
          | {:union, [resolved()]}
          | {:tuple, [resolved()]}
          | {:function, MapSet.t(), resolved()}
          | :set
          | :seq
          | :int
          | :nat

  @doc """
  Resolve a stored type expression against the constant assignments.

  This happens at model-check time, not at compile time, because nearly every
  useful type mentions a constant that has no value until a run assigns one
  (D-19). `where` names the variable, for the error message.
  """
  @spec resolve!(Macro.t(), map(), atom()) :: resolved()
  def resolve!(type, constants, where)

  def resolve!(:set, _constants, _where), do: :set
  def resolve!(:seq, _constants, _where), do: :seq
  def resolve!(:int, _constants, _where), do: :int
  def resolve!(:nat, _constants, _where), do: :nat

  def resolve!(literal, _constants, _where)
      when is_atom(literal) or is_integer(literal) or is_binary(literal),
      do: {:literal, literal}

  def resolve!({:^, _, [{name, _, ctx}]}, constants, where) when is_atom(ctx) do
    case Map.fetch(constants, name) do
      {:ok, %MapSet{} = set} ->
        {:element_of, set}

      {:ok, enumerable} when is_list(enumerable) ->
        {:element_of, MapSet.new(enumerable)}

      {:ok, other} ->
        raise ArgumentError,
              "the type of #{inspect(where)} says `^#{name}`, which means \"any element of " <>
                "the constant\" -- but #{name} was assigned #{inspect(other)}, which is not a " <>
                "set (02-dsl-semantics.md §1.5)."

      :error ->
        raise ArgumentError,
              "the type of #{inspect(where)} refers to ^#{name}, which this run did not assign."
    end
  end

  def resolve!({:|, _, [left, right]}, constants, where) do
    {:union, [resolve!(left, constants, where), resolve!(right, constants, where)]}
  end

  def resolve!({:.., _, [lo, hi]}, constants, where),
    do: {:range, bound!(lo, constants, where), bound!(hi, constants, where)}

  def resolve!({:..//, _, [lo, hi, _step]}, constants, where),
    do: {:range, bound!(lo, constants, where), bound!(hi, constants, where)}

  def resolve!({a, b}, constants, where),
    do: {:tuple, [resolve!(a, constants, where), resolve!(b, constants, where)]}

  def resolve!({:{}, _, elements}, constants, where) when is_list(elements),
    do: {:tuple, Enum.map(elements, &resolve!(&1, constants, where))}

  def resolve!([{:~>, _, [domain, range]}], constants, where) do
    {:function, domain_values!(resolve!(domain, constants, where), where),
     resolve!(range, constants, where)}
  end

  # Every element was checked to be a literal at compile time, so the list IS the
  # set of permitted values. Note that `[:set]` therefore means the literal atom
  # `:set`, while a bare `:set` means any MapSet — inside a list there is nothing
  # for the special form to be ambiguous with.
  def resolve!(list, _constants, _where) when is_list(list), do: {:one_of, list}

  # The domain of a function type has to denote a SET of keys, because the check
  # is "the map's keys are exactly this" -- not "each key is of this type". A
  # map missing a key its domain declares is the failure that matters: TLA+
  # functions are total, and a partial one is what an action that forgot to
  # extend it produces.
  defp domain_values!({:element_of, set}, _where), do: set
  defp domain_values!({:one_of, values}, _where), do: MapSet.new(values)
  defp domain_values!({:literal, value}, _where), do: MapSet.new([value])
  defp domain_values!({:range, lo, hi}, _where), do: MapSet.new(lo..hi//1)

  defp domain_values!(other, where) do
    raise ArgumentError,
          "the type of #{inspect(where)} uses #{inspect(other)} as a function domain, but a " <>
            "domain has to denote a set of keys -- a constant, a literal list, or a range " <>
            "(02-dsl-semantics.md §1.5)."
  end

  defp bound!({:^, _, [{name, _, ctx}]}, constants, where) when is_atom(ctx) do
    case Map.fetch(constants, name) do
      {:ok, bound} when is_integer(bound) ->
        bound

      {:ok, other} ->
        raise ArgumentError,
              "the type of #{inspect(where)} uses ^#{name} as a range bound, but #{name} was " <>
                "assigned #{inspect(other)}, which is not an integer."

      :error ->
        raise ArgumentError,
              "the type of #{inspect(where)} refers to ^#{name}, which this run did not assign."
    end
  end

  defp bound!(bound, _constants, _where) when is_integer(bound), do: bound

  defp bound!({:-, _meta, [bound]}, _constants, _where) when is_integer(bound), do: -bound

  @doc """
  Whether a value inhabits a resolved type.
  """
  @spec member?(resolved(), term()) :: boolean()
  def member?({:literal, literal}, value), do: value === literal
  def member?({:one_of, literals}, value), do: Enum.any?(literals, &(&1 === value))

  def member?({:range, lo, hi}, value),
    do: is_integer(value) and value >= lo and value <= hi

  def member?({:element_of, set}, value), do: MapSet.member?(set, value)
  def member?({:union, types}, value), do: Enum.any?(types, &member?(&1, value))

  def member?({:tuple, types}, value) do
    is_tuple(value) and tuple_size(value) == length(types) and
      value |> Tuple.to_list() |> Enum.zip(types) |> Enum.all?(fn {v, t} -> member?(t, v) end)
  end

  def member?({:function, domain, range}, value) do
    is_map(value) and not is_struct(value) and
      MapSet.new(Map.keys(value)) == domain and
      Enum.all?(Map.values(value), &member?(range, &1))
  end

  def member?(:set, value), do: is_struct(value, MapSet)
  def member?(:seq, value), do: is_list(value)
  def member?(:int, value), do: is_integer(value)
  def member?(:nat, value), do: is_integer(value) and value >= 0

  @doc """
  The typed variables of a spec, resolved against this run's constants.

  Resolution happens once per run rather than once per state: the constants do
  not change, and the state space is where the work is.
  """
  @spec resolved_variables(TLA.Spec.Compiled.t(), map()) :: [{atom(), resolved()}]
  def resolved_variables(spec, constants) do
    for %{name: name, type: type} <- spec.variables, type != nil do
      {name, resolve!(type, constants, name)}
    end
  end

  @doc """
  Check a state against the resolved variable types.

  Types are checked as an invariant rather than used to prune, so a state outside
  its type is a reported violation and not a silently narrower search (D-19).
  """
  @spec check_state([{atom(), resolved()}], TLA.State.t()) ::
          :ok | {:violation, atom(), resolved(), term()}
  def check_state(resolved, state) do
    Enum.find_value(resolved, :ok, fn {name, type} ->
      value = Map.fetch!(state, name)
      if member?(type, value), do: nil, else: {:violation, name, type, value}
    end)
  end

  @doc """
  The implicit `:type_ok` invariant for a run, or `nil` when no variable is typed.

  It is checked in every reachable state, which is why a coverage report lists a
  `type_ok` the spec never declared.
  """
  @spec invariant(TLA.Spec.Compiled.t(), map()) :: TLA.Spec.Compiled.invariant_def() | nil
  def invariant(spec, constants) do
    case resolved_variables(spec, constants) do
      [] ->
        nil

      resolved ->
        %{
          name: :type_ok,
          description: "every variable holds a value of its declared type",
          predicate: fn _constants, state -> check_state(resolved, state) == :ok end
        }
    end
  end

  @doc """
  Explain a `:type_ok` violation: which variable, what it holds, what it declared.
  """
  @spec explain(TLA.Spec.Compiled.t(), map(), TLA.State.t()) :: String.t()
  def explain(spec, constants, state) do
    case spec |> resolved_variables(constants) |> check_state(state) do
      {:violation, name, type, value} ->
        "#{name} = #{inspect(value)}, which is not #{describe(type)}"

      :ok ->
        "no variable is outside its declared type"
    end
  end

  @doc """
  Render a resolved type for a violation message.
  """
  @spec describe(resolved()) :: String.t()
  def describe({:literal, literal}), do: inspect(literal)
  def describe({:one_of, literals}), do: Enum.map_join(literals, " | ", &inspect/1)
  def describe({:range, lo, hi}), do: "#{lo}..#{hi}"
  def describe({:element_of, set}), do: "an element of #{inspect(set)}"
  def describe({:union, types}), do: Enum.map_join(types, " | ", &describe/1)
  def describe({:tuple, types}), do: "{" <> Enum.map_join(types, ", ", &describe/1) <> "}"

  def describe({:function, domain, range}),
    do: "a map with keys #{inspect(MapSet.to_list(domain))} and values in #{describe(range)}"

  def describe(:set), do: "a MapSet"
  def describe(:seq), do: "a list"
  def describe(:int), do: "an integer"
  def describe(:nat), do: "a non-negative integer"
end
