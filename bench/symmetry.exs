# What symmetry reduction buys, and what it costs, on the corpus entries that have
# interchangeable constants.
#
#     mix run bench/symmetry.exs
#
# §Symmetry says the reduction is a lever to be benchmarked rather than assumed: n!
# encodings per state against up to n! fewer states, which is a wash at two or three
# elements and a win further up. This is where that claim gets a number.

Code.require_file("test/differential/distributed_lock/spec.ex")
Code.require_file("test/differential/raft_election/spec.ex")

entries = [
  {TLA.Differential.DistributedLock,
   %{processes: MapSet.new([:p1, :p2]), resources: MapSet.new([:r1, :r2])}, [:processes]},
  {TLA.Differential.DistributedLock,
   %{processes: MapSet.new([:p1, :p2]), resources: MapSet.new([:r1, :r2])},
   [:processes, :resources]},
  {TLA.Differential.DistributedLock,
   %{processes: MapSet.new([:p1, :p2, :p3]), resources: MapSet.new([:r1, :r2])},
   [:processes, :resources]},
  {TLA.Differential.RaftElection, %{servers: MapSet.new([:s1, :s2, :s3]), max_term: 2},
   [:servers]}
]

best_of_three = fn module, config ->
  TLA.ModelChecker.run(module, config)

  Enum.min(for _ <- 1..3, do: elem(:timer.tc(fn -> TLA.ModelChecker.run(module, config) end), 0))
end

for {module, constants, names} <- entries do
  base = %{constants: constants, invariants: [], action_properties: []}
  reduced = Map.put(base, :symmetry, names)

  full = TLA.ModelChecker.run(module, base)
  small = TLA.ModelChecker.run(module, reduced)

  off = best_of_three.(module, base)
  on = best_of_three.(module, reduced)
  permutations = length(TLA.Symmetry.mappings(constants, names))

  IO.puts("""
  #{inspect(module)} symmetry: #{inspect(names)}  (#{permutations} permutations per state)
    states  #{full.distinct_states} -> #{small.distinct_states}  \
  (#{Float.round(full.distinct_states / small.distinct_states, 2)}x fewer)
    time    #{div(off, 1000)}ms -> #{div(on, 1000)}ms
  """)
end
