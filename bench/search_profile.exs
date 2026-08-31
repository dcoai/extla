# Where the single-threaded search spends its time.
#
#     mix run bench/search_profile.exs            # every entry
#     mix run bench/search_profile.exs buffer     # one, by name
#
# `06-architecture.md` §Phase 4 admits `TLA.ModelChecker.Parallel` "only once the
# single-threaded checker is correct and has been profiled". Correct is the differential
# corpus. This is profiled: a number to beat, and a breakdown saying which phase a parallel
# implementation would have to speed up to move it.
#
# ## Why this is not a profiler
#
# `:eprof` and `:fprof` live in OTP's `tools` application, which is absent from this
# Erlang build and from the slim image CI runs on. Rather than take a dependency on an
# application the project does not otherwise need — §06 §Dependencies is emphatic about
# that — each phase is measured by doing it: the bench walks the same state space through
# the same public functions the checker calls, accumulating nanoseconds per phase.
#
# ## What the residual is, and why it is reported rather than distributed
#
# The phases below are the work; the difference between their sum and the checker's own
# wall time is everything else the checker does — its search loop, the graph struct it
# threads, coverage bookkeeping, deadlock classification, and the cost of this bench's own
# timing calls. Attributing that to the phases proportionally would produce a tidier table
# and a false one, so it is a line of its own.
#
# `parameter generation + guards` is one line because `enabled_bindings/3` is what the
# checker calls: it generates and filters in one pass, and splitting it here would time a
# code path the checker does not take.
#
# Not measured, deliberately: liveness. The edge table and ENABLED bits are built only
# under `check_liveness:`, and D-22 already refuses that together with symmetry — a
# parallel liveness graph is a Phase 4 design question, not a phase of this search.

# Loaded the way `bench/symmetry.exs` loads them: the corpus specs are compiled only under
# `MIX_ENV=test`, and a bench should run on a plain `mix run`.
Code.require_file("test/differential/bounded_buffer/spec.ex")
Code.require_file("test/differential/raft_election/spec.ex")

alias TLA.ModelChecker
alias TLA.ModelChecker.Safety
alias TLA.{Coverage, Fingerprint, Spec, State, StateGraph}

entries = [
  # The fast one: a smoke check that the bench itself works, in under a second.
  {"buffer", TLA.Differential.BoundedBuffer, %{}},

  # The real target, at the constants the corpus checks it under — so the number describes
  # a workload TLC has already agreed with rather than one invented to be profiled.
  {"raft", TLA.Differential.RaftElection, %{}}
]

selected =
  case System.argv() do
    [] -> entries
    names -> Enum.filter(entries, fn {name, _module, _override} -> name in names end)
  end

now = fn -> System.monotonic_time(:nanosecond) end

# One pass over the whole reachable state space, timing each phase as it is performed.
# The BFS is the checker's, in miniature and through its own public functions: same
# generators, same guards, same transitions, same fingerprinting, same table.
profile = fn spec, constants ->
  # `type_ok` joins the invariants for a run (`ModelChecker.checked_invariants/2`), so a
  # profile that checked only the declared ones would attribute the type check to the
  # residual — and on a spec with typed variables it is not a small share.
  spec = %{spec | invariants: ModelChecker.checked_invariants(spec, constants)}

  graph = StateGraph.new(spec, constants)

  totals = %{
    params: 0,
    guard: 0,
    transition: 0,
    validate: 0,
    properties: 0,
    fingerprint: 0,
    graph: 0,
    invariants: 0,
    coverage: 0
  }

  coverage = Coverage.init(spec, constants, spec.invariants)

  {graph, totals, frontier} =
    spec.init
    |> Enum.with_index()
    |> Enum.reduce({graph, totals, []}, fn {init_fn, index}, {graph, totals, frontier} ->
      state = init_fn.(constants)
      t0 = now.()
      {graph, id, status} = StateGraph.add_state(graph, state, nil, index, nil)
      totals = Map.update!(totals, :graph, &(&1 + now.() - t0))

      t1 = now.()
      Safety.check_invariants(spec, constants, state, :all)
      totals = Map.update!(totals, :invariants, &(&1 + now.() - t1))

      if status == :new,
        do: {graph, totals, [{state, id} | frontier]},
        else: {graph, totals, frontier}
    end)

  # The checker's `expand/3` and `take_action/6`, in the same order and through the same
  # public functions, with a timer around each phase.
  walk = fn walk, graph, totals, coverage, frontier ->
    case :queue.out(frontier) do
      {:empty, _} ->
        {graph, totals}

      {{:value, {state, id}}, rest} ->
        {graph, totals, coverage, frontier} =
          Enum.reduce(spec.actions, {graph, totals, coverage, rest}, fn action,
                                                                        {graph, totals, coverage,
                                                                         frontier} ->
            t0 = now.()
            bindings = ModelChecker.enabled_bindings(action, constants, state)
            totals = Map.update!(totals, :params, &(&1 + now.() - t0))

            {graph, totals, frontier, distinct} =
              Enum.reduce(bindings, {graph, totals, frontier, 0}, fn binding,
                                                                     {graph, totals, frontier,
                                                                      distinct} ->
                t2 = now.()
                next = action.transition.(constants, state, binding)
                totals = Map.update!(totals, :transition, &(&1 + now.() - t2))

                # Fingerprinting and §6 validation both happen INSIDE `add_state`, so
                # neither can be timed separately without doing it twice. Both are done
                # twice here deliberately and reported as sub-lines rather than summed.
                #
                # Fingerprinting is the phase a parallel implementation parallelises
                # freely, where the ETS write beside it is the one that contends, and a
                # profile that could not tell them apart would not answer the question
                # this bench exists for.
                t5 = now.()
                Fingerprint.compute(next, bits: graph.fingerprint_bits)
                totals = Map.update!(totals, :fingerprint, &(&1 + now.() - t5))

                # Registering the successor comes before the action-property check, as it
                # does in `take_action/6` and for the reason given there: a property must
                # never be handed a state §6 has not vetted.
                t6 = now.()

                {graph, next_id, status} =
                  StateGraph.add_state(graph, next, id, action.name, binding)

                totals = Map.update!(totals, :graph, &(&1 + now.() - t6))

                t4 = now.()
                Safety.check_action_properties(spec, constants, state, next, :all)
                totals = Map.update!(totals, :properties, &(&1 + now.() - t4))

                if status == :new do
                  # Validation is per DISTINCT state since #33, not per transition — the
                  # single change that shape made, and the reason this line is now a
                  # fraction of what it was. It is timed on the `:new` branch because that
                  # is the branch `add_state` itself validates on.
                  t3 = now.()
                  State.validate!(next)
                  totals = Map.update!(totals, :validate, &(&1 + now.() - t3))

                  # `admit/4` observes the state for coverage — including each invariant's
                  # near miss — before checking it. Both are per new state.
                  t7 = now.()
                  Coverage.observe_state(coverage, spec.invariants, constants, next)
                  totals = Map.update!(totals, :coverage, &(&1 + now.() - t7))

                  t8 = now.()
                  Safety.check_invariants(spec, constants, next, :all)
                  totals = Map.update!(totals, :invariants, &(&1 + now.() - t8))

                  {graph, totals, :queue.in({next, next_id}, frontier), distinct + 1}
                else
                  {graph, totals, frontier, distinct}
                end
              end)

            t9 = now.()

            coverage =
              Coverage.observe_action(coverage, action.name, bindings, length(bindings), distinct)

            totals = Map.update!(totals, :coverage, &(&1 + now.() - t9))

            {graph, totals, coverage, frontier}
          end)

        walk.(walk, graph, totals, coverage, frontier)
    end
  end

  walk.(walk, graph, totals, coverage, :queue.from_list(Enum.reverse(frontier)))
end

ms = fn ns -> Float.round(ns / 1_000_000, 1) end
pct = fn part, whole -> if whole == 0, do: 0.0, else: Float.round(part / whole * 100, 1) end

IO.puts("""

Search profile — #{:erlang.system_info(:system_version) |> to_string() |> String.trim()}
""")

for {name, module, override} <- selected do
  spec = Spec.Compiled.from_module(module)
  {:ok, defaults} = Spec.Compiled.resolve_constants(spec)
  constants = Map.merge(defaults, override)
  config = %{constants: constants, check_liveness: false}

  # The checker's own wall time, unmeasured from the inside: the number to beat.
  ModelChecker.run(module, config)
  {wall_us, result} = :timer.tc(fn -> ModelChecker.run(module, config) end)
  wall_ns = wall_us * 1000

  {_graph, totals} = profile.(spec, constants)
  sum = totals |> Map.drop([:fingerprint, :validate]) |> Map.values() |> Enum.sum()
  residual = wall_ns - sum

  IO.puts("#{name} — #{inspect(module)}, constants #{inspect(constants, limit: 4)}")

  IO.puts(
    "  #{result.distinct_states} distinct states, #{result.transitions} transitions, " <>
      "diameter #{result.diameter}"
  )

  IO.puts(
    "  #{ms.(wall_ns)}ms wall, #{Float.round(wall_us / result.distinct_states, 1)}us/state, " <>
      "#{round(result.distinct_states / (wall_us / 1_000_000))} states/s"
  )

  IO.puts("")

  [
    {"parameter generation + guards", totals.params},
    {"transition application", totals.transition},
    {"action properties", totals.properties},
    {"graph: fingerprint + §6 + ETS", totals.graph},
    {"invariant checking (incl. type_ok)", totals.invariants},
    {"coverage bookkeeping", totals.coverage}
  ]
  |> Enum.sort_by(fn {_label, ns} -> -ns end)
  |> Enum.each(fn {label, ns} ->
    IO.puts(
      "    #{String.pad_trailing(label, 34)} #{String.pad_leading("#{ms.(ns)}ms", 9)}  #{pct.(ns, wall_ns)}%"
    )
  end)

  IO.puts(
    "      of the graph line, fingerprinting alone is #{ms.(totals.fingerprint)}ms " <>
      "(#{pct.(totals.fingerprint, totals.graph)}% of it) — measured by doing it"
  )

  IO.puts("      a second time, so NOT counted in the sum. It is the half a worker")
  IO.puts("      parallelises freely; the ETS write beside it is the half that contends.")

  IO.puts(
    "      also of the graph line, §6 validation is #{ms.(totals.validate)}ms " <>
      "(#{pct.(totals.validate, totals.graph)}% of it, #{pct.(totals.validate, wall_ns)}% of wall)"
  )

  IO.puts("      — since #33 it runs once per DISTINCT state rather than once per")
  IO.puts("      transition. Measured a second time, so NOT counted in the sum either.")

  IO.puts(
    "      what is left of the graph line after both is the ETS lookup and insert, " <>
      "#{ms.(totals.graph - totals.fingerprint - totals.validate)}ms"
  )

  IO.puts("      — a difference of three larger numbers, so read it as an order of")
  IO.puts("      magnitude and not a measurement. #31 timed the tables directly.")

  IO.puts(
    "    #{String.pad_trailing("(residual)", 34)} #{String.pad_leading("#{ms.(residual)}ms", 9)}  #{pct.(residual, wall_ns)}%"
  )

  if residual >= 0 do
    IO.puts("      the search loop, the frontier queue, the graph struct, deadlock")
    IO.puts("      classification, and this bench's own timing calls. Not distributed.")
  else
    # Worth saying rather than clamping to zero: a negative residual is a real
    # measurement about the measurement, and hiding it would make the table look
    # more precise than it is.
    IO.puts("      NEGATIVE: the phases' own timer calls — two per phase per")
    IO.puts("      transition — cost more than the work the search does outside them.")
    IO.puts("      Read the percentages as proportions, not as a partition of the wall.")
  end

  IO.puts("")
end
