defmodule ExTLA.ExerciseTest do
  @moduledoc """
  `EXERCISE.md`'s rendering and its row set (#370).

  The coverage READ is not tested here: driving `:cover` from a test would start a VM-global
  cover server beside every concurrent test, which `async_isolation_test.exs`'s rule is about.
  It is exercised where it runs, by `mix extla.exercise --check` in the `test` job, against
  that job's own export. What is tested here is everything around it.
  """
  use ExUnit.Case, async: true

  alias ExTLA.Exercise

  @root Path.expand("../..", __DIR__)

  test "a measured module, an untested function and a never-loaded module each render" do
    entries = [
      %{module: ExTLA.Set, lines: 15, unhit: 0, never_called: []},
      %{module: ExTLA.Fingerprint, lines: 9, unhit: 1, never_called: ["of_encoding/1"]},
      %{module: ExTLA.Unloaded, lines: nil, unhit: nil, never_called: []}
    ]

    golden = Exercise.render(entries)

    assert golden =~
             "**3 modules · 24 lines** · unhit 1 · modules with an unhit line 1 · never loaded 1"

    assert golden =~ "| `ExTLA.Fingerprint` | 9 | 1 | `of_encoding/1` |"
    assert golden =~ "| `ExTLA.Set` | 15 | 0 | — |"
    assert golden =~ "| `ExTLA.Unloaded` | — | — | — |"
  end

  test "rendering ignores the order entries arrive in" do
    a = %{module: ExTLA.Set, lines: 15, unhit: 0, never_called: []}
    b = %{module: ExTLA.Fingerprint, lines: 9, unhit: 1, never_called: ["of_encoding/1"]}

    assert Exercise.render([a, b]) == Exercise.render([b, a])
  end

  test "compiler-generated functions and macros are not reported as never called" do
    for name <- [:__info__, :module_info, :__struct__, :"-run/2-fun-0-", :"MACRO-assert_spec"],
        do: assert(Exercise.generated?(name), "#{name} should be excluded")

    refute Exercise.generated?(:of_encoding)
  end

  # The row set is API_SURFACE.md's module list, so the two goldens cannot disagree about what
  # "shipped" means, and a reader that silently dropped modules would fail here.
  test "EXERCISE.md lists exactly API_SURFACE.md's modules" do
    surface =
      for [_, module] <-
            Regex.scan(
              ~r/^## (\S+) — \d+ items$/m,
              File.read!(Path.join(@root, "API_SURFACE.md"))
            ),
          do: module

    exercise =
      for [_, module] <-
            Regex.scan(~r/^\| `([A-Z][\w.]+)` \|/m, File.read!(Path.join(@root, "EXERCISE.md"))),
          do: module

    assert length(surface) > 50
    assert Enum.sort(exercise) == Enum.sort(surface)
  end
end
