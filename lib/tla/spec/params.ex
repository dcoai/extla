defmodule TLA.Spec.Params do
  @moduledoc """
  Compiles an action's `params:` — the DSL's **only** source of nondeterminism
  (`02-dsl-semantics.md` §3).

  An earlier draft had two mechanisms: `params:` for constant-drawn values and
  `choose/1,2` inside the block for state-drawn ones. The second was both
  redundant and misnamed — TLA+'s `CHOOSE` is deterministic Hilbert choice — and
  it could not work anyway: a function returning one element cannot produce
  several successors.

  With one mechanism, an action body is a pure deterministic function of
  `(pre_state, params)`. That single property is what makes successor generation,
  enabling checks, symmetry canonicalization and Layer 3's refinement check all
  straightforward, so any construct that reintroduces in-body branching has to be
  rejected for the same reason.

  A param may draw from:

  | Form | Source | Example |
  |---|---|---|
  | A constant | `:constant` | `from: ^accounts` |
  | A literal range or list | `:literal` | `amount: 1..10`, `mode: [:a, :b]` |
  | A function of the pre-state | `:state` | `t: fn s -> s.pending end` |

  Params bind left to right, and a state function may take a second argument
  receiving the params bound before it — which is how a spec keeps the
  combinatorial explosion down, filtering in the generator rather than generating
  every combination and rejecting most of them in the guard.
  """

  alias TLA.Spec.{CompileError, Rewriter}

  @doc """
  Compile the `params:` option into generator bodies and their sources.

  Returns `{[{name, arg_asts, body_ast}], [{name, source}]}`, where each body is
  the generator's body given `(constants, pre_state, bound_so_far)`.
  """
  @spec compile!(Macro.t(), Rewriter.t(), Macro.t(), Macro.t(), Macro.t()) ::
          {[{atom(), Macro.t()}], [{atom(), TLA.Spec.Compiled.param_source()}]}
  def compile!(nil, _ctx, _constants, _state, _bound), do: {[], []}

  def compile!(entries, ctx, constants, state, bound) when is_list(entries) do
    compiled =
      Enum.map(entries, fn
        {name, source} when is_atom(name) ->
          {generator, kind} = generator!(name, source, ctx, constants, state, bound)
          {name, generator, kind}

        other ->
          bad!(ctx, nil, "malformed `params:` entry: #{Macro.to_string(other)}",
            hint: "`params:` is a keyword list, as in `params: [from: ^accounts]`."
          )
      end)

    {Enum.map(compiled, fn {name, generator, _} -> {name, generator} end),
     Enum.map(compiled, fn {name, _, kind} -> {name, kind} end)}
  end

  def compile!(other, ctx, _constants, _state, _bound) do
    bad!(ctx, nil, "`params:` must be a keyword list, got: #{Macro.to_string(other)}",
      hint: "As in `params: [from: ^accounts, amount: 1..10]`."
    )
  end

  # A constant: the whole set, unchanged from state to state.
  defp generator!(_name, {:^, _, [{_const, _, var_ctx}]} = pinned, ctx, _c, _s, _b)
       when is_atom(var_ctx) do
    {Rewriter.rewrite(pinned, ctx), :constant}
  end

  # A literal range or list. The bounds may mention constants, which is still a
  # fixed set once the constants are known — hence `:literal`, not `:state`.
  defp generator!(_name, {op, _, _} = literal, ctx, _c, _s, _b) when op in [:.., :..//] do
    {Rewriter.rewrite(literal, ctx), :literal}
  end

  defp generator!(_name, literal, ctx, _c, _s, _b) when is_list(literal) do
    {Rewriter.rewrite(literal, ctx), :literal}
  end

  # A function of the pre-state, optionally also of the params bound so far.
  # This is what replaces `choose`: the direct encoding of `\\E t \\in pending`.
  defp generator!(name, {:fn, meta, [{:->, _, [args, _body]}]} = fun, ctx, _c, state, bound) do
    state_arg = state_arg_name(args)

    inner_ctx = %{
      ctx
      | bound: MapSet.union(ctx.bound, Rewriter.bound_names(fun)),
        read: {:reject, Rewriter.reject_param(state_arg)}
    }

    rewritten = Rewriter.rewrite(fun, inner_ctx)

    case length(args) do
      1 -> {quote(do: unquote(rewritten).(unquote(state))), :state}
      2 -> {quote(do: unquote(rewritten).(unquote(state), unquote(bound))), :state}
      n -> bad_arity!(ctx, meta, name, n)
    end
  end

  defp generator!(name, {:fn, meta, clauses}, ctx, _c, _s, _b) when length(clauses) > 1 do
    bad!(ctx, meta, "the `#{name}` generator has #{length(clauses)} clauses",
      hint:
        "A generator is a single-clause function of the pre-state — `fn s -> … end` — so " <>
          "that it is a total, deterministic function of the state (02-dsl-semantics.md §3)."
    )
  end

  defp generator!(name, other, ctx, _c, _s, _b) do
    bad!(
      ctx,
      meta_of(other),
      "param #{inspect(name)} draws from a non-set: " <>
        Macro.to_string(other),
      hint: """
      A `params:` entry draws from exactly one of (02-dsl-semantics.md §3):

          from: ^accounts                 every element of a constant
          amount: 1..^max_balance         a literal range
          mode: [:a, :b]                  a literal list
          t: fn s -> s.pending end        a function of the pre-state

      For anything computed, use the function form: `fn s -> … end`.\
      """
    )
  end

  defp bad_arity!(ctx, meta, name, arity) do
    bad!(ctx, meta, "the `#{name}` generator takes #{arity} arguments",
      hint:
        "A generator takes the pre-state, `fn s -> … end`, or the pre-state and the params " <>
          "bound before it, `fn s, %{p: p} -> … end` (02-dsl-semantics.md §3)."
    )
  end

  defp state_arg_name([{name, _, var_ctx} | _]) when is_atom(name) and is_atom(var_ctx), do: name
  defp state_arg_name(_), do: :state

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
