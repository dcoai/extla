defmodule ExTLA.Spec.Deps do
  @moduledoc """
  Which spec variables each block reads and writes, computed at compile time.

  This is the foundation of property-directed slicing: a run that checks only some properties
  need not distinguish states that differ outside those properties' cone of influence. That
  cone is derived from the read/write sets recorded here.

  ## Why this has to happen in the macro

  `ExTLA.Spec.Block` compiles an action body into guard and transition functions, so by the
  time the checker runs there is no AST left — actions are closures, pure functions of the
  pre-state and params (`02-dsl-semantics.md` §3). The dependency sets can only be derived
  while the quoted body is still in hand. `ExTLA.Spec.Compiled` already keeps
  `variable_def.type_expr` quoted for resolution at model-check time, so retaining compile-time
  structure is an established pattern here rather than a new one.

  ## Widening is the default

  **A read set is `:all` unless every node in the expression is recognised.** That ordering is
  deliberate and it is the whole soundness argument: an analysis that narrows by default and
  widens on the cases someone remembered is how an unsound optimisation ships. Here the
  narrowing has to earn its way in, node by node.

  The one construct that can genuinely hide a variable read is a **local macro**: it expands
  after this walk, so a reference it introduces is invisible now. Remote calls cannot hide one —
  their arguments are already in this AST — and a local *function* cannot either, because a
  spec variable exists only as a binding inside a block and is not in scope in a function body.
  So the rule is narrow and precise: recognised operators and special forms are walked, remote
  calls are walked, and anything else widens.

  ## What is not a variable

  `^constant` is a constant, not state, and never enters a read set — a state cannot differ in
  a constant. `let` bindings are local names; a body's own intermediates are not state either,
  though the expressions they are bound to are still walked.
  """

  alias ExTLA.Spec.Block

  @typedoc "A read set: the variables an expression may depend on, or `:all` when unknown."
  @type reads :: MapSet.t(atom()) | :all

  # Operators and special forms whose arguments are ordinary expressions. Anything absent from
  # this list widens, so adding to it is the act that narrows the analysis -- do it knowingly.
  @safe_forms ~w(
    + - * / == != === !== < > <= >= and or not && || ! in ++ -- <> |> = .
    if unless cond case fn for with when -> :: {} %{} __block__ __aliases__ & ^
  )a

  @doc """
  Read and write sets for a classified action or init body.

  `writes` are the variables assigned. `reads` is every variable the guard and the right-hand
  sides may depend on, or `:all`.
  """
  @spec block(list(), [atom()], Macro.Env.t() | nil) :: %{
          reads: reads(),
          writes: MapSet.t(atom())
        }
  def block(classified, declared, env \\ nil) do
    declared = MapSet.new(declared)

    writes =
      for {:assign, name, _rhs, _meta} <- classified, into: MapSet.new(), do: name

    {reads, _locals} =
      Enum.reduce(classified, {MapSet.new(), MapSet.new()}, fn
        {:guard, expr, _meta}, {acc, locals} ->
          {union(acc, expression(expr, declared, locals, env)), locals}

        {:assign, _name, rhs, _meta}, {acc, locals} ->
          {union(acc, expression(rhs, declared, locals, env)), locals}

        # A `let` binds a local name. Its right-hand side is still an expression over state, so
        # it is walked; the bound name then shadows for everything after it.
        {:let, pattern, rhs, _meta}, {acc, locals} ->
          {union(acc, expression(rhs, declared, locals, env)),
           MapSet.union(locals, pattern_names(pattern))}
      end)

    %{reads: reads, writes: writes}
  end

  @doc """
  Read set for a standalone expression — an invariant, temporal property, or terminal predicate.
  """
  @spec expression(Macro.t(), MapSet.t(atom()) | [atom()], MapSet.t(atom()), Macro.Env.t() | nil) ::
          reads()
  def expression(ast, declared, locals \\ MapSet.new(), env \\ nil)

  def expression(ast, declared, locals, env) when is_list(declared),
    do: expression(ast, MapSet.new(declared), locals, env)

  def expression(ast, declared, locals, env) do
    walk(ast, declared, locals, env, MapSet.new())
  end

  # --- the walk -------------------------------------------------------------------------

  # `^thing` is a constant reference. A constant is not state, so nothing inside it can make two
  # states differ, and it contributes nothing.
  defp walk({:^, _meta, [_inner]}, _declared, _locals, _env, acc), do: acc

  # A bare identifier: a declared variable unless a `let` has shadowed it.
  defp walk({name, _meta, ctx}, declared, locals, _env, acc)
       when is_atom(name) and is_atom(ctx) do
    if MapSet.member?(declared, name) and not MapSet.member?(locals, name) do
      MapSet.put(acc, name)
    else
      acc
    end
  end

  # A remote call. Its arguments are in this AST, and a function cannot reach a spec variable
  # that is not passed to it, so walking the arguments is complete.
  defp walk({{:., _, [_mod, _fun]}, _meta, args}, declared, locals, env, acc)
       when is_list(args) do
    walk_all(args, declared, locals, env, acc)
  end

  # A local call. Safe only if it is a recognised form, or resolves to an imported/local
  # FUNCTION -- a macro could expand to a variable reference this walk cannot see.
  defp walk({name, _meta, args}, declared, locals, env, acc)
       when is_atom(name) and is_list(args) do
    if name in @safe_forms or function_call?(name, length(args), env) do
      walk_all(args, declared, locals, env, acc)
    else
      :all
    end
  end

  defp walk({a, b}, declared, locals, env, acc),
    do: walk_all([a, b], declared, locals, env, acc)

  defp walk(list, declared, locals, env, acc) when is_list(list),
    do: walk_all(list, declared, locals, env, acc)

  # Literals: atoms, numbers, binaries, and the like depend on nothing.
  defp walk(_other, _declared, _locals, _env, acc), do: acc

  defp walk_all(_nodes, _declared, _locals, _env, :all), do: :all

  defp walk_all(nodes, declared, locals, env, acc) do
    Enum.reduce_while(nodes, acc, fn node, acc ->
      case walk(node, declared, locals, env, acc) do
        :all -> {:halt, :all}
        next -> {:cont, next}
      end
    end)
  end

  # Without an env there is nothing to resolve against, so the honest answer is "unknown", which
  # widens. With one, an imported or locally defined FUNCTION is safe; a macro is not.
  defp function_call?(_name, _arity, nil), do: false

  defp function_call?(name, arity, env) do
    case Macro.Env.lookup_import(env, {name, arity}) do
      [{:function, _module} | _] -> true
      [] -> locally_defined?(name, arity, env)
      _macro -> false
    end
  end

  # A function already defined in the module under compilation. "Already" is load-bearing and
  # conservative in the right direction: a helper defined BELOW the action that calls it is not
  # visible here, so the read set widens rather than narrowing on an assumption.
  defp locally_defined?(name, arity, %{module: module}) when is_atom(module) and module != nil do
    Module.open?(module) and Module.defines?(module, {name, arity}, :def)
  end

  defp locally_defined?(_name, _arity, _env), do: false

  defp union(:all, _other), do: :all
  defp union(_acc, :all), do: :all
  defp union(acc, other), do: MapSet.union(acc, other)

  defp pattern_names(pattern) do
    pattern
    |> Macro.prewalk(MapSet.new(), fn
      {name, _meta, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
        {node, MapSet.put(acc, name)}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  @doc """
  The statements of a block, classified — the same view `ExTLA.Spec.DSL` builds, exposed so the
  dependency sets can be derived from it without reclassifying.
  """
  @spec classify(Macro.t(), map()) :: list()
  def classify(block, ctx) do
    block |> Block.statements() |> Enum.map(&Block.classify!(&1, ctx))
  end
end
