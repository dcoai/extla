defmodule ExTLA.InvariantBehavioursTest do
  use ExUnit.Case, async: true

  alias ExTLA.Invariant.{Agent, Runtime}
  alias ExTLA.TestServers.{CounterRules, Refusing, TrafficLight}

  defp call(pid, event) do
    ref = Process.monitor(pid)
    send(pid, {:"$gen_call", {self(), ref}, event})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        {:ok, reply}

      {:DOWN, ^ref, :process, ^pid, {%ExTLA.Invariant.Violation{} = violation, _stack}} ->
        {:violation, violation}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:exit, reason}
    after
      5_000 -> {:error, :timeout}
    end
  end

  defp light do
    {:ok, pid} = TrafficLight.start_link()
    Process.unlink(pid)
    pid
  end

  describe "a state machine's state is the {name, data} pair" do
    test "and a legal cycle keeps every declaration" do
      pid = light()

      assert {:ok, :green} = call(pid, {:advance, 1})
      assert {:ok, :yellow} = call(pid, {:advance, 1})
      assert {:ok, :red} = call(pid, {:advance, 1})
      assert {:ok, :waited} = call(pid, :wait)
    end

    test "an illegal transition is caught by the action property", _context do
      pid = light()

      assert {:violation, violation} = call(pid, :jump)
      assert violation.type == :action_property
      assert violation.name == :valid_transitions
      assert violation.old_state == {:red, %{cycles: 0}}
      assert violation.state == {:yellow, %{cycles: 0}}
    end

    # `{:keep_state, data}` names no state, so the pair the invariant sees is built from
    # the callback's own arguments and the data the return carried.
    test "a corrupt data half is caught even though the state name did not change" do
      pid = light()

      assert {:violation, violation} = call(pid, :corrupt)
      assert violation.name == :valid_state
      assert violation.state == {:red, %{cycles: -1}}
    end

    test "a precondition matches the event CONTENT, not {type, content}" do
      pid = light()

      assert {:violation, violation} = call(pid, {:advance, 3})
      assert violation.type == :precondition
      assert violation.args == {:advance, 3}
      assert Exception.message(violation) =~ "one step at a time"
    end

    test "init/1 is read as a state machine's, so the invariant sees the pair" do
      # A GenServer's `{:ok, state}` and a state machine's `{:ok, name, data}` are the
      # same shape as `{:ok, state, extra}`. Reading this one wrongly would check
      # `valid_state` against `:red` alone, and its `{name, data} = state` would raise.
      {:ok, pid} = TrafficLight.start_link(0)
      assert {:ok, :waited} = call(pid, :wait)
    end

    test "every :gen_statem return shape resolves to a pair" do
      pre = {:red, %{cycles: 1}}

      assert Runtime.extract_statem_state({:next_state, :green, %{cycles: 1}}, pre) ==
               {:green, %{cycles: 1}}

      assert Runtime.extract_statem_state({:next_state, :green, %{cycles: 1}, []}, pre) ==
               {:green, %{cycles: 1}}

      assert Runtime.extract_statem_state({:keep_state, %{cycles: 2}}, pre) ==
               {:red, %{cycles: 2}}

      assert Runtime.extract_statem_state({:keep_state, %{cycles: 2}, []}, pre) ==
               {:red, %{cycles: 2}}

      assert Runtime.extract_statem_state(:keep_state_and_data, pre) == pre
      assert Runtime.extract_statem_state({:keep_state_and_data, []}, pre) == pre

      assert Runtime.extract_statem_state({:repeat_state, %{cycles: 2}}, pre) ==
               {:red, %{cycles: 2}}

      assert Runtime.extract_statem_state(:repeat_state_and_data, pre) == pre

      # The shape that could not be a clause on `extract_state/2`: a GenServer's
      # `{:stop, reason, state}` carries the whole state, a state machine's carries data.
      assert Runtime.extract_statem_state({:stop, :normal, %{cycles: 3}}, pre) ==
               {:red, %{cycles: 3}}

      assert Runtime.extract_statem_state({:stop_and_reply, :normal, [], %{cycles: 3}}, pre) ==
               {:red, %{cycles: 3}}

      assert Runtime.extract_statem_state({:stop, :normal}, pre) == pre
    end
  end

  describe "init/1 that produces no state" do
    test ":ignore is a refusal to start, not a state to check" do
      assert GenServer.start_link(Refusing, :ignore) == :ignore
    end

    test "and so is {:stop, reason}" do
      Process.flag(:trap_exit, true)
      assert GenServer.start_link(Refusing, :refuse) == {:error, :refused}
    end

    test "while a state that IS produced is checked" do
      Process.flag(:trap_exit, true)
      assert {:ok, pid} = GenServer.start_link(Refusing, 100)
      assert :sys.get_state(pid) == %{balance: 100}

      assert {:error, {%ExTLA.Invariant.Violation{name: :has_balance}, _stack}} =
               GenServer.start_link(Refusing, :not_a_balance)
    end

    test "the tags, directly" do
      assert Runtime.initial_state({:ok, :state}) == {:ok, :state}
      assert Runtime.initial_state({:ok, :state, :hibernate}) == {:ok, :state}
      assert Runtime.initial_state(:ignore) == :none
      assert Runtime.initial_state({:stop, :nope}) == :none

      assert Runtime.initial_statem_state({:ok, :red, %{}}) == {:ok, {:red, %{}}}
      assert Runtime.initial_statem_state({:ok, :red, %{}, []}) == {:ok, {:red, %{}}}
      assert Runtime.initial_statem_state(:ignore) == :none
    end
  end

  describe "an Agent, whose transitions its callers pass in" do
    setup do
      {:ok, pid} = Agent.start_link(CounterRules, fn -> %{count: 0, ceiling: 10} end)
      Process.unlink(pid)
      %{agent: pid}
    end

    test "a legal update passes and returns what Agent.update/3 returns", %{agent: agent} do
      assert Agent.update(CounterRules, agent, &%{&1 | count: &1.count + 1}) == :ok
      assert Agent.get(CounterRules, agent, & &1.count) == 1
    end

    test "an update that breaks an invariant raises in the agent", %{agent: agent} do
      Process.flag(:trap_exit, true)

      assert {:violation, violation} =
               agent_update(agent, &%{&1 | count: &1.count - 5})

      assert violation.name == :never_negative
      assert violation.state == %{count: -5, ceiling: 10}
    end

    test "an action property is checked over the transition", %{agent: agent} do
      Process.flag(:trap_exit, true)

      assert {:violation, violation} = agent_update(agent, &%{&1 | ceiling: &1.ceiling - 1})
      assert violation.name == :ceiling_never_falls
      assert violation.old_state == %{count: 0, ceiling: 10}
    end

    # D-25 records that an `Agent`'s checks dispatch at runtime and that `:disabled` still
    # costs a call there — so `cast/3` is the path that decision is about, and it was held by
    # nothing: replacing its `check_agent_step!/3` with a plain `fun.(state)` left the suite
    # green (#175). A cast is asynchronous, so the violation arrives as the agent's exit,
    # which is also what makes the check invisible unless something watches for it.
    test "a cast that breaks an invariant kills the agent", %{agent: agent} do
      Process.flag(:trap_exit, true)
      ref = Process.monitor(agent)

      assert Agent.cast(CounterRules, agent, &%{&1 | count: &1.count - 5}) == :ok

      assert_receive {:DOWN, ^ref, :process, ^agent, reason}, 1_000

      violation = violation_of(reason)
      assert violation.name == :never_negative
      assert violation.state == %{count: -5, ceiling: 10}
    end

    test "and a legal cast leaves it running", %{agent: agent} do
      ref = Process.monitor(agent)

      assert Agent.cast(CounterRules, agent, &%{&1 | count: &1.count + 1}) == :ok

      refute_receive {:DOWN, ^ref, :process, ^agent, _reason}, 200
      assert Agent.get(CounterRules, agent, & &1.count) == 1
    end

    test "get_and_update checks the new state and returns the reply", %{agent: agent} do
      assert Agent.get_and_update(CounterRules, agent, fn state ->
               {state.count, %{state | count: state.count + 2}}
             end) == 0

      assert Agent.get(CounterRules, agent, & &1.count) == 2
    end

    test "a start_link with an illegal initial state fails to start" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ExTLA.Invariant.Violation{name: :never_negative}, _stack}} =
               Agent.start_link(CounterRules, fn -> %{count: -1, ceiling: 0} end)
    end

    # A read is a stuttering step: nothing moved, so no action property applies, but the
    # invariants must hold of the state that was read.
    test "get checks the invariants of the state it read", %{agent: agent} do
      Process.flag(:trap_exit, true)

      # Corrupt it behind the wrapper's back, the way a plain `Agent.update/2` would.
      :ok = Elixir.Agent.update(agent, fn state -> %{state | count: -1} end)

      assert catch_exit_reason(fn -> Agent.get(CounterRules, agent, & &1.count) end) ==
               :never_negative
    end
  end

  # `Agent.update/3` is a call, so a violation reaches the caller as an exit. The update
  # is made from a task whose own exit is observed, rather than by catching one.
  # A violation raised inside an agent reaches a watcher wrapped in one of two shapes,
  # depending on whether it came through a call or a cast.
  defp violation_of({:exited, {%ExTLA.Invariant.Violation{} = violation, _stack}, _}), do: violation
  defp violation_of({{%ExTLA.Invariant.Violation{} = violation, _stack}, _}), do: violation
  defp violation_of({%ExTLA.Invariant.Violation{} = violation, _stack}), do: violation
  defp violation_of(%ExTLA.Invariant.Violation{} = violation), do: violation

  defp agent_update(agent, fun) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {:updated, Agent.update(CounterRules, agent, fun)})
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:exited, {%ExTLA.Invariant.Violation{} = violation, _}, _}} ->
        {:violation, violation}

      {:DOWN, ^ref, :process, ^pid, {{%ExTLA.Invariant.Violation{} = violation, _}, _}} ->
        {:violation, violation}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:exit, reason}

      {:updated, result} ->
        {:ok, result}
    after
      5_000 -> {:error, :timeout}
    end
  end

  defp catch_exit_reason(fun) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {:ok, fun.()}) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {{%ExTLA.Invariant.Violation{name: name}, _}, _}} -> name
      {:DOWN, ^ref, :process, ^pid, reason} -> {:exit, reason}
      {:ok, value} -> {:returned, value}
    after
      5_000 -> {:error, :timeout}
    end
  end
end
