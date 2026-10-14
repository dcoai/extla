defmodule ExTLA.GenServer do
  @moduledoc """
  Layer 3: a GenServer checked against the specification it claims to refine.

      defmodule Counter do
        use GenServer
        use ExTLA.GenServer, spec: Specs.Counter, refinement: __MODULE__.Refinement

        defmodule Refinement do
          use ExTLA.Refinement

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

  `use ExTLA.GenServer` implies `use ExTLA.Invariant`, so a module may declare `invariant`,
  `action_property`, `precondition` and `postcondition` on its *concrete* state alongside
  the spec's on its abstract one. The two hooks wrap the same callbacks independently and
  nest: neither renames anything, both use `defoverridable` and `super`.

  ## `validate!/3` runs at compile time

  A mapping that does not cover the spec's variables or actions fails the build rather
  than producing misleading passes at runtime. What it cannot decide — the two rules that
  need a concrete state — it names in the deferred list, and `ExTLA.Refinement.abstract!/3`
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
    spec_version = Keyword.get(opts, :spec_version)

    quote do
      use ExTLA.Invariant

      @tla_spec unquote(spec_module)
      @tla_refinement unquote(refinement_module)
      @tla_spec_version unquote(spec_version)

      @before_compile ExTLA.GenServer
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
    stamp = Module.get_attribute(env.module, :tla_spec_version)

    if mode == :disabled do
      quote do
      end
    else
      validate!(spec, refinement)
      check_stamp!(env, spec, stamp)
      # Still-in-the-definitions-table, for the reason `ExTLA.Invariant`'s moduledoc gives at
      # length (#171, #300): `use GenServer` injects `init/1` from its own `@before_compile`,
      # AFTER `@on_definition` is installed, so the hook records it for a module that never
      # wrote one — and by now GenServer's `defoverridable init: 1` has moved it out of the
      # table, so `Module.make_overridable/2` refuses.
      #
      # #300 fixed Layer 1 and left this. Layer 3 hits it UNCONDITIONALLY, because
      # `init_wrapper/1` wraps `init/1` for every mapping rather than only where an invariant
      # applies — and the example at the top of this very moduledoc failed to compile because
      # of it. Found by #301, which compiles the moduledoc examples.
      wrapped =
        env.module
        |> Module.get_attribute(:tla_wrapped, [])
        |> Enum.uniq()
        |> Enum.filter(&Module.defines?(env.module, &1, :def))

      quote do
        @doc false
        def __tla_spec_module__, do: @tla_spec

        @doc false
        def __tla_refinement__, do: @tla_refinement

        @doc false
        def __tla_spec_version__, do: @tla_spec_version

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
  # The `spec_version:` stamp (#67).
  #
  # OPT-IN. A mapping without a stamp compiles exactly as before, and `unstamped` is a
  # legitimate state the ledger reports — this cannot break existing users, and a mechanism
  # that forced every mapping to carry a hash on day one would be adopted by pasting hashes.
  defp check_stamp!(_env, _spec, nil), do: :ok

  defp check_stamp!(env, spec, stamp) do
    case ExTLA.Spec.Hash.module_version(spec) do
      # No source on disk — a spec from a released package. The stamp cannot be checked, and
      # saying so is the honest outcome: passing silently would let an unverifiable stamp read
      # as a verified one, which is worse than having no stamp at all.
      nil ->
        IO.warn(
          "cannot verify spec_version for #{inspect(spec)}: its source is not on disk, or " <>
            "its `defmodule` is not spelled with a literal name (`defmodule __MODULE__.Spec` " <>
            "cannot be located from source), so the stamp is unchecked here.",
          Macro.Env.stacktrace(env)
        )

      ^stamp ->
        :ok

      current ->
        raise ExTLA.Spec.CompileError, """
        #{inspect(env.module)} is stamped against #{inspect(spec)} version #{stamp}, \
        but that spec is now version #{current}.

        The refinement mapping was written against a spec that has since changed. Nothing
        about the mapping itself is checked by this — `abstract/1` still compiles and still
        returns an action name — so the risk is a mapping that is now wrong and whose only
        symptom is a `:diverged` at runtime, on a path that may not be exercised for months.

        RE-READ the mapping against the spec as it stands and confirm that each variable and
        action it names still means what it did. Then record that you have:

            use ExTLA.GenServer,
              spec: #{inspect(spec)},
              spec_version: "#{current}"

        `mix extla.stamp --restamp` will make that edit once you have made the judgement. It is
        a convenience for a decision already taken, not a way to skip it.
        """
    end
  end

  defp validate!(spec, refinement) do
    Code.ensure_compiled!(spec)
    Code.ensure_compiled!(refinement)

    {:ok, deferred} = ExTLA.Refinement.validate!(refinement, spec)
    report_deferred(refinement, deferred)
  end

  # `validate!/3`'s moduledoc argues that "a validator that claims a check it cannot perform
  # is worse than one that states its limits" — and until #169 the statement of limits was
  # discarded here, at the only call site: `{:ok, _deferred} = …`. A user whose mapping has
  # no `concrete_message/2`, so action coverage was never checked at all, was never told.
  #
  # Only the entries tagged `:for_this_mapping` are printed. The two rules that need a
  # concrete state are deferred for every mapping — that is how validation works, not news
  # about this one — and a compile-time message that fires on every module is one a reader
  # learns to skip, which would leave the ones that matter unread.
  defp report_deferred(refinement, deferred) do
    case for {:for_this_mapping, rule} <- deferred, do: rule do
      [] ->
        :ok

      rules ->
        # A message, not a warning, and the distinction is load-bearing.
        #
        # `concrete_message/2` is an `@optional_callbacks` entry: a mapping without one is
        # legal and documented — it can still be CHECKED as it runs, it just cannot be
        # DRIVEN. `IO.warn/2` participates in `--warnings-as-errors`, which this project
        # uses and many consumers do, so warning here would turn a documented choice into a
        # build failure. The first version of this did exactly that and reddened the
        # `compile` job on this repository's own `Undrivable` fixture.
        #
        # What the reader needs is to know which rules went unchecked. That is information,
        # and it belongs on stderr in the register of information.
        IO.puts(
          :stderr,
          """

          #{inspect(refinement)}: #{length(rules)} refinement rule(s) were not checked.

            #{Enum.join(rules, "\n  ")}

          These are limits of what a compile can decide, not findings. `ExTLA.Coverage`
          reports what a run actually exercised (`ExTLA.Refinement`, "What `validate!/3`
          establishes").
          """
        )

        :ok
    end
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
          ExTLA.GenServer.Runtime.record_initial!(@tla_spec, @tla_refinement, tla_result)
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
        tla_pre = ExTLA.GenServer.Runtime.abstract!(@tla_spec, @tla_refinement, unquote(state))
        tla_result = super(unquote_splicing(args))

        tla_post =
          tla_result
          |> ExTLA.Invariant.Runtime.extract_state(unquote(state))
          |> then(&ExTLA.GenServer.Runtime.abstract!(@tla_spec, @tla_refinement, &1))

        ExTLA.GenServer.Runtime.check_transition!(
          @tla_spec,
          @tla_refinement,
          unquote(message),
          tla_pre,
          tla_post
        )

        ExTLA.GenServer.Runtime.check_spec_invariants!(@tla_spec, tla_post)
        ExTLA.GenServer.Runtime.check_action_properties!(@tla_spec, tla_pre, tla_post)

        ExTLA.GenServer.Runtime.record_transition!(
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
