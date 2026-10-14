defmodule ExTLA.GuideCheck.Output do
  @moduledoc """
  The output a guide shows is the output the tool prints (#409, for #398).

  ## What was wrong

  The guide harness checked each block's claim — the verdict, the state count, the depth — and
  never the block of output printed under it. The pages say everything on them is checked, so a
  reader trusted output that had drifted from the tool or never matched it: a lasso rendered the
  way it was rendered two releases ago, a coverage count one off, a footer the tool does not
  print, a trace without the banner every trace now opens with.

  ## How a block is compared

  The command the page quotes is run in this VM — the real `mix extla.*` task, so the block is
  held to exactly what a reader's terminal shows — and its output compared with the block line
  by line. Two things are normalised, and nothing else: a duration (`8ms`), which differs between
  any two runs, and trailing whitespace, which no reader can see.

  A block that shows only part of the output says so with `output=abridged` on its claim: its
  lines must then appear in the real output in the same order, with `…` lines standing for what
  was left out. An abridged block is still checked; it is only allowed to be shorter.

  ## Why the task runs in a process of its own

  A task reports its verdict by exiting, and prints through `Mix.shell/0`, which is global. The
  task runs in a child whose group leader is a `StringIO` and whose `$callers` names this
  process, so whichever shell is installed, `Mix.Shell.IO` writing to the group leader or
  `Mix.Shell.Process` sending to the caller, the output arrives here. Nothing global is written.
  """

  @doc """
  Run `mix TASK ARGS…` in this VM and return what it printed, and how it ended.
  """
  def task([name | args]) do
    module = Mix.Task.get!(name)
    parent = self()
    {:ok, device} = StringIO.open("")

    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:"$callers", [parent])
        Process.group_leader(self(), device)
        module.run(args)
      end)

    reason =
      receive do
        {:DOWN, ^ref, :process, ^pid, reason} -> reason
      after
        120_000 ->
          Process.exit(pid, :kill)
          :timeout
      end

    {_input, printed} = StringIO.contents(device)
    StringIO.close(device)

    printed <> drain_shell("") <> ending(reason)
  end

  # `Mix.Shell.Process` delivers each line as a message. `:info` is what a terminal shows on
  # stdout; `:error` goes to stderr, which `Mix.Shell.IO` does not route through the group leader
  # either, so leaving it out keeps the two shells agreeing.
  defp drain_shell(acc) do
    receive do
      {:mix_shell, :info, [line]} -> drain_shell(acc <> line <> "\n")
      {:mix_shell, _other, _lines} -> drain_shell(acc)
    after
      0 -> acc
    end
  end

  defp ending(:normal), do: ""
  defp ending({:shutdown, _code}), do: ""
  defp ending({%Mix.Error{message: message}, _stacktrace}), do: "** (Mix) #{message}\n"
  defp ending(:timeout), do: "** the task did not finish within 120s\n"
  defp ending(reason), do: "** " <> Exception.format_exit(reason) <> "\n"

  @doc """
  Compare a shown block with the real output: `:ok`, or `{:error, why}` naming the first line
  that differs and carrying the real output, so the block can be regenerated from the message.
  """
  def compare(shown, real, mode \\ :exact)

  def compare(shown, real, :exact) do
    shown = lines(shown)
    real = lines(real)

    if shown == real do
      :ok
    else
      {:error,
       "the output shown differs from what the tool prints" <>
         first_difference(shown, real) <> printed(real)}
    end
  end

  def compare(shown, real, :abridged) do
    wanted = shown |> lines() |> Enum.reject(&(&1 in ["…", "..."]))
    real = lines(real)

    case missing(wanted, real) do
      nil ->
        :ok

      line ->
        {:error,
         "the abridged output shows #{inspect(line)}, which the tool does not print at that " <>
           "point (an abridged block's lines must appear in the real output, in order)" <>
           printed(real)}
    end
  end

  @doc """
  The block's text as compared: durations and trailing whitespace normalised, and the blank
  lines at either end dropped.
  """
  def lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.trim_trailing() |> normalise_duration()))
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  defp normalise_duration(line), do: Regex.replace(~r/\b\d+ms\b/, line, "Nms")

  # The first wanted line that cannot be found after the previous one, or nil.
  defp missing([], _real), do: nil

  defp missing([line | rest], real) do
    case Enum.drop_while(real, &(&1 != line)) do
      [] -> line
      [_found | after_it] -> missing(rest, after_it)
    end
  end

  defp first_difference(shown, real) do
    index =
      Enum.zip(shown, real)
      |> Enum.find_index(fn {a, b} -> a != b end) || min(length(shown), length(real))

    "\n  at line #{index + 1} of the block:\n    shown: #{inspect(Enum.at(shown, index))}\n" <>
      "    real:  #{inspect(Enum.at(real, index))}"
  end

  defp printed(real), do: "\n  the tool prints:\n" <> Enum.map_join(real, "\n", &("    | " <> &1))
end
