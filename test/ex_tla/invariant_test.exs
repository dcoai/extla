defmodule ExTLA.InvariantTest do
  use ExUnit.Case, async: true

  alias ExTLA.Invariant.{Runtime, Violation}
  alias ExTLA.TestServers.{Account, Quiet}

  setup do
    {:ok, pid} = Account.start_link(balance: 100)
    Process.unlink(pid)
    %{account: pid}
  end

  defp call(pid, message), do: ExTLA.TestCall.call(pid, message)

  # How long to wait for a server to die of a violation, matching `ExTLA.TestCall.call/3`'s own
  # timeout — the two wait for the same event and should not disagree about how long it can take.
  #
  # `assert_receive`'s default is 100 ms, and that is too tight here (#145). Under
  # `max_cases: 32` the server has to be scheduled, run the callback, raise, and have `:DOWN`
  # delivered, and on a loaded run that does not always fit — which showed up as an empty mailbox
  # in one of three seeded full-suite runs.
  #
  # This is not a `sleep` and not a race being papered over. #140 removed the race; what is left
  # is a deadline, and a deadline set generously costs the passing case nothing because the
  # assertion returns as soon as the message lands.
  @down 5_000

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

      # And it is the RENDERER's output, not `inspect/1`'s (#175). A `defexception` with no
      # working `message/1` falls back to inspecting the struct, which embeds `message:` and
      # `state:` — so every substring above passes on a violation whose formatting is gone.
      # The banner rule is produced by nothing else.
      assert String.starts_with?(message, "═══ INVARIANT VIOLATED")
      refute message =~ "%ExTLA.Invariant.Violation{"
    end

    # `callbacks:` is resolved when the wrapper is generated, so this is not a filter that
    # runs and declines — there is no call to check `audited` in the `handle_cast` wrapper
    # at all.
    test "one restricted to a callback is not checked in the others", %{account: account} do
      # `:skim` leaves an unlogged movement AND takes the balance to -900, so both invariants
      # have something to say about the post-state. Only one of them is asked: `audited` is
      # declared `callbacks: [:handle_call]`, so the `handle_cast` wrapper contains no call to
      # it. That the reported violation is `never_negative` is the whole assertion.
      #
      # Monitored BEFORE the cast, and the verdict read from the exit reason. The violation
      # raises inside the server (`Violation.report!/2` under `:enabled`), so the cast is fatal
      # and there is nothing to send a second message to — an earlier version of this test sent
      # a `{:deposit, 1}` call and read the violation off the resulting `:DOWN`, which raced the
      # server's death and failed as `{:exit, :noproc}` roughly one full-suite run in five (#129).
      ref = Process.monitor(account)
      GenServer.cast(account, :skim)

      assert_receive {:DOWN, ^ref, :process, ^account, {%Violation{} = violation, _stacktrace}},
                     @down

      assert violation.name == :never_negative

      # From `:skim` alone: 100 - 1_000. The number is load-bearing — it is what distinguishes
      # "the cast's own violation" from "a violation some later callback found", which is the
      # reading the old comment here got wrong.
      assert violation.state.balance == -900
    end

    test "calling a server that is already gone says so, rather than reporting an exit" do
      # The distinction #129 turned on. `{:exit, :noproc}` reads as "the call failed"; it in
      # fact means the call never happened, and a test that gets it has raced something.
      {:ok, pid} = Account.start_link(balance: 100)
      Process.unlink(pid)
      ref = Process.monitor(pid)
      GenServer.cast(pid, :skim)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @down

      assert {:dead_on_arrival, :noproc} = call(pid, {:deposit, 1})
    end

    test "a violation in a cast is fatal, because there is no reply channel to report it on" do
      # Stated directly rather than inferred from a later call's failure. `:enabled` raises
      # (`spec/03-layer1-invariants.md` §Modes), and a raise in `handle_cast/2` terminates the
      # server — the same outcome as in a call, where the caller additionally gets the exit.
      {:ok, pid} = Account.start_link(balance: 100)
      Process.unlink(pid)
      ref = Process.monitor(pid)

      GenServer.cast(pid, :skim)

      assert_receive {:DOWN, ^ref, :process, ^pid, {%Violation{}, _stacktrace}}, @down
      refute Process.alive?(pid)
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
      assert String.starts_with?(message, "═══ ACTION_PROPERTY VIOLATED")
      refute message =~ "%ExTLA.Invariant.Violation{"
    end
  end

  describe "preconditions and postconditions" do
    test "a precondition sees the message's own bindings", %{account: account} do
      assert {:violation, violation} = call(account, {:withdraw, -5})

      assert violation.type == :precondition
      assert violation.args == {:withdraw, -5}
      message = Exception.message(violation)
      assert message =~ "a withdrawal is of a positive amount"
      assert String.starts_with?(message, "═══ PRECONDITION VIOLATED")
      refute message =~ "%ExTLA.Invariant.Violation{"
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
