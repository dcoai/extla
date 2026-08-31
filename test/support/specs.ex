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

    # `:nat`, not `0..^max_balance`: every account starts at ^max_balance, so a
    # transfer pushes the recipient above it. Conservation is what bounds the
    # total, and that is an invariant rather than a type.
    variable :balances, type: [^accounts ~> :nat]
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

  defmodule WeaklyFair do
    @moduledoc """
    `PerBinding` with acquiring only WEAKLY fair, which is what §5.2 says is not
    enough: a competitor takes the lock and gives it back, so `acquire(p)` is
    enabled infinitely often and continuously enabled never, and weak fairness
    lets p wait forever.
    """
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

    temporal :no_starvation do
      Enum.all?(^processes, fn p ->
        (pc[p] == :waiting) ~> (pc[p] == :holding)
      end)
    end

    fairness(:weak, acquire: [:p])
    fairness(:weak, release: [:p], request: [:p])
  end

  defmodule Idling do
    @moduledoc """
    A cycle that only fairness rules out (§5.2): `spin` flips a bit forever while
    `advance` sits enabled beside it, so WF(advance) is what makes `eventually_two`
    hold. `IdlingUnfair` is the same spec with the declaration removed.
    """
    use TLA.Spec

    variable :n, type: 0..2
    variable :spinning, type: [false, true]

    init do
      n = 0
      spinning = false
    end

    action :spin do
      require n == 0
      spinning = not spinning
    end

    action :advance do
      require n < 2
      n = n + 1
    end

    temporal :eventually_two do
      eventually(n == 2)
    end

    temporal :never_two do
      always(n < 2)
    end

    terminal :arrived do
      n == 2
    end

    fairness(:weak, [:advance])
  end

  defmodule IdlingUnfair do
    @moduledoc "`Idling` with no fairness at all, so spinning forever is a behaviour."
    use TLA.Spec

    variable :n, type: 0..2
    variable :spinning, type: [false, true]

    init do
      n = 0
      spinning = false
    end

    action :spin do
      require n == 0
      spinning = not spinning
    end

    action :advance do
      require n < 2
      n = n + 1
    end

    temporal :eventually_two do
      eventually(n == 2)
    end

    terminal :arrived do
      n == 2
    end
  end

  defmodule Stalls do
    @moduledoc """
    A spec that ends (§5.3) before its temporal property is satisfied. Stuttering
    there forever is a legal behaviour, so `eventually_done` is refuted by the end
    state itself — the shape that refutes `raft_election`.
    """
    use TLA.Spec

    variable :phase, type: [:start, :stuck, :done]

    init do
      phase = :start
    end

    action :give_up do
      require phase == :start
      phase = :stuck
    end

    temporal :eventually_done do
      eventually(phase == :done)
    end

    terminal :gave_up do
      phase == :stuck
    end

    fairness(:weak, [:give_up])
  end

  defmodule Terminating do
    @moduledoc "A spec that ends on purpose (§5.3): the end state is declared."
    use TLA.Spec

    constant :max

    variable :produced, type: 0..^max

    init do
      produced = 0
    end

    action :produce do
      require produced < ^max
      produced = produced + 1
    end

    terminal :all_produced do
      produced == ^max
    end
  end

  defmodule Deadlocking do
    @moduledoc "The same shape with no `terminal`, so the end state is a deadlock."
    use TLA.Spec

    constant :max

    variable :produced, type: 0..^max

    init do
      produced = 0
    end

    action :produce do
      require produced < ^max
      produced = produced + 1
    end
  end

  defmodule Unbounded do
    @moduledoc "An unbounded counter, for state constraints and max_states."
    use TLA.Spec

    variable :n

    init do
      n = 0
    end

    action :tick do
      n = n + 1
    end
  end

  defmodule Broken do
    @moduledoc "An invariant that a reachable state refutes, and at a known depth."
    use TLA.Spec

    variable :n

    init do
      n = 0
    end

    action :tick do
      require n < 5
      n = n + 1
    end

    invariant :below_three do
      n < 3
    end

    action_property :never_decreases do
      new.n >= old.n
    end
  end

  defmodule WithDefaults do
    @moduledoc "Carries its own constant assignment, so `mix tla.check` can run it."
    use TLA.Spec

    constant :max, default: 3

    variable :n, type: 0..^max

    init do
      n = 0
    end

    action :tick do
      require n < ^max
      n = n + 1
    end

    # Never enabled: the guard cannot hold. This is the routine failure the
    # coverage report exists to find, and what --strict-coverage fails on.
    action :impossible do
      require n == 99
      n = 0
    end

    terminal :done do
      n == ^max
    end
  end

  defmodule OutsideDomain do
    @moduledoc """
    A guard that reads a function outside its domain — D-20's failure, as a spec.

    `:carol` is not an account. Under `Access.get/2` this guard was `nil >= 1`,
    which is `true` under Erlang term order, so the action fired from a state it
    was never enabled in and the checker explored a state space this spec does
    not describe.
    """
    use TLA.Spec

    constant :accounts, default: MapSet.new([:alice, :bob])

    variable :balances, type: [^accounts ~> :nat]

    init do
      balances = for_each(^accounts, fn _ -> 1 end)
    end

    action :pay_carol do
      require balances[:carol] >= 1

      balances = update(balances, :alice, &(&1 - 1))
    end
  end

  defmodule LetScopes do
    @moduledoc """
    A `let` that only the guard reads, and one that only an assignment reads.

    Each compiled function keeps the bindings it reads and drops the others: the
    block is pure, so a binding nothing reads is dead code — and emitting it
    anyway would cost the spec author an unused-variable warning they cannot
    silence.
    """
    use TLA.Spec

    variable :n, type: 0..3
    variable :log, type: :seq

    init do
      n = 0
      log = seq()
    end

    action :bump do
      let room = 3 - n
      require room > 0
      let entry = %{was: n}

      n = n + 1
      log = append(log, entry)
    end
  end
end
