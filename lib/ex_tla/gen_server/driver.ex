defmodule ExTLA.GenServer.Driver do
  @moduledoc """
  Sending a message to an instrumented server and getting the outcome as a value.

  A conformance violation raises inside the server, which reaches a caller as an exit —
  and `GenServer.call/3` re-raises it. `ExTLA.Replay` and `ExTLA.Simulation` both report what
  happened rather than propagate it, so they send the `:"$gen_call"` themselves, tagged
  with a monitor reference, and read the reply or the `:DOWN` out of the mailbox. Both
  outcomes are then ordinary messages.

  Not a public API: it exists so that the two callers share one definition of "the server
  answered, refused, or died of a conformance finding".
  """

  alias ExTLA.GenServer.Violation

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
  def call(server, message, timeout \\ 5_000), do: deliver(server, {:call, message}, timeout)

  @doc """
  Deliver whatever `c:TLA.Refinement.concrete_message/2` returned, by the route it names.

      {:call, msg}   {:"$gen_call", from, msg}   handle_call/3
      {:cast, msg}   {:"$gen_cast", msg}         handle_cast/2
      {:info, msg}   msg                         handle_info/2
      msg            a call

  D-36 has the reasoning. The short of it: a term is a message and a message does not carry
  how it arrives, so the mapping has to say — and a bare term keeps meaning a call, so no
  mapping written before this changes. `05-layer3-conformance.md`'s own canonical refinement
  maps two actions to `handle_cast/2` clauses, and until this existed they were delivered as
  calls, reached a `handle_call/3` with no matching clause, and replay reported
  `:not_followed` about a server that was correct (#172).

  ## When a cast is done

  A call hands back "answered, refused, or died" as a value. A cast has no reply, and a
  driver that moved on before it was handled would compare the next action against a stale
  state — the defect class of #168, which must not come back through the fix for a different
  one.

  The completion signal is a **`:get_state` system message sent straight after**. It goes
  through the same mailbox, so it is ordered behind the cast: when its reply arrives, the
  cast has been handled. Measured rather than assumed — a cast incrementing a counter,
  followed by this, replies `{:ok, %{n: 1}}`.

  It is sent raw rather than through `:sys.get_state/2` because that function **exits** the
  caller on a timeout or a dead server, and turning an exit back into a value needs a
  `try/rescue`. This whole module exists to avoid exactly that: it sends the `$gen_call` by
  hand and reads the monitor, so all four outcomes are ordinary messages. The cast path is
  the same shape, which is why it costs one `receive` and no extra process.

  No extra round-trip in either caller: `ExTLA.Replay` and `ExTLA.Simulation` each already read
  the server's state once per step, to map the post-state through `abstract/1`.
  """
  def deliver(server, delivery, timeout \\ 5_000) do
    case GenServer.whereis(server) do
      nil -> {:stopped, :noproc}
      pid -> deliver_pid(pid, route(delivery), timeout)
    end
  end

  defp route({:call, message}), do: {:call, message}
  defp route({:cast, message}), do: {:cast, message}
  defp route({:info, message}), do: {:info, message}
  defp route(message), do: {:call, message}

  defp deliver_pid(pid, {:call, message}, timeout) do
    ref = Process.monitor(pid)
    send(pid, {:"$gen_call", {self(), ref}, message})
    await(ref, timeout, fn reply -> {:ok, reply} end)
  end

  defp deliver_pid(pid, {kind, message}, timeout) do
    ref = Process.monitor(pid)
    send(pid, envelope(kind, message))
    send(pid, {:system, {self(), ref}, :get_state})

    # `:no_reply` and not the state: what came back is the CONCRETE state, and this module
    # does not hold the refinement mapping that would make it an abstract one. Both callers
    # read the state themselves on the next line anyway. The value here is the completion,
    # not the contents.
    await(ref, timeout, fn {:ok, _state} -> {:ok, :no_reply} end)
  end

  defp envelope(:cast, message), do: {:"$gen_cast", message}
  defp envelope(:info, message), do: message

  # One `receive` for both routes, because the three failure outcomes are identical: a
  # conformance violation raised in `handle_cast/2` kills the server and arrives as the same
  # `:DOWN` a call's would, and a cast that never completes is a `{:timeout, ms}` — a named
  # finding, never a silent "followed".
  defp await(ref, timeout, on_reply) do
    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        on_reply.(reply)

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
