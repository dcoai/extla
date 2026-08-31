defmodule TLA.State.JsonTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TLA.State.Json

  defp round_trip(term),
    do: term |> Json.encode() |> Jason.encode!() |> Jason.decode!() |> Json.decode!()

  describe "every term 02-dsl-semantics.md §6 permits" do
    test "survives a round trip through JSON" do
      terms = [
        0,
        -17,
        :ready,
        true,
        false,
        nil,
        "a binary",
        [],
        [1, :two, "three"],
        {},
        {:withdraw, 5},
        {:a, {:b, [:c]}},
        %{},
        %{count: 1, status: :ready},
        # The keys a JSON object could not carry: not strings, and not all atoms.
        %{1 => :one, {:pair, 2} => "two", "three" => 3},
        MapSet.new([:alice, :bob]),
        MapSet.new([{1, 2}, {3, 4}]),
        %{queue: [%{to: :bob, amount: 3}], log: MapSet.new([:sent])}
      ]

      for term <- terms, do: assert(round_trip(term) == term)
    end

    property "and so does anything built out of them" do
      leaf =
        StreamData.one_of([
          StreamData.integer(),
          StreamData.member_of([:ready, :incrementing, true, false, nil]),
          StreamData.string(:alphanumeric)
        ])

      term =
        StreamData.tree(leaf, fn child ->
          StreamData.one_of([
            StreamData.list_of(child, max_length: 3),
            StreamData.map(StreamData.list_of(child, max_length: 3), &List.to_tuple/1),
            StreamData.map(StreamData.list_of(child, max_length: 3), &MapSet.new/1),
            StreamData.map_of(leaf, child, max_length: 3)
          ])
        end)

      check all(value <- term) do
        assert round_trip(value) == value
      end
    end

    test "a struct keeps its module" do
      assert round_trip(%TLA.Trace{type: :safety, actions: [:increment]}) == %TLA.Trace{
               type: :safety,
               actions: [:increment]
             }
    end
  end

  describe "what it refuses" do
    # §6 forbids these because state identity is a hash of the value: the first four have
    # no stable identity across runs, and floats make two "equal" states hash differently.
    test "a term a spec's state may not hold, naming the rule" do
      for forbidden <- [self(), make_ref(), fn -> :ok end, 1.5] do
        error = assert_raise Json.Error, fn -> Json.encode(forbidden) end
        assert Exception.message(error) =~ "is not a term a spec's state may hold"
        assert Exception.message(error) =~ "§6"
      end
    end

    test "JSON this module did not write" do
      error = assert_raise Json.Error, fn -> Json.decode!(%{"nope" => 1}) end
      assert Exception.message(error) =~ "is not the JSON form of a state term"
    end

    test "a malformed encoded map" do
      assert_raise Json.Error, ~r/is not a \[key, value\] pair/, fn ->
        Json.decode!(%{"m" => [["one"]]})
      end
    end

    # The atom table is never collected, so a decoder that creates atoms from a file lets
    # a large one exhaust it. The failure is `String.to_existing_atom/1`'s own: an earlier
    # version measured the atom table so the message could name the atom, and that answer
    # depends on what other processes are doing — CI, running its tests concurrently,
    # refuted it.
    test "an atom the system does not already have" do
      assert_raise ArgumentError, ~r/not an already existing atom/, fn ->
        Json.decode!(%{"a" => "no_such_atom_in_this_system"})
      end
    end
  end
end
