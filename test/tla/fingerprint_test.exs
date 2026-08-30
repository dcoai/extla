defmodule TLA.FingerprintTest do
  use ExUnit.Case, async: true

  doctest TLA.Fingerprint

  alias TLA.Fingerprint

  describe "canonical/1" do
    # The whole reason `:deterministic` is passed. A map large enough to be stored
    # as a hashmap rather than a flatmap encodes in internal order without it, so
    # two equal states built by different insertion orders would encode differently
    # and be explored twice.
    test "is insertion-order independent for a map past the flatmap threshold" do
      pairs = for i <- 1..64, do: {:"k#{i}", i}

      ascending = Map.new(pairs)
      descending = Enum.reduce(Enum.reverse(pairs), %{}, fn {k, v}, acc -> Map.put(acc, k, v) end)

      assert ascending == descending
      assert Fingerprint.canonical(ascending) == Fingerprint.canonical(descending)
    end

    test "is insertion-order independent for a MapSet" do
      up = MapSet.new(1..64)
      down = Enum.reduce(64..1//-1, MapSet.new(), &MapSet.put(&2, &1))

      assert up == down
      assert Fingerprint.canonical(up) == Fingerprint.canonical(down)
    end

    test "distinguishes states that differ" do
      refute Fingerprint.canonical(%{x: 1}) == Fingerprint.canonical(%{x: 2})
    end
  end

  describe "compute/2" do
    test "is stable for equal states and differs for unequal ones" do
      assert Fingerprint.compute(%{x: 1, y: 2}) == Fingerprint.compute(%{y: 2, x: 1})
      refute Fingerprint.compute(%{x: 1}) == Fingerprint.compute(%{x: 2})
    end

    test "defaults to 64 bits and accepts 128" do
      assert byte_size(Fingerprint.compute(%{x: 1})) == 8
      assert byte_size(Fingerprint.compute(%{x: 1}, bits: 64)) == 8
      assert byte_size(Fingerprint.compute(%{x: 1}, bits: 128)) == 16
    end

    test "the 64-bit fingerprint is a prefix of the 128-bit one" do
      state = %{x: 1, q: [:a, :b]}
      <<prefix::binary-size(8), _::binary>> = Fingerprint.compute(state, bits: 128)
      assert Fingerprint.compute(state, bits: 64) == prefix
    end

    # A silently accepted `bits: 32` would be an unsound run reported as a sound
    # one, which is the failure this module exists to prevent.
    test "rejects a width it does not implement" do
      assert_raise ArgumentError, ~r/must be one of \[64, 128\]/, fn ->
        Fingerprint.compute(%{x: 1}, bits: 32)
      end
    end
  end

  describe "collision_estimate/2" do
    # The table in 01-foundation.md §Why not :erlang.phash2/1, recomputed. If this
    # test ever disagrees with that table, one of the two is wrong.
    test "reproduces the phash2-versus-64-bit table" do
      assert_in_delta Fingerprint.collision_estimate(100_000, 27), 37.25, 0.01
      assert_in_delta Fingerprint.collision_estimate(1_000_000, 27), 3725.29, 0.01
      assert_in_delta Fingerprint.collision_estimate(10_000_000, 27), 372_529.0, 1.0

      assert_in_delta Fingerprint.collision_estimate(100_000, 64), 2.71e-10, 1.0e-12
      assert_in_delta Fingerprint.collision_estimate(1_000_000, 64), 2.71e-8, 1.0e-10
      assert_in_delta Fingerprint.collision_estimate(10_000_000, 64), 2.71e-6, 1.0e-8
    end

    test "is zero for an empty run and grows quadratically" do
      assert Fingerprint.collision_estimate(0, 64) == 0.0

      one = Fingerprint.collision_estimate(1_000_000, 64)
      two = Fingerprint.collision_estimate(2_000_000, 64)
      assert_in_delta two / one, 4.0, 1.0e-9
    end

    test "128 bits is 2^64 times safer than 64" do
      assert_in_delta Fingerprint.collision_estimate(10_000_000, 64) /
                        Fingerprint.collision_estimate(10_000_000, 128),
                      :math.pow(2, 64),
                      1.0e6
    end
  end
end
