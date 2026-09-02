defmodule TLA.GenServer.Driver do
  @moduledoc """
  Sending a message to an instrumented server and getting the outcome as a value.

  A conformance violation raises inside the server, which reaches a caller as an exit —
  and `GenServer.call/3` re-raises it. `TLA.Replay` and `TLA.Simulation` both report what
  happened rather than propagate it, so they send the `:"$gen_call"` themselves, tagged
  with a monitor reference, and read the reply or the `:DOWN` out of the mailbox. Both
  outcomes are then ordinary messages.

  Not a public API: it exists so that the two callers share one definition of "the server
  answered, refused, or died of a conformance finding".
  """

  alias TLA.GenServer.Violation

  @type outcome ::
          {:ok, term()} | {:violation, Violation.t()} | {:stopped, term()} | {:timeout, timeout()}

  @doc "Call `server` with `message`, reporting the outcome instead of raising it."
  def call(server, message, timeout \\ 5_000) do
    ref = Process.monitor(server)
    send(server, {:"$gen_call", {self(), ref}, message})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        {:ok, reply}

      {:DOWN, ^ref, :process, ^server, {%Violation{} = violation, _stack}} ->
        {:violation, violation}

      {:DOWN, ^ref, :process, ^server, reason} ->
        {:stopped, reason}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:timeout, timeout}
    end
  end
end
