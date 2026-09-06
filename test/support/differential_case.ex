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

  ## Every comparison runs in isolation, and that is why `action_properties: []`
  ## is everywhere

  A comparison selects the one declaration it is about and deselects everything
  else — one invariant name, or one temporal, or one action property, with the
  other lists empty. Both checkers halt at the first violation, so a run checking
  two things reports on whichever it met first, and a length compared out of such
  a run is a length for a different question.

  So a bare `action_properties: []` beside `invariants: [name]` is not an
  oversight; it is the same deselection as the `invariants: []` beside
  `temporals: names` in `check_liveness/2`. #114 read the seven `[]`s as the
  defect, and they are not it: the defect was that **no call site anywhere passed
  a non-empty list**, so the one declaration kind with its own compile path, its
  own runtime check and its own counterexample shape was never compared to
  anything. `check_action_properties/2` is that site, and #112 — an
  `action_property` counterexample built from the wrong end of the step, alive for
  as long as the feature was — is what its absence cost.

  The `setup_all` search is the one exception with a *different* reason, given
  where it happens.
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
        # side, and this `[]` is the one in the file with a reason of its own
        # rather than the isolation reason in the moduledoc: a selected property
        # that is REFUTED halts the search, and a truncated search counts fewer
        # states for a reason that is not a bug. `audit_log` is where that stops
        # being hypothetical — its `log_only_grows` is refuted at the third step,
        # so selecting it here would compare 2 states against TLC's 3.
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
      #
      # It covers `action_property` as well as `temporal` (#114), because TLC's
      # PROPERTIES section holds both — `[][P]_vars` is checked as a property and
      # not as an invariant — and because an action property is exactly what it
      # was failing to notice. `distributed_lock` declared `lock_not_stolen` for
      # as long as the entry existed, `DistributedLock.tla` had no counterpart,
      # and this test passed the whole time by looking only at `spec.temporals`.
      # A test that establishes presence is worth having only over the full list;
      # over part of it, it certifies the part it looks at and hides the rest.
      test "declares the properties TLC was given, and no others", ctx do
        spec = TLA.Spec.Compiled.from_module(@entry.module)

        checked =
          ctx.expected["properties"]
          |> Map.keys()
          |> MapSet.new(&TLA.DifferentialCase.dsl_name(&1, @entry))

        declared =
          MapSet.new(spec.temporals ++ spec.action_properties, &Atom.to_string(&1.name))

        assert MapSet.equal?(declared, checked),
               "the two sides declare different properties -- only in " <>
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

        # `properties` holds both kinds, because it records the .cfg section they
        # came from. Which kind a name is, is a question about the ExTLA spec and
        # is answered there rather than written into the fixture.
        {holding, violated} =
          spec
          |> TLA.DifferentialCase.properties_of_kind(ctx.expected, @entry, :temporal)
          |> Enum.split_with(fn {_, verdict} -> verdict == "holds" end)

        if holding != [] do
          names = Enum.map(holding, &elem(&1, 0))

          result = TLA.DifferentialCase.check_liveness(@entry, names)

          assert result.status == :ok,
                 "every one of #{inspect(names)} holds under TLC, but ExTLA refuted " <>
                   inspect(TLA.DifferentialCase.refuted(result))
        end

        # The row that distinguishes a working liveness checker from one that answers
        # "holds" to everything.
        for {name, "violated"} <- violated do
          result = TLA.DifferentialCase.check_liveness(@entry, [name])

          assert result.status == :violation,
                 "TLC refutes #{name}, but ExTLA reported #{inspect(result.status)}"

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

      # The comparison the corpus did not have (#114), and the reason #112 lived as long
      # as the feature did.
      #
      # Shaped like the INVARIANT comparison rather than the temporal one, because an
      # action property is a safety property. `[][P]_vars` is refuted by a finite prefix
      # ending at the offending step, and TLC reports the breadth-first shortest one — so
      # the LENGTH is a fixture two correct checkers must agree on, exactly as it is for
      # an invariant, and unlike a lasso, which is not canonical. That length is the whole
      # point: #112's defect returned the right VERDICT from the wrong trace, so a
      # comparison of verdicts alone would have passed it.
      test "agrees with TLC on every action property", ctx do
        spec = TLA.DifferentialCase.run_spec(@entry)

        {holding, violated} =
          spec
          |> TLA.DifferentialCase.properties_of_kind(ctx.expected, @entry, :action_property)
          |> Enum.split_with(fn {_, verdict} -> verdict == "holds" end)

        # Several that hold share one run, for the reason several invariants do: a run
        # that checks them all and completes has established every one, because nothing
        # stopped it early.
        if holding != [] do
          names = Enum.map(holding, &elem(&1, 0))
          result = TLA.DifferentialCase.check_action_properties(@entry, names)

          assert result.status == :ok,
                 "every one of #{inspect(names)} holds under TLC, but ExTLA reported " <>
                   "#{inspect(result.status)}#{TLA.DifferentialCase.describe(result.violation)}"
        end

        # A refuted one needs a run of its own, because both checkers halt at the first
        # violation and the shortest counterexample for THIS property is only what a run
        # checking only it reports.
        for {name, %{"violated_at" => depth}} <- violated do
          result = TLA.DifferentialCase.check_action_properties(@entry, [name])

          assert result.status == :violation,
                 "TLC refutes #{name}, but ExTLA reported #{inspect(result.status)}"

          assert result.violation.property == name

          assert result.violation.length == depth,
                 "TLC refutes #{name} with a #{depth}-state behaviour and ExTLA returned " <>
                   "#{result.violation.length} states. A counterexample that ends anywhere " <>
                   "but at the offending step is a legal path to an innocent state (#112)."
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

        for {name, "violated"} <-
              TLA.DifferentialCase.properties_of_kind(spec, ctx.expected, @entry, :temporal) do
          result = TLA.DifferentialCase.check_liveness(@entry, [name])

          assert TLA.Trace.validate(result.violation, spec, @entry.constants) == :ok,
                 "the lasso for #{name} is not a behaviour of the spec"
        end

        # The sharpest of the three, because of what `validate/3` became in #113: a
        # SAFETY trace must now refute the property it names, and an action property's
        # trace refutes it only if its final STEP does. That is precisely the assertion
        # a fabricated counterexample fails — #112's trace was a legal path to an
        # innocent state, which the pre-#113 `validate/3` accepted.
        for {name, %{"violated_at" => _}} <-
              TLA.DifferentialCase.properties_of_kind(
                spec,
                ctx.expected,
                @entry,
                :action_property
              ) do
          result = TLA.DifferentialCase.check_action_properties(@entry, [name])

          assert TLA.Trace.validate(result.violation, spec, @entry.constants) == :ok,
                 "the counterexample for the action property #{name} is not a behaviour " <>
                   "of the spec, or does not refute it"
        end
      end

      # Two records of the same run, held to each other (#128). A counterexample names the
      # actions it took; the coverage report names the actions it believes were never enabled.
      # Those sets cannot both be right and overlap — and they did, because enablement was
      # recorded where an expansion COMPLETED rather than where the guard admitted a binding, so
      # a violation that halted the expansion lost the enablement of the action that caused it.
      #
      # Asserted over every entry that produces a violation rather than only the one that
      # exhibited it. `audit_log` is where it shows, because its `compact` is enabled in exactly
      # one state; `die_hard` is where it hid, because losing one of twelve looks like nothing.
      # A guard that covers only the entry that failed is a guard against one instance.
      test "no counterexample names an action the coverage report calls never-enabled", ctx do
        spec = TLA.DifferentialCase.run_spec(@entry)

        runs =
          for {tlc_name, %{"violated_at" => _}} <- ctx.expected["invariants"] do
            name = TLA.DifferentialCase.invariant_name!(spec, tlc_name, @entry)
            TLA.DifferentialCase.check(@entry, invariants: [name], action_properties: [])
          end ++
            for {name, %{"violated_at" => _}} <-
                  TLA.DifferentialCase.properties_of_kind(
                    spec,
                    ctx.expected,
                    @entry,
                    :action_property
                  ) do
              TLA.DifferentialCase.check_action_properties(@entry, [name])
            end

        for result <- runs do
          named = MapSet.new(result.violation.actions)
          claimed = MapSet.new(result.coverage.never_enabled)

          assert MapSet.disjoint?(named, claimed),
                 "the run took #{inspect(MapSet.to_list(named))} and reported " <>
                   "#{inspect(MapSet.to_list(claimed))} as never enabled — an action cannot be " <>
                   "both in the counterexample and absent from the model"
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

  @doc """
  Check `names` as action properties with nothing else selected.

  The call site #114 found missing. Every other comparison in this module deselects
  action properties; until this existed none selected them, so the corpus contained an
  `action_property` declaration (`distributed_lock`'s `lock_not_stolen`) that no run ever
  evaluated and no oracle ever saw.

  `invariants: []` for the same reason `check_liveness/2` passes it: the checker halts at
  the first violation, so an invariant refuted earlier in the search would end the run
  before the action property was reached and the length compared would answer a different
  question.
  """
  def check_action_properties(entry, names) do
    check(entry, invariants: [], action_properties: names)
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
  The entries of `expected["properties"]` that are of `kind` on the ExTLA side, as
  `{name, verdict}` with the name already translated.

  `expected.json` records a `.cfg`'s whole PROPERTIES section under one key, because that
  is where TLC read it from, and that section holds two different kinds: a `temporal`
  property, and an `action_property`, which is `[][P]_vars` and which TLC checks as a
  PROPERTY rather than as an INVARIANT. They are compared differently — one by verdict
  alone, the other by verdict and counterexample length — so they have to be told apart.

  Which kind a name is, is a question about the **ExTLA spec**, and it is answered from
  the spec rather than recorded in the fixture. A shape written down in two places is a
  shape that can disagree with itself, and the fixture is generated by a tool that has no
  business classifying the user's declarations.
  """
  def properties_of_kind(spec, expected, entry, kind) do
    for {tlc_name, verdict} <- Map.fetch!(expected, "properties"),
        {^kind, name} <- [property_kind!(spec, tlc_name, entry)],
        do: {name, verdict}
  end

  @doc """
  Which kind of declaration a TLC property name is on the ExTLA side, and its name there.

  Resolved through the compiled spec for the reason `invariant_name!/3` is: a property TLC
  checked that the ExTLA spec does not declare would otherwise pass by not being compared.
  """
  def property_kind!(spec, tlc_name, entry) do
    underscored = dsl_name(tlc_name, entry)
    named? = &(Atom.to_string(&1.name) == underscored)

    case {Enum.find(spec.temporals, named?), Enum.find(spec.action_properties, named?)} do
      {%{name: name}, nil} ->
        {:temporal, name}

      {nil, %{name: name}} ->
        {:action_property, name}

      {nil, nil} ->
        raise ExUnit.AssertionError,
          message:
            "TLC checked the property #{tlc_name}, but #{inspect(spec.module)} declares " <>
              "neither `temporal #{underscored}` nor `action_property #{underscored}`. " <>
              "Declared temporals: " <>
              Enum.map_join(spec.temporals, ", ", &inspect(&1.name)) <>
              ". Declared action properties: " <>
              Enum.map_join(spec.action_properties, ", ", &inspect(&1.name)) <> "."

      # Uniqueness is checked per kind (`TLA.Spec.check_unique_names!/3`), so one name can
      # legally be both — and then the .cfg's single entry does not say which one TLC
      # checked, and the comparison would silently pick one.
      {%{}, %{}} ->
        raise ExUnit.AssertionError,
          message:
            "#{inspect(spec.module)} declares both `temporal #{underscored}` and " <>
              "`action_property #{underscored}`, so #{tlc_name} in the .cfg is ambiguous. " <>
              "Rename one."
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
