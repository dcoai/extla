defmodule TLA.PackageSurfaceTest do
  @moduledoc """
  `PACKAGE_SURFACE.md`'s scanner, and the two dependency properties `spec/06` states in prose
  (#270, #274).

  The scanner runs against fixture roots in a `tmp_dir`, because the cases that matter are the
  ones this tree does not have: a git dependency pinned to a branch, a module in a tree the
  package does not ship, a `files:` entry naming a single file rather than a directory.

  §Dependencies used to carry a copy of the `deps` block and now carries a link to the golden
  plus two prose claims. Prose does not drift the way a list does — but these two are load
  bearing, so they are pinned here rather than trusted: "zero required runtime dependencies"
  is the library's central promise, and "dev/test dependencies are not transitive" is why
  `ledger/` may depend on surfex while `lib/` may not.
  """
  use ExUnit.Case, async: true

  alias TLA.PackageSurface

  @moduletag :tmp_dir

  @mix_exs ~S'''
  defmodule Fixture.MixProject do
    use Mix.Project

    def project do
      [
        app: :fixture,
        elixirc_paths: elixirc_paths(Mix.env()),
        deps: deps(),
        package: [files: packaged_files()],
        docs: [filter_modules: &Fixture.MixProject.packaged?/2]
      ]
    end

    def packaged?(_m, _meta), do: true

    defp packaged_files, do: ~w(lib mix.exs README.md)

    defp elixirc_paths(:dev), do: ["lib", "tooling"]
    defp elixirc_paths(_), do: ["lib"]

    defp deps do
      [
        {:jason, "~> 1.4", optional: true},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:sibling, git: "git@example.com:org/sibling.git", branch: "main", only: :dev},
        {:plain, "~> 2.0"}
      ]
    end
  end
  '''

  defp tree(tmp, sources) do
    File.write!(Path.join(tmp, "mix.exs"), @mix_exs)

    for {path, source} <- sources do
      full = Path.join(tmp, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, source)
    end

    PackageSurface.run(tmp)
  end

  defp dependency(surface, name), do: Enum.find(surface.dependencies, &(&1.name == name))
  defp module_row(surface, module), do: Enum.find(surface.modules, &(&1.module == module))

  describe "dependencies, as mix.exs declares them" do
    setup %{tmp_dir: tmp}, do: %{surface: tree(tmp, [{"lib/a.ex", "defmodule A do\nend\n"}])}

    test "a version requirement, with its only: and runtime:", %{surface: surface} do
      assert dependency(surface, :credo).requirement == "~> 1.7"
      assert dependency(surface, :credo).only == "dev, test"
      refute dependency(surface, :credo).runtime
    end

    test "an optional dependency is marked, and is `only: all`", %{surface: surface} do
      assert dependency(surface, :jason).optional
      assert dependency(surface, :jason).only == "all"
    end

    test "a git dependency carries its source and its pin, not a blank requirement",
         %{surface: surface} do
      assert dependency(surface, :sibling).requirement ==
               "git: git@example.com:org/sibling.git branch: main"

      assert dependency(surface, :sibling).only == "dev"
    end

    test "a plain `{:name, requirement}` pair is read", %{surface: surface} do
      assert dependency(surface, :plain).requirement == "~> 2.0"
      assert dependency(surface, :plain).only == "all"
      assert dependency(surface, :plain).runtime
    end
  end

  describe "modules, and whether the package ships them" do
    setup %{tmp_dir: tmp} do
      %{
        surface:
          tree(tmp, [
            {"lib/shipped.ex", "defmodule Shipped do\n  defmodule Inner do\n  end\nend\n"},
            {"tooling/kept_back.ex", "defmodule KeptBack do\nend\n"}
          ])
      }
    end

    test "a module under a shipped directory is packaged", %{surface: surface} do
      assert module_row(surface, Shipped).packaged?
    end

    test "a nested module carries its enclosing name", %{surface: surface} do
      assert module_row(surface, Shipped.Inner)
      refute module_row(surface, Inner)
    end

    test "a module the dev paths compile and the package omits is listed, not hidden",
         %{surface: surface} do
      row = module_row(surface, KeptBack)

      assert row, "a module outside the package must still be listed — that is the finding"
      refute row.packaged?
    end
  end

  describe "the predicate" do
    test "a files: entry naming a directory covers what is under it" do
      assert PackageSurface.packaged?("lib/tla/spec.ex", ["lib"])
      refute PackageSurface.packaged?("ledger/tla/ledger.ex", ["lib"])
    end

    # `research/tla-plus-primer.md` is a `files:` entry that is one file, not a tree. A
    # prefix test alone would ship `research/anything-else.md` with it.
    test "a files: entry naming one file covers that file and nothing beside it" do
      files = ["research/tla-plus-primer.md"]

      assert PackageSurface.packaged?("research/tla-plus-primer.md", files)
      refute PackageSurface.packaged?("research/other.md", files)
    end
  end

  describe "what spec/06 §Dependencies claims in prose" do
    setup do
      %{surface: PackageSurface.run(Path.expand("../..", __DIR__))}
    end

    # The library's central promise: a consumer who depends on ExTLA carries no runtime
    # dependency of its choosing. `optional: true` is not a required dependency — whether it
    # is present is decided when ExTLA compiles.
    test "zero required runtime dependencies", %{surface: surface} do
      required =
        for d <- surface.dependencies, d.only == "all", not d.optional, d.runtime, do: d.name

      assert required == [], "spec/06 claims none; mix.exs declares #{inspect(required)}"
    end

    test "the two `only: all` dependencies are both optional", %{surface: surface} do
      always = for d <- surface.dependencies, d.only == "all", do: d.name

      assert Enum.sort(always) == [:jason, :telemetry]
      assert Enum.all?(surface.dependencies, &(&1.only != "all" or &1.optional))
    end

    # Why `ledger/` may depend on surfex and `lib/` may not: a dev/test dependency is not
    # transitive, so nothing marked that way reaches a consumer.
    test "surfex is dev/test only, which is what lets the ledger use it", %{surface: surface} do
      assert dependency(surface, :surfex).only == "dev, test"
      refute dependency(surface, :surfex).runtime
    end
  end

  describe "the golden is a stable function of source" do
    test "rendering twice produces identical bytes", %{tmp_dir: tmp} do
      surface = tree(tmp, [{"lib/a.ex", "defmodule A do\nend\n"}])
      assert PackageSurface.render(surface) == PackageSurface.render(surface)
    end

    test "no date or clock time reaches the output" do
      rendered = PackageSurface.run() |> PackageSurface.render()
      refute rendered =~ ~r/\d{4}-\d{2}-\d{2}/
      refute rendered =~ ~r/\d{2}:\d{2}:\d{2}/
    end

    test "the committed golden is current — the same equality the surface-drift job asserts" do
      path = Path.expand("../../PACKAGE_SURFACE.md", __DIR__)
      assert File.read!(path) == PackageSurface.run() |> PackageSurface.render()
    end
  end
end
