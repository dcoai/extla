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

  @doc """
  Call `server` — a pid or a registered name — with `message`, reporting the outcome instead
  of raising it.

  The `:DOWN` is matched on the monitor reference alone. It used to be matched on `^server`
  as well, which is right for a pid and wrong for a name: a monitor on a registered name
  delivers its `:DOWN` with `{name, node}` in that position, never the bare atom, so neither
  clause matched, the message sat in the mailbox, and the call fell through to the timeout.
  `Replay.counterexample(…, server: :named)` then reported `:not_followed` after the full
  wait — a violation the server had raised, discarded, with delivery blamed (#207). The
  reference is unique to this call, so it is the whole of what needs matching.
  """
  def call(server, message, timeout \\ 5_000) do
    ref = Process.monitor(server)
    send(server, {:"$gen_call", {self(), ref}, message})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        {:ok, reply}

      {:DOWN, ^ref, :process, _server, {%Violation{} = violation, _stack}} ->
        {:violation, violation}

      {:DOWN, ^ref, :process, _server, reason} ->
        {:stopped, reason}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:timeout, timeout}
    end
  end
end
