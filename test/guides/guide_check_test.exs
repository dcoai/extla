defmodule TLA.GuideCheckTest do
  @moduledoc """
  The harness that keeps `guides/` honest, checked against guides written to lie (#94, #95).

  Every test here writes a small guide whose prose makes a **false** claim and asserts the harness
  rejects it. A gate nobody has seen fail is not known to be a gate — the standard #58, #60, #84
  and #90 were held to, applied to the gate that will guard the tutorial.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias TLA.GuideCheck

  defp guide(tmp, body) do
    path = Path.join(tmp, "guide-#{System.unique_integer([:positive])}.md")
    File.write!(path, body)
    path
  end

  # The annotation goes on the line before the fence, as an HTML comment — see the moduledoc
  # for why the fence itself cannot carry it.
  defp block(annotation, code), do: "<!-- #{annotation} -->\n```elixir\n#{code}```\n"

  # A run-claim stands alone, with no fence under it -- the shape the guides use beside a
  # `mix tla.check` command.
  defp claim(annotation), do: "\n<!-- #{annotation} -->\n"

  # A spec with an invariant a reachable state refutes, at a known depth.
  defp broken_spec(name) do
    block("tla:spec", """
    defmodule #{name} do
      use TLA.Spec

      variable :n, type: 0..10

      init do
        n = 0
      end

      action :tick do
        require n < 10
        n = n + 1
      end

      invariant :at_most_two do
        n <= 2
      end
    end
    """)
  end

  defp working_spec(name) do
    block("tla:spec", """
    defmodule #{name} do
      use TLA.Spec

      variable :n, type: 0..2

      init do
        n = 0
      end

      action :tick do
        require n < 2
        n = n + 1
      end

      invariant :in_range do
        n >= 0 and n <= 2
      end

      # Without this the spec DEADLOCKS at n = 2 -- `tick` is disabled and nothing admits the
      # end state. The harness caught that when this fixture was written, which is the harness
      # working: a "working example" that does not work is exactly what it exists to reject.
      terminal :done do
        n == 2
      end
    end
    """)
  end

  describe "a guide that tells the truth" do
    test "passes when a working example is claimed to work", %{tmp_dir: tmp} do
      m = "GuideTruth.Works#{System.unique_integer([:positive])}"

      path = guide(tmp, working_spec(m) <> claim("tla:check module=#{m} expect=ok"))

      assert GuideCheck.check(path) == []
    end

    test "a run-claim may also sit on a fence, and is then checked once", %{tmp_dir: tmp} do
      m = "GuideTruth.Fenced#{System.unique_integer([:positive])}"

      path =
        guide(
          tmp,
          working_spec(m) <> "\n" <> block("tla:check module=#{m} expect=ok states=99", "")
        )

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims 99 distinct states"
    end

    test "passes when a failing example is claimed to fail, at the right depth and property",
         %{tmp_dir: tmp} do
      m = "GuideTruth.Breaks#{System.unique_integer([:positive])}"

      path =
        guide(
          tmp,
          broken_spec(m) <>
            claim("tla:check module=#{m} expect=violation length=4 invariant=at_most_two")
        )

      assert GuideCheck.check(path) == []
    end

    test "passes when the quoted census is the real one", %{tmp_dir: tmp} do
      m = "GuideTruth.Census#{System.unique_integer([:positive])}"

      path =
        guide(tmp, working_spec(m) <> claim("tla:check module=#{m} expect=ok states=3 depth=3"))

      assert GuideCheck.check(path) == []
    end
  end

  describe "a guide that lies — the tests this harness exists for" do
    test "rejects claiming :ok for a spec that is violated", %{tmp_dir: tmp} do
      m = "GuideLies.NotOk#{System.unique_integer([:positive])}"

      path = guide(tmp, broken_spec(m) <> claim("tla:check module=#{m} expect=ok"))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims this reports :ok"
      assert failure =~ "at_most_two is violated"
    end

    test "rejects claiming a violation for a spec that holds", %{tmp_dir: tmp} do
      m = "GuideLies.NotViolated#{System.unique_integer([:positive])}"

      path = guide(tmp, working_spec(m) <> claim("tla:check module=#{m} expect=violation"))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims a violation"
      assert failure =~ ":ok"
    end

    test "rejects a wrong counterexample length", %{tmp_dir: tmp} do
      m = "GuideLies.WrongLength#{System.unique_integer([:positive])}"

      path =
        guide(tmp, broken_spec(m) <> claim("tla:check module=#{m} expect=violation length=99"))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims a 99-step counterexample"
    end

    test "rejects naming the wrong violated invariant", %{tmp_dir: tmp} do
      m = "GuideLies.WrongInvariant#{System.unique_integer([:positive])}"

      path =
        guide(
          tmp,
          broken_spec(m) <>
            claim("tla:check module=#{m} expect=violation invariant=something_else")
        )

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims something_else is violated"
      assert failure =~ "at_most_two"
    end

    test "rejects a wrong state count", %{tmp_dir: tmp} do
      m = "GuideLies.WrongStates#{System.unique_integer([:positive])}"

      path = guide(tmp, working_spec(m) <> claim("tla:check module=#{m} expect=ok states=99"))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims 99 distinct states"
      assert failure =~ "found 3"
    end

    test "rejects a wrong depth", %{tmp_dir: tmp} do
      m = "GuideLies.WrongDepth#{System.unique_integer([:positive])}"

      path = guide(tmp, working_spec(m) <> claim("tla:check module=#{m} expect=ok depth=99"))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims depth 99"
      assert failure =~ "reached 3"
    end

    test "rejects a tla:spec that does not compile", %{tmp_dir: tmp} do
      path =
        guide(
          tmp,
          block("tla:spec", """
          defmodule Guide.Nonsense do
            use TLA.Spec
            variable :n, type: 0..2
            init do
              n = 0
            end
            action :tick do
              n = undeclared_variable_here
            end
          end
          """)
        )

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "does not compile"
    end

    test "rejects a tla:compile_error block that actually compiles", %{tmp_dir: tmp} do
      m = "GuideLies.Compiles#{System.unique_integer([:positive])}"

      path =
        guide(
          tmp,
          block(~s(tla:compile_error match="something"), """
          defmodule #{m} do
            def fine, do: :ok
          end
          """)
        )

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "compiled successfully"
    end

    test "rejects a compile error whose message is not the one claimed", %{tmp_dir: tmp} do
      path =
        guide(
          tmp,
          block(~s(tla:compile_error match="a message it will never produce"), """
          defmodule Guide.AlsoNonsense do
            use TLA.Spec
            variable :n, type: 0..2
            init do
              n = 0
            end
            action :tick do
              n = undeclared_variable_here
            end
          end
          """)
        )

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "expected the error to contain"
    end
  end

  describe "the real guides/" do
    # Written before any guide existed (#95), so the gate was wired before the prose -- nobody
    # retrofits a gate to a guide that already passes. It now covers getting-started (#96) and
    # every page of the tutorial (#97, #99).
    test "every guide in guides/ tells the truth" do
      guides = GuideCheck.guides()

      if guides == [] do
        # Stated rather than skipped. A silently vacuous test is the "gate that cannot fail"
        # this project keeps rejecting; saying so out loud is the same move TLA_COVERAGE.md
        # makes when it records an item as NOTHING instead of omitting it.
        assert not File.dir?("guides"),
               "guides/ exists but holds no .md files — this check would be silently vacuous"
      else
        failures = Enum.flat_map(guides, &GuideCheck.check/1)

        assert failures == [],
               "guides make claims the code does not support:\n\n" <> Enum.join(failures, "\n")
      end
    end
  end

  describe "pages are checked in sorted path order" do
    # The tutorial's Layer 3 page checks a server against the lock its DSL page declares, so the
    # order pages are checked in is a dependency, and `guides/0` fixes it by sorting paths.

    # Named deliberately rather than by unique integer: the point is the ORDER the names sort in.
    defp page(tmp, name, body) do
      path = Path.join(tmp, name)
      File.write!(path, body)
      path
    end

    test "a page may use a module an earlier page compiled", %{tmp_dir: tmp} do
      m = "GuideOrder.Forward#{System.unique_integer([:positive])}"

      pages = [
        page(tmp, "02-declares.md", working_spec(m)),
        page(tmp, "03-checks.md", claim("tla:check module=#{m} expect=ok"))
      ]

      # Sorted, the declaring page comes first and the module exists by the time the claim runs.
      assert Enum.flat_map(Enum.sort(pages), &GuideCheck.check/1) == []
    end

    test "and is checked before it is defined if the walk does not sort", %{tmp_dir: tmp} do
      # A DIFFERENT module from the test above: once compiled, a module stays in the VM, so
      # reusing one would make this pass for the wrong reason.
      m = "GuideOrder.Reverse#{System.unique_integer([:positive])}"

      pages = [
        page(tmp, "02-declares.md", working_spec(m)),
        page(tmp, "03-checks.md", claim("tla:check module=#{m} expect=ok"))
      ]

      assert [failure] = Enum.flat_map(Enum.sort(pages, :desc), &GuideCheck.check/1)
      assert failure =~ "the run raised"
    end

    test "guides/0 returns the tree sorted, so the tutorial is in reading order" do
      guides = GuideCheck.guides()

      assert guides == Enum.sort(guides)
      assert "guides/getting-started.md" in guides
      assert "guides/tutorial/02-dsl.md" in guides

      tutorial = Enum.filter(guides, &String.starts_with?(&1, "guides/tutorial/"))
      assert length(tutorial) >= 6
    end
  end

  describe "deadlock is its own claim" do
    test "a spec that deadlocks can say so, and is accepted", %{tmp_dir: tmp} do
      m = "GuideDeadlock.Stuck#{System.unique_integer([:positive])}"

      path =
        guide(
          tmp,
          block("tla:spec", """
          defmodule #{m} do
            use TLA.Spec
            variable :n, type: 0..2
            init do
              n = 0
            end
            action :tick do
              require n < 2
              n = n + 1
            end
          end
          """) <> claim("tla:check module=#{m} expect=deadlock")
        )

      assert GuideCheck.check(path) == []
    end

    test "claiming a deadlock for a spec that has none is rejected", %{tmp_dir: tmp} do
      m = "GuideDeadlock.Fine#{System.unique_integer([:positive])}"

      path = guide(tmp, working_spec(m) <> claim("tla:check module=#{m} expect=deadlock"))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims a deadlock"
    end
  end

  describe "an unannotated block is an unchecked claim" do
    test "a bare elixir block is rejected", %{tmp_dir: tmp} do
      path = guide(tmp, "```elixir\n:this_is_never_checked\n```\n")

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "unchecked claim"
      assert failure =~ "tla:skip"
    end

    test "tla:skip is accepted, so a gap is visible on the page rather than silent",
         %{tmp_dir: tmp} do
      path = guide(tmp, block("tla:skip reason=illustrative-pseudocode", ":whatever\n"))

      assert GuideCheck.check(path) == []
    end

    test "a comment that is not on the line before the fence does not annotate it",
         %{tmp_dir: tmp} do
      path = guide(tmp, "<!-- tla:skip reason=too-far-away -->\n\n```elixir\n:unclaimed\n```\n")

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "unchecked claim"
    end
  end

  describe "a block that will not render is wrong before its claim is read" do
    # The first harness put the annotation on the fence: ```elixir tla:spec. Earmark accepts one
    # word after the backticks and nothing else, so under `mix docs` that block was not a block
    # at all -- its code came out as one run of inline text (#96).
    test "an annotation on the fence's info string is rejected, with the reason", %{tmp_dir: tmp} do
      path = guide(tmp, "```elixir tla:skip reason=old-style\n:whatever\n```\n")

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "not a fence Earmark recognises"
      assert failure =~ "mix docs"
    end
  end
end
