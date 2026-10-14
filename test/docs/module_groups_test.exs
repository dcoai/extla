defmodule ExTLA.ModuleGroupsTest do
  @moduledoc """
  Every published module sits in a sidebar group, and the engine sits in Internals (#405, for
  #397).

  ## What was wrong

  HexDocs listed every module in one alphabetical run, so `ExTLA.Invariant.Runtime` — whose
  documentation opens "Not called directly" — sat between the modules a user does call, with
  nothing to tell a newcomer which was which.

  ## Why grouped and not hidden

  `@moduledoc false` would remove the engine from the docs, and also from the relation log's
  reach: surfex skips a hidden module entirely (surfex#219). Grouping keeps both, and an engine
  module stays readable for someone debugging it.

  ## What this holds

  `groups_for_modules` in `mix.exs` is a hand-kept list, so it is held to the modules that
  exist: a published module in no group fails here, which places a new module on purpose
  rather than leaving it in the ungrouped run.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp groups,
    do: Mix.Project.config() |> Keyword.fetch!(:docs) |> Keyword.fetch!(:groups_for_modules)

  defp grouped, do: groups() |> Keyword.values() |> List.flatten()

  # What the docs publish: a module compiled from `lib/` whose docs are not hidden. Mix tasks are
  # left out because ExDoc lists them in a section of their own.
  defp published do
    {:ok, modules} = :application.get_key(:extla, :modules)

    for module <- modules,
        source = to_string(module.module_info(:compile)[:source]),
        String.starts_with?(source, Path.join(@root, "lib") <> "/"),
        not String.starts_with?(inspect(module), "Mix.Tasks."),
        {:docs_v1, _, _, _, moduledoc, _, _} = Code.fetch_docs(module),
        moduledoc != :hidden,
        do: module
  end

  defp moduledoc(module) do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(module)
    doc
  end

  # `ExTLA` is the one module left ungrouped, on purpose: ExDoc lists ungrouped modules first,
  # so the overview heads the sidebar.
  test "every published module is in a group, except the overview" do
    ungrouped = published() -- [ExTLA | grouped()]

    assert ungrouped == [], """
    #{Enum.map_join(ungrouped, ", ", &inspect/1)} would be listed in no group.

    Add each to the group in mix.exs `groups_for_modules` that says what a user does with it,
    or to Internals if a user does not call it.
    """
  end

  test "and no module is in two, or named without existing" do
    assert grouped() -- Enum.uniq(grouped()) == []
    assert grouped() -- published() == []
    refute ExTLA in grouped()
  end

  test "a module that says it is not called directly is in Internals" do
    internals = Keyword.fetch!(groups(), :Internals)

    misplaced =
      for module <- published(),
          moduledoc(module) =~ "Not called directly",
          module not in internals,
          do: module

    assert misplaced == []
    # Anti-vacuity: the phrase is the one #397 found, and the two engines still carry it.
    assert ExTLA.Invariant.Runtime in internals
    assert moduledoc(ExTLA.Invariant.Runtime) =~ "Not called directly"
  end

  test "and the set of published modules is the real one" do
    assert length(published()) > 40
    assert ExTLA.Spec in published()
    refute ExTLA.Mix.TraceFile in published()
  end
end
