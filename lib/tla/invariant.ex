defmodule TLA.Invariant do
  @moduledoc """
  Layer 1: invariants and properties on a running OTP process, checked at every transition.

      defmodule Account do
        use GenServer
        use TLA.Invariant

        invariant :never_negative, desc: "an account may not go below zero" do
          state.balance >= 0
        end

        action_property :no_free_money do
          new.balance <= old.balance or new.deposits > old.deposits
        end

        precondition {:withdraw, amount} do
          amount > 0
        end
      end

  `state` is bound in an `invariant`, `old` and `new` in an `action_property`, and in a
  `precondition` or `postcondition` the pattern's own bindings are in scope alongside
  them. Nothing is passed in explicitly, because a property is a statement about the
  process rather than a function of arguments.

  ## `defoverridable` and `super`, not renaming

  The `@before_compile` hook wraps each callback the module defines by marking it
  overridable and defining a new one that calls `super`. An earlier draft of
  `03-layer1-invariants.md` called a generated `__original_handle_call__/3`, which breaks
  on the thing every real GenServer has: several `handle_call/3` clauses with guards.
  Renaming would have to reproduce every clause head and its guards exactly, and any
  mistake silently changes dispatch. `super` keeps the original clauses intact and
  dispatches to them with their own pattern matching.

  `use TLA.Invariant` goes directly **after** `use GenServer` and **before** the
  callbacks, and the order is load-bearing rather than stylistic. Only the callbacks the
  module's own author writes are wrapped, and they are identified with `@on_definition`,
  which sees a definition only after it is installed. That is also what keeps the wrapper
  off the default `handle_call/3`, `handle_cast/2` and `handle_info/2` that `use
  GenServer` injects — `Module.defines?/2` cannot tell those from the author's, calling
  `super` on them is deprecated, and wrapping a default that exists to stop the server
  with a `:bad_call` is checking a transition nobody wrote.

  ## `:disabled` emits nothing

  When `TLA.Config.mode/0` resolves to `:disabled` where the module compiles, the hook
  emits no wrapper and no `defoverridable`, and the module compiles exactly as written.
  That is what "zero production cost" has to mean: not cheap emitted code, but none. It is
  also why the mode is a `compile_env` macro — a runtime lookup would leave an
  `Application.get_env/2` call and a branch on every callback, which alone would exceed the
  budget the whole layer is meant to fit in.

  ## Cost is decided at compile time wherever it can be

  `callbacks:` restricts an invariant to particular callbacks, and the restriction is
  resolved when the wrapper is generated. A hot callback in a module with nine invariants
  emits a call naming the two that apply, rather than nine names and a filter. Where a
  callback ends up with nothing to check, no call is emitted for it at all.

  `enabled: false` is evaluated at compile time and emits nothing anywhere, for a check too
  costly to run outside a particular environment.
  """

  @callbacks [init: 1, handle_call: 3, handle_cast: 2, handle_info: 2, handle_continue: 2]

  # The state argument's position in each callback, and whether there is a pre-state to
  # compare against. `init/1` has none: its result IS the first state, so its invariants
  # are checked and its action properties cannot be.
  @state_position %{init: nil, handle_call: 2, handle_cast: 1, handle_info: 1, handle_continue: 1}

  defmacro __using__(_opts) do
    quote do
      require TLA.Config

      import TLA.Invariant,
        only: [
          invariant: 2,
          invariant: 3,
          action_property: 2,
          action_property: 3,
          precondition: 2,
          precondition: 3,
          postcondition: 2,
          postcondition: 3
        ]

      Module.register_attribute(__MODULE__, :tla_invariants, accumulate: true)
      Module.register_attribute(__MODULE__, :tla_action_properties, accumulate: true)
      Module.register_attribute(__MODULE__, :tla_preconditions, accumulate: true)
      Module.register_attribute(__MODULE__, :tla_postconditions, accumulate: true)
      Module.register_attribute(__MODULE__, :tla_wrapped, accumulate: true)

      @on_definition TLA.Invariant

      # Expanded HERE, in the instrumented module, so the compile-time dependency on the
      # config key lands on it: editing `config :extla, mode: …` recompiles exactly the
      # modules whose emitted code would change.
      @tla_mode TLA.Config.mode()

      # Read here for the same reason the mode is: `:verbose` has to be able to change
      # what is emitted, not merely what fires.
      @tla_telemetry Application.compile_env(:extla, :telemetry, :quiet)

      @before_compile TLA.Invariant
    end
  end

  @doc """
  A state invariant, checked after every transition.

  `state` is bound in the block. Options: `desc:` for the violation message, `enabled:`
  (compile time — false emits nothing), and `callbacks:` to restrict it to some of them.
  """
  defmacro invariant(name, opts \\ [], do: block) do
    quote do
      @tla_invariants %{
        name: unquote(name),
        opts: unquote(Macro.escape(opts)),
        block: unquote(Macro.escape(block))
      }
    end
  end

  @doc """
  A property of a transition. `old` and `new` are bound; same options as `invariant/3`.
  """
  defmacro action_property(name, opts \\ [], do: block) do
    quote do
      @tla_action_properties %{
        name: unquote(name),
        opts: unquote(Macro.escape(opts)),
        block: unquote(Macro.escape(block))
      }
    end
  end

  @doc """
  A condition checked before the matching callback runs.

  `pattern` is matched against the incoming message and its bindings are in scope in the
  block, alongside `state`. A message the pattern does not match has nothing to say about
  it and passes — which is a different thing from a predicate that returned false, and the
  two are reported differently.
  """
  defmacro precondition(pattern, opts \\ [], do: block) do
    quote do
      @tla_preconditions %{
        pattern: unquote(Macro.escape(pattern)),
        opts: unquote(Macro.escape(opts)),
        block: unquote(Macro.escape(block))
      }
    end
  end

  @doc """
  A condition checked after the matching callback returns. `old`, `new` and the pattern's
  bindings are in scope.
  """
  defmacro postcondition(pattern, opts \\ [], do: block) do
    quote do
      @tla_postconditions %{
        pattern: unquote(Macro.escape(pattern)),
        opts: unquote(Macro.escape(opts)),
        block: unquote(Macro.escape(block))
      }
    end
  end

  @doc false
  # Which callbacks the module's own author defined. `use GenServer` injects defaults for
  # three of them before this hook is installed, so they are not recorded — which is the
  # whole point: `Module.defines?/2` cannot tell them apart, and `super` on a GenServer
  # default is deprecated besides.
  def __on_definition__(env, :def, name, args, _guards, _body) do
    if {name, length(args)} in @callbacks do
      Module.put_attribute(env.module, :tla_wrapped, {name, length(args)})
    end

    :ok
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok

  @doc false
  defmacro __before_compile__(env) do
    mode = Module.get_attribute(env.module, :tla_mode)
    telemetry = Module.get_attribute(env.module, :tla_telemetry)

    invariants = declared(env, :tla_invariants)
    action_properties = declared(env, :tla_action_properties)
    preconditions = declared(env, :tla_preconditions)
    postconditions = declared(env, :tla_postconditions)

    predicates =
      predicate_functions(invariants, action_properties, preconditions, postconditions)

    if mode == :disabled do
      # Nothing at all: no wrapper, no `defoverridable`, and not even the predicates —
      # a module compiled `:disabled` is the module its author wrote.
      quote do
      end
    else
      quote do
        unquote(predicates)
        def __tla_mode__, do: unquote(mode)

        def __tla_telemetry__, do: unquote(telemetry)

        unquote(
          wrappers(env, invariants, action_properties, preconditions, postconditions, telemetry)
        )
      end
    end
  end

  # `enabled: false` is resolved here and the declaration never reaches the emitted code.
  defp declared(env, attribute) do
    env.module
    |> Module.get_attribute(attribute, [])
    |> Enum.reverse()
    |> Enum.filter(&Keyword.get(&1.opts, :enabled, true))
  end

  # ── The predicates ──────────────────────────────────────────────────────────

  defp predicate_functions(invariants, action_properties, preconditions, postconditions) do
    state = Macro.var(:state, nil)
    old = Macro.var(:old, nil)
    new = Macro.var(:new, nil)

    invariant_clauses =
      for %{name: name, block: block} <- invariants do
        quote do
          @doc false
          def __tla_invariant__(unquote(name), unquote(state)) do
            _ = unquote(state)
            unquote(block)
          end
        end
      end

    action_property_clauses =
      for %{name: name, block: block} <- action_properties do
        quote do
          @doc false
          def __tla_action_property__(unquote(name), unquote(old), unquote(new)) do
            _ = {unquote(old), unquote(new)}
            unquote(block)
          end
        end
      end

    precondition_clauses =
      for {%{pattern: pattern, block: block}, index} <- Enum.with_index(preconditions) do
        quote do
          @doc false
          def __tla_precondition__(unquote(index), unquote(pattern), unquote(state)) do
            _ = unquote(state)
            unquote(block)
          end

          @doc false
          def __tla_precondition__(unquote(index), _message, _state), do: :no_match
        end
      end

    postcondition_clauses =
      for {%{pattern: pattern, block: block}, index} <- Enum.with_index(postconditions) do
        quote do
          @doc false
          def __tla_postcondition__(
                unquote(index),
                unquote(pattern),
                unquote(old),
                unquote(new)
              ) do
            _ = {unquote(old), unquote(new)}
            unquote(block)
          end

          @doc false
          def __tla_postcondition__(unquote(index), _message, _old, _new), do: :no_match
        end
      end

    quote do
      unquote_splicing(invariant_clauses)
      unquote_splicing(action_property_clauses)
      unquote_splicing(precondition_clauses)
      unquote_splicing(postcondition_clauses)

      @doc false
      def __tla_describe__(kind, name)

      unquote_splicing(descriptions(:invariant, invariants))
      unquote_splicing(descriptions(:action_property, action_properties))
      def __tla_describe__(_kind, _name), do: ""

      @doc false
      def __tla_conditions__(:precondition), do: unquote(indexed(preconditions))
      def __tla_conditions__(:postcondition), do: unquote(indexed(postconditions))
    end
  end

  defp descriptions(kind, declarations) do
    for %{name: name, opts: opts} <- declarations do
      quote do
        def __tla_describe__(unquote(kind), unquote(name)),
          do: unquote(Keyword.get(opts, :desc, ""))
      end
    end
  end

  defp indexed(declarations) do
    for {%{opts: opts}, index} <- Enum.with_index(declarations),
        do: {index, Keyword.get(opts, :desc, "")}
  end

  # ── The wrappers ────────────────────────────────────────────────────────────

  defp wrappers(env, invariants, action_properties, preconditions, postconditions, telemetry) do
    wrapped = env.module |> Module.get_attribute(:tla_wrapped, []) |> Enum.uniq()

    for {callback, arity} <- @callbacks, {callback, arity} in wrapped do
      wrapper(
        callback,
        arity,
        invariants,
        action_properties,
        preconditions,
        postconditions,
        telemetry
      )
    end
  end

  defp wrapper(
         callback,
         arity,
         invariants,
         action_properties,
         preconditions,
         postconditions,
         telemetry
       ) do
    names = applicable(invariants, callback)
    properties = applicable(action_properties, callback)

    # `init/1` has no pre-state — its result is the first state — so it can carry
    # invariants and cannot carry the three things that compare two states.
    pre_state? = @state_position[callback] != nil

    if names == [] and properties == [] and (preconditions == [] or not pre_state?) and
         (postconditions == [] or not pre_state?) do
      quote do
      end
    else
      emit_wrapper(
        callback,
        arity,
        names,
        properties,
        preconditions,
        postconditions,
        pre_state?,
        telemetry
      )
    end
  end

  defp emit_wrapper(
         callback,
         arity,
         names,
         properties,
         preconditions,
         postconditions,
         pre_state?,
         telemetry
       ) do
    verbose = if telemetry == :verbose, do: [:verbose], else: []
    args = Macro.generate_arguments(arity, __MODULE__)
    message = hd(args)
    state = if pre_state?, do: Enum.at(args, @state_position[callback]), else: nil

    pre =
      if pre_state? and preconditions != [] do
        quote do
          TLA.Invariant.Runtime.check_preconditions!(
            __MODULE__,
            unquote(callback),
            unquote(message),
            unquote(state)
          )
        end
      end

    post =
      if pre_state? and postconditions != [] do
        quote do
          TLA.Invariant.Runtime.check_postconditions!(
            __MODULE__,
            unquote(callback),
            unquote(message),
            unquote(state),
            var!(tla_new_state)
          )
        end
      end

    invariant_check =
      if names != [] do
        quote do
          TLA.Invariant.Runtime.check_invariants!(
            __MODULE__,
            unquote(names),
            var!(tla_new_state),
            unquote_splicing(verbose)
          )
        end
      end

    property_check =
      if pre_state? and properties != [] do
        quote do
          TLA.Invariant.Runtime.check_action_properties!(
            __MODULE__,
            unquote(properties),
            unquote(state),
            var!(tla_new_state),
            unquote_splicing(verbose)
          )
        end
      end

    fallback = if pre_state?, do: state, else: quote(do: nil)

    quote do
      defoverridable [{unquote(callback), unquote(arity)}]

      def unquote(callback)(unquote_splicing(args)) do
        unquote(pre)
        tla_result = super(unquote_splicing(args))
        var!(tla_new_state) = TLA.Invariant.Runtime.extract_state(tla_result, unquote(fallback))
        unquote(post)
        unquote(invariant_check)
        unquote(property_check)
        tla_result
      end
    end
  end

  defp applicable(declarations, callback) do
    for %{name: name, opts: opts} <- declarations,
        callback in Keyword.get(opts, :callbacks, Keyword.keys(@callbacks)),
        do: name
  end
end
