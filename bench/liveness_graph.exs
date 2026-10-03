# What the liveness graph costs, on the two corpus entries big enough to say.
#
#     mix run bench/liveness_graph.exs
#
# The structure of `ExTLA.StateGraph` §The liveness graph is opt-in because it is
# not free, and "not free" is a number rather than an intuition. Time is the best
# of three runs each way; heap is what the completed graph still holds after a
# sweep, which is the figure that decides whether a state space fits in a machine.
#
# It is a script rather than a test: it takes minutes, and a benchmark that fails
# CI on a slow runner teaches people to ignore CI.

Code.require_file("test/differential/raft_election/spec.ex")
Code.require_file("test/differential/bounded_buffer/spec.ex")

entries = [
  {ExTLA.Differential.RaftElection, %{servers: MapSet.new([:s1, :s2, :s3]), max_term: 2}},
  {ExTLA.Differential.BoundedBuffer,
   %{
     producers: MapSet.new([:p1, :p2]),
     consumers: MapSet.new([:c1, :c2]),
     buffer_size: 3,
     max_items: 6
   }}
]

best_of_three = fn module, config ->
  ExTLA.ModelChecker.run(module, config)

  Enum.min(
    for _ <- 1..3, do: elem(:timer.tc(fn -> ExTLA.ModelChecker.run(module, config) end), 0)
  )
end

# Heap the finished graph holds: total memory with it alive minus total before it
# existed, both after a full sweep. `keep` is called while the graph is still
# referenced so the compiler cannot collect it early.
resident = fn build ->
  :erlang.garbage_collect()
  before = :erlang.memory(:total)
  keep = build.()
  :erlang.garbage_collect()
  held = :erlang.memory(:total)
  measured = keep.()
  :erlang.garbage_collect()
  {held - before, measured}
end

for {module, constants} <- entries do
  safety = %{constants: constants, invariants: [], action_properties: []}
  live = Map.put(safety, :liveness_graph, true)

  off = best_of_three.(module, safety)
  on = best_of_three.(module, live)

  {safety_bytes, states} =
    resident.(fn ->
      {_result, graph} = ExTLA.ModelChecker.explore(module, safety)
      fn -> graph.state_count end
    end)

  {live_bytes, edges} =
    resident.(fn ->
      {_result, graph} = ExTLA.ModelChecker.explore(module, live)
      fn -> graph.edges |> Map.values() |> Enum.map(&length/1) |> Enum.sum() end
    end)

  {_result, graph} = ExTLA.ModelChecker.explore(module, live)
  extra = live_bytes - safety_bytes

  IO.puts("""
  #{inspect(module)}
    #{states} states, #{edges} edges, #{length(graph.fairness_index)} fairness constraints
    time  #{div(off, 1000)}ms -> #{div(on, 1000)}ms   (+#{Float.round((on - off) / off * 100, 1)}%)
    heap  #{div(safety_bytes, 1024 * 1024)}MB -> #{div(live_bytes, 1024 * 1024)}MB   \
  (+#{div(extra, 1024)}KB, #{div(extra, max(edges, 1))} bytes per edge)
  """)
end
