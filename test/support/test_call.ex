defmodule ExTLA.TestCall do
  @moduledoc """
  A `GenServer.call/3` that reports a violated invariant as a value.

  A Layer 1 violation under `:enabled` raises inside the server, which reaches the caller
  as an exit — and `GenServer.call/3` re-raises it. Catching that would hide every other
  way the call can fail behind the one clause the test cares about, so this sends the
  `:"$gen_call"` message itself, tagged with a monitor reference, and reads the reply and
  the `:DOWN` from the mailbox. Both outcomes are then ordinary messages: a violation is
  matched, and any other exit reason falls through to a failure that says what it was.

  ## `:dead_on_arrival` is its own answer, and #129 is why

  `Process.monitor/1` on a pid that is **already dead** delivers `:DOWN` immediately with
  reason `:noproc`. That is not the same event as a server dying of the message this function
  sent — in the `:noproc` case the message was never handled, and quite possibly never
  delivered — but both used to come back as `{:exit, reason}`.

  Conflating them cost a full-suite run and a reading of `servers.ex` to diagnose. A test cast
  `:skim` at a server, which raises and kills it, and then called this function expecting to
  read the violation off the `:DOWN`. Whether that worked depended on whether the caller
  reached `Process.monitor/1` before the server finished dying, so the test passed in isolation
  and failed about one loaded full-suite run in five — and its failure, `{:exit, :noproc}`,
  named neither the race nor the dead server.

  So the two are separate return values now. `{:dead_on_arrival, :noproc}` means *this function
  did nothing*: whatever you are testing happened before it was called. If that is a surprise,
  the thing to fix is upstream — monitor before the message that kills the server, rather than
  racing it from here.
  """

  alias ExTLA.Invariant.Violation

  @doc """
  `{:ok, reply}`, or `{:violation, violation}` when the server died of one.

  `{:dead_on_arrival, :noproc}` when the process was already gone before the message was sent —
  the call never ran, so no outcome of it is being reported. Any other exit reason is returned
  as `{:exit, reason}` rather than swallowed.
  """
  @spec call(pid(), term(), timeout()) ::
          {:ok, term()}
          | {:violation, Violation.t()}
          | {:dead_on_arrival, :noproc}
          | {:exit, term()}
          | {:error, :timeout}
  def call(pid, message, timeout \\ 5_000) do
    ref = Process.monitor(pid)
    send(pid, {:"$gen_call", {self(), ref}, message})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        {:ok, reply}

      {:DOWN, ^ref, :process, ^pid, {%Violation{} = violation, _stacktrace}} ->
        {:violation, violation}

      # Only ever delivered for a pid that was dead when `Process.monitor/1` ran, so it says
      # something about the caller's sequencing rather than about this call.
      {:DOWN, ^ref, :process, ^pid, :noproc} ->
        {:dead_on_arrival, :noproc}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:exit, reason}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end
end
