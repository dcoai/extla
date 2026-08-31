defmodule TLA.Differential.BoundedBuffer do
  @moduledoc """
  `BoundedBuffer.tla`, in the ExTLA DSL — and `spec/07-examples.md` Example 3,
  which is the point: the corpus checks the documentation rather than a
  paraphrase of it.

  The first entry with a **sequence** in state. Order matters in a sequence and
  does not in a set, so a fingerprint that canonicalised a list the way it
  canonicalises a set would collapse states that differ only in what is at the
  head, and the state count is where that shows up.

  TLC checks the safety half. The temporal properties and the fairness
  constraints are declared and unchecked in Phase 1.
  """
  use TLA.Spec

  constant :producers, default: MapSet.new([:p1, :p2])
  constant :consumers, default: MapSet.new([:c1, :c2])
  constant :buffer_size, default: 3
  constant :max_items, default: 6

  # TLA+'s `Item`, element for element; the bound is one short of `^max_items`
  # because the first item produced is numbered 0.
  variable :buffer, type: seq(%{producer: ^producers, seq: 0..(^max_items - 1)})
  variable :produced_count, type: 0..^max_items
  variable :consumed_count, type: 0..^max_items
  variable :producer_pc, type: [^producers ~> [:ready, :waiting, :producing]]
  variable :consumer_pc, type: [^consumers ~> [:ready, :waiting, :consuming]]

  init do
    buffer = seq()
    produced_count = 0
    consumed_count = 0
    producer_pc = for_each(^producers, fn _ -> :ready end)
    consumer_pc = for_each(^consumers, fn _ -> :ready end)
  end

  action :produce, params: [p: ^producers] do
    require producer_pc[p] == :ready
    require len(buffer) < ^buffer_size
    require produced_count < ^max_items

    buffer = append(buffer, %{producer: p, seq: produced_count})
    produced_count = produced_count + 1
    producer_pc = update(producer_pc, p, fn _ -> :producing end)
  end

  action :producer_done, params: [p: ^producers] do
    require producer_pc[p] == :producing
    producer_pc = update(producer_pc, p, fn _ -> :ready end)
  end

  action :producer_wait, params: [p: ^producers] do
    require producer_pc[p] == :ready
    require len(buffer) >= ^buffer_size
    producer_pc = update(producer_pc, p, fn _ -> :waiting end)
  end

  action :producer_wake, params: [p: ^producers] do
    require producer_pc[p] == :waiting
    require len(buffer) < ^buffer_size
    producer_pc = update(producer_pc, p, fn _ -> :ready end)
  end

  action :consume, params: [c: ^consumers] do
    require consumer_pc[c] == :ready
    require len(buffer) > 0

    buffer = tail(buffer)
    consumed_count = consumed_count + 1
    consumer_pc = update(consumer_pc, c, fn _ -> :consuming end)
  end

  action :consumer_done, params: [c: ^consumers] do
    require consumer_pc[c] == :consuming
    consumer_pc = update(consumer_pc, c, fn _ -> :ready end)
  end

  action :consumer_wait, params: [c: ^consumers] do
    require consumer_pc[c] == :ready
    require len(buffer) == 0
    consumer_pc = update(consumer_pc, c, fn _ -> :waiting end)
  end

  action :consumer_wake, params: [c: ^consumers] do
    require consumer_pc[c] == :waiting
    require len(buffer) > 0
    consumer_pc = update(consumer_pc, c, fn _ -> :ready end)
  end

  # ── Safety ──

  invariant :buffer_bounded do
    len(buffer) >= 0 and len(buffer) <= ^buffer_size
  end

  invariant :counts_consistent do
    consumed_count <= produced_count and
      produced_count - consumed_count == len(buffer)
  end

  invariant :no_over_consumption do
    consumed_count <= ^max_items
  end

  # Legitimate end state (`02-dsl-semantics.md` §5.3): everything produced and
  # consumed, producers idle, consumers parked. Without this the checker reports
  # a deadlock — and it would be right to, since the spec had not said this
  # state was intended. TLC does report one, which is what the corpus compares.
  terminal :all_items_consumed do
    produced_count == ^max_items and consumed_count == ^max_items and
      Enum.all?(^producers, fn p -> producer_pc[p] == :ready end) and
      Enum.all?(^consumers, fn c -> consumer_pc[c] == :waiting end)
  end

  # ── Liveness (Phase 2) ──

  temporal :producers_make_progress do
    always(eventually(produced_count > 0))
  end

  temporal :consumers_make_progress do
    (len(buffer) > 0) ~> (consumed_count > 0)
  end

  temporal :no_producer_starvation do
    Enum.all?(^producers, fn p ->
      (producer_pc[p] == :waiting) ~> (producer_pc[p] == :ready)
    end)
  end

  # The bound shows through here. Once `^max_items` have been produced the
  # buffer drains and every consumer parks in :waiting for good — correctly, in
  # the spec's own terms. A starvation-freedom property has to except that end
  # state, or it is refuted by the model bound rather than by the design.
  temporal :no_consumer_starvation do
    Enum.all?(^consumers, fn c ->
      (consumer_pc[c] == :waiting)
      ~> (consumer_pc[c] == :ready or produced_count == ^max_items)
    end)
  end

  fairness(:weak, [:produce, :consume, :producer_done, :consumer_done])
  fairness(:weak, producer_wake: [:p])
  fairness(:strong, consumer_wake: [:c])
end
