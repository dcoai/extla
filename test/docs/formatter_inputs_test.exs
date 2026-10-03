defmodule ExTLA.FormatterInputsTest do
  @moduledoc """
  `.formatter.exs` covers every Elixir file this repository tracks (#317).

  Its `inputs:` read `["{mix,.formatter}.exs", "{bench,config,lib,test}/**/*.{ex,exs}"]`,
  and two directories holding real Elixir were outside it: `bin/` — the CHANGELOG guard and
  the stream_data fallback check — and `ledger/`, which is the surface-drift ledger, its six
  Mix tasks and the modules behind five of this project's six goldens. `scripts/` was
  outside it too.

  **One of those files was unformatted while the `format` job passed.** That is the shape
  worth gating rather than the files worth adding: a gate that does not cover what it
  appears to reads, from the outside, exactly like a gate that does — which is this
  milestone's subject. The job is unchanged; what changed is what it can see.

  ## Why the tracked set, and not a wildcard

  `git ls-files` is the honest denominator. A `Path.wildcard` over the tree would sweep in
  `tmp/`, where ExUnit's `tmp_dir` writes a directory per test and which `.gitignore`
  excludes for a reason recorded there — the paths embed test names. What the formatter
  owes coverage to is what the repository carries.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  describe ".formatter.exs" do
    test "covers every Elixir file the repository tracks" do
      uncovered = tracked() -- covered()

      assert uncovered == [], """
      #{length(uncovered)} tracked Elixir file(s) are outside `.formatter.exs`'s `inputs:`:

        #{Enum.join(uncovered, "\n  ")}

      `mix format` and `mix format --check-formatted` both read that list, so a file outside
      it is neither formatted nor checked — and the CI `format` job passes over it in
      silence. Add the directory to `inputs:`.
      """
    end

    # Anti-vacuity, both ways: an empty `inputs:` would make the assertion above pass by
    # having nothing to compare, and so would an empty tracked set.
    test "and both sides of that comparison are real" do
      assert length(tracked()) > 150
      assert length(covered()) > 150

      for directory <- ~w(lib test bench bin ledger scripts) do
        assert Enum.any?(tracked(), &String.starts_with?(&1, directory <> "/")),
               "#{directory}/ tracks no Elixir; drop it from this list or from `inputs:`"

        assert Enum.any?(covered(), &String.starts_with?(&1, directory <> "/")),
               "`inputs:` does not reach #{directory}/"
      end

      assert "mix.exs" in covered()
    end
  end

  defp covered do
    @root
    |> Path.join(".formatter.exs")
    |> Code.eval_file()
    |> elem(0)
    |> Keyword.fetch!(:inputs)
    # `match_dot: true`, as `mix format` itself expands these: without it `.formatter.exs`
    # is not matched by its own `{mix,.formatter}.exs` entry.
    |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1), match_dot: true))
    |> Enum.map(&Path.relative_to(&1, @root))
    |> Enum.sort()
  end

  defp tracked do
    {output, 0} = System.cmd("git", ["ls-files", "*.ex", "*.exs"], cd: @root)

    output
    |> String.split("\n", trim: true)
    |> Enum.sort()
  end
end
