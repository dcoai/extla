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
  | `a..b` | An integer in the range; either bound may be `^const` |
  | `^name` | Any element of the constant (which must be a set) |
  | `t1 \\| t2` | Union — a value of either type |
  | `{t1, t2, …}` | A tuple of that arity, element-wise |
  | `[dom ~> rng]` | A map whose keys are exactly `dom` and whose values are in `rng` |
  | `:set`, `:seq` | Any `MapSet` / any list |
  """

  alias TLA.Spec.CompileError

  @special [:set, :seq]

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

  # `a..b` and `a..b//step` — an integer range. Bounds may be `^const`.
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
          a..b                  an integer range; a bound may be ^const
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

  @doc """
  The atoms that mean something other than themselves inside a `type:`.
  """
  @spec special_atoms() :: [atom()]
  def special_atoms, do: @special
end
