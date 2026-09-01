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
        # `liveness_graph: true` so the edge table exists for `TLA.GraphAudit` to audit.
        # Built here rather than in that test, because building it there meant exploring
        # `raft_election` a second time — 20 seconds of this suite for a graph this one
        # already has.
        {result, graph} =
          TLA.DifferentialCase.explore(@entry,
            invariants: [],
            action_properties: [],
            liveness_graph: true
          )

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

      # The verdicts are compared below; this is the check that the two sides are
      # comparing the same LIST. A `temporal` added to `spec.ex` and not to the
      # module would otherwise sit there unchecked, and the verdict comparison
      # would pass by not looking at it.
      test "declares the temporal properties TLC was given, and no others", ctx do
        spec = TLA.Spec.Compiled.from_module(@entry.module)

        checked =
          ctx.expected["properties"]
          |> Map.keys()
          |> MapSet.new(&TLA.DifferentialCase.dsl_name(&1, @entry))

        declared = MapSet.new(spec.temporals, &Atom.to_string(&1.name))

        assert MapSet.equal?(declared, checked),
               "the two sides declare different temporal properties -- only in " <>
                 "#{inspect(@entry.module)}: " <>
                 inspect(Enum.sort(MapSet.difference(declared, checked))) <>
                 ", only in #{ctx.expected["module"]}.cfg: " <>
                 inspect(Enum.sort(MapSet.difference(checked, declared)))
      end

      # The same shape as the invariant comparison, for the same reasons. A run that
      # checks several properties TLC says hold and comes back :ok has established every
      # one of them, because nothing stopped it early; a violated one needs a run of its
      # own, because both checkers halt at the first.
      test "agrees with TLC on every temporal property", ctx do
        spec = TLA.Spec.Compiled.from_module(@entry.module)

        {holding, violated} =
          Enum.split_with(ctx.expected["properties"], fn {_, verdict} -> verdict == "holds" end)

        if holding != [] do
          names =
            Enum.map(holding, fn {tlc_name, _} ->
              TLA.DifferentialCase.temporal_name!(spec, tlc_name, @entry)
            end)

          result = TLA.DifferentialCase.check_liveness(@entry, names)

          assert result.status == :ok,
                 "every one of #{inspect(names)} holds under TLC, but ExTLA refuted " <>
                   inspect(TLA.DifferentialCase.refuted(result))
        end

        # The row that distinguishes a working liveness checker from one that answers
        # "holds" to everything.
        for {tlc_name, "violated"} <- violated do
          name = TLA.DifferentialCase.temporal_name!(spec, tlc_name, @entry)
          result = TLA.DifferentialCase.check_liveness(@entry, [name])

          assert result.status == :violation,
                 "TLC refutes #{tlc_name}, but ExTLA reported #{inspect(result.status)}"

          assert TLA.DifferentialCase.refuted(result) == name
          assert result.violation.prefix.length > 0

          # The counterexample, checked a second way. `TLA.ModelChecker.Liveness` reasons
          # about components of the state graph; `TLA.Temporal` walks the behaviour it
          # handed back. They share no code, so agreement is evidence — and the cycle has
          # to be one the spec's own fairness permits, or the lasso is not a behaviour of
          # the spec at all.
          behavior = TLA.Trace.to_behavior(result.violation)

          assert :violated in TLA.TemporalCheck.verdicts(spec, @entry.constants, name, behavior),
                 "the checker refuted #{name}, but its own counterexample does not"

          for {constraint, verdict} <-
                TLA.TemporalCheck.fairness_verdicts(spec, @entry.constants, behavior) do
            assert verdict == :holds,
                   "the counterexample's cycle breaks #{constraint}, so the spec's " <>
                     "fairness forbids the behaviour it was handed back as"
          end
        end
      end

      # Every violation the entry produces, safety and liveness alike, checked against the
      # spec rather than against a fixture. Until this existed, nothing checked that a
      # counterexample's consecutive states were connected by the actions it names: the
      # states could be reachable, the actions real, and the pairing between them
      # fabricated, and every gate in the project would pass it.
      test "every counterexample it produces is a behaviour the spec admits", ctx do
        spec = TLA.DifferentialCase.run_spec(@entry)

        for {tlc_name, %{"violated_at" => _}} <- ctx.expected["invariants"] do
          name = TLA.DifferentialCase.invariant_name!(spec, tlc_name, @entry)

          result =
            TLA.DifferentialCase.check(@entry, invariants: [name], action_properties: [])

          assert TLA.Trace.validate(result.violation, spec, @entry.constants) == :ok,
                 "the safety counterexample for #{name} is not a behaviour of the spec"
        end

        for {tlc_name, "violated"} <- ctx.expected["properties"] do
          name = TLA.DifferentialCase.temporal_name!(spec, tlc_name, @entry)
          result = TLA.DifferentialCase.check_liveness(@entry, [name])

          assert TLA.Trace.validate(result.violation, spec, @entry.constants) == :ok,
                 "the lasso for #{name} is not a behaviour of the spec"
        end
      end

      # The two records that are self-consistent when wrong. #54's sweep found
      # `drops_a_liveness_edge` surviving every gate: a missing out-edge makes some cycle
      # unfindable, and an unfindable cycle is indistinguishable from a property that
      # holds, so every temporal verdict still matched `expected.json`.
      test "what the search recorded is what the spec admits", ctx do
        spec = TLA.DifferentialCase.run_spec(@entry)

        # Only a complete run can be audited. A bounded one has states it discovered and
        # never expanded, and reading those as missing edges would manufacture a finding
        # out of a limit the run already reports.
        assert ctx.result.status in [:ok, :violation],
               "the audit needs a complete run, got #{inspect(ctx.result.status)}"

        assert TLA.GraphAudit.audit(spec, @entry.constants, ctx.graph) == :ok

        # Every invariant the run would check, including the implicit `type_ok`, decides
        # every reachable state with a real boolean — `Safety.check_invariants/4` reads
        # the result with `if`, so a truthy non-boolean would report `holds` and `nil`
        # would report a violation the spec never expressed.
        invariants = TLA.ModelChecker.checked_invariants(spec, @entry.constants)

        # Found once, used twice: an independent walk over the whole reachable set is the
        # expensive part, and both remaining checks are questions about that same set.
        states = TLA.GraphAudit.reachable(spec, @entry.constants)

        assert TLA.GraphAudit.invariant_partition(@entry.constants, invariants, states) == :ok

        # The collision margin a run reports is a probability. This is the observation.
        assert TLA.GraphAudit.fingerprint_injectivity(ctx.graph, states) == :ok
      end

      # Shortest-ness, checked without the fixture. `expected.json` records TLC's length
      # and the comparison above uses it, so a search that stopped being breadth-first is
      # caught only where the length happens to change. This asserts it from the spec
      # alone, with a search that shares no traversal code with the checker's — which is
      # what makes it trustworthy on a spec TLC has never seen.
      #
      # Only entries with a violated INVARIANT are covered, and today that is `die_hard`
      # alone: the others have none. That is a fact about the corpus rather than a budget
      # this test declined to spend, and it is stated rather than left to be inferred from
      # a test that silently does nothing.
      test "a violated invariant's counterexample is the shortest one there is", ctx do
        violated = Enum.filter(ctx.expected["invariants"], fn {_, v} -> is_map(v) end)
        spec = TLA.DifferentialCase.run_spec(@entry)

        for {tlc_name, _} <- violated do
          name = TLA.DifferentialCase.invariant_name!(spec, tlc_name, @entry)
          invariant = Enum.find(spec.invariants, &(&1.name == name))

          result =
            TLA.DifferentialCase.check(@entry, invariants: [name], action_properties: [])

          assert TLA.BoundedSearch.nothing_violates_before?(
                   spec,
                   @entry.constants,
                   &invariant.predicate.(@entry.constants, &1),
                   result.violation.length
                 ),
                 "an independent search found a violation of #{name} shorter than the " <>
                   "#{result.violation.length}-state counterexample the checker returned"
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
  Check `names` as temporal properties with nothing else selected — the same isolation the
  invariant comparison uses, so a difference is about the property and not about something
  the TLA+ module does not have.
  """
  def check_liveness(entry, names) do
    check(entry, invariants: [], action_properties: [], check_liveness: true, temporals: names)
  end

  @doc "The property a liveness violation refuted, or `nil`."
  def refuted(%{violation: %{prefix: prefix}}), do: prefix.property
  def refuted(_result), do: nil

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
    underscored = dsl_name(tlc_name, entry)

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

  @doc """
  The ExTLA name of a TLC temporal property.

  Resolved through the compiled spec for the reason `invariant_name!/3` is: a property TLC
  checked that the ExTLA spec does not declare would otherwise pass by not being compared.
  """
  def temporal_name!(spec, tlc_name, entry) do
    underscored = dsl_name(tlc_name, entry)

    case Enum.find(spec.temporals, &(Atom.to_string(&1.name) == underscored)) do
      nil ->
        raise ExUnit.AssertionError,
          message:
            "TLC checked the temporal property #{tlc_name}, but #{inspect(spec.module)} " <>
              "declares no `temporal #{underscored}`. Declared: " <>
              Enum.map_join(spec.temporals, ", ", &inspect(&1.name)) <> "."

      temporal ->
        temporal.name
    end
  end

  @doc """
  The ExTLA name of a TLC declaration, as a string.

  `Macro.underscore/1` unless the entry's `names` map says otherwise, which is
  where the conventions that underscoring cannot bridge are stated.
  """
  def dsl_name(tlc_name, entry) do
    case Map.fetch(entry.names, tlc_name) do
      {:ok, mapped} -> Atom.to_string(mapped)
      :error -> Macro.underscore(tlc_name)
    end
  end

  @doc false
  def describe(nil), do: ""
  def describe(violation), do: ": #{inspect(violation.property)} at #{violation.length} states"
end
