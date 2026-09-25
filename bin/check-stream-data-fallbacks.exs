# The `stream_data` fallbacks, executed (#89, #90).
#
# `TLA.PropertyTest` and `TLA.Invariant.Test` gate their generator functions behind
# `if Code.ensure_loaded?(StreamData)`, with an `else` branch that defines the same functions to
# raise a helpful ArgumentError rather than be undefined. That branch is compiled ONLY where
# `stream_data` is absent -- which is how the library builds as a dependency, and never how the
# suite runs. `consumer-compile` (#63) compiles it, so it is linted; until this script nothing
# CALLED it.
#
# Those messages are the whole consumer-facing experience of a missing optional dependency: the
# function name, the dep spec, the version. A typo in any of them would reach a consumer and
# nothing here would notice. Same defect class as #84 -- a failure path nothing executes.
#
# NO try/rescue (CLAUDE.md). Each call runs in a monitored process and the exception is read out
# of the DOWN reason. That is reading a crash, not handling one: nothing is swallowed, and a call
# that returns normally is a FAILURE here rather than a silent pass.
#
# Run under MIX_ENV=prod, by `consumer-compile`. Under MIX_ENV=test these branches do not exist
# and this script would assert against the wrong half.

defmodule Check do
  @timeout 5_000

  def raises!(label, fun) do
    {_pid, ref} = spawn_monitor(fun)

    receive do
      {:DOWN, ^ref, :process, _, {%ArgumentError{message: message}, _stack}} ->
        verify!(label, message)

      {:DOWN, ^ref, :process, _, :normal} ->
        die("#{label} RETURNED instead of raising — the fallback branch is missing or inert")

      {:DOWN, ^ref, :process, _, other} ->
        die("#{label} failed with #{inspect(other)}, expected an ArgumentError")
    after
      @timeout -> die("#{label} neither returned nor raised within #{@timeout}ms")
    end
  end

  # The message is the deliverable, so it is checked rather than merely its existence.
  defp verify!(label, message) do
    checks = [
      {"name itself", String.contains?(message, label)},
      {"name the dependency", String.contains?(message, "stream_data")},
      {"give the dep line",
       String.contains?(message, ~s({:stream_data, "~> 1.0", only: [:dev, :test]}))}
    ]

    case for({what, false} <- checks, do: what) do
      [] ->
        IO.puts("  ok  #{label}")

      missing ->
        die(
          "#{label} raised, but its message does not #{Enum.join(missing, ", nor ")}:\n    #{message}"
        )
    end
  end

  defp die(reason) do
    IO.puts(:stderr, "FAIL  #{reason}")
    System.halt(1)
  end
end

unless Code.ensure_loaded?(StreamData) do
  IO.puts("stream_data absent, as expected — executing the three fallbacks:")
else
  IO.puts(:stderr, "FAIL  stream_data IS loaded, so the fallback branches are not compiled.")
  IO.puts(:stderr, "      This script only means anything under MIX_ENV=prod.")
  System.halt(1)
end

Check.raises!("TLA.PropertyTest.init_states/2", fn -> TLA.PropertyTest.init_states(nil, nil) end)

Check.raises!("TLA.PropertyTest.action_sequences/3", fn ->
  TLA.PropertyTest.action_sequences(nil, nil)
end)

Check.raises!("TLA.Invariant.Test.valid_states/3", fn ->
  TLA.Invariant.Test.valid_states(nil, nil, nil)
end)

IO.puts("all three fallbacks raise, and say how to fix it")
