defmodule ExTLA.Spec.Rewriter do
  @moduledoc """
  Resolves the three name classes of `02-dsl-semantics.md` §1 inside a spec block.

  Inside a spec block a bare identifier is one of exactly three things, and the
  class is determined syntactically, never by inference:

  | Syntax | Class | Rewrites to |
  |---|---|---|
  | `^name` | Constant | `Map.fetch!(constants, :name)` |
  | `name` | Variable | `Map.fetch!(state, :name)` |
  | `let name = …` | Local | left alone; ordinary Elixir |

  ## Why locals are over-approximated

  A bare name that is neither a declared variable nor a constant may still be a
  perfectly good local: a `let` pattern, a `fn` argument, a comprehension
  generator, a `case` clause head. `bound_names/1` collects every name bound
  **anywhere** in the block, ignoring scope, and a read of a name in that set is
  left alone.

  Over-approximating is the deliberate direction to be wrong in. Missing a
  binding would turn working Elixir into a spurious "undeclared variable" error;
  including one too many only means a genuine typo is reported by Elixir's own
  compiler ("undefined variable") instead of by this one. The first is a
  regression, the second is a slightly worse message.
  """

  alias ExTLA.Spec.CompileError

  @enforce_keys [:module, :declaration, :variables, :constants, :read]
  defstruct [
    :module,
    :declaration,
    :variables,
    :constants,
    # {:state, ast}      — bare variables read that state
    # {:reject, builder} — bare variables are an error here; the builder turns
    #                      the name into {problem, hint}. `init` has no earlier
    #                      state to read (§1.2), `action_property` needs
    #                      old./new. (§4), and a `params:` generator takes the
    #                      state as its own argument.
    :read,
    :line,
    bound: MapSet.new(),
    # The names the declaration binds BEFORE its block: an action's `params:`, an action
    # property's `old`/`new`. They are in `bound` too, alongside every name the block binds,
    # which is why `bound` cannot serve the shadow check: a `let`'s own name is in it. These
    # are the ones a `let` may not take (#210).
    params: MapSet.new(),
    constants_ast: nil
  ]

  @type t :: %__MODULE__{}

  @ignored_specials [:__MODULE__, :__ENV__, :__CALLER__, :__DIR__, :__STACKTRACE__, :__block__]

  @doc """
  Rewrite an expression, resolving `^constants` and bare variables.
  """
  def rewrite(ast, %__MODULE__{} = ctx), do: walk(ast, ctx)

  # ── The walk ────────────────────────────────────────────────────────────────
  #
  # Hand-written rather than Macro.prewalk/3 because a rewritten node contains
  # generated variables (`tla_state`, `tla_constants`) that must not be walked
  # again -- prewalk descends into what it just produced, and would then report
  # the generated names as undeclared variables.

  defp walk({:^, meta, [{name, _, var_ctx}]}, ctx) when is_atom(name) and is_atom(var_ctx) do
    unless MapSet.member?(ctx.constants, name) do
      bad!(:undeclared_constant, ctx, meta, "undeclared constant: ^#{name}",
        hint:
          "Constants are declared with `constant :#{name}` before the block that uses them. " <>
            declared_note(ctx.constants)
      )
    end

    quote do: Map.fetch!(unquote(constants_ast(ctx)), unquote(name))
  end

  # A `let` pattern is ordinary Elixir and is left alone; only the right-hand
  # side is rewritten. Rewriting a pattern would turn `^const` into a function
  # call in a match position, which is not a pattern at all.
  defp walk({:=, meta, [lhs, rhs]}, ctx) do
    {:=, meta, [lhs, walk(rhs, ctx)]}
  end

  # `f[x]` is TLA+ function application, not `Access.get/2` (D-20). The rule has
  # no exceptions inside a spec block -- it holds for a variable, for a local,
  # for `old.`/`new.` and for a `params:` generator's own state argument --
  # because a rule with exceptions is one an author has to remember the shape of,
  # and `nil` where a domain error belongs is the failure this closes.
  #
  # The source text goes along for the error message: `balances[:carol]` names
  # the function the way the spec wrote it, which `Map.fetch!/2` cannot.
  defp walk({{:., _, [Access, :get]}, meta, [collection, key]}, ctx) do
    where = Macro.to_string(collection)

    quote line: line_of(meta, ctx) do
      ExTLA.Spec.Helpers.at(
        unquote(walk(collection, ctx)),
        unquote(walk(key, ctx)),
        unquote(where)
      )
    end
  end

  # `&name/arity` names a FUNCTION, never a state variable (#359). The name node
  # `{name, meta, nil}` has a variable's shape, so the generic clauses below resolved it as
  # one: `&abs/1` and `&+/2` failed as "undeclared variable", advising `variable :abs`. A
  # capture's name is left alone, even where a declared variable shares it, because that is
  # what Elixir means by it (02-dsl-semantics.md §1). A qualified `&Mod.name/arity` already
  # compiled; it takes this clause too, so the module part is still walked (it can be a
  # local holding a module). `&(&1 + n)` is not this shape and is walked as any expression,
  # so `n` there is still a variable.
  defp walk({:&, meta, [{:/, slash_meta, [{name, _, var_ctx} = function, arity]}]}, _ctx)
       when is_atom(name) and is_atom(var_ctx) and is_integer(arity) do
    {:&, meta, [{:/, slash_meta, [function, arity]}]}
  end

  defp walk(
         {:&, meta, [{:/, slash_meta, [{{:., _, [_module, _name]}, _, []} = remote, arity]}]},
         ctx
       )
       when is_integer(arity) do
    {:&, meta, [{:/, slash_meta, [walk(remote, ctx), arity]}]}
  end

  defp walk({form, meta, args}, ctx) when is_list(args) do
    {walk(form, ctx), meta, Enum.map(args, &walk(&1, ctx))}
  end

  defp walk({name, meta, var_ctx}, ctx) when is_atom(name) and is_atom(var_ctx) do
    resolve_name(name, meta, var_ctx, ctx)
  end

  defp walk({a, b}, ctx), do: {walk(a, ctx), walk(b, ctx)}

  defp walk(list, ctx) when is_list(list), do: Enum.map(list, &walk(&1, ctx))

  defp walk(other, _ctx), do: other

  defp resolve_name(name, meta, var_ctx, ctx) do
    cond do
      name in @ignored_specials ->
        {name, meta, var_ctx}

      String.starts_with?(Atom.to_string(name), "_") ->
        {name, meta, var_ctx}

      MapSet.member?(ctx.variables, name) ->
        read_variable(name, meta, var_ctx, ctx)

      MapSet.member?(ctx.bound, name) ->
        {name, meta, var_ctx}

      MapSet.member?(ctx.constants, name) ->
        bad!(:constant_without_pin, ctx, meta, "constant #{inspect(name)} referenced without `^`",
          hint:
            "Write `^#{name}`. A bare name means a state variable and a pinned name means a " <>
              "constant (02-dsl-semantics.md §1.1); without the pin this would read as a " <>
              "variable that does not exist."
        )

      true ->
        bad!(:undeclared_variable, ctx, meta, "undeclared variable: #{name}",
          hint:
            "Declare it with `variable :#{name}`, bind it with `let #{name} = …`, or write " <>
              "`^#{name}` if it is a constant. " <> declared_note(ctx.variables)
        )
    end
  end

  defp read_variable(name, _meta, _var_ctx, %{read: {:state, state_ast}}) do
    quote do: Map.fetch!(unquote(state_ast), unquote(name))
  end

  defp read_variable(name, meta, _var_ctx, %{read: {:reject, builder}} = ctx) do
    {problem, hint} = builder.(name)
    bad!(:variable_not_readable_here, ctx, meta, problem, hint: hint)
  end

  @doc """
  The rejection builder for `init`: there is no earlier state to read.
  """
  def reject_init do
    fn name ->
      {"`init` cannot read variable #{inspect(name)}",
       "An `init` block defines the initial state; there is no earlier state to read " <>
         "(02-dsl-semantics.md §1.2). Compute the value with `let`, or from `^constants`."}
    end
  end

  @doc """
  The rejection builder for `action_property`: §4 requires `old.`/`new.`.
  """
  def reject_action_property do
    fn name ->
      {"bare variable #{inspect(name)} in an action_property",
       "An action property constrains a transition, so a bare name would be ambiguous. " <>
         "Write `old.#{name}` for the pre-state and `new.#{name}` for the post-state " <>
         "(02-dsl-semantics.md §4)."}
    end
  end

  @doc """
  The rejection builder for a `params:` generator, which receives the pre-state
  as its own argument.
  """
  def reject_param(state_arg) do
    fn name ->
      {"bare variable #{inspect(name)} in a `params:` generator",
       "A state function receives the pre-state as its argument, so write " <>
         "`#{state_arg}.#{name}` (02-dsl-semantics.md §3)."}
    end
  end

  # ── Bound-name collection ───────────────────────────────────────────────────

  @doc """
  Every name bound anywhere in the AST, ignoring scope. See the module note on
  why this over-approximates.
  """
  def bound_names(ast) do
    {_ast, bound} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:=, _, [lhs, _rhs]} = node, acc ->
          {node, MapSet.union(acc, pattern_names(lhs))}

        {:<-, _, [lhs, _rhs]} = node, acc ->
          {node, MapSet.union(acc, pattern_names(lhs))}

        {:->, _, [heads, _body]} = node, acc ->
          {node, Enum.reduce(heads, acc, &MapSet.union(&2, pattern_names(&1)))}

        node, acc ->
          {node, acc}
      end)

    bound
  end

  @doc """
  The variable names bound by a pattern. A pinned name is a value, not a
  binding, so `^x` contributes nothing.
  """
  def pattern_names(pattern) do
    {_ast, names} =
      Macro.prewalk(pattern, MapSet.new(), fn
        {:^, _, [_pinned]}, acc ->
          {:__tla_skipped__, acc}

        {name, _, var_ctx} = node, acc when is_atom(name) and is_atom(var_ctx) ->
          if name in @ignored_specials, do: {node, acc}, else: {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    names
  end

  # ── Diagnostics ─────────────────────────────────────────────────────────────

  defp declared_note(set) do
    if MapSet.size(set) == 0 do
      "None are declared in this module."
    else
      "Declared: " <> (set |> Enum.sort() |> Enum.map_join(", ", &inspect/1)) <> "."
    end
  end

  defp line_of(meta, ctx), do: (is_list(meta) && Keyword.get(meta, :line)) || ctx.line || 0

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

  @doc false
  def constants_ast(%__MODULE__{constants_ast: nil}), do: Macro.var(:tla_constants, __MODULE__)
  def constants_ast(%__MODULE__{constants_ast: ast}), do: ast
end
