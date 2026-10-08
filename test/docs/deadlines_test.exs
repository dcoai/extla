defmodule ExTLA.DeadlinesTest do
  @moduledoc """
  A short deadline in a test says why (#362, #366).

  `cast_delivery_test.exs` waited 1 s for a server to die and report it, and on an
  oversubscribed host it missed: a crashing server writes its crash report before it exits,
  and under log pressure that takes two to three orders of magnitude longer than idle. The
  test was asserting an *event*, and an event has no business with a short deadline. A
  passing wait returns the moment the event arrives, so a long bound costs nothing and only a
  real hang ever waits it out.

  A short deadline is right in two cases: when the timeout **is** the outcome asserted (a
  silent server reports `{:timeout, ms}`), and in a `refute_receive`, which waits its whole
  window either way. Both stay short, and both are a decision a reviewer should see. So the
  same shape as #343's `# filter:` guard applies.

  ## What is checked

  - Every literal deadline under #{5_000} ms passed to `assert_receive/2`, `refute_receive/2` or
    `ExTLA.GenServer.Driver.deliver/3`, in any `test/**/*_test.exs`, has a `# deadline: <reason>`
    line in the comment block directly above its call.
  - `test/test_helper.exs` sets `assert_receive_timeout` to at least that much. ExUnit's own
    default is 100 ms, and every `assert_receive` without an explicit bound inherits it, so
    the default is part of the guarantee.
  - The count of short deadlines found is asserted, so a reader that stopped finding them
    would not pass quietly.

  Read from source, not from compiled modules: the comment is the point, and it is gone by
  compile time. Calls whose deadline is not a literal (`:timer.seconds(30)`) are not short by
  construction here and are not checked.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @threshold 5_000
  # How many short deadlines the tree holds now, each with its reason. A new one updates this,
  # which is the moment to write the reason.
  @expected_short 3

  describe "test/" do
    test "every short deadline says why" do
      found = for {path, source} <- sources(), d <- short_deadlines(source), do: {path, d}

      offenders =
        for {path, %{line: line, justified?: false} = d} <- found, do: "#{path}:#{line} #{d.call}"

      assert offenders == [], """
      #{length(offenders)} short deadline(s) with no `# deadline: <reason>` above them:

      #{Enum.map_join(offenders, "\n", &"  - #{&1}")}

      If the test asserts an event (a message, a death, a reply), drop the deadline or make it
      long: a passing wait returns at the event, and a short bound fails a correct test on a
      busy host. If the timeout is itself the outcome, or this is a refute, keep it and say so.
      """

      assert length(found) == @expected_short, """
      expected #{@expected_short} short deadlines in test/, found #{length(found)}:

      #{Enum.map_join(found, "\n", fn {path, d} -> "  - #{path}:#{d.line} #{d.call}" end)}
      """
    end

    test "assert_receive's default bound is long" do
      helper = File.read!(Path.join(@root, "test/test_helper.exs"))
      assert [_, value] = Regex.run(~r/assert_receive_timeout:\s*([0-9_]+)/, helper)
      assert value |> String.replace("_", "") |> String.to_integer() >= @threshold
    end
  end

  describe "the reader" do
    test "flags a short deadline with no reason, and accepts one with a reason" do
      source = """
      test "x" do
        assert_receive :done, 200
        # deadline: the absence is the point.
        refute_receive :late, 100
        # A comment block whose first line is the reason, and which goes on.
        # deadline: the timeout is the asserted outcome,
        # and this line continues it.
        assert {:timeout, 50} = Driver.deliver(pid, :m, 50)
        assert_receive :fine, 10_000
        assert_receive :default
      end
      """

      assert [
               %{line: 2, justified?: false},
               %{line: 4, justified?: true},
               %{line: 8, justified?: true}
             ] = short_deadlines(source)
    end
  end

  defp sources do
    for path <- Path.wildcard(Path.join(@root, "test/**/*_test.exs")) |> Enum.sort(),
        do: {Path.relative_to(path, @root), File.read!(path)}
  end

  @doc false
  def short_deadlines(source) do
    lines = String.split(source, "\n")

    {_, found} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn node, acc ->
        case deadline(node) do
          {call, ms, line} when ms < @threshold ->
            {node, [%{call: call, line: line, justified?: justified?(lines, line)} | acc]}

          _ ->
            {node, acc}
        end
      end)

    Enum.sort_by(found, & &1.line)
  end

  defp deadline({name, meta, [_pattern, ms]})
       when name in [:assert_receive, :refute_receive] and is_integer(ms),
       do: {"#{name}(…, #{ms})", ms, meta[:line]}

  defp deadline({{:., meta, [{:__aliases__, _, aliases}, :deliver]}, _, [_server, _delivery, ms]})
       when is_integer(ms) do
    if List.last(aliases) == :Driver, do: {"Driver.deliver(…, #{ms})", ms, meta[:line]}, else: nil
  end

  defp deadline(_node), do: nil

  # A `# deadline:` line anywhere in the contiguous comment block directly above `line`.
  defp justified?(lines, line) do
    lines
    |> Enum.take(line - 1)
    |> Enum.reverse()
    |> Enum.take_while(&String.match?(&1, ~r/^\s*#/))
    |> Enum.any?(&String.match?(&1, ~r/^\s*# deadline: \S/))
  end
end
