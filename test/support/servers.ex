defmodule ExTLA.TestServers do
  @moduledoc """
  GenServers used across the Layer 1 tests. They live here rather than inline so they
  compile once, and so a compile error in one is reported against a file.
  """

  defmodule Account do
    @moduledoc "Every Layer 1 declaration at once, on a deliberately breakable server."
    use GenServer
    use ExTLA.Invariant

    invariant :never_negative, desc: "an account may not go below zero" do
      state.balance >= 0
    end

    invariant :audited, desc: "every movement is logged", callbacks: [:handle_call] do
      length(state.log) == state.movements
    end

    action_property :no_free_money, desc: "money appears only through a deposit" do
      new.balance <= old.balance or new.deposits > old.deposits
    end

    precondition {:withdraw, amount}, desc: "a withdrawal is of a positive amount" do
      amount > 0
    end

    postcondition {:withdraw, amount}, desc: "a withdrawal moves the balance by its amount" do
      new.balance == old.balance - amount
    end

    # The same claim over a second message shape, so more than one postcondition is in
    # play and each is dispatched by its own pattern.
    postcondition {:withdraw_wrongly, amount},
      desc: "a withdrawal moves the balance by its amount" do
      new.balance == old.balance - amount
    end

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, [])

    @impl true
    def init(opts) do
      {:ok, %{balance: Keyword.get(opts, :balance, 0), deposits: 0, movements: 0, log: []}}
    end

    @impl true
    def handle_call({:deposit, amount}, _from, state) do
      state = %{
        state
        | balance: state.balance + amount,
          deposits: state.deposits + amount,
          movements: state.movements + 1,
          log: [{:deposit, amount} | state.log]
      }

      {:reply, state.balance, state}
    end

    def handle_call({:withdraw, amount}, _from, state) do
      state = %{
        state
        | balance: state.balance - amount,
          movements: state.movements + 1,
          log: [{:withdraw, amount} | state.log]
      }

      {:reply, state.balance, state}
    end

    # Breaks `no_free_money`: the balance rises with no deposit behind it.
    def handle_call(:conjure, _from, state) do
      {:reply, :ok,
       %{
         state
         | balance: state.balance + 100,
           movements: state.movements + 1,
           log: [:conjure | state.log]
       }}
    end

    # Breaks `audited`, and only under `handle_call` — which is where the invariant is
    # declared to apply.
    def handle_call(:forget_to_log, _from, state) do
      {:reply, :ok, %{state | movements: state.movements + 1}}
    end

    # Breaks the postcondition without breaking any invariant.
    def handle_call({:withdraw_wrongly, amount}, _from, state) do
      {:reply, :ok,
       %{
         state
         | balance: state.balance - amount - 1,
           movements: state.movements + 1,
           log: [{:withdraw, amount} | state.log]
       }}
    end

    @impl true
    def handle_cast(:skim, state) do
      # `audited` does not apply here, so an unlogged movement passes; `never_negative`
      # does apply, and a big enough skim breaks it.
      {:noreply, %{state | balance: state.balance - 1_000, movements: state.movements + 1}}
    end
  end

  defmodule Quiet do
    @moduledoc "A server with no declarations at all: the hook must emit no wrapper."
    use GenServer
    use ExTLA.Invariant

    def init(state), do: {:ok, state}
    def handle_call(:ping, _from, state), do: {:reply, :pong, state}
  end

  defmodule Refusing do
    @moduledoc """
    A server whose `init/1` may decline to start. `:ignore` and `{:stop, reason}` are
    refusals rather than first states, and an invariant checked against the absence of a
    state reports a violation of a predicate that was given nothing to be about.
    """
    use GenServer
    use ExTLA.Invariant

    invariant :has_balance, desc: "a started account has a balance" do
      is_integer(state.balance)
    end

    @impl true
    def init(:ignore), do: :ignore
    def init(:refuse), do: {:stop, :refused}
    def init(balance), do: {:ok, %{balance: balance}}
  end

  defmodule TrafficLight do
    @moduledoc """
    §03's state machine, as a raw `:gen_statem` in `:handle_event_function` mode.

    `GenStateMachine` is the same callback with a different name on the tin, and taking
    the dependency to test it would prove less: what is being tested is that a state
    machine's state is the `{state_name, data}` pair everywhere — in the invariant, in the
    action property, and in what `init/1` produces.
    """
    @behaviour :gen_statem
    use ExTLA.Invariant

    invariant :valid_state, desc: "one of three colours, and the count never goes backwards" do
      {name, data} = state
      name in [:red, :yellow, :green] and data.cycles >= 0
    end

    action_property :valid_transitions, desc: "green follows red, yellow green, red yellow" do
      {old_name, _} = old
      {new_name, _} = new

      case {old_name, new_name} do
        {:red, :green} -> true
        {:green, :yellow} -> true
        {:yellow, :red} -> true
        {same, same} -> true
        _ -> false
      end
    end

    precondition {:advance, steps}, desc: "the light advances one step at a time" do
      steps == 1
    end

    def start_link(cycles \\ 0), do: :gen_statem.start_link(__MODULE__, cycles, [])

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init(cycles), do: {:ok, :red, %{cycles: cycles}}

    @impl true
    def handle_event({:call, from}, {:advance, _steps}, name, data) do
      next = %{red: :green, green: :yellow, yellow: :red}[name]
      data = if next == :red, do: %{data | cycles: data.cycles + 1}, else: data
      {:next_state, next, data, [{:reply, from, next}]}
    end

    # Breaks `valid_transitions`: red to yellow is not a step this light takes.
    def handle_event({:call, from}, :jump, :red, data) do
      {:next_state, :yellow, data, [{:reply, from, :yellow}]}
    end

    # A stuttering step. `:keep_state_and_data` carries no state at all, so the extraction
    # has to rebuild the pair from the callback's own arguments.
    def handle_event({:call, from}, :wait, _name, _data) do
      {:keep_state_and_data, [{:reply, from, :waited}]}
    end

    # Breaks `valid_state` through the data half, and through a return that keeps the
    # state name: the pair the invariant sees is {unchanged name, new data}.
    def handle_event({:call, from}, :corrupt, _name, data) do
      {:keep_state, %{data | cycles: -1}, [{:reply, from, :corrupted}]}
    end
  end

  defmodule CounterRules do
    @moduledoc """
    Declarations and nothing else: the module an `Agent`'s checks name.

    An `Agent` has no callback module, so there is nothing here to wrap — which is also
    the test that `@before_compile` emits predicates for a module with no callbacks at
    all.
    """
    use ExTLA.Invariant

    invariant :never_negative, desc: "a counter may not go below zero" do
      state.count >= 0
    end

    invariant :ceiling_positive, desc: "a counter counts towards something" do
      state.ceiling > 0
    end

    action_property :ceiling_never_falls, desc: "the ceiling only ever rises" do
      new.ceiling >= old.ceiling
    end
  end
end
