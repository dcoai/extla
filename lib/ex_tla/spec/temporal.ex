defmodule ExTLA.Spec.Temporal do
  @moduledoc """
  Parses a `temporal` block into the bounded fragment of
  `02-dsl-semantics.md` §5.1:

      formula  ::= temporal | Enum.all?(^constant, fn x -> formula end)
      temporal ::= pred | always(pred) | eventually(pred)
                 | always(eventually(pred)) | eventually(always(pred))
                 | pred ~> pred | always(pred ~> pred)

  **The nesting is bounded, and the grammar says so.** `always`, `eventually`
  and `~>` take a `pred`, not a `formula`, so `always(always(P))` is outside the
  grammar and fails to compile with the module, declaration and line — the
  checker evaluates these seven shapes and no others.

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

  alias ExTLA.Spec.{Block, CompileError, Rewriter}

  @formula_ops [:always, :eventually, :~>]

  # Where each formula operator may appear, and what its argument may then contain. This
  # table IS the fragment's nesting bound, and it is the front end's because §5.1 promises
  # that a formula outside the fragment is a **compile** error — "every rule here is enforced
  # at compile time".
  #
  # It was enforced nowhere at compile time and three times after it, each in its own words:
  # `Liveness.shape/4` raises (only under `check_liveness: true`),
  # `GenServer.Runtime.verdict/3` has no fallback clause and dies with a
  # `FunctionClauseError` under `mix extla.simulate`, and `Coverage.walk/3` does the same by
  # default. Four hand-kept copies of one enumeration, which is this project's recurring
  # defect: a list that stops being true without saying so.
  #
  # Widening the fragment means changing this table, §5.1's grammar, and those three
  # consumers together — `test/ex_tla/spec/temporal_fragment_test.exs` drives every shape here
  # through all of them, so widening one alone goes red.
  @nesting %{
    {:always, :formula} => :always,
    {:always, :eventually} => :predicate,
    {:eventually, :formula} => :eventually,
    {:eventually, :always} => :predicate,
    {:~>, :formula} => :predicate,
    {:~>, :always} => :predicate
  }

  @doc false
  # Public so the fragment's gate can DERIVE the shapes from the bound rather than keep its
  # own list beside it. A second hand-kept list of the fragment is the defect this table
  # exists to end, and a test that enumerates the shapes itself is exactly that list: widen
  # the table and the gate would still assert the old seven, in the file whose job is to
  # notice (#277).
  def nesting, do: @nesting

  @doc """
  Parse a temporal block into quoted code that builds a
  `ExTLA.Spec.Compiled.temporal_formula()`.
  """
  def parse!({:__block__, meta, statements}, ctx) when length(statements) > 1 do
    bad!(
      :temporal_block_not_one_formula,
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

    formula(single, ctx, :formula)
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
  defp formula({:always, meta, [inner]} = ast, ctx, position) do
    case formula(unwrap(inner), ctx, nest!(ast, :always, meta, position, ctx)) do
      {:{}, _, [:leads_to, _, _]} = leads_to -> leads_to
      other -> quote do: {:always, unquote(other)}
    end
  end

  defp formula({:eventually, meta, [inner]} = ast, ctx, position) do
    inner_position = nest!(ast, :eventually, meta, position, ctx)
    quote do: {:eventually, unquote(formula(unwrap(inner), ctx, inner_position))}
  end

  defp formula({:~>, meta, [p, q]} = ast, ctx, position) do
    nest!(ast, :~>, meta, position, ctx)
    quote do: {:leads_to, unquote(predicate(p, ctx)), unquote(predicate(q, ctx))}
  end

  # `\A x \in C : F(x)` — a conjunction of instantiated formulas, each of which
  # is itself in the fragment, so checking one needs nothing new.
  # Only at the formula position. `always(Enum.all?(^procs, fn p -> done[p] end))` is
  # `always(pred)` — a quantifier over a constant with a BOOLEAN body is an ordinary state
  # predicate, and the rewriter has handled one inside an `invariant` all along. Taking it as
  # a formula-level `\A` there built `{:always, {:for_all, …}}`, which no consumer evaluates:
  # it died in `Coverage.walk/3` with a `FunctionClauseError`, under the DEFAULT
  # configuration, on a formula that reads perfectly and means what it looks like (#277).
  defp formula(
         {{:., _, [{:__aliases__, _, [:Enum]}, :all?]}, meta,
          [set, {:fn, _, [{:->, _, [[{var, _, var_ctx}], body]}]}]},
         ctx,
         :formula
       )
       when is_atom(var) and is_atom(var_ctx) do
    unless quantifiable_set?(set) do
      bad!(
        :temporal_quantifier_domain,
        ctx,
        meta,
        "a temporal quantifier must range over a constant or a literal list",
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
       fn unquote(quantified) -> unquote(formula(unwrap(body), inner_ctx, :formula)) end}
    end
  end

  defp formula(other, ctx, _position) do
    if op = unsupported_op(other) do
      bad!(
        :unsupported_temporal_operator,
        ctx,
        meta_of(other),
        "unsupported temporal operator: #{op}",
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
      bad!(
        :temporal_operator_in_state_predicate,
        ctx,
        meta_of(ast),
        "temporal operator #{op} where a state predicate is required",
        hint:
          "A state predicate is evaluated at ONE state; `always`, `eventually` and `~>` " <>
            "are formulas, evaluated over a whole behaviour. The operands of `~>` are " <>
            "predicates, and so is the body of a quantifier that sits under a temporal " <>
            "operator (02-dsl-semantics.md §5.1)."
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

  # The operator is supported; this nesting of it is not — a distinction the message has to
  # make, because "unsupported temporal operator: always/1" about a formula whose author
  # wrote nothing but supported operators would send them looking for the wrong thing.
  defp nest!(ast, op, meta, position, ctx) do
    case Map.fetch(@nesting, {op, position}) do
      {:ok, inner_position} ->
        inner_position

      :error ->
        bad!(
          :temporal_nesting_outside_fragment,
          ctx,
          meta,
          # The literal prefix is not decoration: `DIAGNOSTICS.md` renders a message's
          # interpolations as `…`, so a problem built entirely from them is the row
          # `… …: …` — a golden listing a diagnostic it cannot describe.
          "a nesting the fragment does not evaluate: #{rendered(op)} #{where(position)}" <>
            " — #{Macro.to_string(ast)}",
          hint: """
          The fragment (02-dsl-semantics.md §5.1) nests at most two operators deep:

              formula  ::= temporal | Enum.all?(^constant, fn x -> formula end)
              temporal ::= pred | always(pred) | eventually(pred)
                         | always(eventually(pred)) | eventually(always(pred))
                         | pred ~> pred | always(pred ~> pred)

          This is not a parser limitation to work around: the checker evaluates these
          shapes by SCC analysis, and there is no shape to approximate a deeper one with
          that would not be a weaker check reported as the real thing.

          `always(always(P))` is `always(P)`, and `eventually(eventually(P))` is
          `eventually(P)` — write the inner one. For anything else, one `temporal`
          declaration per property usually says what was meant and is checkable.\
          """
        )
    end
  end

  defp rendered(:~>), do: "`~>`"
  defp rendered(op), do: "`#{op}`"

  defp where(:always), do: "directly inside `always(…)`"
  defp where(:eventually), do: "directly inside `eventually(…)`"
  defp where(:predicate), do: "where the fragment allows only a state predicate"

  defp quantifiable_set?({:^, _, [{name, _, ctx}]}) when is_atom(name) and is_atom(ctx), do: true
  defp quantifiable_set?(list) when is_list(list), do: true
  defp quantifiable_set?(_), do: false

  defp meta_of({_, meta, _}) when is_list(meta), do: meta
  defp meta_of(_), do: nil

  defp bad!(kind, ctx, meta, problem, extra) do
    CompileError.raise!(
      module: ctx.module,
      declaration: ctx.declaration,
      line: (is_list(meta) && Keyword.get(meta, :line)) || ctx.line,
      problem: problem,
      hint: Keyword.get(extra, :hint),
      kind: kind
    )
  end
end
