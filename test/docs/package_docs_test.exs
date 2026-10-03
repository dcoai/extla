defmodule ExTLA.PackageDocsTest do
  @moduledoc """
  The published documentation advertises nothing a consumer cannot call (#274, from #270).

  `mix docs` runs under `MIX_ENV=dev` — `ex_doc` is a dev dependency and exists nowhere else
  — and `elixirc_paths(:dev)` includes `ledger/`. So the built documentation carried
  `ExTLA.Ledger`, `ExTLA.Spec.Version`, `mix tla.coverage` and eight more, eleven modules in all,
  to a reader whose `mix deps.get` brings them `lib/` only. Nobody decided to document the
  ledger: the docs job's environment did.

  The two halves of that promise were checked in two environments that cannot see each other.
  `consumer-compile` compiles the package under `MIX_ENV=prod` and proves `ledger/` is absent
  from it — and has no `ex_doc`, so it never builds docs. The docs job builds them and never
  looks at the package. This is the join.

  It needs a built `doc/`, which only the `docs` job produces. That requirement is a **tag**,
  not a directory: `test/docs/` is run by the `test` job too, where `doc/` does not exist, and
  a first version of this file learned that by failing there. `:needs_built_docs` is excluded
  in `test_helper.exs` and included by the job that has the artifact — which is #217's
  recommendation, adopted here because without it this test can only be written two ways that
  are both wrong: absent, or passing on an absence. The guard below **fails** when `doc/` is
  missing, so under the tag it cannot become the vacuous check #156 found next door to it.
  """
  use ExUnit.Case, async: true

  @moduletag :needs_built_docs

  @root Path.expand("../..", __DIR__)
  @built Path.join(@root, "doc")

  setup_all do
    %{surface: ExTLA.PackageSurface.run(@root)}
  end

  describe "the built documentation" do
    test "contains a page for no module the package leaves out", %{surface: surface} do
      built = built_modules()

      unshipped =
        for row <- surface.modules, not row.packaged?, inspect(row.module) in built, do: row

      assert unshipped == [], """
      #{length(unshipped)} modules have a published page and are not in the package:

        #{Enum.map_join(unshipped, "\n  ", &"#{inspect(&1.module)} (#{&1.path})")}

      `mix.exs`'s `docs: [filter_modules: …]` keeps a module out of the docs when no `files:`
      entry ships it. Either the filter is no longer applied, or a source tree was added to
      `elixirc_paths(:dev)` and to the package at different times.
      """
    end

    test "does contain the modules the package ships", %{surface: surface} do
      built = built_modules()
      packaged = for row <- surface.modules, row.packaged?, do: inspect(row.module)

      # Not an equality: `@moduledoc false` keeps a shipped module out of the docs on
      # purpose, which is a different decision from this one and not this gate's business.
      assert Enum.any?(packaged, &(&1 in built)),
             "no packaged module has a page; the filter is excluding everything"
    end
  end

  describe "the golden and mix.exs agree about what ships" do
    test "every module row's packaged? matches the predicate the docs are filtered on",
         %{surface: surface} do
      for row <- surface.modules do
        metadata = %{source_path: Path.join(@root, row.path)}

        assert ExTLA.MixProject.packaged?(row.module, metadata) == row.packaged?,
               "#{inspect(row.module)}: PACKAGE_SURFACE.md says packaged?=#{row.packaged?}, " <>
                 "mix.exs's filter says otherwise"
      end
    end
  end

  # A reading that silently returns nothing turns both assertions above into `assert [] == []`.
  # `doc/` is absent in every job but `docs`, and a runtime branch that passed on absence is
  # exactly how the slug cross-check next door went four weeks without running (#156).
  defp built_modules do
    unless File.dir?(@built) do
      flunk("""
      #{@built} does not exist, so this test asserts nothing.

      It needs the documentation this job builds: `MIX_ENV=dev mix docs` before
      `mix test test/docs`. If you are running the suite locally, either build the docs or
      run `mix test --exclude needs_built_docs` — do not make the absence a pass.
      """)
    end

    pages =
      @built
      |> Path.join("*.html")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".html"))

    if pages == [], do: flunk("#{@built} holds no pages")

    # A module page is named for the module; an extra's page is named for its file. Both are
    # `.html` here, so the module set is what the sidebar's Modules section lists.
    pages
  end
end
