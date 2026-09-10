defmodule TLA.ModelChecker.Liveness do
  @moduledoc """
  Temporal property checking over the liveness graph.

  A liveness property is refuted by an infinite behaviour, and an infinite behaviour in a
  finite graph is a **lasso**: a finite prefix, then a cycle repeated forever. The states
  a behaviour visits infinitely often are a strongly connected set, so the search is for
  a strongly connected component that (a) the property forbids being cycled in forever
  and (b) the spec's fairness constraints permit cycling in.

  ## What "permits" means

  A component `S` is unfair when a fairness constraint says it cannot be the tail of a
  behaviour (`02-dsl-semantics.md` §5.2):

  - **WF(A)** is broken by `S` when `A` is enabled in *every* state of `S` and no edge
    inside `S` takes it — continuously enabled and never taken.
  - **SF(A)** is broken by `S` when `A` is enabled in *some* state of `S` and no edge
    inside `S` takes it — repeatedly enabled and never taken.

  Both read the ENABLED bits `TLA.StateGraph` recorded while each state was materialized,
  and the edges beside them. That is what the liveness graph is for.

  A broken WF kills every strongly connected *subset* of `S` too: a subset has `A` enabled
  everywhere as well, and no more edges to take it with. A broken SF does not — dropping
  the states where `A` is enabled can leave a smaller component that is fair. So the
  search does exactly that and recurses, which is the shape of the Emerson–Lei algorithm
  and the reason this is not just "Tarjan, then filter".

  ## A terminal state stutters forever

  `02-dsl-semantics.md` §5.3: a state with no successors is a legal end of a behaviour,
  which stutters there. So a stuck state is a self-loop here, and it is always fair —
  nothing is enabled in it, so no constraint can require anything to be taken. A
  leads-to whose consequent has not held by then is violated there, which is the correct
  verdict and the one that refutes `raft_election`'s `eventually_elect_leader`.

  ## The supported fragment

  `02-dsl-semantics.md` §5.1, as `TLA.Spec.Temporal` parses it. Each formula reduces to
  one of six shapes, and each shape to a question about components:

  | Formula | Refuted by |
  |---|---|
  | `pred` | an initial state where it is false |
  | `always(pred)` | any reachable state where it is false |
  | `eventually(pred)` | a fair component of the ¬pred subgraph, reached without leaving it |
  | `always(eventually(pred))` | a fair component of the ¬pred subgraph, reached any way at all |
  | `eventually(always(pred))` | a fair component holding a ¬pred state |
  | `p ~> q` | a reachable `p ∧ ¬q` state that reaches a fair component of the ¬q subgraph |

  `always(pred)` needs no component search: every reachable state has a fair continuation,
  because a walk to a *bottom* component is always available and a bottom component is
  always fair — every action enabled inside it has its edge inside it, since nothing
  leaves.

  A nesting outside this table raises rather than being approximated. §5.1's grammar is
  recursive and admits shapes like `always(eventually(always(p)))`; evaluating one of
  those as though it were something simpler is the silently-weaker check this project
  exists to avoid.

  ## What it costs

  One pass materializing every state to evaluate the properties' predicates — the states
  are not kept (`08-decisions.md` D-5), so they are regenerated, one transition each,
  holding only the states that still have children to generate. Then Tarjan per property,
  which is linear in the graph.
  """

  alias TLA.{Spec, StateGraph, Temporal, Trace}

  @type verdict :: :ok | {:violation, atom(), Trace.lasso()}

  @doc """
  Check a spec's temporal properties against a completed liveness graph.

  `selected` is `:all` or a list of property names, the way `invariants:` selects
  invariants — the differential corpus asks one property at a time, because that is how
  TLC reports them.

  Returns the first violation in declaration order, with the lasso that refutes it.
  """
  def check(spec, graph, selected \\ :all) do
    complete!(graph)

    instances =
      spec.temporals
      |> select(selected)
      |> Enum.flat_map(&instances(&1, graph.constants))

    case instances do
      [] -> :ok
      instances -> run(graph, instances)
    end
  end

  defp run(graph, instances) do
    {shapes, predicates} = index_predicates(instances)
    values = evaluate(graph, predicates)

    Enum.reduce_while(shapes, :ok, fn instance, :ok ->
      case refute(graph, values, instance.shape) do
        nil -> {:cont, :ok}
        witness -> {:halt, {:violation, instance.name, lasso(graph, instance, witness)}}
      end
    end)
  end

  # A liveness verdict is about every behaviour of the spec, so it needs every behaviour
  # to have been explored. Only an expanded state has out-edges, so a run stopped by
  # `max_states`, held back by a state constraint or halted by a safety violation leaves
  # a graph whose missing edges are indistinguishable from a state that ends the spec —
  # which is precisely the shape that refutes a liveness property.
  @doc """
  Whether this graph can carry a liveness verdict at all.

  The non-raising counterpart to the check below, so a caller can decline to ask rather than
  crash after the search (#167). A `state_constraint:` holds states back without expanding
  them, so a constrained run reaches the end with a graph that has fewer edge entries than
  states — and `check_liveness: true` alongside it used to die with `ArgumentError` there,
  taking the valid safety result with it.

  The pairing is only *conditionally* bad: a constraint that never actually holds a state
  back leaves a complete graph and liveness works. That is why this is a predicate the
  caller consults rather than an up-front refusal like symmetry's and workers' — those are
  unconditionally incompatible and can be rejected before any work happens.
  """
  def answerable?(graph) do
    StateGraph.liveness?(graph) and map_size(graph.edges) == graph.state_count
  end

  defp complete!(graph) do
    unless StateGraph.liveness?(graph) do
      raise ArgumentError,
            "liveness checking needs the liveness graph: explore with `check_liveness: " <>
              "true`. Parent pointers are a spanning tree and have no cycles at all."
    end

    unless map_size(graph.edges) == graph.state_count do
      raise ArgumentError,
            "the search did not expand every state (#{map_size(graph.edges)} of " <>
              "#{graph.state_count}), so this graph describes part of the state space. A " <>
              "liveness verdict over it would be a claim about behaviours that were never " <>
              "explored."
    end
  end

  defp select(temporals, :all), do: temporals
  defp select(temporals, names), do: Enum.filter(temporals, &(&1.name in names))

  # ── The fragment ────────────────────────────────────────────────────────────

  # `\A x \in C : F(x)` is a conjunction of instances, each of which is itself in the
  # fragment — so quantifiers are expanded away here and nothing downstream knows about
  # them. The bound values ride along so a violation can say which instance failed.
  defp instances(temporal, constants) do
    temporal.formula.(constants)
    |> unquantify(constants)
    |> Enum.map(fn {bound, formula} ->
      %{name: temporal.name, bound: bound, formula: formula}
    end)
  end

  defp unquantify({:for_all, set, instance}, constants) do
    for value <- Enum.to_list(set.(constants)),
        {bound, formula} <- unquantify(instance.(value), constants),
        do: {[value | bound], formula}
  end

  defp unquantify(formula, _constants), do: [{[], formula}]

  # One shape per instance, and one index per distinct predicate position. Predicates are
  # evaluated once per state for all properties at once, which is what keeps the
  # materialization pass to one.
  defp index_predicates(instances) do
    {shapes, predicates, _n} =
      Enum.reduce(instances, {[], [], 0}, fn instance, {shapes, predicates, n} ->
        {shape, predicates, n} = shape(instance.formula, instance, predicates, n)
        {[Map.put(instance, :shape, shape) | shapes], predicates, n}
      end)

    {Enum.reverse(shapes), Enum.reverse(predicates)}
  end

  defp shape({:predicate, p}, _i, preds, n), do: {{:initial, n}, [p | preds], n + 1}

  defp shape({:always, {:predicate, p}}, _i, preds, n), do: {{:invariant, n}, [p | preds], n + 1}

  defp shape({:eventually, {:predicate, p}}, _i, preds, n),
    do: {{:eventually, n}, [p | preds], n + 1}

  defp shape({:always, {:eventually, {:predicate, p}}}, _i, preds, n),
    do: {{:infinitely_often, n}, [p | preds], n + 1}

  defp shape({:eventually, {:always, {:predicate, p}}}, _i, preds, n),
    do: {{:eventually_always, n}, [p | preds], n + 1}

  defp shape({:leads_to, p, q}, _i, preds, n),
    do: {{:leads_to, n, n + 1}, [q, p | preds], n + 2}

  defp shape(formula, instance, _preds, _n) do
    raise ArgumentError,
          "temporal property #{inspect(instance.name)} nests operators more deeply than the " <>
            "checker evaluates: #{describe_shape(formula)}. The shapes it checks are " <>
            "`pred`, `always(pred)`, `eventually(pred)`, `always(eventually(pred))`, " <>
            "`eventually(always(pred))` and `p ~> q`, each optionally under " <>
            "`Enum.all?(^constant, …)` (02-dsl-semantics.md §5.1). Approximating this one " <>
            "with a shape it is not would be a weaker check reported as the real thing."
  end

  defp describe_shape({op, inner}) when op in [:always, :eventually],
    do: "#{op}(#{describe_shape(inner)})"

  defp describe_shape({:leads_to, _, _}), do: "p ~> q"
  defp describe_shape({:predicate, _}), do: "pred"
  defp describe_shape(other), do: inspect(other)

  # ── Evaluating the predicates ───────────────────────────────────────────────

  # Every state, materialized once, in id order. Ids are handed out as states are
  # discovered, so a state's id is always greater than its parent's and the parent has
  # already been built when its turn comes. A state is dropped as soon as the last of its
  # children has used it, which keeps this pass to the size of the frontier rather than
  # of the state space — the trade D-5 exists to preserve.
  defp evaluate(graph, predicates) do
    {_live, _left, values} =
      Enum.reduce(
        0..(graph.state_count - 1)//1,
        {%{}, child_counts(graph), %{}},
        fn id, {live, left, values} ->
          record = StateGraph.node_record(graph, id)
          state = materialize(graph, record, live)
          {live, left} = release(live, left, record.parent)

          live = if Map.has_key?(left, id), do: Map.put(live, id, state), else: live

          {live, left, Map.put(values, id, bits(predicates, state))}
        end
      )

    values
  end

  defp child_counts(graph) do
    Enum.reduce(0..(graph.state_count - 1)//1, %{}, fn id, counts ->
      case StateGraph.node_record(graph, id).parent do
        nil -> counts
        parent -> Map.update(counts, parent, 1, &(&1 + 1))
      end
    end)
  end

  defp materialize(graph, %{parent: nil, init_index: index}, _live),
    do: graph.spec.init |> Enum.at(index) |> apply([graph.constants])

  defp materialize(graph, %{parent: parent, action: action, params: params}, live) do
    Spec.Compiled.action(graph.spec, action).transition.(
      graph.constants,
      Map.fetch!(live, parent),
      params
    )
  end

  # One more child of `parent` has been built. When it was the last, the parent's own
  # state is no longer needed by anything and goes.
  defp release(live, left, nil), do: {live, left}

  defp release(live, left, parent) do
    case Map.fetch!(left, parent) - 1 do
      0 -> {Map.delete(live, parent), Map.delete(left, parent)}
      n -> {live, Map.put(left, parent, n)}
    end
  end

  defp bits(predicates, state) do
    Enum.reduce(predicates, <<>>, fn predicate, acc ->
      <<acc::bitstring, if(predicate.(state), do: 1, else: 0)::1>>
    end)
  end

  defp holds?(values, id, index) do
    case Map.fetch!(values, id) do
      <<_::size(^index), 1::1, _::bitstring>> -> true
      _ -> false
    end
  end

  defp where(graph, values, index, truth) do
    MapSet.new(Enum.filter(0..(graph.state_count - 1)//1, &(holds?(values, &1, index) == truth)))
  end

  defp all_states(graph), do: MapSet.new(0..(graph.state_count - 1)//1)

  # ── Refuting each shape ─────────────────────────────────────────────────────

  defp refute(graph, values, {:initial, index}) do
    graph.initial_states
    |> Enum.sort()
    |> Enum.find(&(not holds?(values, &1, index)))
    |> finite()
  end

  defp refute(graph, values, {:invariant, index}) do
    0..(graph.state_count - 1)//1
    |> Enum.find(&(not holds?(values, &1, index)))
    |> finite()
  end

  # ◇P is refuted by a behaviour that never reaches P, so the prefix is restricted too:
  # it has to start at an initial ¬P state and stay in ¬P all the way to the cycle.
  defp refute(graph, values, {:eventually, index}) do
    region = where(graph, values, index, false)

    with [_ | _] = components <- fair_components(graph, region, &always/1),
         sources <- graph.initial_states |> Enum.sort() |> Enum.filter(&(&1 in region)),
         %{} = found <- reach(graph, region, sources, union(components)) do
      cycle_witness(graph, components, found, region, [])
    else
      _ -> nil
    end
  end

  # []◇P is refuted by a behaviour that reaches P only finitely often — its tail stays in
  # ¬P, but how it got there is unconstrained.
  defp refute(graph, values, {:infinitely_often, index}) do
    region = where(graph, values, index, false)

    with [_ | _] = components <- fair_components(graph, region, &always/1),
         %{} = found <- reach(graph, all_states(graph), initials(graph), union(components)) do
      cycle_witness(graph, components, found, all_states(graph), [])
    else
      _ -> nil
    end
  end

  # ◇[]P is refuted by a behaviour where ¬P keeps coming back, so the cycle has to hold a
  # ¬P state — and it has to still hold one after any fairness split.
  defp refute(graph, values, {:eventually_always, index}) do
    holds_nowhere = &Enum.any?(&1, fn id -> not holds?(values, id, index) end)
    components = fair_components(graph, all_states(graph), holds_nowhere)

    with [_ | _] <- components,
         %{} = found <- reach(graph, all_states(graph), initials(graph), union(components)) do
      component = Enum.find(components, &MapSet.member?(&1, found.entry))
      required = component |> Enum.sort() |> Enum.find(&(not holds?(values, &1, index)))
      cycle_witness(graph, components, found, all_states(graph), [{:state, required}])
    else
      _ -> nil
    end
  end

  # P ~> Q is refuted by a reachable P state from which Q never comes. The prefix to that
  # state is unconstrained; everything after it stays in ¬Q.
  defp refute(graph, values, {:leads_to, p, q}) do
    region = where(graph, values, q, false)

    with [_ | _] = components <- fair_components(graph, region, &always/1),
         trapped <- back_reach(graph, region, union(components)),
         [_ | _] = candidates <-
           Enum.filter(Enum.sort(trapped), &holds?(values, &1, p)),
         %{} = to_state <-
           reach(graph, all_states(graph), initials(graph), MapSet.new(candidates)),
         %{} = to_cycle <- reach(graph, region, [to_state.entry], union(components)) do
      found = %{
        source: to_state.source,
        entry: to_cycle.entry,
        steps: to_state.steps ++ to_cycle.steps
      }

      cycle_witness(graph, components, found, region, [])
    else
      _ -> nil
    end
  end

  defp always(_component), do: true

  defp finite(nil), do: nil
  defp finite(id), do: {:finite, id}

  defp initials(graph), do: graph.initial_states |> Enum.sort()

  defp union(components), do: Enum.reduce(components, MapSet.new(), &MapSet.union(&2, &1))

  defp cycle_witness(graph, components, found, region, extra) do
    component = Enum.find(components, &MapSet.member?(&1, found.entry))

    %{
      source: found.source,
      entry: found.entry,
      steps: found.steps,
      component: component,
      region: region,
      extra: extra ++ fairness_targets(graph, component)
    }
    |> then(&{:cycle, &1})
  end

  # ── Components ──────────────────────────────────────────────────────────────

  # Every fair strongly connected subgraph of `region` that `witness?` accepts. Maximal
  # components first; a component broken only by strong fairness is split on the states
  # where the unfair constraint is enabled and searched again, because a subset that
  # avoids them may be fair where the whole was not.
  defp fair_components(graph, region, witness?) do
    graph |> StateGraph.sccs(region) |> Enum.flat_map(&refine(graph, &1, witness?))
  end

  defp refine(graph, component, witness?) do
    cond do
      not cyclic?(graph, component) ->
        []

      true ->
        case unfair(graph, component) do
          nil ->
            if witness?.(component), do: [component], else: []

          # Continuously enabled and never taken. Every subset has it enabled everywhere
          # too, and no edge this one lacked — so nothing below is fair either.
          {:weak, _index} ->
            []

          {:strong, index} ->
            smaller =
              MapSet.new(Enum.reject(component, &StateGraph.enabled?(graph, &1, index)))

            if MapSet.size(smaller) == 0,
              do: [],
              else: fair_components(graph, smaller, witness?)
        end
    end
  end

  defp cyclic?(graph, component) do
    MapSet.size(component) > 1 or
      Enum.any?(component, fn id ->
        Enum.any?(successors(graph, id), fn {_action, _params, next} -> next == id end)
      end)
  end

  defp unfair(graph, component) do
    graph.fairness_index
    |> Enum.with_index()
    |> Enum.find_value(fn {{fairness, binding}, index} ->
      cond do
        taken?(graph, component, fairness.action, binding) -> nil
        fairness.kind == :weak -> weak_break(graph, component, index)
        fairness.kind == :strong -> strong_break(graph, component, index)
      end
    end)
  end

  defp weak_break(graph, component, index) do
    if Enum.all?(component, &StateGraph.enabled?(graph, &1, index)), do: {:weak, index}
  end

  defp strong_break(graph, component, index) do
    if Enum.any?(component, &StateGraph.enabled?(graph, &1, index)), do: {:strong, index}
  end

  defp taken?(graph, component, action, binding) do
    Enum.any?(component, fn id ->
      Enum.any?(StateGraph.successors(graph, id), fn {name, params, next} ->
        name == action and MapSet.member?(component, next) and Temporal.extends?(params, binding)
      end)
    end)
  end

  # A stuck state stutters forever (§5.3), which is a self-loop with no action — so it is
  # a component of its own, and a fair one, since nothing is enabled in it to be required.
  defp successors(graph, id) do
    case StateGraph.successors(graph, id) do
      [] -> [{nil, nil, id}]
      edges -> edges
    end
  end

  # ── Paths ───────────────────────────────────────────────────────────────────

  # Shortest path from any of `sources` to any of `targets`, staying inside `region`.
  # Breadth-first, and sources and successors in id order, so the counterexample a run
  # reports does not depend on how a map happened to be laid out.
  defp reach(graph, region, sources, targets) do
    sources = Enum.filter(sources, &MapSet.member?(region, &1))

    case Enum.find(sources, &MapSet.member?(targets, &1)) do
      nil -> search(graph, region, sources, targets)
      id -> %{source: id, entry: id, steps: []}
    end
  end

  defp search(graph, region, sources, targets) do
    queue = :queue.from_list(Enum.map(sources, &{&1, &1, []}))
    seen = MapSet.new(sources)
    bfs(graph, region, targets, queue, seen)
  end

  defp bfs(graph, region, targets, queue, seen) do
    case :queue.out(queue) do
      {:empty, _} ->
        nil

      {{:value, {source, id, steps}}, rest} ->
        {queue, seen, found} =
          graph
          |> StateGraph.successors(id)
          |> Enum.reduce({rest, seen, nil}, fn
            _edge, {queue, seen, found} when found != nil ->
              {queue, seen, found}

            {action, params, next}, {queue, seen, nil} ->
              cond do
                not MapSet.member?(region, next) ->
                  {queue, seen, nil}

                MapSet.member?(targets, next) ->
                  {queue, seen,
                   %{source: source, entry: next, steps: Enum.reverse([{action, params} | steps])}}

                MapSet.member?(seen, next) ->
                  {queue, seen, nil}

                true ->
                  {:queue.in({source, next, [{action, params} | steps]}, queue),
                   MapSet.put(seen, next), nil}
              end
          end)

        found || bfs(graph, region, targets, queue, seen)
    end
  end

  # Every state of `region` from which `targets` is reachable without leaving `region`.
  defp back_reach(graph, region, targets) do
    reverse =
      Enum.reduce(region, %{}, fn id, acc ->
        graph
        |> StateGraph.successors(id)
        |> Enum.reduce(acc, fn {_action, _params, next}, acc ->
          if MapSet.member?(region, next), do: Map.update(acc, next, [id], &[id | &1]), else: acc
        end)
      end)

    grow(reverse, MapSet.new(targets), Enum.to_list(targets))
  end

  defp grow(_reverse, seen, []), do: seen

  defp grow(reverse, seen, [id | rest]) do
    fresh = reverse |> Map.get(id, []) |> Enum.reject(&MapSet.member?(seen, &1))
    grow(reverse, Enum.into(fresh, seen), fresh ++ rest)
  end

  # ── The counterexample ──────────────────────────────────────────────────────

  defp lasso(graph, instance, {:finite, id}) do
    %{
      prefix:
        Trace.generate(graph, id,
          type: :liveness,
          property: instance.name,
          message: describe(instance, "does not hold in this state")
        ),
      cycle: nil
    }
  end

  defp lasso(graph, instance, {:cycle, witness}) do
    init_index = StateGraph.node_record(graph, witness.source).init_index

    prefix =
      Trace.replay(graph, init_index, witness.steps,
        type: :liveness,
        property: instance.name,
        message: describe(instance, "is refuted by this behaviour")
      )

    cycle_steps = closed_walk(graph, witness)

    %{prefix: prefix, cycle: Trace.from(graph, List.last(prefix.states), cycle_steps, [])}
  end

  defp describe(%{bound: []} = instance, what),
    do: "temporal property #{inspect(instance.name)} #{what}"

  defp describe(instance, what) do
    values = instance.bound |> Enum.reverse() |> Enum.map_join(", ", &inspect/1)
    "temporal property #{inspect(instance.name)}, at #{values}, #{what}"
  end

  # A closed walk from the entry state through everything the cycle has to contain: the
  # state or edge that satisfies each fairness constraint, and whatever the property
  # itself demands. Without them the printed cycle could be one a fairness constraint
  # forbids — a counterexample the spec's own assumptions rule out is not one.
  defp closed_walk(graph, %{entry: entry, component: component, extra: targets}) do
    {steps, at} =
      Enum.reduce(targets, {[], entry}, fn target, {steps, at} ->
        {more, landed} = leg(graph, component, at, target)
        {steps ++ more, landed}
      end)

    {home, ^entry} = leg(graph, component, at, {:state, entry})

    case steps ++ home do
      [] -> forced_cycle(graph, component, entry)
      walk -> walk
    end
  end

  defp leg(_graph, _component, at, {:state, at}), do: {[], at}

  defp leg(graph, component, at, {:state, target}) do
    found = reach(graph, component, [at], MapSet.new([target]))
    {found.steps, target}
  end

  defp leg(graph, component, at, {:edge, from, action, params, to}) do
    {steps, ^from} = leg(graph, component, at, {:state, from})
    {steps ++ [{action, params}], to}
  end

  # Nothing above needed the walk to go anywhere, so it has to find a cycle of its own:
  # a self-edge, or the shortest way out of the entry state and back. It comes back empty
  # only for a state with no successors at all, which stutters (§5.3) and has no action to
  # print.
  defp forced_cycle(graph, component, entry) do
    graph
    |> StateGraph.successors(entry)
    |> Enum.filter(fn {_action, _params, next} -> MapSet.member?(component, next) end)
    |> Enum.find_value([], fn {action, params, next} ->
      if next == entry do
        [{action, params}]
      else
        case reach(graph, component, [next], MapSet.new([entry])) do
          nil -> nil
          found -> [{action, params} | found.steps]
        end
      end
    end)
  end

  # One target per fairness constraint: a state of the component where it is disabled, or
  # failing that an edge inside the component that takes it. The component is fair, so one
  # of the two exists for each — and the walk has to actually GO there. A constraint is
  # satisfied by a behaviour, not by a component, so a cycle that skipped past the state
  # where the constraint is disabled would be a cycle that constraint forbids, printed as
  # a counterexample.
  defp fairness_targets(graph, component) do
    ordered = Enum.sort(component)

    graph.fairness_index
    |> Enum.with_index()
    |> Enum.flat_map(fn {{fairness, binding}, index} ->
      case Enum.find(ordered, &(not StateGraph.enabled?(graph, &1, index))) do
        nil -> taking_edge(graph, component, fairness.action, binding)
        disabled -> [{:state, disabled}]
      end
    end)
  end

  defp taking_edge(graph, component, action, binding) do
    Enum.find_value(Enum.sort(component), [], fn id ->
      graph
      |> StateGraph.successors(id)
      |> Enum.find_value(fn {name, params, next} ->
        if name == action and MapSet.member?(component, next) and
             Temporal.extends?(params, binding),
           do: [{:edge, id, name, params, next}]
      end)
    end)
  end
end
