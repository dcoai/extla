defmodule TLA.Spec.Block do
  @moduledoc """
  Compiles an `init` or `action` body into the guard and transition functions of
  `TLA.Spec.Compiled.action_def/0`.

  ## An action body is a conjunction, not a sequence

  This is the rule most likely to surprise an Elixir programmer, and the one that
  makes the DSL mean what TLA+ means (`02-dsl-semantics.md` §2):

  1. Every right-hand side reads the **pre-state**. Assignment order is irrelevant.
  2. Every left-hand side writes the **post-state**. Nothing is visible to
     another right-hand side in the same block.
  3. A variable not assigned is implicitly `UNCHANGED`.
  4. A variable may be assigned at most once.

  So `action :swap do x = y; y = x end` swaps them. It does not set both to the
  old `y`.

  The compiled shape is what makes that true without any analysis: every read
  becomes `Map.fetch!(pre_state, :name)`, each assignment's value lands in its
  own temporary, and the post-state is one `Map.merge/2` at the end. There is no
  intermediate state for a later right-hand side to observe, because there is no
  intermediate state.

  `let` bindings *are* sequential — they are ordinary Elixir — so they are
  emitted in source order and a later one may read an earlier one.
  """

  alias TLA.Spec.{CompileError, Rewriter}

  @doc """
  Split a block into its top-level statements.
  """
  @spec statements(Macro.t()) :: [Macro.t()]
  def statements({:__block__, _, stmts}), do: stmts
  def statements(nil), do: []
  def statements(single), do: [single]

  @doc """
  Classify one statement of an `init` or `action` body.
  """
  @spec classify!(Macro.t(), Rewriter.t()) ::
          {:guard, Macro.t(), keyword()}
          | {:let, Macro.t(), Macro.t(), keyword()}
          | {:assign, atom(), Macro.t(), keyword()}
  def classify!({:require, meta, [expr]}, _ctx), do: {:guard, expr, meta}

  def classify!({:let, meta, [{:=, _, [pattern, rhs]}]}, ctx) do
    check_no_shadow!(pattern, meta, ctx)
    {:let, pattern, rhs, meta}
  end

  def classify!({:let, meta, [other]}, ctx) do
    bad!(ctx, meta, "`let` needs a binding: #{Macro.to_string(other)}",
      hint: "Write `let name = expression` (02-dsl-semantics.md §1.3)."
    )
  end

  def classify!({:=, meta, [{name, _, var_ctx}, rhs]}, _ctx)
      when is_atom(name) and is_atom(var_ctx),
      do: {:assign, name, rhs, meta}

  def classify!({:=, meta, [pattern, _rhs]}, ctx) do
    bad!(ctx, meta, "destructuring assignment without `let`: #{Macro.to_string(pattern)}",
      hint:
        "`=` on a declared variable assigns the post-state, so an intermediate value needs " <>
          "its own form: `let #{Macro.to_string(pattern)} = …` (02-dsl-semantics.md §1.3)."
    )
  end

  def classify!(other, ctx) do
    bad!(ctx, meta_of(other), "unexpected statement: #{Macro.to_string(other)}",
      hint:
        "An action body is a conjunction of a guard and next-state equations " <>
          "(02-dsl-semantics.md §2). Every statement is `require expr`, " <>
          "`let pattern = expr`, or `variable = expr`."
    )
  end

  @doc """
  Check the classified statements of an action body and return the assignments,
  in source order, having rejected a variable assigned twice or not declared.
  """
  @spec assignments!([tuple()], Rewriter.t()) :: [{atom(), Macro.t(), keyword()}]
  def assignments!(classified, ctx) do
    classified
    |> Enum.filter(&match?({:assign, _, _, _}, &1))
    |> Enum.map(fn {:assign, name, rhs, meta} -> {name, rhs, meta} end)
    |> tap(fn assignments -> Enum.each(assignments, &check_declared!(&1, ctx)) end)
    |> tap(&check_unique!(&1, ctx))
  end

  defp check_declared!({name, _rhs, meta}, ctx) do
    unless MapSet.member?(ctx.variables, name) do
      hint =
        if MapSet.member?(ctx.constants, name) do
          "#{name} is a constant. Constants are fixed for a run and cannot be assigned."
        else
          "Declare it with `variable :#{name}`, or bind a local with `let #{name} = …`."
        end

      bad!(ctx, meta, "assignment to undeclared variable: #{name}", hint: hint)
    end
  end

  defp check_unique!(assignments, ctx) do
    assignments
    |> Enum.group_by(fn {name, _, _} -> name end)
    |> Enum.each(fn
      {_name, [_single]} ->
        :ok

      {name, [_ | _] = dupes} ->
        {_, _, meta} = List.last(dupes)

        bad!(ctx, meta, "variable #{inspect(name)} assigned #{length(dupes)} times",
          hint:
            "An action body is a conjunction, not a sequence, so two assignments to one " <>
              "variable are two contradictory equations rather than a last-write-wins " <>
              "(02-dsl-semantics.md §2)."
        )
    end)
  end

  @doc """
  The guard: the conjunction of the block's `require`s, evaluated on the
  pre-state with params bound.

  `let`s are interleaved in source order rather than hoisted, so a `require` may
  guard the `let` that follows it — `require Map.has_key?(f, k)` before
  `let v = f[k]` has to actually protect it, which it only does if `and`
  short-circuits over the binding.
  """
  @spec guard_body([tuple()], Rewriter.t()) :: Macro.t()
  def guard_body(classified, ctx) do
    case last_guard_index(classified) do
      nil ->
        true

      last ->
        classified
        |> Enum.take(last + 1)
        |> Enum.reverse()
        |> Enum.reduce(true, fn
          {:guard, expr, _meta}, rest ->
            quote do: unquote(Rewriter.rewrite(expr, ctx)) and unquote(rest)

          {:let, pattern, rhs, _meta}, rest ->
            quote generated: true do
              unquote(pattern) = unquote(Rewriter.rewrite(rhs, ctx))
              unquote(rest)
            end

          {:assign, _, _, _}, rest ->
            rest
        end)
    end
  end

  defp last_guard_index(classified) do
    classified
    |> Enum.with_index()
    |> Enum.filter(&match?({{:guard, _, _}, _}, &1))
    |> List.last()
    |> case do
      nil -> nil
      {_stmt, index} -> index
    end
  end

  @doc """
  The transition: the post-state, as one merge of the assigned variables onto
  the pre-state. A variable not assigned is untouched, which is `UNCHANGED`.
  """
  @spec transition_body([tuple()], Rewriter.t(), Macro.t()) :: Macro.t()
  def transition_body(classified, ctx, state_ast) do
    {steps, updates} =
      Enum.flat_map_reduce(classified, [], fn
        {:let, pattern, rhs, _meta}, updates ->
          step =
            quote generated: true do
              unquote(pattern) = unquote(Rewriter.rewrite(rhs, ctx))
            end

          {[step], updates}

        {:assign, name, rhs, _meta}, updates ->
          temp = temp_var(name)
          step = quote(do: unquote(temp) = unquote(Rewriter.rewrite(rhs, ctx)))
          {[step], [{name, temp} | updates]}

        {:guard, _, _}, updates ->
          {[], updates}
      end)

    merge = {:%{}, [], Enum.reverse(updates)}

    quote generated: true do
      (unquote_splicing(steps))
      Map.merge(unquote(state_ast), unquote(merge))
    end
  end

  @doc """
  The initial state: every declared variable, assigned exactly once.

  An `init` that leaves a variable out would produce a partial state, and the
  omission would surface much later as a `KeyError` from whichever action first
  reads it — a long way from the declaration that caused it.
  """
  @spec init_body([tuple()], Rewriter.t(), [atom()]) :: Macro.t()
  def init_body(classified, ctx, declared) do
    Enum.each(classified, fn
      {:guard, _expr, meta} ->
        bad!(ctx, meta, "`require` is not permitted in `init`",
          hint:
            "An `init` block defines a starting state unconditionally. For several possible " <>
              "starting states, write several `init` blocks — they are disjuncted."
        )

      _other ->
        :ok
    end)

    assignments = assignments!(classified, ctx)
    assigned = Enum.map(assignments, fn {name, _, _} -> name end)

    case declared -- assigned do
      [] ->
        :ok

      missing ->
        bad!(ctx, nil, "`init` does not assign #{Enum.map_join(missing, ", ", &inspect/1)}",
          hint:
            "Every declared variable needs an initial value; a partial initial state would " <>
              "surface as a KeyError from whichever action first reads the missing one."
        )
    end

    {steps, updates} =
      Enum.flat_map_reduce(classified, [], fn
        {:let, pattern, rhs, _meta}, updates ->
          step =
            quote generated: true do
              unquote(pattern) = unquote(Rewriter.rewrite(rhs, ctx))
            end

          {[step], updates}

        {:assign, name, rhs, _meta}, updates ->
          temp = temp_var(name)
          step = quote(do: unquote(temp) = unquote(Rewriter.rewrite(rhs, ctx)))
          {[step], [{name, temp} | updates]}

        {:guard, _, _}, updates ->
          {[], updates}
      end)

    state = {:%{}, [], Enum.reverse(updates)}

    quote generated: true do
      (unquote_splicing(steps))
      unquote(state)
    end
  end

  @doc """
  Bind each param to a local of the same name, so the block can read `from`
  where `params: [from: ^accounts]` was declared.

  The binding is marked `generated: true` — including on the variable itself, not
  only on the match — because a guard that does not mention every param is
  perfectly normal and should not warn.
  """
  @spec bind_params([atom()], Macro.t()) :: [Macro.t()]
  def bind_params(names, params_ast) do
    Enum.map(names, fn name ->
      quote generated: true do
        unquote({name, [generated: true], nil}) = Map.fetch!(unquote(params_ast), unquote(name))
      end
    end)
  end

  @doc """
  Prepare a predicate block — `invariant`, `terminal`, `action_property`.

  `let` becomes an ordinary match, and an assignment to a declared variable is
  rejected: §1.2 permits assignment only in `init` and `action`, where it means
  "the post-state". In a predicate there is no post-state for it to mean.
  """
  @spec desugar_predicate!(Macro.t(), Rewriter.t()) :: Macro.t()
  def desugar_predicate!(block, ctx) do
    block
    |> statements()
    |> Enum.map(&desugar_statement!(&1, ctx))
    |> case do
      [single] -> single
      many -> {:__block__, [], many}
    end
  end

  defp desugar_statement!({:let, meta, [{:=, _, [pattern, rhs]}]}, ctx) do
    check_no_shadow!(pattern, meta, ctx)
    {:=, meta, [pattern, rhs]}
  end

  defp desugar_statement!({:let, meta, [other]}, ctx) do
    bad!(ctx, meta, "`let` needs a binding: #{Macro.to_string(other)}",
      hint: "Write `let name = expression` (02-dsl-semantics.md §1.3)."
    )
  end

  defp desugar_statement!({:=, meta, [{name, _, var_ctx}, _rhs]} = statement, ctx)
       when is_atom(name) and is_atom(var_ctx) do
    if MapSet.member?(ctx.variables, name) do
      bad!(ctx, meta, "assignment to variable #{inspect(name)} outside `init`/`action`",
        hint:
          "`=` on a declared variable means \"the post-state\", and there is no post-state " <>
            "here (02-dsl-semantics.md §1.2). For an intermediate value write " <>
            "`let #{name} = …`."
      )
    end

    statement
  end

  defp desugar_statement!(statement, _ctx), do: statement

  # §1.3: a `let` may shadow nothing. A local named after a declared variable
  # would make every later bare use of that name ambiguous — and the ambiguity
  # would resolve silently, one way in this block and the other way everywhere
  # else in the spec.
  defp check_no_shadow!(pattern, meta, ctx) do
    pattern
    |> Rewriter.pattern_names()
    |> Enum.each(fn name ->
      cond do
        MapSet.member?(ctx.variables, name) ->
          bad!(ctx, meta, "`let` binds #{inspect(name)}, which is a declared variable",
            hint:
              "A `let` may shadow nothing (02-dsl-semantics.md §1.3): a bare `#{name}` after " <>
                "this line would mean the local, while everywhere else in the spec it means " <>
                "the variable. Rename the local."
          )

        MapSet.member?(ctx.constants, name) ->
          bad!(ctx, meta, "`let` binds #{inspect(name)}, which is a declared constant",
            hint: "A `let` may shadow nothing (02-dsl-semantics.md §1.3). Rename the local."
          )

        true ->
          :ok
      end
    end)
  end

  defp temp_var(name), do: Macro.var(:"tla_assigned_#{name}", __MODULE__)

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
