defmodule ExTLA.Exercise do
  @moduledoc """
  What `mix test` exercises in each shipped module, from its coverage export (#323, #370).

  Nothing in the project could answer "is this code exercised?". `mix extla.mutants` answers
  the stronger question, whether anything *asserts* on it, but over 13 hand-written mutants in
  5 files. #323 found four lines that never ran, each by a person reading code: a task whose
  `run/1` could be replaced by a `raise` with the suite still green, two statuses never
  produced, a detail clause reached by nothing. A line counter would have named all four.

  This is that counter, as a golden rather than a threshold. A percentage is a number nobody
  reads, and it can be met by testing anything. A row per module puts *which* module moved in
  the diff.

  ## A row

  One per module in `API_SURFACE.md`'s list, the shipped modules, so the row count is held to
  that golden's. `Lines` is the lines `:cover` counts as executable, and `Unhit` those the
  suite never reached. `Never called` names each function the suite never entered, which is
  the stablest signal: it changes when coverage changes, not when an edit above it moves line
  numbers. Compiler-generated functions (`__info__/1`, `module_info/0,1`, anonymous-function
  bodies) are left out, and so are macros, which run when their caller compiles and so are
  never seen entering by a run-time export.

  ## Determinism

  The golden is drift-gated, so it must not move between two runs of the same code. Two full
  runs on 2026-10-09 left the same 588 lines unhit, the same lines in all 152 modules. Only
  hit-or-not is used, never a count, which async scheduling could change.
  """

  # `:cover` is OTP's `:tools` application, loaded at run time by `Mix.ensure_application!/1`
  # below. Not a dependency of the shipped library, so the compiler cannot see it.
  @compile {:no_warn_undefined, :cover}

  @generated ~w(__info__ __struct__ __impl__ module_info)a

  @doc "One entry per shipped module, from the coverage export at `coverdata`."
  def run(coverdata, modules) do
    Mix.ensure_application!(:tools)
    :cover.stop()
    {:ok, _pid} = :cover.start()
    :ok = :cover.import(String.to_charlist(coverdata))
    imported = MapSet.new(:cover.imported_modules())

    entries = Enum.map(modules, &entry(&1, MapSet.member?(imported, &1)))
    :cover.stop()
    entries
  end

  defp entry(module, false), do: %{module: module, lines: nil, unhit: nil, never_called: []}

  defp entry(module, true) do
    {:ok, lines} = :cover.analyse(module, :calls, :line)
    # Per-function LINE coverage, not `:calls`: a call count is not recorded for a function
    # whose body opens with `receive`, so `:calls` named `GenServer.Driver.await/3` as never
    # called while every line of it ran. A function was entered if any of its lines ran.
    {:ok, functions} = :cover.analyse(module, :coverage, :function)

    executable = for {{^module, line}, calls} <- lines, line > 0, do: calls

    never_called =
      for {{^module, name, arity}, {0, uncovered}} <- functions,
          uncovered > 0,
          not generated?(name),
          do: "#{name}/#{arity}"

    %{
      module: module,
      lines: length(executable),
      unhit: Enum.count(executable, &(&1 == 0)),
      never_called: Enum.sort(never_called)
    }
  end

  @doc false
  def generated?(name) when name in @generated, do: true
  # `-…` are anonymous-function bodies. `MACRO-…` is a macro, which runs when its caller
  # COMPILES, so a run-time coverage export never sees it enter and would name every macro.
  def generated?(name), do: String.starts_with?(Atom.to_string(name), ["-", "MACRO-"])

  @doc "The golden spec."
  def golden_spec(entries) do
    measured = Enum.reject(entries, &is_nil(&1.lines))
    lines = measured |> Enum.map(& &1.lines) |> Enum.sum()
    unhit = measured |> Enum.map(& &1.unhit) |> Enum.sum()

    %{
      name: "EXERCISE.md",
      purpose:
        "What mix test exercises in each shipped module: executable lines, the ones never " <>
          "reached, and the functions never entered (#323).",
      task: "extla.exercise",
      gate: "test",
      hardness: :hard,
      prose: prose(),
      stats: [
        Surfex.Golden.stat(
          "#{length(entries)} modules · #{lines} lines",
          [
            {"unhit", unhit},
            {"modules with an unhit line", Enum.count(measured, &(&1.unhit > 0))},
            {"never loaded", length(entries) - length(measured)}
          ]
        )
      ],
      columns: ["Module", "Lines", "Unhit", "Never called"],
      rows: Enum.map(entries, &row/1)
    }
  end

  defp prose do
    """
    Generated from `mix test --cover --export-coverage test`, run in the `test` job. A row is
    one shipped module (`API_SURFACE.md`'s list). `Unhit` counts executable lines the suite
    never reached; `Never called` names the functions it never entered, compiler-generated
    ones excluded. A module never loaded by any test reads `—`. A row that grows is coverage
    lost; one that shrinks is coverage gained, recorded so it cannot be lost again quietly.\
    """
  end

  defp row(%{module: module, lines: nil}) do
    %{
      "Module" => {:code, inspect(module)},
      "Lines" => :absent,
      "Unhit" => :absent,
      "Never called" => :absent
    }
  end

  defp row(entry) do
    %{
      "Module" => {:code, inspect(entry.module)},
      "Lines" => Integer.to_string(entry.lines),
      "Unhit" => Integer.to_string(entry.unhit),
      "Never called" =>
        case entry.never_called do
          [] -> :absent
          names -> {:raw, Enum.map_join(names, ", ", &"`#{&1}`")}
        end
    }
  end

  @doc "Render the golden."
  def render(entries), do: entries |> golden_spec() |> Surfex.Golden.render()
end
