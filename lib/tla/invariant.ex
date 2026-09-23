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

  @callbacks [
    init: 1,
    handle_call: 3,
    handle_cast: 2,
    handle_info: 2,
    handle_continue: 2,
    handle_event: 4
  ]

  # The state argument's position in each callback, and whether there is a pre-state to
  # compare against. `init/1` has none: its result IS the first state, so its invariants
  # are checked and its action properties cannot be. `handle_event/4` has no single
  # position — a state machine's state is the `{state_name, data}` pair, built in
  # `state_expression/2` from two arguments.
  @state_position %{
    init: nil,
    handle_call: 2,
    handle_cast: 1,
    handle_info: 1,
    handle_continue: 1,
    handle_event: :statem
  }

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
    declaration = "invariant #{inspect(name)}"
    {enabled, opts} = pop_enabled!(opts, __CALLER__, declaration)

    quote do
      @tla_invariants %{
        name: unquote(name),
        opts: unquote(Macro.escape(opts)),
        enabled: TLA.Invariant.__enabled__!(unquote(enabled), unquote(declaration)),
        block: unquote(Macro.escape(block))
      }
    end
  end

  @doc """
  A property of a transition. `old` and `new` are bound; same options as `invariant/3`.
  """
  defmacro action_property(name, opts \\ [], do: block) do
    declaration = "action_property #{inspect(name)}"
    {enabled, opts} = pop_enabled!(opts, __CALLER__, declaration)

    quote do
      @tla_action_properties %{
        name: unquote(name),
        opts: unquote(Macro.escape(opts)),
        enabled: TLA.Invariant.__enabled__!(unquote(enabled), unquote(declaration)),
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
    declaration = "precondition"
    {enabled, opts} = pop_enabled!(opts, __CALLER__, declaration)

    quote do
      @tla_preconditions %{
        pattern: unquote(Macro.escape(pattern)),
        opts: unquote(Macro.escape(opts)),
        enabled: TLA.Invariant.__enabled__!(unquote(enabled), unquote(declaration)),
        block: unquote(Macro.escape(block))
      }
    end
  end

  @doc """
  A condition checked after the matching callback returns. `old`, `new` and the pattern's
  bindings are in scope.
  """
  defmacro postcondition(pattern, opts \\ [], do: block) do
    declaration = "postcondition"
    {enabled, opts} = pop_enabled!(opts, __CALLER__, declaration)

    quote do
      @tla_postconditions %{
        pattern: unquote(Macro.escape(pattern)),
        opts: unquote(Macro.escape(opts)),
        enabled: TLA.Invariant.__enabled__!(unquote(enabled), unquote(declaration)),
        block: unquote(Macro.escape(block))
      }
    end
  end

  # `enabled:` is the one declaration option whose VALUE matters rather than its syntax, and
  # that difference is why it did not work (#149).
  #
  # Every other option is stored with `Macro.escape/1` and read back as a literal: `desc: "x"`
  # escapes to the string, `callbacks: [:handle_cast]` to the list. `enabled: Mix.env() == :test`
  # escapes to a `{:==, _, _}` TUPLE -- and `Enum.filter/2` keeps everything but `false` and
  # `nil`, so the tuple was truthy and the declaration was always emitted. The option worked
  # for a literal `false` and for nothing else, which is the one input for which it is useless,
  # since a literal `false` is indistinguishable from deleting the declaration.
  #
  # So `enabled:` is popped out and spliced UNESCAPED into the caller's module body, where it
  # is evaluated at the caller's compile time in the caller's context. `Mix.env()` resolves;
  # `Application.compile_env/3` resolves and registers its recompilation dependency properly,
  # which manual evaluation here would not.
  #
  # Two failure modes, both loud:
  #
  #   * an expression that does not evaluate to a boolean is caught by `__enabled__!/2` below,
  #     naming the declaration;
  #   * an expression that does not evaluate at all -- an undefined variable, a missing module
  #     -- is Elixir's own compile error at the declaration's line. That one does not carry
  #     the declaration name, and adding it would mean wrapping the evaluation in a rescue,
  #     which would swallow real bugs to improve a message.
  # Which options each declaration kind actually consumes. `callbacks:` is honoured only for
  # invariants and action properties -- `applicable/2` is reached from the wrapper, and
  # preconditions and postconditions do not go through it, they are emitted from
  # `__tla_conditions__/1`. So `precondition {:x, n}, callbacks: [:handle_cast]` used to be
  # accepted and silently ignored, which is the same defect as an unknown key: an option
  # nobody reads is indistinguishable from an option nobody wrote (#149 item 2).
  @accepted_options %{
    "invariant" => [:desc, :enabled, :callbacks],
    "action_property" => [:desc, :enabled, :callbacks],
    "precondition" => [:desc, :enabled],
    "postcondition" => [:desc, :enabled]
  }

  defp pop_enabled!(opts, caller, declaration) when is_list(opts) do
    reject_unknown_options!(opts, caller, declaration)
    Keyword.pop(opts, :enabled, true)
  end

  defp pop_enabled!(opts, caller, declaration) do
    raise CompileError.exception(
            file: caller.file,
            line: caller.line,
            description:
              "#{declaration}: options must be a literal keyword list, got " <>
                "#{Macro.to_string(opts)}. `enabled:` is read at compile time, so the list " <>
                "cannot be built at runtime."
          )
  end

  # A key nobody reads and a key nobody wrote look the same to a `Keyword.get/3` with a
  # default, which is how `callbaks: [:handle_cast]` came to compile into an invariant that
  # applied to every callback. The accepted set is small and fixed, so saying which key is
  # wrong and what was expected costs nothing and is the whole difference between a typo
  # found at compile time and a check quietly doing something else.
  defp reject_unknown_options!(opts, caller, declaration) do
    kind = declaration |> String.split(" ") |> hd()
    accepted = Map.fetch!(@accepted_options, kind)

    reject_unknown_callbacks!(opts, caller, declaration)

    unless Keyword.keyword?(opts) do
      raise CompileError.exception(
              file: caller.file,
              line: caller.line,
              description: "#{declaration}: options must be a keyword list, got #{inspect(opts)}"
            )
    end

    case opts |> Keyword.keys() |> Enum.uniq() |> Enum.reject(&(&1 in accepted)) do
      [] ->
        :ok

      unknown ->
        raise CompileError.exception(
                file: caller.file,
                line: caller.line,
                description:
                  "#{declaration}: unknown option#{if length(unknown) > 1, do: "s"} " <>
                    "#{Enum.map_join(unknown, ", ", &inspect/1)}. " <>
                    "#{kind} accepts #{Enum.map_join(accepted, ", ", &inspect/1)}."
              )
    end
  end

  # A `callbacks:` VALUE naming a callback that does not exist deletes the declaration
  # silently (#166). `applicable/2` keeps a name only where the callback matches, so a typo
  # yields an empty name list for every wrapper and the invariant applies to nothing:
  #
  #     invariant :never_negative, callbacks: [:handle_cal] do   # typo
  #
  # Verified: a withdrawal of 999 against a balance of 100 returned `:ok` and left `-899`.
  #
  # This is #158's defect one level down -- there the KEY was unchecked, here the VALUE is --
  # and the accepted set is just as small and fixed, so it gets the same treatment.
  #
  # Only a literal list is checkable here; anything else is left to `check_declared_callbacks!/2`
  # after `@on_definition` has seen the module's definitions.
  defp reject_unknown_callbacks!(opts, caller, declaration) do
    with true <- Keyword.keyword?(opts),
         names when is_list(names) <- Keyword.get(opts, :callbacks),
         true <- Enum.all?(names, &is_atom/1) do
      case Enum.reject(names, &Keyword.has_key?(@callbacks, &1)) do
        [] ->
          :ok

        unknown ->
          raise CompileError.exception(
                  file: caller.file,
                  line: caller.line,
                  description:
                    "#{declaration}: `callbacks:` names #{Enum.map_join(unknown, ", ", &inspect/1)}, " <>
                      "which is not an instrumented callback. Accepted: " <>
                      "#{@callbacks |> Keyword.keys() |> Enum.map_join(", ", &inspect/1)}. " <>
                      "A callback that does not exist matches no wrapper, so the declaration " <>
                      "would be emitted for nothing and never checked."
                )
      end
    else
      _not_a_literal_list -> :ok
    end
  end

  # The other half, and the likelier one in a codebase that changes: a callback that EXISTS
  # but this module does not define. `@tla_wrapped` is only complete at `@before_compile`, so
  # this cannot run at declaration time.
  #
  # It is a warning rather than an error because it is legitimate in one case -- a callback
  # added to the module later, in a subsequent edit -- and because raising would make the
  # order of definitions load-bearing in a way the macro's own docs already warn is fragile.
  defp check_declared_callbacks!(declarations, wrapped, env) do
    defined = MapSet.new(wrapped, fn {name, _arity} -> name end)

    for %{name: name, opts: opts} <- declarations,
        requested = Keyword.get(opts, :callbacks),
        is_list(requested),
        missing = Enum.reject(requested, &MapSet.member?(defined, &1)),
        missing != [] do
      IO.warn(
        "#{inspect(env.module)}: #{inspect(name)} is restricted to " <>
          "#{Enum.map_join(missing, ", ", &inspect/1)}, which this module does not define, " <>
          "so it will never be checked. Define the callback, or drop it from `callbacks:`.",
        Macro.Env.stacktrace(env)
      )
    end

    :ok
  end

  @doc false
  # Called in the caller's module body with `enabled:`'s evaluated value. A non-boolean is a
  # mistake worth naming -- before #149 it was silently truthy, which is how `Mix.env() == :test`
  # read as "always on".
  def __enabled__!(value, _declaration) when is_boolean(value), do: value

  def __enabled__!(value, declaration) do
    raise ArgumentError,
          "#{declaration}: `enabled:` must evaluate to a boolean at compile time, got " <>
            "#{inspect(value)}. It decides whether this declaration is emitted at all, so a " <>
            "truthy non-boolean cannot be accepted as `true` -- that is the defect #149 fixed."
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

  # `enabled:` is resolved in the CALLER, at its compile time -- see `pop_enabled!/3`. By the
  # time a declaration reaches here its `:enabled` is a real boolean, so a false one never
  # reaches the emitted code.
  defp declared(env, attribute) do
    env.module
    |> Module.get_attribute(attribute, [])
    |> Enum.reverse()
    |> Enum.filter(& &1.enabled)
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

      # Every declared name, unfiltered by `callbacks:`. The wrappers do not use this —
      # they are emitted with the names that apply to them — but a caller with no callback
      # to speak of does: `TLA.Invariant.Agent`, whose transitions run inside somebody
      # else's process, and `TLA.Invariant.Test`, which has to name every invariant that
      # failed rather than the first.
      @doc false
      def __tla_names__(:invariant), do: unquote(Enum.map(invariants, & &1.name))
      def __tla_names__(:action_property), do: unquote(Enum.map(action_properties, & &1.name))
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
    check_declared_callbacks!(invariants ++ action_properties, wrapped, env)

    context = %{
      invariants: invariants,
      action_properties: action_properties,
      preconditions: preconditions,
      postconditions: postconditions,
      telemetry: telemetry,
      # A module that defines `handle_event/4` is a state machine, and that decides how
      # its `init/1` is read too: a GenServer's returns `{:ok, state}`, a state machine's
      # returns `{:ok, state_name, data}`, and the shared `extract_state/2` would take the
      # name for the whole state.
      statem?: {:handle_event, 4} in wrapped
    }

    for {callback, arity} <- @callbacks, {callback, arity} in wrapped do
      wrapper(callback, arity, context)
    end
  end

  defp wrapper(callback, arity, context) do
    names = applicable(context.invariants, callback)
    properties = applicable(context.action_properties, callback)

    # `init/1` has no pre-state — its result is the first state — so it can carry
    # invariants and cannot carry the three things that compare two states.
    pre_state? = @state_position[callback] != nil

    context =
      Map.merge(context, %{names: names, properties: properties, pre_state?: pre_state?})

    cond do
      not pre_state? and names == [] -> quote(do: nil)
      pre_state? and nothing_to_check?(context) -> quote(do: nil)
      not pre_state? -> emit_init_wrapper(arity, context)
      true -> emit_wrapper(callback, arity, context)
    end
  end

  defp nothing_to_check?(context) do
    context.names == [] and context.properties == [] and context.preconditions == [] and
      context.postconditions == []
  end

  # `init/1`, which carries invariants and nothing else — and only when it produced a
  # state at all. `:ignore` and a bare `{:stop, reason}` are refusals to start, not first
  # states, and checking an invariant against the absence of one would report a violation
  # of a predicate that was never given anything to be about.
  defp emit_init_wrapper(arity, context) do
    args = Macro.generate_arguments(arity, __MODULE__)
    verbose = verbose(context.telemetry)

    shape = if context.statem?, do: :statem, else: :genserver

    quote do
      defoverridable [{:init, unquote(arity)}]

      def init(unquote_splicing(args)) do
        tla_result = super(unquote_splicing(args))

        TLA.Invariant.Runtime.check_initial_invariants!(
          __MODULE__,
          unquote(context.names),
          tla_result,
          unquote(shape),
          unquote_splicing(verbose)
        )

        tla_result
      end
    end
  end

  defp emit_wrapper(callback, arity, context) do
    verbose = verbose(context.telemetry)
    args = Macro.generate_arguments(arity, __MODULE__)
    message = message_expression(callback, args)
    state = state_expression(callback, args)

    # `verbose` is spliced into all FOUR calls. It reached only the two below it until #279,
    # so `[:extla, :precondition, :checked]` and `[:extla, :postcondition, :checked]` were
    # documented in `03-layer1-invariants.md` and could not fire — and the same file's API
    # block, three hundred lines down, listed the two arities the code actually had. #22
    # amended the block from the code and left the event table where it was.
    pre =
      if context.preconditions != [] do
        quote do
          TLA.Invariant.Runtime.check_preconditions!(
            __MODULE__,
            unquote(callback),
            unquote(message),
            unquote(state),
            unquote_splicing(verbose)
          )
        end
      end

    post =
      if context.postconditions != [] do
        quote do
          TLA.Invariant.Runtime.check_postconditions!(
            __MODULE__,
            unquote(callback),
            unquote(message),
            unquote(state),
            var!(tla_new_state),
            unquote_splicing(verbose)
          )
        end
      end

    invariant_check =
      if context.names != [] do
        quote do
          TLA.Invariant.Runtime.check_invariants!(
            __MODULE__,
            unquote(context.names),
            var!(tla_new_state),
            unquote_splicing(verbose)
          )
        end
      end

    property_check =
      if context.properties != [] do
        quote do
          TLA.Invariant.Runtime.check_action_properties!(
            __MODULE__,
            unquote(context.properties),
            unquote(state),
            var!(tla_new_state),
            unquote_splicing(verbose)
          )
        end
      end

    quote do
      defoverridable [{unquote(callback), unquote(arity)}]

      def unquote(callback)(unquote_splicing(args)) do
        unquote(pre)
        tla_result = super(unquote_splicing(args))
        var!(tla_new_state) = unquote(extraction(callback, state))
        unquote(post)
        unquote(invariant_check)
        unquote(property_check)
        tla_result
      end
    end
  end

  defp verbose(:verbose), do: [:verbose]
  defp verbose(_telemetry), do: []

  # A state machine's state is the `{state_name, data}` pair, which is what `invariant`
  # and `action_property` bind — §03's `TrafficLight` destructures it in the block. The
  # pair is built here rather than passed as two arguments so that every declaration is
  # written against one `state`, whatever behaviour the module implements.
  defp state_expression(:handle_event, args) do
    quote do: {unquote(Enum.at(args, 2)), unquote(Enum.at(args, 3))}
  end

  defp state_expression(callback, args), do: Enum.at(args, @state_position[callback])

  # For a GenServer the message a precondition matches is the callback's first argument.
  # For a state machine it is the event *content* — not `{event_type, content}` — so that
  # a `precondition {:withdraw, amount}` is the same declaration whichever behaviour
  # carries it, and so that a pattern does not have to know whether the message arrived as
  # a call, a cast or an info.
  defp message_expression(:handle_event, args), do: Enum.at(args, 1)
  defp message_expression(_callback, args), do: hd(args)

  # `:gen_statem`'s returns are a different language from a GenServer's, and one of them
  # collides: `{:stop, reason, new_data}` carries DATA where a GenServer's carries the
  # whole state. So the state machine gets its own extraction rather than more clauses on
  # the shared one.
  defp extraction(:handle_event, fallback) do
    quote do: TLA.Invariant.Runtime.extract_statem_state(tla_result, unquote(fallback))
  end

  defp extraction(_callback, fallback) do
    quote do: TLA.Invariant.Runtime.extract_state(tla_result, unquote(fallback))
  end

  defp applicable(declarations, callback) do
    for %{name: name, opts: opts} <- declarations,
        callback in Keyword.get(opts, :callbacks, Keyword.keys(@callbacks)),
        do: name
  end
end
