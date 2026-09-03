defmodule TLA.DocLinksTest do
  @moduledoc """
  The gate over the **built** documentation (#102, #103), and the fixtures that prove it can fail.

  It exists because a gate over source markdown cannot see a link ExDoc writes itself. The defect
  that motivated it — `readme.html`, the sidebar's home link, on all 84 generated pages — was
  invisible to every check this project had, and was found only by resolving a page's links against
  the built HTML by hand.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias TLA.DocLinks

  defp page(tmp, name, body) do
    File.write!(Path.join(tmp, name), body)
  end

  describe "a site whose links resolve" do
    test "accepts pages, anchors, cross-page anchors and assets", %{tmp_dir: tmp} do
      page(tmp, "a.html", """
      <a href="b.html">page</a>
      <a href="b.html#heading">cross-page anchor</a>
      <a href="#own">same page</a>
      <a href="style.css">asset</a>
      <h2 id="own">Own</h2>
      """)

      page(tmp, "b.html", ~s(<h2 id="heading">Heading</h2>))
      File.write!(Path.join(tmp, "style.css"), "body{}")

      assert DocLinks.check(tmp) == []
    end

    test "leaves external links, mailto and javascript alone", %{tmp_dir: tmp} do
      page(tmp, "a.html", """
      <a href="https://example.com/nope.html#nope">http</a>
      <a href="//example.com/nope.html">protocol-relative</a>
      <a href="mailto:someone@example.com">mail</a>
      <a href="javascript:void(0)">js</a>
      <a href="">empty</a>
      """)

      assert DocLinks.check(tmp) == []
    end
  end

  describe "a site with a 404 in it — the tests this gate exists for" do
    test "a page that was never generated is named", %{tmp_dir: tmp} do
      # #102 exactly: ExDoc's own sidebar link, to a page the build did not produce.
      page(tmp, "a.html", ~s(<a href="readme.html" class="sidebar-projectName">ExTLA</a>))

      assert [failure] = DocLinks.check(tmp)
      assert failure =~ "a.html:"
      assert failure =~ ~s(link to "readme.html")
      assert failure =~ "not in the built docs"
    end

    test "an anchor no element carries is named, on another page", %{tmp_dir: tmp} do
      page(tmp, "a.html", ~s(<a href="b.html#15-type-annotations">wrong slug</a>))
      page(tmp, "b.html", ~s(<h2 id="1-5-type-annotations">Type annotations</h2>))

      assert [failure] = DocLinks.check(tmp)
      assert failure =~ "anchor #15-type-annotations"
      assert failure =~ "b.html has no element with that id"
    end

    test "an anchor no element carries is named, on this page", %{tmp_dir: tmp} do
      page(tmp, "a.html", ~s(<a href="#gone">here</a><h2 id="present">Present</h2>))

      assert [failure] = DocLinks.check(tmp)
      assert failure =~ "anchor #gone"
      assert failure =~ "this page has no element with that id"
    end

    test "a missing asset is named — the README's LICENSE link, before it was an extra",
         %{tmp_dir: tmp} do
      page(tmp, "readme.html", ~s(MIT — see <a href="LICENSE">LICENSE</a>.))

      assert [failure] = DocLinks.check(tmp)
      assert failure =~ ~s(link to "LICENSE")
    end

    test "every distinct broken link is reported", %{tmp_dir: tmp} do
      page(tmp, "a.html", ~s(<a href="one.html">1</a><a href="two.html">2</a>))

      assert length(DocLinks.check(tmp)) == 2
    end

    test "the same broken link on two pages is reported for each", %{tmp_dir: tmp} do
      # What made #102 costly: one wrong link, repeated by the generator onto every page.
      page(tmp, "a.html", ~s(<a href="gone.html">x</a>))
      page(tmp, "b.html", ~s(<a href="gone.html">x</a>))

      assert length(DocLinks.check(tmp)) == 2
    end
  end

  describe "it says when it cannot answer" do
    test "an unbuilt directory is :not_built, never an empty pass", %{tmp_dir: tmp} do
      assert DocLinks.check(tmp) == :not_built
      assert DocLinks.check(Path.join(tmp, "nope")) == :not_built
    end
  end

  describe "the real built docs" do
    test "every internal link in doc/ resolves" do
      case DocLinks.check() do
        :not_built ->
          # Stated rather than skipped: this is the assertion CI's `docs` job exists to make
          # real, and a silent pass here is the defect #75 and #90 were raised about.
          IO.puts(
            "\n  doc/ is not built, so the built-docs link check did not run. " <>
              "`MIX_ENV=dev mix docs` first; CI's `docs` job does.\n"
          )

          assert not File.dir?("doc"),
                 "doc/ exists but holds no .html files — this check would be silently vacuous"

        failures ->
          assert failures == [],
                 "the built documentation links to things it does not contain:\n\n" <>
                   Enum.join(Enum.take(failures, 40), "\n")
      end
    end
  end
end
