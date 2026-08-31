defmodule TLA.Differential.Paxos do
  @moduledoc """
  `Paxos.tla`, in the ExTLA DSL — Lamport's specification of the algorithm in
  *Paxos Made Simple*, the consensus half without the leader election that makes
  it terminate.

  The sixth and last corpus entry. What it adds over the other five is
  `phase_2a`'s guard, which quantifies over a **subset** of the messages in
  flight: "some set of promises covering a quorum". Enabling that action means
  searching a powerset of a state-dependent set rather than testing a field, and
  a guard that is subtly too permissive shows up nowhere except in the state
  count.

  Message-type tags are model values on the TLC side and atoms here:
  `phase1a`/`:phase_1a` and so on, per the corpus README.

  One deliberate weakening, the same one the other message-passing entries
  record: §1.5 cannot type the elements of a collection, so TLA+'s
  `msgs \\subseteq Message` has no counterpart here.
  """
  use TLA.Spec

  constant :acceptors, default: MapSet.new([:a1, :a2, :a3])
  constant :values, default: MapSet.new([:v1, :v2])
  constant :max_ballot, default: 1

  # Any two quorums intersect. That is the whole reason Paxos is safe; TLA+
  # states it as an ASSUME, and here it is a property of the constant a run is
  # given.
  constant :quorums,
    default:
      MapSet.new([
        MapSet.new([:a1, :a2]),
        MapSet.new([:a1, :a3]),
        MapSet.new([:a2, :a3]),
        MapSet.new([:a1, :a2, :a3])
      ])

  variable :max_bal, type: [^acceptors ~> -1..^max_ballot]
  variable :max_v_bal, type: [^acceptors ~> -1..^max_ballot]
  variable :max_val, type: [^acceptors ~> (^values | :none)]
  variable :msgs, type: :set

  init do
    max_bal = for_each(^acceptors, fn _ -> -1 end)
    max_v_bal = for_each(^acceptors, fn _ -> -1 end)
    max_val = for_each(^acceptors, fn _ -> :none end)
    msgs = set()
  end

  # ── Actions ──
  #
  # Nothing ever leaves `msgs`. A message that has been read is still there to be
  # read again, which is how the model says the network may duplicate and
  # reorder — and why no action here is "receive".

  action :phase_1a, params: [b: 0..^max_ballot] do
    msgs = put(msgs, %{type: :phase_1a, bal: b})
  end

  action :phase_1b,
    params: [
      a: ^acceptors,
      m: fn st, %{a: a} ->
        Enum.filter(st.msgs, &(&1.type == :phase_1a and &1.bal > st.max_bal[a]))
      end
    ] do
    max_bal = update(max_bal, a, fn _ -> m.bal end)

    msgs =
      put(msgs, %{
        type: :phase_1b,
        acc: a,
        bal: m.bal,
        mbal: max_v_bal[a],
        mval: max_val[a]
      })
  end

  # The heart of the algorithm. A value may be proposed at ballot `b` if some set
  # of promises covering a quorum either reports no acceptance at all, or reports
  # one at a highest ballot `c` whose value is `v`. The proposer is not free to
  # pick: if anyone might already have chosen, it must propose what they had.
  action :phase_2a, params: [b: 0..^max_ballot, v: ^values] do
    require not Enum.any?(msgs, &(&1.type == :phase_2a and &1.bal == b))

    let promises = set(Enum.filter(msgs, &(&1.type == :phase_1b and &1.bal == b)))

    require Enum.any?(^quorums, fn q ->
              Enum.any?(TLA.Set.powerset(promises), fn s ->
                Enum.all?(q, fn a -> Enum.any?(s, &(&1.acc == a)) end) and
                  (Enum.all?(s, &(&1.mbal == -1)) or
                     Enum.any?(0..(b - 1)//1, fn c ->
                       Enum.all?(s, &(&1.mbal <= c)) and
                         Enum.any?(s, &(&1.mbal == c and &1.mval == v))
                     end))
              end)
            end)

    msgs = put(msgs, %{type: :phase_2a, bal: b, val: v})
  end

  action :phase_2b,
    params: [
      a: ^acceptors,
      m: fn st, %{a: a} ->
        Enum.filter(st.msgs, &(&1.type == :phase_2a and &1.bal >= st.max_bal[a]))
      end
    ] do
    max_bal = update(max_bal, a, fn _ -> m.bal end)
    max_v_bal = update(max_v_bal, a, fn _ -> m.bal end)
    max_val = update(max_val, a, fn _ -> m.val end)
    msgs = put(msgs, %{type: :phase_2b, acc: a, bal: m.bal, val: m.val})
  end

  # ── Safety ──

  # The point of the algorithm: at most one value is ever chosen. It holds, so
  # the state count carries the whole comparison.
  invariant :consistency, desc: "at most one value is ever chosen" do
    let chosen =
          Enum.filter(^values, fn v ->
            Enum.any?(0..^max_ballot, fn b ->
              Enum.any?(^quorums, fn q ->
                Enum.all?(q, fn a ->
                  member?(msgs, %{type: :phase_2b, acc: a, bal: b, val: v})
                end)
              end)
            end)
          end)

    length(chosen) <= 1
  end

  # Nothing is accepted that was not proposed at that ballot, which is what makes
  # `consistency` an argument about proposals rather than about votes.
  invariant :accepted_was_proposed do
    Enum.all?(msgs, fn m ->
      m.type != :phase_2b or
        Enum.any?(msgs, &(&1.type == :phase_2a and &1.bal == m.bal and &1.val == m.val))
    end)
  end
end
