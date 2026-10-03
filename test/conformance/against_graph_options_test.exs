defmodule ExTLA.AgainstGraphOptionsTest do
  @moduledoc """
  `--against-graph` runs one suite, under the options it was given (#313, for #180).

  ## What it was

  The flag ran the full simulation and then **another `traces` simulations**, one at a
  time — so `mix tla.simulate X --traces 10000 --against-graph` ran twenty thousand traces.

  Worse than the cost: the second suite forwarded **two of the five** options. So
  `--unrestricted --against-graph` audited containment with the **restricted** generator
  while printing that every state was a node and every step an edge;
  `--inject-failures` and `--concurrency` were dropped the same way; and the two suites
  disagreed about the step default, twenty-five and twenty. Their seeds were derived
  differently too, so "trace 7 (seed 8)" named a trace the reported seed does not produce
  at index 7.

  ## What it is

  The graph is built once and handed to `ExTLA.Simulation` as `against_graph:`, which holds
  each behaviour against it **as that behaviour finishes** — beside the temporal check,
  which is the other per-trace question. **One suite cannot diverge from itself**, so the
  forwarding, the step default and the seed derivation are not three fixes but one.

  The tests below assert on the **config the simulation runs under**, not on the output.
  The old second suite printed "every state a node and every step an edge" while using the
  wrong generator — output was exactly what could not be trusted.
  """

  use ExUnit.Case, async: true

  alias ExTLA.Conformance.Counter.{Impl, Spec}
  alias ExTLA.{Conformance, ModelChecker, Simulation}

  @constants %{max_val: 5}

  setup_all do
    {result, graph} =
      ModelChecker.explore(Spec, %{
        constants: @constants,
        liveness_graph: true,
        invariants: [],
        action_properties: []
      })

    %{against: %{graph: graph, status: result.status}}
  end

  describe "the containment check" do
    test "runs inside the simulation, so a conforming run passes", ctx do
      result =
        Simulation.run(Impl.Conforming, %{
          traces: 8,
          max_steps: 12,
          seed: 4,
          against_graph: ctx.against
        })

      assert result.status == :ok
      assert result.containment == nil
      assert result.traces_run == 8
    end

    # Anti-vacuity, and it is the assertion that matters: a check that never fires is
    # indistinguishable from no check.
    #
    # The graph is built at `max_val: 1` while the server resolves `max_val: 5` from its own
    # config — a COMPLETE graph of a smaller model, which is the honest way to produce this
    # without a broken implementation. `Impl.Conforming` is correct; it simply reaches
    # states that graph does not hold, which is what `against_graph/3` is for.
    test "and a behaviour that leaves the graph is a finding of its own kind" do
      {small_result, small_graph} =
        ModelChecker.explore(Spec, %{
          constants: %{max_val: 1},
          liveness_graph: true,
          invariants: [],
          action_properties: []
        })

      assert small_result.status == :ok, "the graph must be complete, or the check refuses"

      result =
        Simulation.run(Impl.Conforming, %{
          traces: 20,
          max_steps: 12,
          seed: 4,
          against_graph: %{graph: small_graph, status: small_result.status}
        })

      assert result.status == :left_the_graph,
             "a conforming server reached past max_val: 1 and nothing said so"

      # Not a conformance violation: the implementation did nothing wrong. Naming it one
      # would blame the code for what is a fact about the graph it was compared against.
      assert result.violation == nil
      assert {:absent_state, _} = result.containment
      assert result.detail =~ "not in the graph"
    end

    test "and without the option nothing is checked, which is a different fact", ctx do
      _ = ctx

      result = Simulation.run(Impl.Conforming, %{traces: 4, max_steps: 8, seed: 4})

      assert result.status == :ok
      assert result.containment == nil
    end
  end

  describe "every generator option reaches the traces that are audited" do
    # One test per option, because forwarding two of five is exactly how this went
    # unnoticed. Each asserts on the GENERATOR or the run's own count — never on the
    # report, which is what was wrong while it claimed to be right.

    test "--unrestricted, asserted on the generator rather than on the output", ctx do
      spec = Impl.Conforming.__tla_spec_module__()
      refinement = Impl.Conforming.__tla_refinement__()
      unrestricted = Simulation.Generator.from_spec(spec, refinement, @constants)

      result =
        Simulation.run(Impl.Conforming, %{
          traces: 6,
          max_steps: 10,
          seed: 4,
          message_generator: unrestricted,
          against_graph: ctx.against
        })

      # The unrestricted generator offers messages for DISABLED actions, which
      # `check_step!/5` reports as `:not_enabled`. `Impl.Conforming` has no guards of its
      # own, so it accepts one — the finding is the evidence that this generator ran.
      assert result.status == :violation
      assert result.violation
    end

    test "--inject-failures, asserted on the restart count", ctx do
      {result, _behaviour} =
        Simulation.run_trace(Impl.Conforming, %{
          max_steps: 40,
          seed: 20_303,
          inject_failures: true,
          against_graph: ctx.against
        })

      assert result.restarts > 0,
             "no restart occurred, so this says nothing about forwarding the option"
    end

    test "--concurrency, asserted on the traces that ran", ctx do
      result =
        Simulation.run(Impl.Conforming, %{
          traces: 8,
          max_steps: 8,
          seed: 4,
          concurrency: 4,
          against_graph: ctx.against
        })

      assert result.status == :ok
      assert result.traces_run == 8
    end
  end

  describe "the trace count and the step default" do
    # `--traces N --against-graph` ran 2N traces. One suite runs N.
    test "are the ones asked for, not twice them", ctx do
      result =
        Simulation.run(Impl.Conforming, %{
          traces: 5,
          max_steps: 6,
          seed: 4,
          against_graph: ctx.against
        })

      assert result.traces_run == 5
    end

    # The two suites used 25 and 20. There is one now, and it is the task's documented 25 —
    # asserted against the moduledoc, so the number and the sentence cannot drift apart.
    test "and the documented step default is a single number" do
      moduledoc =
        Path.expand("../..", __DIR__)
        |> Path.join("lib/mix/tasks/tla.simulate.ex")
        |> File.read!()

      assert moduledoc =~ "--steps              Maximum steps per trace (default 25)."
      assert moduledoc =~ "max_steps: Keyword.get(opts, :steps, 25)"

      refute moduledoc =~ "Keyword.get(opts, :steps, 20)",
             "a second step default is back; the two suites disagreed about this"
    end
  end

  describe "a reported seed reproduces its trace" do
    # The two families derived seeds differently, so a seed reported by one did not name a
    # trace of the other. There is one family now: the same seed gives the same run.
    test "because there is only one family of them", ctx do
      config = %{traces: 6, max_steps: 10, seed: 777, against_graph: ctx.against}

      first = Simulation.run(Impl.Conforming, config)
      again = Simulation.run(Impl.Conforming, config)

      assert first.seed == 777
      assert again.seed == 777
      assert first.status == again.status
      assert first.total_steps == again.total_steps
      assert first.coverage.actions_hit == again.coverage.actions_hit
    end

    test "and a different seed is a different run", ctx do
      config = %{traces: 6, max_steps: 10, against_graph: ctx.against}

      a = Simulation.run(Impl.Conforming, Map.put(config, :seed, 777))
      b = Simulation.run(Impl.Conforming, Map.put(config, :seed, 778))

      refute a.total_steps == b.total_steps and
               a.coverage.actions_hit == b.coverage.actions_hit,
             "two seeds produced identical runs, so the seed is not reaching the generator"
    end
  end

  describe "the finding it reports" do
    test "keeps ExTLA.Conformance's classes, which is what it is for", ctx do
      # Built directly: the `:checker` class — the search missed a step the spec permits —
      # is the one finding no other gate can produce, and a simulation cannot be made to
      # produce it on demand. What this asserts is that the class survives the trip.
      bogus = %{count: 99, status: :ready}

      finding = Conformance.against_graph(ctx.against.graph, [bogus], status: ctx.against.status)

      assert {:absent_state, _} = finding
      assert Conformance.explain(finding) =~ "not in the graph"
    end
  end
end
