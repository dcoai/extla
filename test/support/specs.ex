defmodule TLA.TestSpecs do
  @moduledoc """
  Spec modules used across the DSL tests. They live here rather than inline in a
  test so that they compile once, with the rest of `test/support`, and so that a
  compile error in one is reported against a file rather than a heredoc.
  """

  defmodule Counter do
    @moduledoc "The smallest spec that exercises init, action, guard and invariant."
    use TLA.Spec

    constant :max

    variable :n, type: 0..^max
    variable :done, type: [false, true]

    init do
      n = 0
      done = false
    end

    action :increment do
      require n < ^max
      require not done
      n = n + 1
    end

    action :finish do
      require n == ^max
      require not done
      done = true
    end

    action :reset do
      require done
      n = 0
      done = false
    end

    invariant :within_bounds, desc: "the counter never leaves its declared range" do
      n >= 0 and n <= ^max
    end

    terminal :nothing_left do
      done and n == 0 and false
    end

    action_property :never_jumps do
      new.n - old.n <= 1
    end

    temporal :eventually_done do
      eventually(done)
    end

    fairness(:weak, [:increment, :finish])
  end

  defmodule Swap do
    @moduledoc "The §2 example: an action body is a conjunction, so this swaps."
    use TLA.Spec

    variable :x
    variable :y

    init do
      x = 1
      y = 2
    end

    action :swap do
      x = y
      y = x
    end
  end

  defmodule Transfer do
    @moduledoc "The worked example of 02-dsl-semantics.md §8, verbatim in shape."
    use TLA.Spec

    constant :accounts
    constant :max_balance

    variable :balances, type: [^accounts ~> 0..^max_balance]
    variable :status, type: [:idle, :transferring, :done, :error]
    variable :pending, type: :set
    variable :log, type: :seq

    init do
      balances = for_each(^accounts, fn _ -> ^max_balance end)
      status = :idle
      pending = set()
      log = seq()
    end

    action :begin_transfer,
      params: [from: ^accounts, to: ^accounts, amount: 1..^max_balance] do
      require from != to
      require status == :idle
      require balances[from] >= amount

      balances = update(balances, from, &(&1 - amount))
      pending = put(pending, {to, amount})
      status = :transferring
    end

    action :complete_transfer, params: [t: fn s -> s.pending end] do
      require status == :transferring

      let {to, amount} = t
      balances = update(balances, to, &(&1 + amount))
      pending = delete(pending, t)
      status = if size(delete(pending, t)) == 0, do: :done, else: :transferring
      log = append(log, %{to: to, amount: amount})
    end

    action :fail_transfer do
      require status == :transferring
      status = :error
      pending = set()
    end

    action :reset do
      require status in [:done, :error]
      status = :idle
    end

    invariant :conservation_of_money do
      let total = sum(values(balances)) + sum(pending, fn {_to, amt} -> amt end)
      total == ^max_balance * MapSet.size(^accounts)
    end

    action_property :no_phantom_credit do
      Enum.all?(^accounts, fn a ->
        new.balances[a] <= old.balances[a] or
          Enum.any?(old.pending, fn {to, _} -> to == a end)
      end)
    end

    temporal :no_stuck_pending do
      (status == :transferring) ~> (status in [:done, :error])
    end

    fairness(:weak, [:complete_transfer, :reset])
    fairness(:strong, [:fail_transfer])
  end

  defmodule PerBinding do
    @moduledoc "Per-binding fairness and a dependent param generator (§5.2, §3)."
    use TLA.Spec

    constant :processes

    variable :pc, type: [^processes ~> [:idle, :waiting, :holding]]
    variable :owner

    init do
      pc = for_each(^processes, fn _ -> :idle end)
      owner = nil
    end

    action :request, params: [p: ^processes] do
      require pc[p] == :idle
      pc = update(pc, p, fn _ -> :waiting end)
    end

    action :acquire, params: [p: ^processes] do
      require pc[p] == :waiting
      require owner == nil
      pc = update(pc, p, fn _ -> :holding end)
      owner = p
    end

    action :release, params: [p: ^processes] do
      require owner == p
      pc = update(pc, p, fn _ -> :idle end)
      owner = nil
    end

    invariant :one_holder do
      Enum.count(values(pc), &(&1 == :holding)) <= 1
    end

    temporal :no_starvation do
      Enum.all?(^processes, fn p ->
        (pc[p] == :waiting) ~> (pc[p] == :holding)
      end)
    end

    fairness(:strong, acquire: [:p])
    fairness(:weak, release: [:p], request: [:p])
  end
end
