defmodule TLA.TestCall do
  @moduledoc """
  A `GenServer.call/3` that reports a violated invariant as a value.

  A Layer 1 violation under `:enabled` raises inside the server, which reaches the caller
  as an exit — and `GenServer.call/3` re-raises it. Catching that would hide every other
  way the call can fail behind the one clause the test cares about, so this sends the
  `:"$gen_call"` message itself, tagged with a monitor reference, and reads the reply and
  the `:DOWN` from the mailbox. Both outcomes are then ordinary messages: a violation is
  matched, and any other exit reason falls through to a failure that says what it was.
  """

  alias TLA.Invariant.Violation

  @doc """
  `{:ok, reply}`, or `{:violation, violation}` when the server died of one.

  Any other exit reason is returned as `{:exit, reason}` rather than swallowed.
  """
  @spec call(pid(), term(), timeout()) ::
          {:ok, term()} | {:violation, Violation.t()} | {:exit, term()} | {:error, :timeout}
  def call(pid, message, timeout \\ 5_000) do
    ref = Process.monitor(pid)
    send(pid, {:"$gen_call", {self(), ref}, message})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        {:ok, reply}

      {:DOWN, ^ref, :process, ^pid, {%Violation{} = violation, _stacktrace}} ->
        {:violation, violation}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:exit, reason}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end
end
