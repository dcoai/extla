defmodule TLA.InvariantTest do
  use ExUnit.Case, async: true

  alias TLA.Invariant.Runtime
  alias TLA.TestServers.{Account, Quiet}

  setup do
    {:ok, pid} = Account.start_link(balance: 100)
    Process.unlink(pid)
    %{account: pid}
  end

  defp call(pid, message), do: TLA.TestCall.call(pid, message)

  describe "a transition that holds" do
    test "returns what the callback returned, untouched", %{account: account} do
      assert {:ok, 150} = call(account, {:deposit, 50})
      assert {:ok, 120} = call(account, {:withdraw, 30})
    end
  end

  describe "invariants" do
    test "a violated one names itself, its description and the state", %{account: account} do
      assert {:violation, violation} = call(account, {:withdraw, 500})

      assert violation.type == :invariant
      assert violation.name == :never_negative
      assert violation.module == Account
      assert violation.state.balance == -400

      message = Exception.message(violation)
      assert message =~ "INVARIANT VIOLATED: never_negative"
      assert message =~ "an account may not go below zero"
      assert message =~ ~r/balance\s+= -400/
    end

    # `callbacks:` is resolved when the wrapper is generated, so this is not a filter that
    # runs and declines — there is no call to check `audited` in the `handle_cast` wrapper
    # at all.
    test "one restricted to a callback is not checked in the others", %{account: account} do
      # `:skim` leaves an unlogged movement, which `audited` would refuse — but `audited`
      # is declared `callbacks: [:handle_call]`.
      GenServer.cast(account, :skim)
      assert {:violation, violation} = call(account, {:deposit, 1})

      # It survived the cast; the invariant that does apply to a cast is what caught it.
      assert violation.name == :never_negative
    end

    test "and is checked in the callback it was restricted to", %{account: account} do
      assert {:violation, violation} = call(account, :forget_to_log)
      assert violation.name == :audited
    end
  end

  describe "action properties" do
    test "compare the two states, and print what changed", %{account: account} do
      assert {:violation, violation} = call(account, :conjure)

      assert violation.type == :action_property
      assert violation.name == :no_free_money
      assert violation.old_state.balance == 100
      assert violation.state.balance == 200

      message = Exception.message(violation)
      assert message =~ "ACTION_PROPERTY VIOLATED: no_free_money"
      assert message =~ "before:"
      assert message =~ "after:"
      assert message =~ "← changed"
    end
  end

  describe "preconditions and postconditions" do
    test "a precondition sees the message's own bindings", %{account: account} do
      assert {:violation, violation} = call(account, {:withdraw, -5})

      assert violation.type == :precondition
      assert violation.args == {:withdraw, -5}
      assert Exception.message(violation) =~ "a withdrawal is of a positive amount"
    end

    # A message the pattern does not match has nothing to say about it. That is a
    # different thing from a predicate that returned false, and only one of them is a
    # violation.
    test "a message no pattern matches passes without comment", %{account: account} do
      assert {:ok, 150} = call(account, {:deposit, 50})
    end

    test "a postcondition catches what no invariant would", %{account: account} do
      assert {:violation, violation} = call(account, {:withdraw_wrongly, 10})

      assert violation.type == :postcondition
      assert violation.state.balance == 89
      assert Exception.message(violation) =~ "moves the balance by its amount"
    end
  end

  describe "what the hook emits" do
    test "nothing for a module that declares nothing" do
      {:ok, pid} = GenServer.start_link(Quiet, %{})

      assert GenServer.call(pid, :ping) == :pong
      refute function_exported?(Quiet, :__tla_invariant__, 2)
    end

    # `use GenServer` injects defaults for three callbacks before the hook is installed.
    # Wrapping them would be checking a transition nobody wrote, and `super` on one is
    # deprecated besides.
    test "no wrapper on the callbacks `use GenServer` injected" do
      refute function_exported?(Account, :handle_continue, 2)
    end

    test "the mode is baked in where the module compiled" do
      assert Account.__tla_mode__() == :enabled
    end
  end

  describe "extract_state/2" do
    test "reads the post-state out of every callback return that carries one" do
      assert Runtime.extract_state({:reply, :ok, :new}, :old) == :new
      assert Runtime.extract_state({:reply, :ok, :new, :hibernate}, :old) == :new
      assert Runtime.extract_state({:noreply, :new}, :old) == :new
      assert Runtime.extract_state({:noreply, :new, {:continue, :x}}, :old) == :new
      assert Runtime.extract_state({:stop, :normal, :new}, :old) == :new
      assert Runtime.extract_state({:stop, :normal, :reply, :new}, :old) == :new
      assert Runtime.extract_state({:ok, :new}, :old) == :new
      assert Runtime.extract_state({:ok, :new, :hibernate}, :old) == :new
    end

    # Not every return carries a state. Treating those as stuttering is right — nothing
    # moved — and it keeps the wrapper from having to know which callback it is in.
    test "falls back to the pre-state for a return that carries none" do
      assert Runtime.extract_state({:stop, :normal}, :old) == :old
      assert Runtime.extract_state(:ignore, :old) == :old
      assert Runtime.extract_state({:error, :nope}, :old) == :old
    end
  end
end
