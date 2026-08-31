defmodule TLA.DifferentialCase do
  @moduledoc """
  The comparisons every differential corpus entry runs against TLC.

  One ExUnit module per entry rather than one `describe` per entry, for two
  reasons: `setup_all` — which is what runs each entry's search once instead of
  once per assertion — cannot live inside a `describe`, and separate modules let
  ExUnit run the entries concurrently. The corpus is now big enough for both to
  matter; `raft_election` alone explores 58k states.

      defmodule TLA.DifferentialTest.RaftElection do
        use TLA.DifferentialCase, entry: entry
      end

  An `entry` is `%{name:, module:, constants:, names:}`, described in
  `test/differential/differential_test.exs`.
  """

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case, async: true

      alias TLA.ModelChecker

      @entry unquote(opts[:entry])
      @corpus Path.expand("../differential", __DIR__)

      setup_all do
        expected =
          Path.join([@corpus, @entry.name, "expected.json"])
          |> File.read!()
          |> Jason.decode!()

        # The state-count comparison must run with nothing selected on either
        # side. An ExTLA action property that TLC's module does not have would
        # otherwise halt the search early and make the counts differ for a
        # reason that is not a bug.
        {result, graph} =
          TLA.DifferentialCase.explore(@entry, invariants: [], action_properties: [])

        %{expected: expected, result: result, graph: graph}
      end

      test "explores the same number of distinct states as TLC", ctx do
        assert ctx.result.distinct_states == ctx.expected["distinct_states"]
      end

      # Catches the narrower failure of a search that stopped early but
      # coincidentally reached the same state count.
      test "reaches the same search depth as TLC", ctx do
        assert ctx.result.diameter == ctx.expected["diameter"]
      end

      # TLC calls any state with no successors a deadlock. ExTLA reports one only
      # where no `terminal` predicate admits it (`02-dsl-semantics.md` §5.3), so
      # the two sides are compared on where the search STOPS — and a spec that
      # declares a terminal is then held to both halves of that claim:
      #
      #   too narrow — a stuck state no terminal admits is still a deadlock here
      #   too broad  — a terminal that admits a state which HAS successors comes
      #                back as `terminal_but_live` in the coverage report
      test "stops where TLC stops, and every stuck state was declared", ctx do
        stuck? = MapSet.size(ctx.graph.terminal) > 0 or MapSet.size(ctx.graph.deadlocked) > 0

        assert stuck? == ctx.expected["deadlock"]

        spec = TLA.Spec.Compiled.from_module(@entry.module)

        if spec.terminals != [] do
          refute ctx.result.deadlock,
                 "a stuck state that no `terminal` admits: #{inspect(ctx.result.violation)}"

          assert ctx.result.coverage.terminal_but_live == []
        end
      end

      test "agrees with TLC on every invariant", ctx do
        spec = TLA.DifferentialCase.run_spec(@entry)

        {holding, violated} =
          Enum.split_with(ctx.expected["invariants"], fn {_, verdict} -> verdict == "holds" end)

        # The invariants TLC says hold are checked in a single run. A run that
        # checks several of them and completes has established every one, because
        # nothing stopped it early — the same argument that lets TLC report on
        # several INVARIANTs from one search.
        if holding != [] do
          names =
            Enum.map(holding, fn {tlc_name, _} ->
              TLA.DifferentialCase.invariant_name!(spec, tlc_name, @entry)
            end)

          result = TLA.DifferentialCase.check(@entry, invariants: names, action_properties: [])

          assert result.status == :ok,
                 "every one of #{inspect(names)} holds under TLC, but ExTLA reported " <>
                   "#{inspect(result.status)}#{TLA.DifferentialCase.describe(result.violation)}"
        end

        # A violated one still needs a run of its own: TLC halts at the first
        # violation and so does this checker, so the shortest counterexample for
        # THIS invariant is only what a run checking only it reports.
        for {tlc_name, %{"violated_at" => depth}} <- violated do
          name = TLA.DifferentialCase.invariant_name!(spec, tlc_name, @entry)
          result = TLA.DifferentialCase.check(@entry, invariants: [name], action_properties: [])

          assert result.status == :violation
          assert result.violation.property == name

          # The shortest counterexample, in states. TLC searches breadth-first
          # and so does this checker, so a longer trace here would mean the
          # search order has drifted — and a checker that hands back a longer
          # trace than necessary is handing back a worse explanation of the same
          # bug.
          assert result.violation.length == depth
        end
      end

      test "the counterexample replays to the state that violates the invariant", ctx do
        violated = Enum.find(ctx.expected["invariants"], fn {_, verdict} -> is_map(verdict) end)

        if violated do
          {tlc_name, _} = violated
          spec = TLA.DifferentialCase.run_spec(@entry)
          name = TLA.DifferentialCase.invariant_name!(spec, tlc_name, @entry)
          result = TLA.DifferentialCase.check(@entry, invariants: [name], action_properties: [])
          invariant = Enum.find(spec.invariants, &(&1.name == name))

          states = result.violation.states
          {before, [last]} = Enum.split(states, -1)

          assert Enum.all?(before, &invariant.predicate.(@entry.constants, &1)),
                 "a state before the last one already violated #{name}, so the trace is not minimal"

          refute invariant.predicate.(@entry.constants, last)
        end
      end
    end
  end

  @doc "Run the checker on an entry, returning `{result, graph}`."
  def explore(entry, opts) do
    TLA.ModelChecker.explore(
      entry.module,
      Map.merge(%{constants: entry.constants}, Map.new(opts))
    )
  end

  @doc "Run the checker on an entry, returning the result."
  def check(entry, opts), do: entry |> explore(opts) |> elem(0)

  @doc """
  The invariants a run actually checks, which includes the implicit `:type_ok`
  of §1.5 — TLC's TypeOK is a declared invariant there and a `type:` annotation
  here, and the corpus compares the two.
  """
  def run_spec(entry) do
    spec = TLA.Spec.Compiled.from_module(entry.module)
    %{spec | invariants: TLA.ModelChecker.checked_invariants(spec, entry.constants)}
  end

  @doc """
  The ExTLA name of a TLC invariant.

  The `.cfg` names an invariant `NotSolved`; the DSL spec names it `:not_solved`.
  Resolving through the compiled spec rather than `String.to_existing_atom/1`
  also catches the case worth catching: an invariant TLC checked that the ExTLA
  spec does not have, which would otherwise pass by not being compared.
  """
  def invariant_name!(spec, tlc_name, entry) do
    underscored =
      case Map.fetch(entry.names, tlc_name) do
        {:ok, mapped} -> Atom.to_string(mapped)
        :error -> Macro.underscore(tlc_name)
      end

    case Enum.find(spec.invariants, &(Atom.to_string(&1.name) == underscored)) do
      nil ->
        raise ExUnit.AssertionError,
          message:
            "TLC checked #{tlc_name}, but #{inspect(spec.module)} declares no invariant " <>
              "#{underscored}. Declared: " <>
              Enum.map_join(spec.invariants, ", ", &inspect(&1.name)) <> "."

      invariant ->
        invariant.name
    end
  end

  @doc false
  def describe(nil), do: ""
  def describe(violation), do: ": #{inspect(violation.property)} at #{violation.length} states"
end
