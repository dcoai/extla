defmodule ExTLA.NamespaceTest do
  @moduledoc """
  Every module ExTLA defines lives under `ExTLA` (D-40).

  A library uses its name as the prefix of all its modules, because the VM loads one module
  per name and two libraries defining the same one cannot be used together. Elixir's code
  anti-patterns call the alternative "namespace trespassing". ExTLA defined everything under
  `TLA` until #338: the most generic name a TLA+ library could take.

  Read from the compiled application rather than from source, so a module defined by a
  macro or nested in another counts like any other. Only `lib/` and `ledger/` are held to
  it: they are what ships and the project's own tooling. Test support modules follow the
  convention but are not a published surface.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # Mix tasks are the one exception the anti-pattern names: Mix owns `Mix.Tasks`, and a task
  # is found by living there.
  defp allowed?(name),
    do:
      name == "ExTLA" or String.starts_with?(name, "ExTLA.") or
        String.starts_with?(name, "Mix.Tasks.")

  defp project_modules do
    {:ok, modules} = :application.get_key(:extla, :modules)

    for module <- modules,
        source = module.module_info(:compile)[:source] |> to_string() |> Path.relative_to(@root),
        String.starts_with?(source, ["lib/", "ledger/"]),
        do: {inspect(module), source}
  end

  test "every module under lib/ and ledger/ is ExTLA, ExTLA.* or a Mix task" do
    outside =
      for {name, source} <- project_modules(), not allowed?(name), do: "#{name} (#{source})"

    assert outside == [], """
    #{length(outside)} module(s) outside the ExTLA namespace:

      #{Enum.join(outside, "\n  ")}

    Name it ExTLA.<Something> (D-40). A Mix task belongs under Mix.Tasks.
    """
  end

  # Anti-vacuity: the walk has to find the library, or an empty list passes the test above.
  test "and the walk finds the library itself, from both trees" do
    names = project_modules() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    sources = project_modules() |> Enum.map(&elem(&1, 1))

    assert "ExTLA" in names
    assert "ExTLA.ModelChecker" in names
    assert Enum.any?(sources, &String.starts_with?(&1, "ledger/"))
    assert Enum.any?(sources, &String.starts_with?(&1, "lib/mix/tasks/"))
  end
end
