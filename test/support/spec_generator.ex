defmodule ExTLA.SpecGenerator do
  @moduledoc """
  Small random specifications, as a scenario source for the agreement properties (#50).

  `verify_symmetry:` runs a model both ways and fails if any verdict differs;
  `parallel_agreement_test.exs` does the same across 1/2/4/8 workers. Both compare **ExTLA
  against ExTLA** — they need no TLA+ and no TLC — and the oracle is the only reason their
  extent is six. Remove the oracle from the loop and scenario volume is limited only by
  time.

  ## Structs, not modules

  A generated spec is a `%ExTLA.Spec.Compiled{}` built directly, with closures for its
  guards and transitions. The alternative — emitting DSL source and compiling a module per
  spec — would be slow and would **create an atom per module**, which is the one thing
  `ExTLA.State.Json`'s `String.to_existing_atom/1` exists to avoid doing from data. Every
  name here comes from a fixed pool, so a thousand generated specs create no atoms at all.

  ## Generated from a description, so shrinking is readable

  `StreamData` generates a plain description — variables, initial states, actions,
  invariants — and `compile/1` turns it into the struct. Shrinking then works on the
  description, and a failure prints something a person can read and retype rather than a
  set of opaque closures.

  ## Bounded by construction

  Every variable ranges over `0..bound`, and an action's guard includes the range
  condition for the change it makes, so no transition can leave the range. The state space
  is at most `(bound + 1)^length(vars)` — a handful of states, which is the point: a
  thousand tiny models exercise more shapes than six large ones, and each one finishes.

  ## What it does not generate, and why

  **Symmetry declarations.** Soundness is the author's obligation (D-17): a declaration is
  sound only if no action and no property can tell the constant's elements apart, and
  nothing verifies that statically. A generator that emitted unsound ones would spend its
  budget on `ExTLA.Symmetry.UnsoundError` rather than on the property under test, so the
  symmetry arm of #50 is left to the hand-written `symmetry_test.exs` until the generator
  can guarantee what D-17 requires.

  **Liveness.** D-22 refuses symmetry with it and D-27 refuses `workers:` with it, so the
  worker property is safety-only by construction.
  """

  alias ExTLA.Spec

  # Fixed pools. Nothing here is computed from generated data, so no atom is ever created
  # at runtime however many specs are drawn.
  @vars [:a, :b, :c]
  @action_names [:act1, :act2, :act3, :act4]
  @invariant_names [:inv1, :inv2]

  if Code.ensure_loaded?(StreamData) do
    @doc """
    A generator of spec descriptions. `compile/1` turns one into a `Spec.Compiled`.
    """
    @spec description() :: StreamData.t(map())
    def description do
      StreamData.bind(StreamData.integer(1..2), fn bound ->
        StreamData.bind(StreamData.integer(2..3), fn var_count ->
          vars = Enum.take(@vars, var_count)

          StreamData.fixed_map(%{
            bound: StreamData.constant(bound),
            vars: StreamData.constant(vars),
            init: initial_states(vars, bound),
            actions: actions(vars, bound),
            invariants: invariants(vars, bound)
          })
        end)
      end)
    end

    defp initial_states(vars, bound) do
      StreamData.uniq_list_of(
        StreamData.fixed_map(Map.new(vars, &{&1, StreamData.integer(0..bound)})),
        min_length: 1,
        max_length: 2
      )
    end

    defp actions(vars, bound) do
      StreamData.uniq_list_of(
        StreamData.fixed_map(%{
          var: StreamData.member_of(vars),
          op: StreamData.member_of([:inc, :dec]),
          # A guard on another variable, or none. This is what makes some actions
          # disabled in some states, which is what makes the state graph a graph rather
          # than a product.
          guard:
            StreamData.one_of([
              StreamData.constant(nil),
              StreamData.tuple(
                {StreamData.member_of(vars), StreamData.member_of([:lt, :gt, :eq]),
                 StreamData.integer(0..bound)}
              )
            ]),
          # Params, so binding enumeration is exercised too.
          step: StreamData.member_of([:one, :param])
        }),
        min_length: 1,
        max_length: 4
      )
      |> StreamData.map(fn actions ->
        actions |> Enum.with_index() |> Enum.map(fn {a, i} -> Map.put(a, :name, name(i)) end)
      end)
    end

    defp invariants(vars, bound) do
      StreamData.uniq_list_of(
        StreamData.fixed_map(%{
          var: StreamData.member_of(vars),
          limit: StreamData.integer(0..bound)
        }),
        max_length: 2
      )
      |> StreamData.map(fn invariants ->
        invariants
        |> Enum.with_index()
        |> Enum.map(fn {inv, i} -> Map.put(inv, :name, Enum.at(@invariant_names, i)) end)
      end)
    end

    defp name(index), do: Enum.at(@action_names, rem(index, length(@action_names)))
  else
    @doc "Unavailable: `stream_data` is not loaded."
    @spec description() :: no_return()
    def description do
      raise ArgumentError, "ExTLA.SpecGenerator needs `stream_data`, which is not loaded."
    end
  end

  @doc """
  Turn a description into a `ExTLA.Spec.Compiled` the checker will run.

  Deterministic: the same description always compiles to the same spec, which is what
  makes a recorded seed reproduce a failure exactly.
  """
  @spec compile(map()) :: Spec.Compiled.t()
  def compile(description) do
    %Spec.Compiled{
      module: __MODULE__,
      constants: [],
      variables: Enum.map(description.vars, &%{name: &1, type: nil}),
      init: Enum.map(description.init, fn state -> fn _constants -> state end end),
      actions: Enum.map(description.actions, &action(&1, description)),
      invariants: Enum.map(description.invariants, &invariant/1),
      action_properties: [],
      temporals: [],
      terminals: [],
      fairness: []
    }
  end

  defp action(%{step: :one} = spec, description) do
    %{
      name: spec.name,
      params: [],
      param_sources: [],
      guard: fn _c, state, _p -> in_range?(spec, state, 1, description) and extra(spec, state) end,
      transition: fn _c, state, _p -> Map.update!(state, spec.var, &apply_op(spec.op, &1, 1)) end
    }
  end

  defp action(%{step: :param} = spec, description) do
    %{
      name: spec.name,
      params: [{:d, fn _c, _state, _bound -> [1, 2] end}],
      param_sources: [{:d, :literal}],
      guard: fn _c, state, params ->
        in_range?(spec, state, params.d, description) and extra(spec, state)
      end,
      transition: fn _c, state, params ->
        Map.update!(state, spec.var, &apply_op(spec.op, &1, params.d))
      end
    }
  end

  # The range condition is part of every guard, so a transition can never leave
  # `0..bound` and the state space is finite by construction rather than by luck.
  defp in_range?(%{op: :inc, var: var}, state, by, %{bound: bound}),
    do: Map.fetch!(state, var) + by <= bound

  defp in_range?(%{op: :dec, var: var}, state, by, _description),
    do: Map.fetch!(state, var) - by >= 0

  defp extra(%{guard: nil}, _state), do: true
  defp extra(%{guard: {var, :lt, value}}, state), do: Map.fetch!(state, var) < value
  defp extra(%{guard: {var, :gt, value}}, state), do: Map.fetch!(state, var) > value
  defp extra(%{guard: {var, :eq, value}}, state), do: Map.fetch!(state, var) == value

  defp apply_op(:inc, value, by), do: value + by
  defp apply_op(:dec, value, by), do: value - by

  defp invariant(%{name: name, var: var, limit: limit}) do
    %{
      name: name,
      description: "#{var} <= #{limit}",
      predicate: fn _c, state -> Map.fetch!(state, var) <= limit end,
      near_miss: nil
    }
  end

  @doc """
  A description rendered as something a person can read in a failure message, and retype.
  """
  @spec format(map()) :: String.t()
  def format(description) do
    actions =
      Enum.map_join(description.actions, "\n", fn a ->
        "    #{a.name}: #{a.op} #{a.var} by #{if a.step == :one, do: "1", else: "d in [1,2]"}" <>
          if(a.guard, do: " when #{inspect(a.guard)}", else: "")
      end)

    invariants =
      Enum.map_join(description.invariants, "\n", fn i ->
        "    #{i.name}: #{i.var} <= #{i.limit}"
      end)

    """
      vars: #{inspect(description.vars)} over 0..#{description.bound}
      init: #{inspect(description.init)}
      actions:
    #{actions}
      invariants:
    #{if invariants == "", do: "    (none)", else: invariants}
    """
  end
end
