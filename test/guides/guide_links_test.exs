defmodule TLA.GuideCheck.LinksTest do
  @moduledoc """
  The link gate, checked against guides whose links go nowhere (#98, #99).

  #96 and #97 each verified their links by hand against the built docs, and #97 got four wrong the
  same way — ExDoc's anchor for `### 1.5 Type annotations` is `1-5-type-annotations`, not
  `15-type-annotations`. These are the tests that make that a build failure instead of a review
  step, and each one is seen red before the guides are trusted to pass.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias TLA.GuideCheck.Links

  doctest TLA.GuideCheck.Links

  defp guide(tmp, name, body) do
    path = Path.join(tmp, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  describe "a link that resolves" do
    test "to a sibling file, with and without an anchor", %{tmp_dir: tmp} do
      guide(tmp, "target.md", "# Target\n\n## 1.5 Type annotations\n\nBody.\n")

      path =
        guide(tmp, "source.md", """
        # Source

        [the file](target.md), [a heading in it](target.md#1-5-type-annotations).
        """)

      assert Links.check(path) == []
    end

    test "to a heading on the same page", %{tmp_dir: tmp} do
      path = guide(tmp, "source.md", "# Source\n\n[below](#the-rest)\n\n## The rest\n")

      assert Links.check(path) == []
    end

    test "up and across a directory, the shape the tutorial's pages use", %{tmp_dir: tmp} do
      guide(tmp, "spec/02-dsl-semantics.md", "# DSL\n\n## 4. `action_property` uses `old`\n")

      path =
        guide(tmp, "guides/tutorial/02-dsl.md", """
        # Page

        [the rule](../../spec/02-dsl-semantics.md#4-action_property-uses-old)
        """)

      assert Links.check(path) == []
    end

    test "and a URL is left alone", %{tmp_dir: tmp} do
      path =
        guide(tmp, "source.md", """
        # Source

        [http](https://example.com/x.md#nope), [mailto](mailto:someone@example.com)
        """)

      assert Links.check(path) == []
    end
  end

  describe "a link that goes nowhere — the tests this gate exists for" do
    test "a file that does not exist is rejected, and named", %{tmp_dir: tmp} do
      path = guide(tmp, "source.md", "# Source\n\n[gone](no-such-page.md)\n")

      assert [failure] = Links.check(path)
      assert failure =~ ~s|link to "no-such-page.md"|
      assert failure =~ "does not exist"
      assert failure =~ "source.md:3"
    end

    test "an anchor no heading generates is rejected, on another page", %{tmp_dir: tmp} do
      guide(tmp, "target.md", "# Target\n\n## 1.5 Type annotations\n")

      path = guide(tmp, "source.md", "# Source\n\n[wrong](target.md#15-type-annotations)\n")

      assert [failure] = Links.check(path)
      assert failure =~ "no heading whose anchor is \"15-type-annotations\""
    end

    test "an anchor no heading generates is rejected, on the same page", %{tmp_dir: tmp} do
      path = guide(tmp, "source.md", "# Source\n\n[wrong](#not-a-heading)\n\n## A heading\n")

      assert [failure] = Links.check(path)
      assert failure =~ ~s|link to "#not-a-heading"|
    end

    test "a relative path that escapes into nothing is rejected", %{tmp_dir: tmp} do
      path = guide(tmp, "guides/tutorial/page.md", "# Page\n\n[up](../spec/thing.md)\n")

      assert [failure] = Links.check(path)
      assert failure =~ "does not exist"
    end

    test "every broken link is reported, not just the first", %{tmp_dir: tmp} do
      path = guide(tmp, "source.md", "# Source\n\n[a](one.md)\n\n[b](two.md)\n")

      assert length(Links.check(path)) == 2
    end
  end

  describe "the real guides" do
    test "every link in every guide resolves" do
      failures = Enum.flat_map(TLA.GuideCheck.guides(), &Links.check/1)

      assert failures == [],
             "guides link to things that do not exist:\n\n" <> Enum.join(failures, "\n")
    end

    # The slug cross-check moved to `test/docs/slug_model_test.exs` (#290). It lived here,
    # and the `docs` job — the only one that builds `doc/` — runs `mix test test/docs`, so
    # it took its `else` branch on every CI run, asserted that a directory does not exist,
    # and passed. It had never run. It now carries `:needs_built_docs` and FAILS on an
    # absent `doc/` rather than passing, which is the shape `package_docs_test.exs` uses.
  end
end
