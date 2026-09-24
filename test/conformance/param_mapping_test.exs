defmodule TLA.Conformance.ParamMappingTest do
  @moduledoc """
  A refinement mapping for actions that take **params** (#284).

  ## The gap this closes

  `TLA.Refinement.validate!/3` probes each action by applying `concrete_message/2` to a
  sample binding, and `sample_params/3` fell back to `%{}` whenever it had no state to
  draw one from — which is whenever a constant has no value at compile time. For a
  param-less action `%{}` is the real binding and the probe is sound. For an action with
  params it is not a binding the search would ever produce, so a mapping written for the
  real ones matched no clause and the probe raised `FunctionClauseError` **from inside the
  validator**.

  It survived because every refinement fixture in `test/conformance/` is for
  `TLA.Conformance.Counter.Spec`, whose three actions take no params — so the whole suite
  exercised exactly the one case the fallback handles. The specification's own examples do
  not: `spec/07`'s lock server maps `request_lock` with `%{p: p, r: r}`, and it could not
  compile.

  This file is the missing case. `spec/05`'s and `spec/07`'s blocks are the other half of
  the guard, compiled by the guide harness since the skips came off.
  """
  # `async: false` since #169: the config-constants describe block writes application
  # config, which every other test in the VM reads. `async_isolation_test.exs` fails an
  # `async: true` file that does this, which is how the rule is kept.
  use ExUnit.Case, async: false

  alias TLA.Refinement

  defmodule Spec do
    @moduledoc false
    use TLA.Spec

    # No `default:`, which is the shape a published example has: the assignment belongs to
    # a run, so at compile time there is no initial state to draw a binding from.
    constant :resources

    variable :held, type: [^resources ~> [false, true]]

    init do
      held = for_each(^resources, fn _ -> false end)
    end

    action :grab, params: [r: ^resources] do
      require held[r] == false
      held = update(held, r, fn _ -> true end)
    end

    action :drop_all do
      require Enum.any?(^resources, fn r -> held[r] end)
      held = for_each(^resources, fn _ -> false end)
    end
  end

  defmodule Mapping do
    @moduledoc false
    use TLA.Refinement

    def abstract(%{locks: locks}), do: %{held: locks}

    def abstract_action({:grab, r}), do: {:grab, %{r: r}}
    def abstract_action(:drop_all), do: {:drop_all, %{}}
    def abstract_action(_other), do: :unmapped

    # The shape that crashed: a clause per param, and no clause for `%{}`.
    def concrete_message(:grab, %{r: r}), do: {:grab, r}
    def concrete_message(:drop_all, _params), do: :drop_all
  end

  describe "a mapping for an action with params" do
    # The assertion this work item exists for. Before #284 this raised FunctionClauseError.
    test "validates without a binding to probe it with" do
      assert {:ok, _deferred} = Refinement.validate!(Mapping, Spec)
    end

    test "and the action it could not probe is named in the deferred list" do
      {:ok, deferred} = Refinement.validate!(Mapping, Spec)

      # Tagged `:for_this_mapping` since #169, because an un-probed action is news about
      # THIS mapping rather than a limit of every compile — and that is the tag
      # `use TLA.GenServer` prints.
      assert {:for_this_mapping, unprobed} =
               Enum.find(deferred, &match?({:for_this_mapping, _rule}, &1)),
             "nothing in #{inspect(deferred)} names the action that was not probed"

      assert unprobed =~ "[:grab]"
      assert unprobed =~ "[:resources] is not assigned"

      # `drop_all` takes no params, so `%{}` IS its binding and it was really checked.
      refute unprobed =~ "drop_all"
    end

    test "and is fully checked once the constants have values" do
      {:ok, deferred} = Refinement.validate!(Mapping, Spec, %{resources: MapSet.new([:r1, :r2])})

      refute Enum.any?(deferred, &match?({:for_this_mapping, _rule}, &1)),
             "with constants assigned there is a binding to probe with, so nothing is " <>
               "deferred beyond the two no compile can decide"
    end
  end

  describe "the check is not weakened where it can still be made" do
    defmodule Unnamed do
      @moduledoc false
      use TLA.Refinement

      def abstract(%{locks: locks}), do: %{held: locks}
      def abstract_action({:grab, r}), do: {:grab, %{r: r}}
      def abstract_action(_other), do: :unmapped

      # `drop_all` produces a message nothing maps back — the action is dead here.
      def concrete_message(:grab, %{r: r}), do: {:grab, r}
      def concrete_message(:drop_all, _params), do: :nothing_maps_this
    end

    # Skipping the un-probeable actions must not turn into skipping the probe. With
    # constants assigned every action has a binding, and an unnamed one is still refused.
    test "an action no message names is still refused, with constants assigned" do
      error =
        assert_raise Refinement.Error, fn ->
          Refinement.validate!(Unnamed, Spec, %{resources: MapSet.new([:r1, :r2])})
        end

      assert Exception.message(error) =~ "names no message for"
      assert Exception.message(error) =~ "drop_all"
    end

    # And without them, for the param-LESS action, which `%{}` genuinely binds.
    test "and without them, where the action takes no params" do
      error = assert_raise Refinement.Error, fn -> Refinement.validate!(Unnamed, Spec) end

      assert Exception.message(error) =~ "drop_all"
    end
  end

  describe "constants that come only from application config" do
    # `validate!/3` resolved constants with `default_constants/1` — the reader that sees
    # `default:` options and nothing else — so a spec assigned through
    # `config :extla, MySpec, constants: %{…}` was validated against the EMPTY assignment
    # and reported the rules as decided (#169). `resolve_constants/1`, which merges config,
    # was in the same module and simply not the one called.
    setup do
      previous = Application.get_env(:extla, Spec)
      Application.put_env(:extla, Spec, constants: %{resources: MapSet.new([:r1, :r2])})

      on_exit(fn ->
        if previous,
          do: Application.put_env(:extla, Spec, previous),
          else: Application.delete_env(:extla, Spec)
      end)

      :ok
    end

    test "are resolved, so the probes have real bindings to use" do
      {:ok, deferred} = Refinement.validate!(Mapping, Spec)

      refute Enum.any?(deferred, &match?({:for_this_mapping, _rule}, &1)),
             "the constants are in config, so `grab` has bindings and nothing about " <>
               "this mapping is undecided: #{inspect(deferred)}"
    end

    test "and a mapping that is wrong for them still fails" do
      error =
        assert_raise Refinement.Error, fn -> Refinement.validate!(__MODULE__.Unnamed, Spec) end

      assert Exception.message(error) =~ "names no message for"
    end
  end

  describe "the round-trip probe" do
    # Five resources, so an action has five bindings at the initial state — more than the
    # three the probe used to take (#169). `WrongForTheFourth` round-trips correctly for
    # :r1, :r2 and :r3 and wrongly for :r4, which the old sample could not reach.
    #
    # D-35 records why taking all of them costs nothing: measured across the differential
    # corpus, every action has between 0 and 4 bindings at an initial state, because the
    # sets a param draws from are mostly empty there.
    defmodule FiveResources do
      @moduledoc false
      use TLA.Spec

      constant :resources, default: MapSet.new([:r1, :r2, :r3, :r4, :r5])

      variable :held, type: [^resources ~> [false, true]]

      init do
        held = for_each(^resources, fn _ -> false end)
      end

      action :grab, params: [r: ^resources] do
        require held[r] == false
        held = update(held, r, fn _ -> true end)
      end
    end

    defmodule WrongForTheFourth do
      @moduledoc false
      use TLA.Refinement

      def abstract(%{locks: locks}), do: %{held: locks}

      def abstract_action({:grab, :r4}), do: {:grab, %{r: :wrong}}
      def abstract_action({:grab, r}), do: {:grab, %{r: r}}
      def abstract_action(_other), do: :unmapped

      def concrete_message(:grab, %{r: r}), do: {:grab, r}
    end

    test "reaches a binding the old sample of three could not" do
      error =
        assert_raise Refinement.Error, fn ->
          Refinement.validate!(__MODULE__.WrongForTheFourth, __MODULE__.FiveResources)
        end

      assert Exception.message(error) =~ "does not round-trip grab"
      assert Exception.message(error) =~ ":r4"
    end

    test "and a mapping right for all five passes" do
      assert {:ok, deferred} = Refinement.validate!(Mapping, __MODULE__.FiveResources)

      refute Enum.any?(deferred, &match?({:for_this_mapping, _rule}, &1))
    end
  end
end
