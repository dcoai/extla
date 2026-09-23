# Generated from spec/07-examples.md Example 1 — do not edit.
#
# Regenerate with `mix tla.examples --write`; the `surface-drift` job fails on a
# difference. The specification is the page's fence: editing this file is editing a
# copy, which is the drift D-21 introduced and #280 closed.
defmodule TLA.Differential.DistributedLock do
  @moduledoc """
  `DistributedLock.tla`, in the ExTLA DSL — generated from `spec/07-examples.md` Example
  1, so "verbatim" holds by construction rather than by discipline.

  What this entry adds over the others is in `test/differential/README.md`. What it
  *specifies* is the page, and only the page.
  """
  use TLA.Spec

  constant :processes, default: MapSet.new([:p1, :p2])
  constant :resources, default: MapSet.new([:r1, :r2])

  variable :owner, type: [^resources ~> (^processes | :none)]
  variable :waiting, type: [^resources ~> set(^processes)]

  variable :pc,
    type: [^processes ~> (:idle | :requesting | {:holding, ^resources} | :releasing)]

  init do
    owner = for_each(^resources, fn _ -> :none end)
    waiting = for_each(^resources, fn _ -> set() end)
    pc = for_each(^processes, fn _ -> :idle end)
  end

  action :request_lock, params: [p: ^processes, r: ^resources] do
    require pc[p] == :idle

    waiting = update(waiting, r, &put(&1, p))
    pc = update(pc, p, fn _ -> :requesting end)
  end

  action :acquire_lock, params: [p: ^processes, r: ^resources] do
    require pc[p] == :requesting
    require owner[r] == :none
    require member?(waiting[r], p)

    owner = update(owner, r, fn _ -> p end)
    waiting = update(waiting, r, &delete(&1, p))
    pc = update(pc, p, fn _ -> {:holding, r} end)
  end

  action :release_lock, params: [p: ^processes, r: ^resources] do
    require pc[p] == {:holding, r}
    require owner[r] == p

    owner = update(owner, r, fn _ -> :none end)
    pc = update(pc, p, fn _ -> :releasing end)
  end

  action :return_to_idle, params: [p: ^processes] do
    require pc[p] == :releasing

    pc = update(pc, p, fn _ -> :idle end)
  end

  # ── Safety ──

  # Stated over `pc`, which is per PROCESS, so two processes can in principle
  # both be `{:holding, r}` — that is what gives this invariant content.
  invariant :mutual_exclusion,
    desc: "at most one process holds any given resource — THE lock property" do
    Enum.all?(^resources, fn r ->
      Enum.count(^processes, fn p -> pc[p] == {:holding, r} end) <= 1
    end)
  end

  invariant :owner_is_valid do
    Enum.all?(^resources, fn r ->
      owner[r] == :none or MapSet.member?(^processes, owner[r])
    end)
  end

  invariant :holding_means_owner do
    Enum.all?(^processes, fn p ->
      case pc[p] do
        {:holding, r} -> owner[r] == p
        _ -> true
      end
    end)
  end

  action_property :lock_not_stolen do
    Enum.all?(^resources, fn r ->
      old.owner[r] == new.owner[r] or
        old.owner[r] == :none or new.owner[r] == :none
    end)
  end

  # ── Liveness (Phase 2) ──

  temporal :no_starvation,
    desc: "every requesting process eventually acquires; needs SF per process" do
    Enum.all?(^processes, fn p ->
      (pc[p] == :requesting) ~> match?({:holding, _}, pc[p])
    end)
  end

  temporal :lock_eventually_released do
    Enum.all?(^processes, fn p ->
      match?({:holding, _}, pc[p]) ~> (pc[p] == :idle)
    end)
  end

  fairness(:strong, acquire_lock: [:p])
  fairness(:weak, release_lock: [:p], return_to_idle: [:p])
end
