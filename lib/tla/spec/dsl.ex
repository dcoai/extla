defmodule TLA.Spec.DSL do
  @moduledoc """
  The macros that form the specification DSL.

  Each one accumulates a declaration into a module attribute and defines the
  functions that declaration compiles to; `TLA.Spec.__before_compile__/1`
  assembles them into a `TLA.Spec.Compiled` struct.

  Every rule in `02-dsl-semantics.md` is checked here, when the spec module
  compiles, because the DSL already accumulates every declaration it needs. A
  spec either means something precise or does not compile — it never reaches the
  checker in a state where a diagnostic would have to be a runtime surprise.
  """

  alias TLA.Spec.{Block, CompileError, Deps, Params, Rewriter, Temporal}

  @reserved [:state, :old, :new]

  # The implicit invariant of §1.5, checked in every reachable state. A declared
  # one of the same name would either shadow it or be shadowed by it, and a
  # coverage report naming `type_ok` would then be ambiguous about which was
  # checked.
  @reserved_invariants [:type_ok]

  @doc """
  Declare a constant parameter. Its value is assigned at model-check time.
  Referenced in blocks as `^name`.

  ## Options

  - `default:` — the assignment `mix tla.check` uses when nothing else supplies
    one. `04-layer2-model-checker.md` specified the task without saying where a
    run's constants come from, and a checker cannot start without them; a default
    beside the declaration is the answer that needs no second file. Application
    config still overrides it, and `TLA.ModelChecker.run/2` ignores it entirely.
  """
  defmacro constant(name, opts \\ []) do
    caller = __CALLER__
    check_name!(caller, "constant", name)
    check_reserved!(caller, "constant", name)
    check_fresh!(caller, name)
    check_options!(opts, caller, "constant", name)

    put(caller, :tla_constants, %{name: name, opts: opts, line: caller.line})
  end

  @doc """
  Declare a state variable with an optional `type:` annotation.
  Referenced in blocks as a bare `name`.

  The type is stored quoted and resolved at model-check time, because nearly
  every useful type mentions a constant (`02-dsl-semantics.md` §1.5, D-19). It
  is checked as the implicit invariant `:type_ok` in every reachable state; it
  does NOT restrict exploration, so a state outside its type is a reported
  violation rather than a pruned branch.
  """
  defmacro variable(name, opts \\ []) do
    caller = __CALLER__
    check_name!(caller, "variable", name)
    check_reserved!(caller, "variable", name)
    check_fresh!(caller, name)

    check_options!(opts, caller, "variable", name)
    {type, rest} = pop_option(opts, :type, caller, "variable #{inspect(name)}")

    put(caller, :tla_variables, %{name: name, type: type, opts: rest, line: caller.line})
  end

  @doc """
  Define an initial state. Variables are assigned with `=`; every declared
  variable must be assigned exactly once.

  Multiple `init` blocks are disjuncted — a nondeterministic choice of starting
  state.
  """
  defmacro init(opts) do
    caller = __CALLER__
    {block, _} = pop_do!(opts, caller, "init")

    index = length(Module.get_attribute(caller.module, :tla_inits) || [])
    fun = :"__tla_init_#{index}__"
    constants = Macro.var(:tla_constants, __MODULE__)

    ctx =
      context(caller, "init", %{
        read: {:reject, Rewriter.reject_init()},
        constants_ast: constants,
        block: block
      })

    declared = declared_names(caller, :tla_variables)
    classified = Enum.map(Block.statements(block), &Block.classify!(&1, ctx))
    body = Block.init_body(classified, ctx, declared)

    put(caller, :tla_inits, %{fun: fun, line: caller.line})

    quote generated: true do
      @doc false
      def unquote(fun)(unquote(constants)), do: unquote(body)
    end
  end

  @doc """
  Define a named action (state transition).

  `params:` is the action's only source of nondeterminism. Inside the block,
  `require expr` is an enabling condition, `let pat = expr` is an ordinary local
  binding, and `variable = expr` is a next-state equation whose right-hand side
  reads the pre-state. Variables not assigned are implicitly `UNCHANGED`.

  See `02-dsl-semantics.md` §2-3 for the full semantics.
  """
  defmacro action(name, opts \\ [], block) do
    caller = __CALLER__
    check_name!(caller, "action", name)
    {block, opts} = pop_do!(merge_opts(opts, block, caller, "action"), caller, "action")
    check_options!(opts, caller, "action", name)
    {params_ast, _rest} = pop_option(opts, :params, caller, "action #{inspect(name)}")

    constants = Macro.var(:tla_constants, __MODULE__)
    state = Macro.var(:tla_state, __MODULE__)
    params = Macro.var(:tla_params, __MODULE__)
    bound = Macro.var(:tla_bound, __MODULE__)

    param_ctx =
      context(caller, "action #{inspect(name)}", %{
        read: {:reject, Rewriter.reject_param(:state)},
        constants_ast: constants,
        block: params_ast
      })

    {generators, sources} = Params.compile!(params_ast, param_ctx, constants, state, bound)
    param_names = Enum.map(generators, fn {param, _} -> param end)
    check_param_names!(caller, name, param_names, param_ctx)

    ctx =
      context(caller, "action #{inspect(name)}", %{
        read: {:state, state},
        constants_ast: constants,
        block: block,
        extra_bound: MapSet.new(param_names)
      })

    classified = Enum.map(Block.statements(block), &Block.classify!(&1, ctx))
    _ = Block.assignments!(classified, ctx)

    bindings = Block.bind_params(param_names, params)
    guard = Block.guard_body(classified, ctx)
    transition = Block.transition_body(classified, ctx, state)

    guard_fun = :"__tla_action_#{name}_guard__"
    transition_fun = :"__tla_action_#{name}_transition__"

    deps = Deps.block(classified, declared_names(caller, :tla_variables), caller)

    put(caller, :tla_actions, %{
      name: name,
      guard_fun: guard_fun,
      transition_fun: transition_fun,
      reads: deps.reads,
      writes: deps.writes,
      param_funs:
        Enum.map(generators, fn {param, _} ->
          {param, :"__tla_action_#{name}_param_#{param}__"}
        end),
      param_sources: sources,
      line: caller.line
    })

    generator_defs =
      for {param, body} <- generators do
        fun = :"__tla_action_#{name}_param_#{param}__"

        quote generated: true do
          @doc false
          def unquote(fun)(unquote(constants), unquote(state), unquote(bound)),
            do: unquote(body)
        end
      end

    quote generated: true do
      @doc false
      def unquote(guard_fun)(unquote(constants), unquote(state), unquote(params)) do
        (unquote_splicing(bindings))
        unquote(guard)
      end

      @doc false
      def unquote(transition_fun)(unquote(constants), unquote(state), unquote(params)) do
        (unquote_splicing(bindings))
        unquote(transition)
      end

      unquote_splicing(generator_defs)
    end
  end

  @doc """
  Define a state invariant (safety property), checked in every reachable state.

  The block is a bare boolean expression over variables and `^constants`.
  `desc:` carries a description; it is an option rather than a positional string
  because two trailing optional positionals cannot be told apart (D-18).
  """
  defmacro invariant(name, opts \\ [], block) do
    caller = __CALLER__

    state_predicate(
      caller,
      :tla_invariants,
      "invariant",
      name,
      merge_opts(opts, block, caller, "invariant")
    )
  end

  @doc """
  Declare a legitimate end state (`02-dsl-semantics.md` §5.3). A successor-less
  state satisfying any `terminal` predicate is not reported as a deadlock.

  Nothing else changes: invariants are still checked there, no action is
  disabled by it, and for liveness it stutters forever.
  """
  defmacro terminal(name, opts \\ [], block) do
    caller = __CALLER__

    state_predicate(
      caller,
      :tla_terminals,
      "terminal",
      name,
      merge_opts(opts, block, caller, "terminal")
    )
  end

  @doc """
  Define an action property (transition constraint).

  The block is a bare boolean expression; `old` and `new` are implicitly bound.
  A bare variable name is a compile error here — see `02-dsl-semantics.md` §4.
  """
  defmacro action_property(name, opts \\ [], block) do
    caller = __CALLER__
    check_name!(caller, "action_property", name)

    {block, opts} =
      pop_do!(merge_opts(opts, block, caller, "action_property"), caller, "action_property")

    check_options!(opts, caller, "action_property", name)
    {description, _} = pop_option(opts, :desc, caller, "action_property #{inspect(name)}")

    constants = Macro.var(:tla_constants, __MODULE__)

    # `generated: true` on the variables themselves, not just on the `quote` below.
    #
    # A one-sided property — one that constrains only the post-state, which is how you say
    # "every transition into this state establishes this" — leaves the other binding
    # unused, and the compiler then warns about a variable that does not appear in the
    # source. There is nothing the author can prefix with an underscore, because they did
    # not write it.
    #
    # The `quote generated: true` at the bottom of this macro is the mechanism for
    # suppressing exactly that, and it does not reach these: it marks the nodes the quote
    # CREATES, and a node injected with `unquote/1` carries its own metadata. So the flag
    # goes here, where the variables are built.
    old = {:old, [generated: true], nil}
    new = {:new, [generated: true], nil}

    ctx =
      context(caller, "action_property #{inspect(name)}", %{
        read: {:reject, Rewriter.reject_action_property()},
        constants_ast: constants,
        block: block,
        extra_bound: MapSet.new([:old, :new])
      })

    body = block |> Block.desugar_predicate!(ctx) |> Rewriter.rewrite(ctx)
    fun = :"__tla_action_property_#{name}__"

    put(caller, :tla_action_properties, %{
      name: name,
      description: description || "",
      fun: fun,
      line: caller.line
    })

    quote generated: true do
      @doc false
      def unquote(fun)(unquote(constants), unquote(old), unquote(new)), do: unquote(body)
    end
  end

  @doc """
  Define a temporal property (liveness), within the bounded fragment of
  `02-dsl-semantics.md` §5.1. A formula outside the fragment is a compile error
  naming the unsupported operator — never a silently weaker check.
  """
  defmacro temporal(name, opts \\ [], block) do
    caller = __CALLER__
    check_name!(caller, "temporal", name)
    {block, opts} = pop_do!(merge_opts(opts, block, caller, "temporal"), caller, "temporal")
    check_options!(opts, caller, "temporal", name)

    constants = Macro.var(:tla_constants, __MODULE__)

    ctx =
      context(caller, "temporal #{inspect(name)}", %{
        read: {:state, Macro.var(:tla_state, Temporal)},
        constants_ast: constants,
        block: block
      })

    formula = Temporal.parse!(block, ctx)
    fun = :"__tla_temporal_#{name}__"
    {description, _} = pop_option(opts, :desc, caller, "temporal #{inspect(name)}")

    put(caller, :tla_temporals, %{
      name: name,
      description: description || "",
      opts: opts,
      fun: fun,
      line: caller.line
    })

    quote generated: true do
      @doc false
      def unquote(fun)(unquote(constants)), do: unquote(formula)
    end
  end

  @doc """
  Declare fairness constraints (`02-dsl-semantics.md` §5.2).

      fairness :weak, [:done, :reset]        # WF(Done), WF(Reset)
      fairness :strong, acquire_lock: [:p]   # \\A p : SF(AcquireLock(p))

  Whole-action fairness guarantees only that *some* binding fires, which is
  consistent with one process starving while the others take turns — so any
  per-process property needs the second form.

  Naming an action that does not exist, params that are not a leading prefix of
  the action's params, or a state-drawn param, is a compile error. Those checks
  run in `@before_compile`, where every action is known regardless of
  declaration order.
  """
  defmacro fairness(kind, entries) when kind in [:weak, :strong] do
    caller = __CALLER__
    line = caller.line

    declarations =
      case entries do
        list when is_list(list) ->
          Enum.map(list, fn
            action when is_atom(action) ->
              {action, []}

            {action, params} when is_atom(action) and is_list(params) ->
              {action, params}

            other ->
              CompileError.raise!(
                module: caller.module,
                declaration: "fairness",
                line: line,
                problem: "malformed fairness entry: #{Macro.to_string(other)}",
                hint:
                  "Each entry is an action name — `fairness :weak, [:done]` — or " <>
                    "`action: [params]` for one constraint per binding, as in " <>
                    "`fairness :strong, acquire_lock: [:p]`."
              )
          end)

        other ->
          CompileError.raise!(
            module: caller.module,
            declaration: "fairness",
            line: line,
            problem: "fairness takes a list, got: #{Macro.to_string(other)}",
            hint: "As in `fairness :weak, [:done, :reset]`."
          )
      end

    Enum.each(declarations, fn {action, per} ->
      put(caller, :tla_fairness, %{kind: kind, action: action, per: per, line: line})
    end)

    :ok
  end

  defmacro fairness(kind, _entries) do
    CompileError.raise!(
      module: __CALLER__.module,
      declaration: "fairness",
      line: __CALLER__.line,
      problem: "fairness kind must be :weak or :strong, got: #{Macro.to_string(kind)}",
      hint:
        ":weak means \"must fire if continuously enabled\", :strong \"if repeatedly enabled\"."
    )
  end

  # ── Shared shapes ───────────────────────────────────────────────────────────

  defp state_predicate(caller, attribute, kind, name, opts) do
    check_name!(caller, kind, name)
    check_reserved_invariant!(caller, kind, name)
    {block, opts} = pop_do!(opts, caller, kind)
    check_options!(opts, caller, kind, name)
    {description, _} = pop_option(opts, :desc, caller, "#{kind} #{inspect(name)}")

    constants = Macro.var(:tla_constants, __MODULE__)
    state = Macro.var(:tla_state, __MODULE__)

    ctx =
      context(caller, "#{kind} #{inspect(name)}", %{
        read: {:state, state},
        constants_ast: constants,
        block: block
      })

    desugared = Block.desugar_predicate!(block, ctx)
    body = Rewriter.rewrite(desugared, ctx)
    fun = :"__tla_#{kind}_#{name}__"

    near_miss = if kind == "invariant", do: Block.near_miss(desugared)
    near_miss_fun = if near_miss, do: :"__tla_invariant_#{name}_near_miss__"

    reads =
      Deps.expression(desugared, declared_names(caller, :tla_variables), MapSet.new(), caller)

    entry =
      case kind do
        "invariant" ->
          %{
            name: name,
            description: description || "",
            fun: fun,
            near_miss_fun: near_miss_fun,
            reads: reads,
            line: caller.line
          }

        "terminal" ->
          %{name: name, fun: fun, reads: reads, line: caller.line}
      end

    put(caller, attribute, entry)

    near_miss_def =
      if near_miss do
        quote generated: true do
          @doc false
          def unquote(near_miss_fun)(unquote(constants), unquote(state)),
            do: unquote(Rewriter.rewrite(near_miss, ctx))
        end
      end

    quote generated: true do
      @doc false
      def unquote(fun)(unquote(constants), unquote(state)), do: unquote(body)

      unquote(near_miss_def)
    end
  end

  # ── Compile-time checks and plumbing ────────────────────────────────────────

  # Accumulated in the macro BODY, at expansion time. See the note on
  # `TLA.Spec.__using__/1`: an attribute written by generated code is invisible
  # to the expansion of a later macro, and `action` has to know which names are
  # declared variables while it expands.
  defp put(caller, attribute, entry) do
    Module.put_attribute(caller.module, attribute, entry)
    :ok
  end

  defp context(caller, declaration, opts) do
    block = Map.get(opts, :block)
    extra = Map.get(opts, :extra_bound, MapSet.new())

    %Rewriter{
      module: caller.module,
      declaration: declaration,
      line: caller.line,
      variables: MapSet.new(declared_names(caller, :tla_variables)),
      constants: MapSet.new(declared_names(caller, :tla_constants)),
      read: Map.fetch!(opts, :read),
      constants_ast: Map.get(opts, :constants_ast),
      bound: MapSet.union(extra, Rewriter.bound_names(block))
    }
  end

  defp declared_names(caller, attribute) do
    caller.module
    |> Module.get_attribute(attribute)
    |> Kernel.||([])
    |> Enum.reverse()
    |> Enum.map(& &1.name)
  end

  defp check_name!(_caller, _kind, name) when is_atom(name) and not is_nil(name), do: :ok

  defp check_name!(caller, kind, name) do
    CompileError.raise!(
      module: caller.module,
      declaration: kind,
      line: caller.line,
      problem: "#{kind} name must be a literal atom, got: #{Macro.to_string(name)}",
      hint: "Names are read at compile time, so they cannot be computed."
    )
  end

  defp check_reserved!(caller, kind, name) when name in @reserved do
    CompileError.raise!(
      module: caller.module,
      declaration: "#{kind} #{inspect(name)}",
      line: caller.line,
      problem: "#{inspect(name)} is a reserved name",
      hint:
        "`state`, `old` and `new` are implicitly bound in some blocks " <>
          "(02-dsl-semantics.md §1.4), so declaring one would capture rather than shadow. " <>
          "Rename it — the Raft example calls its state `srv_state` for this reason."
    )
  end

  defp check_reserved!(_caller, _kind, _name), do: :ok

  defp check_reserved_invariant!(caller, "invariant", name) when name in @reserved_invariants do
    CompileError.raise!(
      module: caller.module,
      declaration: "invariant #{inspect(name)}",
      line: caller.line,
      problem: "#{inspect(name)} is checked implicitly and cannot be declared",
      hint:
        "Types are checked as the invariant `:type_ok` in every reachable state " <>
          "(02-dsl-semantics.md §1.5). Declare the constraint as `variable :x, type: …` " <>
          "instead, or give this invariant another name."
    )
  end

  defp check_reserved_invariant!(_caller, _kind, _name), do: :ok

  defp check_fresh!(caller, name) do
    taken =
      declared_names(caller, :tla_variables) ++ declared_names(caller, :tla_constants)

    if name in taken do
      CompileError.raise!(
        module: caller.module,
        declaration: "declaration of #{inspect(name)}",
        line: caller.line,
        problem: "#{inspect(name)} is already declared",
        hint:
          "A second declaration cannot shadow the first — a block referring to " <>
            "#{inspect(name)} would have no way to say which one it meant."
      )
    end
  end

  defp check_param_names!(caller, action, names, ctx) do
    Enum.each(names, fn param ->
      cond do
        MapSet.member?(ctx.variables, param) ->
          CompileError.raise!(
            module: caller.module,
            declaration: "action #{inspect(action)}",
            line: caller.line,
            problem: "param #{inspect(param)} has the same name as a declared variable",
            hint:
              "Inside the block a bare `#{param}` would be ambiguous between the param and " <>
                "the variable. Rename the param."
          )

        param in @reserved ->
          CompileError.raise!(
            module: caller.module,
            declaration: "action #{inspect(action)}",
            line: caller.line,
            problem: "param #{inspect(param)} is a reserved name",
            hint: "`state`, `old` and `new` are implicitly bound (02-dsl-semantics.md §1.4)."
          )

        true ->
          :ok
      end
    end)

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      [dupe | _] ->
        CompileError.raise!(
          module: caller.module,
          declaration: "action #{inspect(action)}",
          line: caller.line,
          problem: "param #{inspect(dupe)} is declared twice",
          hint: "Params bind left to right; two entries of one name is not a binding order."
        )
    end
  end

  # `f :name, desc: "…" do … end` passes the block as a THIRD argument, while
  # `f :name, desc: "…", do: block` folds it into the second. Merging covers both
  # call shapes, which is why every block macro takes `opts \\ [], block` rather
  # than the `do: block` pattern that only matches the first.
  defp merge_opts(opts, block, _caller, _kind) when is_list(opts) and is_list(block) do
    Keyword.merge(opts, block)
  end

  defp merge_opts(opts, block, caller, kind) do
    CompileError.raise!(
      module: caller.module,
      declaration: kind,
      line: caller.line,
      problem:
        "options must be a literal keyword list, got: " <>
          Macro.to_string(if is_list(opts), do: block, else: opts)
    )
  end

  defp pop_do!(opts, caller, kind) when is_list(opts) do
    case Keyword.pop(opts, :do) do
      {nil, _} ->
        CompileError.raise!(
          module: caller.module,
          declaration: kind,
          line: caller.line,
          problem: "#{kind} needs a `do` block"
        )

      {block, rest} ->
        {block, rest}
    end
  end

  defp pop_do!(other, caller, kind) do
    CompileError.raise!(
      module: caller.module,
      declaration: kind,
      line: caller.line,
      problem: "#{kind} options must be a keyword list, got: #{Macro.to_string(other)}"
    )
  end

  # Pops an option out of the QUOTED keyword list, because some option values —
  # `type:` above all — must be kept as syntax rather than evaluated.
  #
  # `Keyword.keyword?/1` rather than a `rescue`. The earlier version wrapped a `case` whose
  # two branches were identical in a bare `rescue _`, which meant any failure inside — not
  # only a malformed list — was reported as "options must be a literal keyword list". A
  # diagnostic that can be wrong about what went wrong is worse than none in the DSL
  # compiler's own error path, which is where an author is already confused. Asking the
  # question directly answers it exactly, and surfaces a real bug as itself (#160).
  defp pop_option(opts, key, caller, declaration) do
    unless keyword_list?(opts) do
      CompileError.raise!(
        module: caller.module,
        declaration: declaration,
        line: caller.line,
        problem: "options must be a literal keyword list, got: #{Macro.to_string(opts)}"
      )
    end

    Keyword.pop(opts, key)
  end

  # What each declaration CONSUMES, established by reading the consumers rather than the
  # documentation: `:default` at `TLA.Spec.Compiled.defaults/1`, `:type` and `:params` popped
  # here, `:desc` popped for the three predicate forms. `temporal` reads none.
  #
  # An option nobody reads and an option nobody wrote are the same thing to a `Keyword.pop/2`
  # with a default, which is how `variable :n, type: :nat, bogus: 1` came to compile. The list
  # therefore records consumption, not intent: `desc:` is NOT accepted on `temporal`, `action`,
  # `variable` or `constant`, because nothing there would ever read it. Accepting it would put
  # back exactly the silence this closes.
  @accepted_options %{
    "constant" => [:default],
    "variable" => [:type],
    "action" => [:params],
    "invariant" => [:desc],
    "terminal" => [:desc],
    "action_property" => [:desc],
    "temporal" => [:desc]
  }

  # Call AFTER `pop_do!/3`: a block reaches these macros as a `:do` entry in the same list, so
  # validating before it is removed would reject every declaration in the project.
  defp check_options!(opts, caller, kind, name) do
    accepted = Map.fetch!(@accepted_options, kind)
    declaration = "#{kind} #{inspect(name)}"

    unless keyword_list?(opts) do
      CompileError.raise!(
        module: caller.module,
        declaration: declaration,
        line: caller.line,
        problem: "options must be a literal keyword list, got: #{Macro.to_string(opts)}"
      )
    end

    case opts |> Keyword.keys() |> Enum.uniq() |> Enum.reject(&(&1 in accepted)) do
      [] ->
        :ok

      unknown ->
        CompileError.raise!(
          module: caller.module,
          declaration: declaration,
          line: caller.line,
          problem: "unknown option#{if length(unknown) > 1, do: "s"}: #{keys(unknown)}",
          hint: accepts_hint(kind, accepted)
        )
    end
  end

  defp accepts_hint(kind, accepted), do: "`#{kind}` accepts #{keys(accepted)}."

  defp keys(list), do: Enum.map_join(list, ", ", &inspect/1)

  defp keyword_list?(opts), do: is_list(opts) and Keyword.keyword?(opts)
end
