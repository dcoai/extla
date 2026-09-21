defmodule TLA.Spec.Temporal do
  @moduledoc """
  Parses a `temporal` block into the bounded fragment of
  `02-dsl-semantics.md` §5.1:

      formula ::= always(formula) | eventually(formula) | pred ~> pred | pred
                | Enum.all?(^constant, fn x -> formula end)

  There is no negation, conjunction or disjunction **of formulas**. A `pred` may
  of course contain `not`/`and`/`or`; the restriction is on combining formulas.

  This is deliberate, not a gap: the fragment covers the properties people
  actually write and is checkable by SCC analysis without constructing a Büchi
  automaton. A formula outside it is a compile error naming the unsupported
  operator — never a silently weaker check.

  `P ~> Q` already means `always(P implies eventually(Q))`, so `always(P ~> Q)`
  is accepted and collapsed rather than rejected: TLA+ users write it out of
  habit and it means the same thing.
  """

  alias TLA.Spec.{Block, CompileError, Rewriter}

  @formula_ops [:always, :eventually, :~>]

  @doc """
  Parse a temporal block into quoted code that builds a
  `TLA.Spec.Compiled.temporal_formula()`.
  """
  def parse!({:__block__, meta, statements}, ctx) when length(statements) > 1 do
    bad!(
      ctx,
      meta,
      "a `temporal` block is a single formula, got #{length(statements)} statements",
      hint:
        "Unlike `invariant`, a temporal block has no state to compute an intermediate value " <>
          "in — the formula is evaluated over a behavior, not at one point. Declare one " <>
          "`temporal` per property."
    )
  end

  def parse!(ast, ctx) do
    single = unwrap(ast)

    # The same rule the predicate forms take, from the same function, so the two
    # paths cannot disagree about it again (#150). They did: this path never
    # desugars, so it never saw `Block.desugar_statement!/2`'s check, and a
    # `temporal` whose body was `status = :done` compiled into a formula that
    # cannot be refuted -- reporting that the property holds, having checked
    # nothing.
    Block.reject_assignment!(single, ctx)

    formula(single, ctx)
  end

  defp reject_in_set do
    fn name ->
      {"variable #{inspect(name)} in a temporal quantifier's set",
       "A quantifier ranges over a constant or a literal list, so its instances are fixed " <>
         "before any state exists; a set that reads the state would have a different shape " <>
         "in every state (02-dsl-semantics.md §5.1). Quantify over a `^constant`, or move " <>
         "the condition into the predicate."}
    end
  end

  defp unwrap({:__block__, _, [single]}), do: single
  defp unwrap(other), do: other

  # always(P ~> Q) is P ~> Q. The collapse happens here rather than in the
  # checker so that the stored formula has one shape per meaning.
  defp formula({:always, _meta, [inner]}, ctx) do
    case formula(unwrap(inner), ctx) do
      {:{}, _, [:leads_to, _, _]} = leads_to -> leads_to
      other -> quote do: {:always, unquote(other)}
    end
  end

  defp formula({:eventually, _meta, [inner]}, ctx) do
    quote do: {:eventually, unquote(formula(unwrap(inner), ctx))}
  end

  defp formula({:~>, _meta, [p, q]}, ctx) do
    quote do: {:leads_to, unquote(predicate(p, ctx)), unquote(predicate(q, ctx))}
  end

  # `\A x \in C : F(x)` — a conjunction of instantiated formulas, each of which
  # is itself in the fragment, so checking one needs nothing new.
  defp formula(
         {{:., _, [{:__aliases__, _, [:Enum]}, :all?]}, meta,
          [set, {:fn, _, [{:->, _, [[{var, _, var_ctx}], body]}]}]},
         ctx
       )
       when is_atom(var) and is_atom(var_ctx) do
    unless quantifiable_set?(set) do
      bad!(ctx, meta, "a temporal quantifier must range over a constant or a literal list",
        hint:
          "Write `Enum.all?(^processes, fn p -> … end)`. A state-dependent set would make " <>
            "the formula's shape depend on the state, so there would be no fixed set of " <>
            "instances to check (02-dsl-semantics.md §5.1)."
      )
    end

    # The rewriter resolves a declared variable before a bound name, so a quantifier named
    # after one would read the state variable in every instance and never the bound value.
    Block.check_no_shadow!({var, meta, var_ctx}, meta, ctx, "the quantifier")

    inner_ctx = %{ctx | bound: MapSet.put(ctx.bound, var)}

    # A bare variable in the set is the §5.1 error, said as such. This used to rewrite with
    # `read: :init`, a mode no clause of the rewriter handles, so `Enum.all?([x, 1], …)` died
    # with a `FunctionClauseError` from inside the compiler instead of a diagnostic (#210).
    set_expr = Rewriter.rewrite(set, %{inner_ctx | read: {:reject, reject_in_set()}})
    quantified = Macro.var(var, nil)

    quote do
      {:for_all, fn unquote(Rewriter.constants_ast(ctx)) -> unquote(set_expr) end,
       fn unquote(quantified) -> unquote(formula(unwrap(body), inner_ctx)) end}
    end
  end

  defp formula(other, ctx) do
    if op = unsupported_op(other) do
      bad!(ctx, meta_of(other), "unsupported temporal operator: #{op}",
        hint: """
        The supported fragment (02-dsl-semantics.md §5.1) is:

            formula ::= always(formula) | eventually(formula) | pred ~> pred | pred
                      | Enum.all?(^constant, fn x -> formula end)

        There is no negation, conjunction or disjunction OF FORMULAS. A `pred` may
        contain `not`/`and`/`or` freely — the restriction is on combining formulas.
        Splitting the block into one `temporal` declaration per conjunct usually
        says the same thing and is checkable.\
        """
      )
    end

    quote do: {:predicate, unquote(predicate(other, ctx))}
  end

  defp predicate(ast, ctx) do
    if op = unsupported_op(ast) do
      bad!(ctx, meta_of(ast), "temporal operator #{op} where a state predicate is required",
        hint:
          "The operands of `~>` are state predicates, not formulas " <>
            "(02-dsl-semantics.md §5.1)."
      )
    end

    state = Macro.var(:tla_state, __MODULE__)

    body =
      ast
      |> Rewriter.rewrite(%{ctx | read: {:state, state}})
      |> Block.boolean!(ctx.module, ctx.declaration)

    quote do: fn unquote(state) -> unquote(body) end
  end

  # A formula operator anywhere inside something that must be a predicate (or a
  # combination of formulas) is the error §5.1 exists to report.
  defp unsupported_op(ast) do
    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {op, _, args} = node, nil when op in @formula_ops and is_list(args) ->
          {node, "#{op}/#{length(args)}"}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp quantifiable_set?({:^, _, [{name, _, ctx}]}) when is_atom(name) and is_atom(ctx), do: true
  defp quantifiable_set?(list) when is_list(list), do: true
  defp quantifiable_set?(_), do: false

  defp meta_of({_, meta, _}) when is_list(meta), do: meta
  defp meta_of(_), do: nil

  defp bad!(ctx, meta, problem, extra) do
    CompileError.raise!(
      module: ctx.module,
      declaration: ctx.declaration,
      line: (is_list(meta) && Keyword.get(meta, :line)) || ctx.line,
      problem: problem,
      hint: Keyword.get(extra, :hint)
    )
  end
end
