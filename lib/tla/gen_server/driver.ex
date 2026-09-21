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
  Call `server` — any `GenServer.server()`: a pid, a registered name, `{name, node}`,
  `{:global, _}` or `{:via, _, _}` — with `message`, reporting the outcome instead of
  raising it.

  **Every shape is the pid path.** The server is resolved once with `GenServer.whereis/1`
  and the monitor and the send both take the pid; a name that resolves to nothing is
  `{:stopped, :noproc}` with nothing sent. Two defects lived in treating the shapes
  separately. The `:DOWN` was matched on `^server`, and a monitor on a registered name
  delivers `{name, node}` there, so a violation raised under a name sat unread until the
  timeout and `Replay` reported `:not_followed` (#207). Then `send/2` to a name whose process
  had just died raised `invalid destination`, where the same send to a dead pid is a no-op
  answered by the monitor's `:noproc` — one shape raising and the other reporting, for one
  situation (#254). Resolving first removes the second by construction; the reference-only
  `:DOWN` match below removes the first. A process that dies between the lookup and the send
  is the dead-pid case: a no-op send and a `:noproc` `:DOWN`.
  """
  def call(server, message, timeout \\ 5_000) do
    case GenServer.whereis(server) do
      nil -> {:stopped, :noproc}
      pid -> call_pid(pid, message, timeout)
    end
  end

  defp call_pid(pid, message, timeout) do
    ref = Process.monitor(pid)
    send(pid, {:"$gen_call", {self(), ref}, message})

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
