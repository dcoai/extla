defmodule TLA.Spec do
  @moduledoc """
  `use TLA.Spec` turns a module into a specification.

      defmodule Specs.Counter do
        use TLA.Spec

        constant :max
        variable :n, type: 0..^max

        init do
          n = 0
        end

        action :increment do
          require n < ^max
          n = n + 1
        end

        invariant :within_bounds do
          n >= 0 and n <= ^max
        end
      end

  The declarations accumulate into module attributes and compile to ordinary
  functions on the module; `@before_compile` assembles them into a
  `TLA.Spec.Compiled` struct, reachable as `Specs.Counter.__tla_spec__/0` or
  `TLA.Spec.Compiled.from_module/1`.

  The DSL's semantics are normative in `02-dsl-semantics.md`, and every rule
  there is enforced when this module compiles — a spec either means something
  precise or does not compile.
  """

  alias TLA.Spec.{CompileError, Type}

  @attributes [
    :tla_constants,
    :tla_variables,
    :tla_inits,
    :tla_actions,
    :tla_invariants,
    :tla_action_properties,
    :tla_temporals,
    :tla_fairness,
    :tla_terminals
  ]

  # The attributes are registered HERE, in the macro body, rather than from
  # inside the `quote`. Elixir expands an entire `defmodule` body before
  # evaluating any of it, so an attribute written by generated code is not
  # visible to a later macro's expansion — and `action` has to know, while it
  # expands, which names are declared variables. Accumulating at expansion time
  # is what makes that work, and it is why the DSL macros call
  # `Module.put_attribute/3` in their bodies instead of emitting `@tla_...`.
  defmacro __using__(_opts) do
    Enum.each(@attributes, &Module.register_attribute(__CALLER__.module, &1, accumulate: true))

    quote do
      import TLA.Spec.DSL
      import TLA.Spec.Helpers

      @before_compile TLA.Spec
    end
  end

  defmacro __before_compile__(env) do
    module = env.module

    constants = read(module, :tla_constants)
    variables = read(module, :tla_variables)
    inits = read(module, :tla_inits)
    actions = read(module, :tla_actions)
    invariants = read(module, :tla_invariants)
    action_properties = read(module, :tla_action_properties)
    temporals = read(module, :tla_temporals)
    terminals = read(module, :tla_terminals)
    fairness = read(module, :tla_fairness)

    constant_names = MapSet.new(constants, & &1.name)

    # Deferred to here rather than checked in `variable/2`, because a type may
    # legitimately mention a constant declared further down the module.
    Enum.each(variables, fn variable ->
      if variable.type do
        Type.validate!(variable.type, constant_names,
          module: module,
          declaration: "variable #{inspect(variable.name)}",
          line: variable.line
        )
      end
    end)

    check_unique_names!(module, "action", actions)
    check_unique_names!(module, "invariant", invariants)
    check_unique_names!(module, "action_property", action_properties)
    check_unique_names!(module, "temporal", temporals)
    check_unique_names!(module, "terminal", terminals)
    check_has_init!(module, env, inits, variables)
    Enum.each(fairness, &check_fairness!(module, &1, actions))

    quote generated: true do
      @doc """
      The compiled specification (`TLA.Spec.Compiled`).
      """
      def __tla_spec__ do
        %TLA.Spec.Compiled{
          module: __MODULE__,
          constants: unquote(compiled_constants(constants)),
          variables: unquote(compiled_variables(variables)),
          init: unquote(compiled_inits(inits)),
          actions: unquote(compiled_actions(actions)),
          invariants: unquote(compiled_invariants(invariants)),
          action_properties: unquote(compiled_action_properties(action_properties)),
          temporals: unquote(compiled_temporals(temporals)),
          terminals: unquote(compiled_terminals(terminals)),
          fairness: unquote(compiled_fairness(fairness))
        }
      end
    end
  end

  # ── Assembling the compiled struct ──────────────────────────────────────────

  defp compiled_constants(constants) do
    for %{name: name, opts: opts} <- constants do
      quote do: %{name: unquote(name), opts: unquote(opts || [])}
    end
  end

  defp compiled_variables(variables) do
    for %{name: name, type: type, opts: opts} <- variables do
      quote do
        %{
          name: unquote(name),
          type: unquote(Macro.escape(type)),
          opts: unquote(opts || [])
        }
      end
    end
  end

  defp compiled_inits(inits) do
    for %{fun: fun} <- inits, do: quote(do: &(__MODULE__.unquote(fun) / 1))
  end

  defp compiled_actions(actions) do
    for action <- actions do
      params =
        for {param, fun} <- action.param_funs do
          quote do: {unquote(param), &(__MODULE__.unquote(fun) / 3)}
        end

      quote do
        %{
          name: unquote(action.name),
          params: unquote(params),
          param_sources: unquote(Macro.escape(action.param_sources)),
          guard: &(__MODULE__.unquote(action.guard_fun) / 3),
          transition: &(__MODULE__.unquote(action.transition_fun) / 3),
          # #87/#91: which variables this action reads and writes, derived from the body's AST
          # while it still existed. Carried but not yet consulted -- the cone of influence is
          # #92 and projected fingerprinting is #93.
          reads: unquote(Macro.escape(action.reads)),
          writes: unquote(Macro.escape(action.writes))
        }
      end
    end
  end

  defp compiled_invariants(invariants) do
    for %{name: name, description: description, fun: fun, near_miss_fun: near_miss} = inv <-
          invariants do
      near_miss =
        if near_miss, do: quote(do: &(__MODULE__.unquote(near_miss) / 2)), else: nil

      quote do
        %{
          name: unquote(name),
          description: unquote(description),
          predicate: &(__MODULE__.unquote(fun) / 2),
          near_miss: unquote(near_miss),
          # #87/#91. `type_ok` is the exception that matters: it reads every variable by
          # construction, so a cone built naively from invariants is always the whole state.
          # #92 handles it separately rather than letting it collapse every projection.
          reads: unquote(Macro.escape(inv.reads))
        }
      end
    end
  end

  defp compiled_action_properties(properties) do
    for %{name: name, description: description, fun: fun} <- properties do
      quote do
        %{
          name: unquote(name),
          description: unquote(description),
          predicate: &(__MODULE__.unquote(fun) / 3)
        }
      end
    end
  end

  # The `description` is what the author wrote in `desc:`, and it travels to the liveness
  # checker's refutation message the way an invariant's travels to a violation's (#176). It
  # was STORED and dropped here for a fortnight: #160 made the macro keep it, on the
  # reasoning that accepting an option nothing reads is the same defect as an unknown key,
  # and the value then stopped at this function. The test written to protect that fix
  # asserted only that the module compiles, which the pre-fix code did too.
  defp compiled_temporals(temporals) do
    for %{name: name, description: description, opts: opts, fun: fun} <- temporals do
      quote do
        %{
          name: unquote(name),
          description: unquote(description),
          formula: &(__MODULE__.unquote(fun) / 1),
          opts: unquote(opts || [])
        }
      end
    end
  end

  defp compiled_terminals(terminals) do
    for %{name: name, fun: fun} <- terminals do
      quote do: %{name: unquote(name), predicate: &(__MODULE__.unquote(fun) / 2)}
    end
  end

  defp compiled_fairness(fairness) do
    for %{kind: kind, action: action, per: per} <- fairness do
      quote do: %{kind: unquote(kind), action: unquote(action), per: unquote(per)}
    end
  end

  # ── Cross-declaration checks ────────────────────────────────────────────────

  defp check_unique_names!(module, kind, declarations) do
    declarations
    |> Enum.group_by(& &1.name)
    |> Enum.each(fn
      {_name, [_single]} ->
        :ok

      {name, [_ | _] = dupes} ->
        CompileError.raise!(
          kind: :duplicate_declaration,
          module: module,
          declaration: "#{kind} #{inspect(name)}",
          line: List.last(dupes).line,
          problem: "#{kind} #{inspect(name)} is declared #{length(dupes)} times",
          hint:
            "Names identify declarations in traces, coverage and counterexamples, so two " <>
              "of them would be two things the output cannot tell apart."
        )
    end)
  end

  # A spec with variables and no `init` has no reachable states at all, and the
  # checker would report "0 states, no violations" — a pass, over nothing.
  defp check_has_init!(module, env, [], [_ | _]) do
    CompileError.raise!(
      kind: :no_init_block,
      module: module,
      declaration: "the spec",
      line: env.line,
      problem: "no `init` block",
      hint:
        "A spec with variables and no initial state has no reachable states, and checking " <>
          "it would report success over an empty search."
    )
  end

  defp check_has_init!(_module, _env, _inits, _variables), do: :ok

  defp check_fairness!(module, %{action: name, per: per, line: line}, actions) do
    action = Enum.find(actions, &(&1.name == name))

    unless action do
      CompileError.raise!(
        kind: :unknown_action_in_fairness,
        module: module,
        declaration: "fairness",
        line: line,
        problem: "unknown action in fairness: #{inspect(name)}",
        hint: known_actions(actions)
      )
    end

    param_names = Enum.map(action.param_sources, fn {param, _} -> param end)

    unless List.starts_with?(param_names, per) do
      CompileError.raise!(
        kind: :fairness_params_not_a_prefix,
        module: module,
        declaration: "fairness",
        line: line,
        problem:
          "fairness params #{inspect(per)} are not a leading prefix of " <>
            "#{inspect(name)}'s params #{inspect(param_names)}",
        hint:
          "`\\A p : SF(Acquire(p))` quantifies over the outermost binding, so the named " <>
            "params have to be the leading ones (02-dsl-semantics.md §5.2)."
      )
    end

    Enum.each(per, fn param ->
      if List.keyfind(action.param_sources, param, 0) == {param, :state} do
        CompileError.raise!(
          kind: :fairness_over_a_state_drawn_param,
          module: module,
          declaration: "fairness",
          line: line,
          problem: "fairness over a state-drawn param: #{inspect(name)}.#{param}",
          hint:
            "Per-binding fairness declares one constraint per binding, and a state function " <>
              "returns a different set in every state — so there is no fixed collection of " <>
              "bindings to attach them to (02-dsl-semantics.md §5.2)."
        )
      end
    end)
  end

  defp known_actions([]), do: "No actions are declared in this module."

  defp known_actions(actions),
    do: "Declared actions: " <> Enum.map_join(actions, ", ", &inspect(&1.name)) <> "."

  defp read(module, attribute) do
    module
    |> Module.get_attribute(attribute)
    |> Kernel.||([])
    |> Enum.reverse()
  end
end
