defmodule TLA.Conformance.TraceBufferTest do
  @moduledoc """
  The trace buffer's bound, through the GenServer wrapper (#285).

  ## Why this is its own file, and `async: false`

  `trace_buffer` is application config, and `TLA.GenServer.Runtime.record_transition!/4`
  reads it **in whatever process is recording**. Setting it to 3 to watch the buffer drop
  states therefore sets it to 3 for every test running beside this one that records a
  transition — and this test lived in `test/conformance/step_test.exs`, which is
  `async: true`.

  Before #278 the damage was silent: a neighbour's trace was truncated, its temporal
  verdicts became `:inconclusive`, and `step_test`'s own neighbour asserts
  `verdict in [:holds, :inconclusive]`, which is exactly what a corrupted run still
  satisfies. A passing result that means nothing was checked, arriving through the config
  of a test three files away.

  `TLA.InvariantModesTest` and `TLA.TelemetryVerboseTest` make the same choice for `mode:`
  and `telemetry:` and say so in the same words. This file is the third, and
  `test/docs/async_isolation_test.exs` now fails a fourth that forgets.

  ## What it covers that `truncated_behaviour_test.exs` does not

  That file (#278) drives 1,201 transitions past the *shipped* default and asserts the
  buffer reports what it dropped — at the `TLA.GenServer.Runtime` level, calling
  `record_transition!/4` directly. This one is the same bound reached through the
  **instrumented callback**: a real server, real `handle_call`s, the wrapper doing the
  recording. Which is why it is moved rather than deleted.
  """
  use ExUnit.Case, async: false

  alias TLA.Conformance.Counter.Impl
  alias TLA.GenServer.Runtime

  defp call(pid, message) do
    ref = Process.monitor(pid)
    send(pid, {:"$gen_call", {self(), ref}, message})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        {:ok, reply}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:exit, reason}
    after
      5_000 -> {:error, :timeout}
    end
  end

  setup do
    previous = Application.get_env(:extla, :trace_buffer)
    Application.put_env(:extla, :trace_buffer, 3)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:extla, :trace_buffer, previous),
        else: Application.delete_env(:extla, :trace_buffer)
    end)

    {:ok, pid} = Impl.Conforming.start_link()
    Process.unlink(pid)

    %{server: pid}
  end

  describe "the trace is bounded" do
    test "and drops oldest-first rather than growing without limit", %{server: server} do
      for _ <- 1..4 do
        assert {:ok, :ok} = call(server, :increment)
        assert {:ok, :ok} = call(server, :done)
      end

      trace = Runtime.get_trace(server)
      assert length(trace.states) == 3
      assert List.last(trace.states) == %{count: 4, status: :ready}

      # And it says how many it dropped to stay at three, which is what makes a verdict
      # about the behaviour's first state refusable rather than wrong (#278). Ten states
      # were recorded — the initial one, then a pre and a post for the first transition and
      # a post for each of the seven after it — and three are kept.
      assert trace.dropped == 7
      assert length(trace.states) + trace.dropped == 10
    end
  end
end
