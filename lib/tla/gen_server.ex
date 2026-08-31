defmodule TLA.GenServer do
  @moduledoc """
  Layer 3: a GenServer checked against the specification it claims to refine.

      defmodule Counter do
        use GenServer
        use TLA.GenServer, spec: Specs.Counter, refinement: __MODULE__.Refinement

        defmodule Refinement do
          use TLA.Refinement

          def abstract(%{value: v, status: s}), do: %{count: v, status: s}
          def abstract_action({:increment, _}), do: {:increment, %{}}
          def abstract_action(_), do: :unmapped
          def concrete_message(:increment, _), do: {:increment, 1}
        end

        # ... ordinary GenServer callbacks
      end

  Every transition is mapped through the refinement, and then four things happen:

  1. the **step** is checked against the spec's action — the guard must have held, and the
     spec's transition must reproduce the abstract post-state;
  2. an `:unmapped` message must not have moved the abstract state;
  3. the spec's invariants and action properties are checked on the abstract states; and
  4. the transition is appended to the process's bounded behaviour trace.

  Step 1 is the point. Without it the layer verifies that a projection of the state
  satisfies some predicates, which passes every implementation bug that reaches a
  legal-looking state by an illegal route (`05-layer3-conformance.md` §What conformance
  means here). §07's Example 4 is exactly that bug: an `increment` that also does `done`'s
  work leaves `count` in bounds, so every invariant holds and only the step check refuses
  it.

  ## Layer 1 comes with it

  `use TLA.GenServer` implies `use TLA.Invariant`, so a module may declare `invariant`,
  `action_property`, `precondition` and `postcondition` on its *concrete* state alongside
  the spec's on its abstract one. The two hooks wrap the same callbacks independently and
  nest: neither renames anything, both use `defoverridable` and `super`.

  ## `validate!/2` runs at compile time

  A mapping that does not cover the spec's variables or actions fails the build rather
  than producing misleading passes at runtime. What it cannot decide — the two rules that
  need a concrete state — it names in the deferred list, and `TLA.Refinement.abstract!/3`
  checks those on every mapping instead.

  ## `:disabled` emits nothing

  As in Layer 1, and for the same reason: the mode is resolved where the instrumented
  module compiles, and under `:disabled` the module compiles exactly as written — no
  wrapper, no `defoverridable`, and no compile-time validation of a mapping that will
  never run.
  """

  @doc false
  defmacro __using__(opts) do
    spec_module = Keyword.fetch!(opts, :spec)
    refinement_module = Keyword.fetch!(opts, :refinement)

    quote do
      use TLA.Invariant

      @tla_spec unquote(spec_module)
      @tla_refinement unquote(refinement_module)

      @before_compile TLA.GenServer
    end
  end

  # The transition-carrying callbacks. `init/1` is wrapped too, but for the trace and the
  # invariants only: its result is the first abstract state, and a first state is not a
  # step for the refinement check to be about.
  @callbacks [handle_call: 3, handle_cast: 2, handle_info: 2, handle_continue: 2]

  @state_position %{handle_call: 2, handle_cast: 1, handle_info: 1, handle_continue: 1}

  @doc false
  defmacro __before_compile__(env) do
    spec = Module.get_attribute(env.module, :tla_spec)
    refinement = Module.get_attribute(env.module, :tla_refinement)
    mode = Module.get_attribute(env.module, :tla_mode)

    if mode == :disabled do
      quote do
      end
    else
      validate!(spec, refinement)
      wrapped = env.module |> Module.get_attribute(:tla_wrapped, []) |> Enum.uniq()

      quote do
        unquote(init_wrapper(wrapped))

        unquote_splicing(
          for {callback, arity} <- @callbacks, {callback, arity} in wrapped do
            wrapper(callback, arity)
          end
        )
      end
    end
  end

  # Compile-time validation, on the module the build is compiling. A refinement mapping
  # that does not cover the spec is a build failure rather than a runtime surprise —
  # `validate!/3` is given the spec's declared constants, because a compile has no run to
  # take an assignment from.
  defp validate!(spec, refinement) do
    Code.ensure_compiled!(spec)
    Code.ensure_compiled!(refinement)

    {:ok, _deferred} = TLA.Refinement.validate!(refinement, spec)
    :ok
  end

  # `init/1`'s result IS the first abstract state. There is no step to check and no
  # `:unmapped` claim to test, but the state has to be in the trace — a temporal property
  # over a behaviour that starts at the second state is a property of a different
  # behaviour.
  defp init_wrapper(wrapped) do
    if {:init, 1} in wrapped do
      quote do
        defoverridable init: 1

        def init(tla_arg) do
          tla_result = super(tla_arg)
          TLA.GenServer.Runtime.record_initial!(@tla_spec, @tla_refinement, tla_result)
          tla_result
        end
      end
    end
  end

  defp wrapper(callback, arity) do
    args = Macro.generate_arguments(arity, __MODULE__)
    message = hd(args)
    state = Enum.at(args, @state_position[callback])

    quote do
      defoverridable [{unquote(callback), unquote(arity)}]

      def unquote(callback)(unquote_splicing(args)) do
        tla_pre = TLA.GenServer.Runtime.abstract!(@tla_spec, @tla_refinement, unquote(state))
        tla_result = super(unquote_splicing(args))

        tla_post =
          tla_result
          |> TLA.Invariant.Runtime.extract_state(unquote(state))
          |> then(&TLA.GenServer.Runtime.abstract!(@tla_spec, @tla_refinement, &1))

        TLA.GenServer.Runtime.check_transition!(
          @tla_spec,
          @tla_refinement,
          unquote(message),
          tla_pre,
          tla_post
        )

        TLA.GenServer.Runtime.check_spec_invariants!(@tla_spec, tla_post)
        TLA.GenServer.Runtime.check_action_properties!(@tla_spec, tla_pre, tla_post)

        TLA.GenServer.Runtime.record_transition!(
          @tla_spec,
          unquote(message),
          tla_pre,
          tla_post
        )

        tla_result
      end
    end
  end
end
