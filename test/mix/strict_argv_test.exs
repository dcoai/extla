defmodule TLA.StrictArgvTest do
  @moduledoc """
  Every `mix tla.*` task refuses an unknown flag rather than dropping it (#166).

  Three of the eight used `OptionParser.parse/2` and discarded the invalid-options element,
  so a typo was accepted and the flag simply did not apply. Two of the three are CI gates:

      mix tla.coverage --check   exit 1 when the ledger has drifted
      mix tla.coverage --chek    exit 0, prints the ledger, checks nothing

  D-10 forbids exactly that — an advisory gate on a verification artifact — and this is how
  it arrives without anyone deciding it: through a typo in a pipeline file nobody re-reads.

  **This is an enumeration, not a list.** The tasks are discovered from the loaded modules,
  so a task added later is covered on the day it is added rather than on the day someone
  remembers to add it here. That distinction is the whole subject of #166: a hand-written
  set of things to check cannot report what is missing from it.
  """
  use ExUnit.Case, async: true

  # Discovered rather than written down. `Mix.Task.load_all/0` returns every task module the
  # project and its dependencies define; the `Tla.` prefix selects this project's.
  defp tla_tasks do
    Mix.Task.load_all()
    |> Enum.filter(&(&1 |> Module.split() |> Enum.take(3) == ~w(Mix Tasks Tla)))
    |> Enum.sort()
  end

  test "there are tasks to check, and the discovery still finds them" do
    tasks = tla_tasks()

    # Without this the test below iterates an empty list and passes having checked nothing —
    # which is the same defect it exists to prevent, one level up.
    assert length(tasks) >= 6, """
    Found only #{inspect(tasks)}.

    Either the tasks moved out of the `Mix.Tasks.Tla` namespace or this discovery is no
    longer finding them. Both are worth knowing: an empty list would make every assertion
    below vacuous.
    """
  end

  test "every task parses argv strictly" do
    lenient =
      for task <- tla_tasks(),
          source = task.module_info(:compile)[:source],
          source != nil,
          text = File.read!(to_string(source)),
          # `OptionParser.parse/2` returns a third element listing what it could not parse,
          # and every caller here discarded it. `parse!/2` raises instead.
          Regex.match?(~r/OptionParser\.parse\(/, text),
          do: task

    assert lenient == [], """
    These tasks parse argv leniently, so an unknown flag is silently dropped:

    #{Enum.map_join(lenient, "\n", &"  #{inspect(&1)}")}

    Use `OptionParser.parse!/2`. A task that accepts `--chek` and carries on is a task whose
    exit code says nothing about what it was asked to do — and two of these are CI gates.
    """
  end
end
