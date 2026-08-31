defmodule TLA.SymmetryTest do
  use ExUnit.Case, async: true

  alias TLA.{ModelChecker, Symmetry, Trace}
  alias TLA.TestSpecs.{Asymmetric, Counter, PerBinding}

  @processes %{processes: MapSet.new([:p1, :p2])}

  describe "mappings/2" do
    test "one per permutation, identity included" do
      mappings = Symmetry.mappings(@processes, [:processes])

      assert length(mappings) == 2
      assert %{p1: :p1, p2: :p2} in mappings
      assert %{p1: :p2, p2: :p1} in mappings
    end

    test "n! per set, and the product across sets" do
      assert length(Symmetry.mappings(%{s: MapSet.new([:a, :b, :c])}, [:s])) == 6

      two_sets = %{s: MapSet.new([:a, :b]), t: MapSet.new([:x, :y])}
      assert length(Symmetry.mappings(two_sets, [:s, :t])) == 4
    end

    test "the same list every run, so a fingerprint is too" do
      assert Symmetry.mappings(@processes, [:processes]) ==
               Symmetry.mappings(@processes, [:processes])
    end

    test "a constant this run did not assign is an error naming it" do
      assert_raise ArgumentError, ~r/assigned no value/, fn ->
        Symmetry.mappings(@processes, [:resources])
      end
    end

    test "a constant with no elements to permute is an error" do
      assert_raise ArgumentError, ~r/Only a set or a list/, fn ->
        Symmetry.mappings(%{limit: 3}, [:limit])
      end
    end
  end

  describe "permute/2" do
    test "replaces an element wherever it appears" do
      mapping = %{p1: :p2, p2: :p1}

      state = %{
        owner: :p1,
        waiting: MapSet.new([:p1, :p2]),
        queue: [:p2, :p1],
        held: {:holding, :p1},
        pc: %{p1: :idle, p2: :waiting}
      }

      assert Symmetry.permute(state, mapping) == %{
               owner: :p2,
               waiting: MapSet.new([:p1, :p2]),
               queue: [:p1, :p2],
               held: {:holding, :p2},
               pc: %{p2: :idle, p1: :waiting}
             }
    end

    test "leaves everything it was not told about alone" do
      assert Symmetry.permute(%{n: 1, s: "p1"}, %{p1: :p2}) == %{n: 1, s: "p1"}
    end
  end

  describe "canonical/2" do
    test "two states that differ only by a permutation encode the same" do
      mappings = Symmetry.mappings(@processes, [:processes])

      one = %{pc: %{p1: :waiting, p2: :idle}, owner: nil}
      other = %{pc: %{p1: :idle, p2: :waiting}, owner: nil}

      assert Symmetry.canonical(one, mappings) == Symmetry.canonical(other, mappings)
    end

    test "two states that differ otherwise do not" do
      mappings = Symmetry.mappings(@processes, [:processes])

      one = %{pc: %{p1: :waiting, p2: :idle}, owner: nil}
      other = %{pc: %{p1: :holding, p2: :idle}, owner: :p1}

      assert Symmetry.canonical(one, mappings) != Symmetry.canonical(other, mappings)
    end
  end

  describe "the reduction" do
    test "explores fewer states and reaches the same verdict" do
      full = ModelChecker.run(PerBinding, %{constants: @processes})
      reduced = ModelChecker.run(PerBinding, %{constants: @processes, symmetry: [:processes]})

      assert reduced.status == full.status
      assert reduced.distinct_states < full.distinct_states
      assert reduced.deadlock == full.deadlock
    end

    # The graph keeps the first state of an orbit to be discovered, not a canonicalized
    # stand-in — so every state it files is one the spec can actually reach, and a trace
    # replayed through it is a real behaviour rather than a normalized one.
    test "every state it keeps is one the unreduced run also found" do
      reduced = states_of(PerBinding, %{constants: @processes, symmetry: [:processes]})
      full = states_of(PerBinding, %{constants: @processes})

      assert MapSet.subset?(reduced, full)
      assert MapSet.size(reduced) < MapSet.size(full)
    end

    test "says what it is paying when the permutation count gets large" do
      big = %{s: MapSet.new(for i <- 1..5, do: :"e#{i}")}
      small = %{s: MapSet.new([:a, :b, :c])}

      assert length(Symmetry.mappings(big, [:s])) == 120
      assert length(Symmetry.mappings(small, [:s])) == 6
    end
  end

  describe "verify_symmetry" do
    test "a sound declaration passes and returns the reduced run" do
      result =
        ModelChecker.run(PerBinding, %{
          constants: @processes,
          symmetry: [:processes],
          verify_symmetry: true
        })

      full = ModelChecker.run(PerBinding, %{constants: @processes})

      assert result.status == :ok
      assert result.distinct_states < full.distinct_states
    end

    # `Asymmetric`'s invariant names p2, so collapsing p1 and p2 hides the state that
    # breaks it: the reduced run verifies and the unreduced one does not. Nothing can
    # catch this statically (D-17); this is the check that does.
    test "an unsound one is caught, and the message says what differed" do
      config = %{constants: @processes, symmetry: [:processes]}

      assert ModelChecker.run(Asymmetric, config).status == :ok
      assert ModelChecker.run(Asymmetric, %{constants: @processes}).status == :violation

      error =
        assert_raise TLA.Symmetry.UnsoundError, fn ->
          ModelChecker.run(Asymmetric, Map.put(config, :verify_symmetry, true))
        end

      message = Exception.message(error)
      assert message =~ "is not sound for this spec"
      assert message =~ "status: :ok with the reduction, :violation without"
      assert message =~ "D-17"
    end

    test "asking to verify nothing is an error rather than a no-op" do
      assert_raise ArgumentError, ~r/no `symmetry:` to verify/, fn ->
        ModelChecker.run(Counter, %{constants: %{max: 2}, verify_symmetry: true})
      end
    end
  end

  describe "what it refuses" do
    # The quotient graph identifies states, so a path that leaves an orbit and one that
    # returns to it look the same — and a cycle is what a liveness verdict is read off.
    test "symmetry together with liveness checking" do
      assert_raise ArgumentError, ~r/not sound together/, fn ->
        ModelChecker.run(PerBinding, %{
          constants: @processes,
          symmetry: [:processes],
          check_liveness: true
        })
      end
    end
  end

  defp states_of(module, config) do
    {_result, graph} = ModelChecker.explore(module, config)

    MapSet.new(0..(graph.state_count - 1)//1, fn id ->
      graph |> Trace.generate(id) |> Map.fetch!(:states) |> List.last()
    end)
  end
end
