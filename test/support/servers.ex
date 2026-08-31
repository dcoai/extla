defmodule TLA.TestServers do
  @moduledoc """
  GenServers used across the Layer 1 tests. They live here rather than inline so they
  compile once, and so a compile error in one is reported against a file.
  """

  defmodule Account do
    @moduledoc "Every Layer 1 declaration at once, on a deliberately breakable server."
    use GenServer
    use TLA.Invariant

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
    use TLA.Invariant

    def init(state), do: {:ok, state}
    def handle_call(:ping, _from, state), do: {:reply, :pong, state}
  end
end
