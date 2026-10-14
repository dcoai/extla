defmodule ExTLA.GuideCheckTest do
  @moduledoc """
  The harness that keeps `guides/` honest, checked against guides written to lie (#94, #95).

  Every test here writes a small guide whose prose makes a **false** claim and asserts the harness
  rejects it. A gate nobody has seen fail is not known to be a gate — the standard #58, #60, #84
  and #90 were held to, applied to the gate that will guard the tutorial.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ExTLA.GuideCheck

  defp guide(tmp, body) do
    path = Path.join(tmp, "guide-#{System.unique_integer([:positive])}.md")
    File.write!(path, body)
    path
  end

  # The annotation goes on the line before the fence, as an HTML comment — see the moduledoc
  # for why the fence itself cannot carry it.
  defp block(annotation, code), do: "<!-- #{annotation} -->\n```elixir\n#{code}```\n"

  # A run-claim stands alone, with no fence under it -- the shape the guides use beside a
  # `mix extla.check` command.
  defp claim(annotation), do: "\n<!-- #{annotation} -->\n"

  # A page whose output came from `config :extla, Spec, symmetry: […]` is checked under that
  # config, the way the reader ran it (#409). The harness may not write application env, so it
  # is written here, in a file that is `async: false` for exactly this; each key is a guide's
  # own spec module, which nothing else configures, and it is removed again after the run.
  defp with_env(env, fun) do
    for {key, value} <- env, do: Application.put_env(:extla, key, value)
    result = fun.()
    for {key, _value} <- env, do: Application.delete_env(:extla, key)
    result
  end

  # A spec with an invariant a reachable state refutes, at a known depth.
  defp broken_spec(name) do
    block("tla:spec", """
    defmodule #{name} do
      use ExTLA.Spec

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
      use ExTLA.Spec

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

  # A claim with the block of output a page shows under it (#409).
  defp claim_with_output(annotation, output),
    do: "\n<!-- #{annotation} -->\n```\n#{output}\n```\n"

  describe "an output block (#409)" do
    test "that is what the tool prints passes", %{tmp_dir: tmp} do
      m = "GuideOutput.Exact#{System.unique_integer([:positive])}"

      [_, real] =
        guide(tmp, working_spec(m) <> claim("tla:check module=#{m} expect=ok"))
        |> then(fn path ->
          GuideCheck.check(path)
          {:ok, ExTLA.GuideCheck.Output.task(["extla.check", m])}
        end)
        |> Tuple.to_list()

      path =
        guide(tmp, working_spec(m) <> claim_with_output("tla:check module=#{m} expect=ok", real))

      assert GuideCheck.check(path) == []
    end

    test "that has drifted from it is rejected, naming the line and carrying the real output",
         %{tmp_dir: tmp} do
      m = "GuideOutput.Drift#{System.unique_integer([:positive])}"

      shown = "#{m} — verified\n  4 distinct states, 2 transitions, depth 3, 1ms"

      path =
        guide(tmp, working_spec(m) <> claim_with_output("tla:check module=#{m} expect=ok", shown))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "the output shown differs from what the tool prints"
      assert failure =~ ~s(shown: "  4 distinct states)
      assert failure =~ "| #{m} — verified"
    end

    test "that is abridged passes when its lines appear in order, durations normalised",
         %{tmp_dir: tmp} do
      m = "GuideOutput.Abridged#{System.unique_integer([:positive])}"

      shown = "#{m} — verified\n  3 distinct states, 2 transitions, depth 3, 999ms\n…\n  type_ok"

      path =
        guide(
          tmp,
          working_spec(m) <>
            claim_with_output("tla:check module=#{m} expect=ok output=abridged", shown)
        )

      assert [] = GuideCheck.check(path) |> Enum.reject(&(&1 =~ "type_ok")),
             "the abridged lines appear in the real output"
    end

    test "that is abridged is still rejected for a line the tool does not print",
         %{tmp_dir: tmp} do
      m = "GuideOutput.AbridgedWrong#{System.unique_integer([:positive])}"

      shown = "#{m} — verified\n…\n  a line nothing prints"

      path =
        guide(
          tmp,
          working_spec(m) <>
            claim_with_output("tla:check module=#{m} expect=ok output=abridged", shown)
        )

      assert [failure] = GuideCheck.check(path)
      assert failure =~ ~s(shows "  a line nothing prints")
    end

    test "tla:output holds a tla:run block's exception to what it raised", %{tmp_dir: tmp} do
      run = block(~s(tla:run expect=raise match="boom"), ~s|raise ArgumentError, "boom"\n|)

      ok = guide(tmp, run <> "\n<!-- tla:output -->\n```\n** (ArgumentError) boom\n```\n")
      assert GuideCheck.check(ok) == []

      wrong = guide(tmp, run <> "\n<!-- tla:output -->\n```\n** (ArgumentError) bang\n```\n")
      assert [failure] = GuideCheck.check(wrong)
      assert failure =~ "the output shown differs"
    end

    test "output that needs config is not compared without a with_env:", %{tmp_dir: tmp} do
      m = "GuideOutput.Config#{System.unique_integer([:positive])}"

      symmetric =
        block("tla:spec", """
        defmodule #{m} do
          use ExTLA.Spec

          constant :ids, default: set([:a, :b])
          variable :seen, type: set(^ids)

          init do
            seen = set()
          end

          action :see, params: [i: ^ids] do
            require not member?(seen, i)
            seen = put(seen, i)
          end

          terminal :all_seen do
            size(seen) == 2
          end
        end
        """)

      path =
        guide(
          tmp,
          symmetric <>
            claim_with_output(
              "tla:check module=#{m} expect=ok symmetry=ids output=abridged",
              "#{m}"
            )
        )

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "given no `with_env:`"
    end

    test "a bare fence in a guide that nothing checks is rejected", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "guides"))
      path = Path.join(tmp, "guides/page.md")
      File.write!(path, "# Page\n\n```\nsome output\n```\n\n```text\nnot output\n```\n")

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "page.md:3: a bare ``` block renders as output, and nothing checks it"
    end
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
            use ExTLA.Spec
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
            use ExTLA.Spec
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

  describe "the real pages" do
    # Written before any guide existed (#95), so the gate was wired before the prose -- nobody
    # retrofits a gate to a guide that already passes. It now covers getting-started (#96),
    # every page of the tutorial (#97, #99), and since #281 all of `spec/` and `README.md`.
    test "every page tells the truth" do
      pages = GuideCheck.pages()

      failures =
        Enum.flat_map(pages, fn page -> GuideCheck.check(page, with_env: &with_env/2) end)

      assert failures == [],
             "pages make claims the code does not support:\n\n" <> Enum.join(failures, "\n")
    end

    # Anti-vacuity. The test above passes on an empty list, and the list is a glob — one
    # wrong path and it checks nothing while reporting green, which is the failure shape
    # #164's layer 2 had. The counts are lower bounds rather than equalities so that adding
    # a page does not fail an unrelated build; what they catch is a glob that stopped
    # matching.
    test "and the pages are actually found, in all three trees" do
      pages = GuideCheck.pages()

      assert "guides/getting-started.md" in pages
      assert "spec/02-dsl-semantics.md" in pages
      assert "README.md" in pages

      blocks = Enum.flat_map(pages, &GuideCheck.blocks/1)

      assert length(pages) >= 18
      assert length(blocks) >= 100, "only #{length(blocks)} blocks found; the glob is wrong"
    end

    # `spec/` is the half #281 added, and the one whose blocks are mostly NOT compiled —
    # they are API sketches another gate owns. "Nothing compiles this" and "something else
    # gates this" are different facts, and this asserts the second is what is written down:
    # every block in `spec/` and `README.md` is annotated, one way or the other.
    test "every block in spec/ and README.md is compiled or skipped with a reason" do
      unannotated =
        for path <- GuideCheck.pages(),
            String.starts_with?(path, "spec/") or path == "README.md",
            {annotation, _code, line} <- GuideCheck.blocks(path),
            annotation.kind in [:none, :bad_fence] or
              (annotation.kind == :skip and annotation[:reason] in [nil, ""]),
            do: "#{path}:#{line} — #{annotation.kind}"

      assert unannotated == [], """
      #{length(unannotated)} blocks in the specification are neither compiled nor skipped
      with a reason:

        #{Enum.join(unannotated, "\n  ")}
      """
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

    # `assert guides == Enum.sort(guides)` is what stood here, and `Path.wildcard` already
    # returns sorted paths — so deleting the production `Enum.sort` left it green (#175).
    # The order is a DEPENDENCY (a page may use a module an earlier page compiled), so what
    # has to be asserted is the order, against a list this test builds itself.
    test "guides/0 returns the tree sorted, so the tutorial is in reading order" do
      guides = GuideCheck.guides()

      assert guides == Enum.sort(guides)

      tutorial_order =
        guides
        |> Enum.filter(&String.starts_with?(&1, "guides/tutorial/"))
        |> Enum.map(&Path.basename/1)

      assert tutorial_order == Enum.sort(tutorial_order)
      assert List.first(tutorial_order) == "00-introduction.md"
      assert List.last(tutorial_order) == "10-in-your-project.md"
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
            use ExTLA.Spec
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

    # #215, enforced by #281. "An unannotated block is an unchecked claim" is the rule one
    # test up, and a reasonless skip is an unchecked claim wearing an annotation.
    test "a skip with no reason is rejected", %{tmp_dir: tmp} do
      path = guide(tmp, block("tla:skip", ":whatever\n"))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "tla:skip needs a reason"
    end

    test "and an empty reason is the same thing", %{tmp_dir: tmp} do
      path = guide(tmp, block(~s(tla:skip reason=""), ":whatever\n"))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "needs a reason"
    end

    # A reason is a sentence, and the value scanner reads one token: `reason=a shell
    # invocation, and the timing is from this machine` was parsed as "a". Nothing failed,
    # because until #281 nothing asked what a reason SAID — and a rule that reads one word
    # of it would accept `reason=x` for anything.
    test "a reason runs to the end of the annotation, spaces and all", %{tmp_dir: tmp} do
      reason = "an API sketch, gated by spec_api_test"
      path = guide(tmp, block("tla:skip reason=#{reason}", ":whatever\n"))

      assert [{annotation, _code, _line}] = GuideCheck.blocks(path)
      assert annotation[:reason] == reason
      assert GuideCheck.check(path) == []
    end

    test "a comment that is not on the line before the fence does not annotate it",
         %{tmp_dir: tmp} do
      path = guide(tmp, "<!-- tla:skip reason=too-far-away -->\n\n```elixir\n:unclaimed\n```\n")

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "unchecked claim"
    end
  end

  describe "tla:deps holds an install instruction to the release record" do
    # The directive #154 asked for: "a block that is not a spec but is still checkable".
    # The install snippet was `tla:skip reason=a mix.exs fragment, not a spec` — true, and
    # taken to mean not checkable, and it then read `tag: "v0.1.0"` against a release of
    # v0.3.20 for a fortnight, in documentation that ships in the package.
    @public_git Mix.Project.config()[:source_url] <> ".git"

    defp deps_block(tag, url \\ @public_git) do
      block("tla:deps", """
      def deps do
        [
          {:extla, git: "#{url}", tag: "#{tag}"}
        ]
      end
      """)
    end

    defp newest_release do
      [_match, version] = Regex.run(~r/^## \[(\d+\.\d+\.\d+)\]/m, File.read!("CHANGELOG.md"))
      version
    end

    test "accepts the tag that matches CHANGELOG.md's newest release", %{tmp_dir: tmp} do
      path = guide(tmp, deps_block("v" <> newest_release()))

      assert GuideCheck.check(path) == []
    end

    # The failure this exists for, in the shape it actually took.
    test "rejects a tag from an older release", %{tmp_dir: tmp} do
      path = guide(tmp, deps_block("v0.1.0"))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ ~s(documents "v0.1.0")
      assert failure =~ "newest release in CHANGELOG.md is v#{newest_release()}"
    end

    test "and a tag from a release that does not exist yet", %{tmp_dir: tmp} do
      path = guide(tmp, deps_block("v99.0.0"))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ ~s(documents "v99.0.0")
    end

    # The install line has to be one a public reader can follow (#402). It pointed at the
    # private instance where day-to-day work happens until v0.5.0.
    test "rejects an install URL other than the package's source_url", %{tmp_dir: tmp} do
      private = "https://gitlab.conet.yarina.org/dco-tek/extla.git"
      path = guide(tmp, deps_block("v" <> newest_release(), private))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ ~s(installs from "#{private}")
      assert failure =~ @public_git
    end

    test "a block with no extla dependency says so rather than passing", %{tmp_dir: tmp} do
      path =
        guide(
          tmp,
          block("tla:deps", "def deps do\n  [{:jason, \"~> 1.4\"}]\nend\n")
        )

      assert [failure] = GuideCheck.check(path)
      assert failure =~ ~s(no `{:extla, "~> …"}` or `{:extla, …, tag:)
    end

    # The install is from Hex since #424, and the requirement is held to the same record.
    defp hex_block(requirement),
      do: block("tla:deps", "def deps do\n  [{:extla, #{inspect(requirement)}}]\nend\n")

    defp newest_line do
      version = Version.parse!(newest_release())
      "#{version.major}.#{version.minor}"
    end

    test "accepts a Hex requirement on the newest release's line", %{tmp_dir: tmp} do
      path = guide(tmp, hex_block("~> #{newest_line()}.0"))

      assert GuideCheck.check(path) == []
    end

    test "rejects a requirement on an older line", %{tmp_dir: tmp} do
      path = guide(tmp, hex_block("~> 0.1.0"))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ ~s(requires "~> 0.1.0")
      assert failure =~ "newest release in CHANGELOG.md is v#{newest_release()}"
    end

    # `~> 0.6` admits 0.7, and before 1.0 a minor may break the interface.
    test "rejects a two-part requirement, which would admit the next minor", %{tmp_dir: tmp} do
      path = guide(tmp, hex_block("~> #{newest_line()}"))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "three parts"
    end

    test "rejects a requirement the newest release does not satisfy", %{tmp_dir: tmp} do
      path = guide(tmp, hex_block("~> #{newest_line()}.99"))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ ~s(requires "~> #{newest_line()}.99")
    end

    test "and one that does not parse is a finding, not a crash", %{tmp_dir: tmp} do
      path = guide(tmp, block("tla:deps", "def deps do\n  [{:extla,\nend\n"))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "does not parse"
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
