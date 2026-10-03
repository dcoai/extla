defmodule ExTLA.SlugModelTest do
  @moduledoc """
  `ExTLA.GuideCheck.Links.slug/1` is ExDoc's slug, compared against ids ExDoc really generated
  (#290, for #156).

  ## The gate that had never run

  This lived in `test/guides/guide_links_test.exs`. It is the only thing proving the link
  gate's anchor model is true — every `#some-heading` link in every guide is checked against
  `slug/1`'s reimplementation of ExDoc's slugifier, and if that reimplementation is wrong
  the whole link gate is wrong in the same direction, silently.

  Its author anticipated vacuity and guarded for it, and the guard fired on the wrong
  condition:

      if File.regular?("doc/02-dsl-semantics.html") do
        …the real comparison…
      else
        assert not File.dir?("doc"), "doc/ exists but … would be silently vacuous"
      end

  In CI the answer is always "not built" — the `docs` job runs `mix test test/docs`, and
  this was in `test/guides/`; `doc/` is gitignored and uncached, so the `test` job has never
  had one. So the `else` branch ran every time, asserted that a directory does not exist,
  and passed. **The cross-validation had never run at all**, missed by directory placement
  rather than by anyone's decision.

  ## What changed

  The requirement is a tag, not a directory — #217's recommendation, which
  `package_docs_test.exs` already follows next door, and whose moduledoc names this very
  test as the thing it was avoiding becoming. `:needs_built_docs` is excluded in
  `test_helper.exs` and included by the one job that builds the artifact.

  And the guard now **fails** on an absent `doc/` instead of passing. Under the tag that is
  safe — the test only runs where the artifact exists — and it means the check can never
  again report green for having skipped itself.
  """
  use ExUnit.Case, async: true

  @moduletag :needs_built_docs

  alias ExTLA.GuideCheck.Links

  @root Path.expand("../..", __DIR__)
  @page "spec/02-dsl-semantics.md"
  @built "doc/02-dsl-semantics.html"

  describe "the slug model" do
    test "matches the ids ExDoc generated" do
      built = Path.join(@root, @built)

      assert File.regular?(built), """
      #{@built} has not been built, so this comparison has nothing to run against.

      This test carries `@moduletag :needs_built_docs` and runs only where `mix docs` has
      run — the `docs` job. It FAILS rather than skips, because the version of it that
      passed on an absent `doc/` is exactly the defect #156 found: a gate that reported
      green for never having run.
      """

      ids =
        ~r/id="([^"]+)"/
        |> Regex.scan(File.read!(built))
        |> Enum.map(fn [_match, id] -> id end)
        |> MapSet.new()

      headings =
        ~r/^\#{2,6}[ \t]+(.+?)[ \t]*$/m
        |> Regex.scan(File.read!(Path.join(@root, @page)))
        |> Enum.map(fn [_match, heading] -> heading end)

      assert headings != [], "#{@page} has no headings; this comparison would be vacuous"

      wrong =
        for heading <- headings,
            slug = Links.slug(heading),
            not MapSet.member?(ids, slug),
            do: "#{inspect(heading)} → #{inspect(slug)}"

      assert wrong == [], """
      slug/1 does not reproduce ExDoc's ids for #{length(wrong)} heading(s):

        #{Enum.join(wrong, "\n  ")}

      Every anchor link the guide gate accepts is checked against slug/1, so a slug model
      that has drifted from ExDoc passes links a reader cannot follow — which is what #97
      did four times before the gate existed (`### 1.5 Type annotations` is
      `1-5-type-annotations`, not `15-type-annotations`).
      """
    end

    # Anti-vacuity, and it is the point of this file: the assertion above is a comprehension
    # that passes on an empty list, and the ids it compares against come from a regex over a
    # file. If either reads nothing, everything is green.
    test "and the comparison actually read both sides" do
      built = Path.join(@root, @built)
      assert File.regular?(built)

      ids = ~r/id="([^"]+)"/ |> Regex.scan(File.read!(built)) |> Enum.map(&Enum.at(&1, 1))

      headings =
        ~r/^\#{2,6}[ \t]+(.+?)[ \t]*$/m |> Regex.scan(File.read!(Path.join(@root, @page)))

      assert length(ids) > 20, "only #{length(ids)} ids found in #{@built}"
      assert length(headings) > 20, "only #{length(headings)} headings found in #{@page}"
    end
  end
end
