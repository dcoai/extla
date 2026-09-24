defmodule TLA.StampTest do
  @moduledoc """
  `mix tla.stamp` end to end, over a tree with all four statuses (#308, for #173).

  ## What was not covered

  It is the only code in the project that rewrites files under `lib/`, and it was the least
  covered thing in it. **Replacing `run/1`'s entire body with a raise left the full suite
  green**: the tests called `states/0` and `module_index/0` and nothing else, and there is no
  CI job.

  Two of its four statuses had **never executed**. The real corpus holds only fresh and
  unstamped mappings, so collapsing `:stale` and `:unverifiable` into `:fresh` stayed green,
  and the coverage gate did not move because the golden records `stale 0`. Dead with them:
  both `detail/1` clauses, the "N stale" report, and the documented stale-wins-over-fresh
  precedence. The code's own comment states the stakes — *"folding it into `fresh` would
  report it as verified"*.

  ## Why the fixture is outside every scanned tree

  A genuinely stale stamp in a compiled tree is a **compile error** — that is what the
  mechanism is for — so the corpus cannot hold one, and a stale stamp anywhere
  `Mix.Tasks.Tla.Stamp.roots/0` scans would put the repository's own report permanently in
  the red. `test/fixtures/stamp/README.md` has the rest; `run/2` and `states/1` take the
  roots for exactly this.
  """

  # `async: false`, and `Mix.shell/1` is why: it is VM-global, and
  # `test/mix/tla_coverage_test.exs` swaps it to `Mix.Shell.Process` in its own setup. Run
  # concurrently with that, `capture_io/1` here sees an empty string and the report tests
  # fail for a reason that has nothing to do with the report. Every other Mix task test in
  # this directory that reads shell output is `async: false` and pins the shell in setup;
  # this one was not, and it flaked once before it was.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Tla.Stamp

  setup do
    Mix.shell(Mix.Shell.IO)
    :ok
  end

  @root Path.expand("../..", __DIR__)

  # Both, and the second is not incidental: a mapping's status depends on finding its spec's
  # source, so with the fixture alone every entry is `:unverifiable` for want of the spec —
  # a fact about the roots rather than about the mappings.
  @roots ["test/fixtures/stamp", "test/conformance"]

  defp states, do: Stamp.states(@roots)

  defp status_of(module), do: Enum.find(states(), &(&1.module == module)).status

  describe "the fixture tree" do
    test "produces all four statuses" do
      found = states() |> Enum.map(& &1.status) |> Enum.uniq() |> Enum.sort()

      assert found == [:fresh, :stale, :unstamped, :unverifiable]
    end

    test "and each one for the reason it was written for" do
      assert status_of(StampFixture.Stale.First) == :stale
      assert status_of(StampFixture.Stale.Second) == :stale
      assert status_of(StampFixture.StaleDistinct.First) == :stale
      assert status_of(StampFixture.Unstamped) == :unstamped
      assert status_of(StampFixture.Unverifiable) == :unverifiable
      assert Enum.find(states(), &(&1.module == StampFixture.Unverifiable)).current == nil
      assert status_of(TLA.Conformance.Counter.Impl.Conforming) == :fresh
    end

    # The two stale files carry different SHAPES of staleness, and the distinction is what
    # #310 turns on: two mappings sharing one stamp, versus two carrying different ones.
    test "and the shared-stamp file really does share one" do
      [first, second] =
        states()
        |> Enum.filter(&(&1.module in [StampFixture.Stale.First, StampFixture.Stale.Second]))

      assert first.stamp == second.stamp
      assert first.path == second.path
    end

    test "and the distinct-stamp file really does not" do
      [first, second] =
        states()
        |> Enum.filter(
          &(&1.module in [StampFixture.StaleDistinct.First, StampFixture.StaleDistinct.Second])
        )

      assert first.stamp != second.stamp
      assert first.path == second.path
    end

    # The fixture is inert by construction, and that is load-bearing rather than tidy: a
    # stale stamp in a compiled tree is a compile error, and one in a scanned tree would put
    # `mix tla.stamp` permanently in the red for this repository.
    test "and is not in any tree the task scans by default" do
      scanned = Stamp.sources()

      refute Enum.any?(scanned, &String.starts_with?(&1, "test/fixtures/")),
             "the fixture is on the default roots, so this repository's own `mix tla.stamp` " <>
               "reports a stale stamp that is not a finding about it"
    end

    # `Mix.Project.config()` only answers for the env this suite runs in, so the claim
    # "in no environment" is checked against `mix.exs` itself. A stale stamp in a compiled
    # tree is a compile error, which is what the mechanism is for.
    test "and is not compiled in any environment" do
      mix_exs = @root |> Path.join("mix.exs") |> File.read!()

      clauses = Regex.scan(~r/defp elixirc_paths\(.*?\),?\s*\n?\s*do: (\[.*?\])/s, mix_exs)

      assert length(clauses) >= 3, "mix.exs yielded #{length(clauses)} elixirc_paths clauses"

      for [_match, paths] <- clauses do
        refute paths =~ "fixtures",
               "an elixirc_paths clause compiles the fixture tree: #{paths}"
      end
    end
  end

  describe "the report" do
    test "names every status it found" do
      output = capture_io(fn -> Stamp.run([], @roots) end)

      for status <- ~w(fresh stale unstamped unverifiable) do
        assert output =~ status, "the report never says #{status}"
      end
    end

    # The detail clauses, both of which were reached by nothing.
    test "and shows a stale mapping's stamp beside the current one" do
      output = capture_io(fn -> Stamp.run([], @roots) end)

      assert output =~ "00000000 →",
             "a stale entry does not show `<stamp> → <current>`: #{output}"
    end

    test "and says why an unverifiable one could not be checked" do
      output = capture_io(fn -> Stamp.run([], @roots) end)

      assert output =~ "(spec source not found)"
    end

    # #173's defect 4, fixed at #310. It used to be dropped before `state/2` saw it, so the
    # task could report "no refinement mappings found" about a file it had read and could
    # not understand -- *cannot be checked* collapsed into *absent*.
    test "and a mapping whose spec: is not a literal alias is reported, not dropped" do
      assert status_of(StampFixture.Dropped) == :unverifiable
    end

    # Two ways to be unverifiable, and they call for different fixes: a missing source file,
    # versus a `spec:` this task cannot read without compiling. Reporting only the status
    # would send a reader looking for the wrong thing.
    test "and says which of the two kinds of unverifiable it is" do
      output = capture_io(fn -> Stamp.run([], @roots) end)

      assert output =~ "(spec source not found)"
      assert output =~ "(spec: is not a literal alias"
    end

    # Anti-vacuity for both: a task that found no mappings at all would satisfy neither of
    # the status assertions above by accident, but it would satisfy a weaker version of them.
    test "and never says it found nothing about a tree that has mappings" do
      output = capture_io(fn -> Stamp.run([], @roots) end)

      refute output =~ "no refinement mappings found"
      assert length(states()) > 5
    end

    # `run/1` against the real project, so replacing its body with a raise reddens the suite
    # whatever the fixture does. This is the measurement that found the gap.
    test "and runs against this project's own sources" do
      output = capture_io(fn -> Stamp.run([]) end)

      assert output =~ "TLA.Conformance.Counter.Impl.Conforming"
      assert output =~ "fresh"
    end
  end

  describe "the roots" do
    # The hardcoded `["lib", "test", "ledger"]` is gone: `ledger` is a directory of THIS
    # repository, and a consumer running the task got it scanned along with their whole test
    # tree. `elixirc_paths` is the project's own answer to "where is my code".
    test "come from the project's elixirc_paths, with lib as a floor" do
      assert "lib" in Stamp.roots()

      for path <- Mix.Project.config()[:elixirc_paths] do
        assert path in Stamp.roots()
      end
    end

    test "and scanning them finds the mappings this repository has" do
      modules = Stamp.states() |> Enum.map(& &1.module)

      assert TLA.Conformance.Counter.Impl.Conforming in modules
      refute StampFixture.Stale.First in modules
    end
  end

  describe "the fixture's own integrity" do
    # A test that let `--restamp` rewrite these files would pass once and then test a tree
    # with no stale stamp in it. Nothing here rewrites them; this asserts it stays that way.
    test "the stale stamps on disk are the ones this file expects" do
      stale = File.read!(Path.join(@root, "test/fixtures/stamp/stale.ex"))
      distinct = File.read!(Path.join(@root, "test/fixtures/stamp/stale_distinct.ex"))

      assert stale =~ ~s(spec_version: "00000000")
      assert distinct =~ ~s(spec_version: "11111111")
      assert distinct =~ ~s(spec_version: "22222222")

      # And none of them can become current by accident when the spec moves.
      current = TLA.Spec.Hash.module_version(TLA.Conformance.Counter.Spec)
      refute current in ~w(00000000 11111111 22222222 33333333)
    end
  end

  # ── --restamp ───────────────────────────────────────────────────────────────

  describe "--restamp" do
    @describetag :tmp_dir

    # ON A COPY, always. `--restamp` rewrites source in place, and a test that let it rewrite
    # the committed fixture would pass once and then run forever against a tree with no stale
    # stamp in it — the shape of green that means nothing. `the fixture's own integrity`
    # above is the other half of that guarantee.
    setup %{tmp_dir: tmp} do
      copy = Path.join(tmp, "stamp")
      File.cp_r!(Path.join(@root, "test/fixtures/stamp"), copy)

      # Driven with the real conformance tree beside it, so the specs resolve.
      %{roots: [copy, Path.join(@root, "test/conformance")], copy: copy}
    end

    defp copied(copy, name), do: copy |> Path.join(name) |> File.read!()

    defp current_version, do: TLA.Spec.Hash.module_version(TLA.Conformance.Counter.Spec)

    defp occurrences(source, stamp) do
      source |> String.split(~s(spec_version: "#{stamp}")) |> length() |> Kernel.-(1)
    end

    # The defect. `String.replace/3` replaces every occurrence by design, so the first call
    # fixed both mappings and the second found nothing — `Mix.raise` then told the user to
    # hand-edit something already done.
    test "rewrites two mappings sharing one stamp in a single pass", ctx do
      capture_io(fn -> Stamp.run(["--restamp"], ctx.roots) end)

      after_ = copied(ctx.copy, "stale.ex")

      assert occurrences(after_, "00000000") == 0
      assert occurrences(after_, current_version()) == 2
    end

    # And it does not abort. The crash took every later file with it, which is most of the
    # damage it did: one bad file left the rest of the project unstamped.
    test "and goes on to the next file", ctx do
      capture_io(fn -> Stamp.run(["--restamp"], ctx.roots) end)

      after_ = copied(ctx.copy, "stale_distinct.ex")

      assert occurrences(after_, "11111111") == 0
      assert occurrences(after_, "22222222") == 0
      assert occurrences(after_, current_version()) == 2
    end

    test "and names every module it restamped, not every rewrite it made", ctx do
      output = capture_io(fn -> Stamp.run(["--restamp"], ctx.roots) end)

      for module <- ~w(Stale.First Stale.Second StaleDistinct.First StaleDistinct.Second) do
        assert output =~ "restamped StampFixture.#{module}"
      end
    end

    test "and leaves every mapping that is not stale alone", ctx do
      unstamped = copied(ctx.copy, "unstamped.ex")

      capture_io(fn -> Stamp.run(["--restamp"], ctx.roots) end)

      assert copied(ctx.copy, "unstamped.ex") == unstamped
      assert occurrences(copied(ctx.copy, "unverifiable.ex"), "33333333") == 1
      assert occurrences(copied(ctx.copy, "dropped.ex"), "44444444") == 1
    end

    test "and a second run has nothing to do", ctx do
      capture_io(fn -> Stamp.run(["--restamp"], ctx.roots) end)
      output = capture_io(fn -> Stamp.run(["--restamp"], ctx.roots) end)

      assert output =~ "nothing to restamp."
    end
  end

  describe "--restamp refuses rather than guessing" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      path = Path.join(tmp, "one.ex")
      File.write!(path, ~s(  use TLA.GenServer, spec_version: "aaaaaaaa"\n))
      %{path: path}
    end

    defp stale(path, opts) do
      %{
        module: Keyword.get(opts, :module, Fixture.One),
        path: path,
        stamp: Keyword.fetch!(opts, :stamp),
        current: Keyword.fetch!(opts, :current),
        status: :stale
      }
    end

    # The dedupe does not weaken the guard: a stamp that genuinely is not in the file is
    # still a fault, and still says which module to look at.
    test "when the stamp is not in the file at all", ctx do
      state = stale(ctx.path, stamp: "deadbeef", current: "cafebabe")

      assert_raise Mix.Error, ~r/does not contain spec_version: "deadbeef"/, fn ->
        capture_io(fn -> Stamp.restamp([state]) end)
      end
    end

    # The one case grouping by `{path, stamp}` could get wrong: two specs sharing an 8-hex
    # stamp in one file. Rewriting the group to either value would stamp a mapping against a
    # spec nobody read it against, which is the one thing `--restamp` must not do — the task
    # records a judgement rather than performing one.
    test "when two mappings share a stamp and resolve to different versions", ctx do
      group = [
        stale(ctx.path, module: Fixture.A, stamp: "aaaaaaaa", current: "11111111"),
        stale(ctx.path, module: Fixture.B, stamp: "aaaaaaaa", current: "22222222")
      ]

      assert_raise Mix.Error, ~r/resolve to different versions/, fn ->
        capture_io(fn -> Stamp.restamp(group) end)
      end

      # And it refused BEFORE writing, which is the part that matters.
      assert File.read!(ctx.path) =~ ~s(spec_version: "aaaaaaaa")
    end

    # Anti-vacuity for both: the same shape, without the fault, rewrites cleanly.
    test "but rewrites a group that agrees", ctx do
      group = [
        stale(ctx.path, module: Fixture.A, stamp: "aaaaaaaa", current: "33333333"),
        stale(ctx.path, module: Fixture.B, stamp: "aaaaaaaa", current: "33333333")
      ]

      capture_io(fn -> Stamp.restamp(group) end)

      assert File.read!(ctx.path) =~ ~s(spec_version: "33333333")
    end
  end

  # ── --check ─────────────────────────────────────────────────────────────────

  describe "--check" do
    @describetag :tmp_dir

    # A tree per case, so each test says exactly which mapping it is about. The conformance
    # tree comes along where a spec has to resolve.
    setup %{tmp_dir: tmp} do
      %{tmp: tmp, conformance: Path.join(@root, "test/conformance")}
    end

    defp mapping(tmp, name, opts) do
      dir = Path.join(tmp, name)
      File.mkdir_p!(dir)

      version = Keyword.get(opts, :stamp)
      stamp = if version, do: ",\n    spec_version: #{inspect(version)}", else: ""

      File.write!(Path.join(dir, "m.ex"), """
      defmodule CheckFixture.#{name} do
        use GenServer

        use TLA.GenServer,
          spec: #{Keyword.fetch!(opts, :spec)},
          refinement: TLA.Conformance.Counter.Refinement#{stamp}

        def init(a), do: {:ok, a}
      end
      """)

      dir
    end

    defp check(roots) do
      capture_io(fn ->
        assert catch_exit(Stamp.run(["--check"], roots)) == {:shutdown, 1}
      end)
    end

    defp check_passes(roots) do
      capture_io(fn -> assert Stamp.run(["--check"], roots) == :ok end)
    end

    test "exits 1 on a stale stamp", ctx do
      dir =
        mapping(ctx.tmp, "Stale", spec: "TLA.Conformance.Counter.Spec", stamp: "00000000")

      output = check([dir, ctx.conformance])

      assert output =~ "not verified by anything"
      assert output =~ "CheckFixture.Stale"
    end

    # Nothing checks this one: the task cannot find the source, and the compile-time check
    # only warns. It is the case `--check` exists for on a project that does not compile
    # with `--warnings-as-errors`.
    test "and on a stamp whose spec has no source here", ctx do
      dir = mapping(ctx.tmp, "NoSource", spec: "CheckFixture.NoSuchSpec", stamp: "00000000")

      output = check([dir, ctx.conformance])

      assert output =~ "CheckFixture.NoSource"
    end

    test "but exits 0 on a fresh stamp", ctx do
      current = TLA.Spec.Hash.module_version(TLA.Conformance.Counter.Spec)
      dir = mapping(ctx.tmp, "Fresh", spec: "TLA.Conformance.Counter.Spec", stamp: current)

      check_passes([dir, ctx.conformance])
    end

    # The stamp is opt-in. Failing on its absence would make it mandatory by the back door.
    test "and on an unstamped mapping", ctx do
      dir = mapping(ctx.tmp, "Unstamped", spec: "TLA.Conformance.Counter.Spec")

      check_passes([dir, ctx.conformance])
    end

    # THE ROW THAT LOOKS LIKE A FINDING AND IS NOT (D-37). This task cannot resolve an
    # attribute `spec:` without compiling, so it reports `:unverifiable` — but the compiler
    # verifies that stamp completely, which the next test measures rather than asserts by
    # assumption. Failing here would be a false finding about a fully checked mapping.
    test "and on a mapping whose spec: is an attribute, which the COMPILER verifies", ctx do
      dir = Path.join(ctx.tmp, "Attr")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "m.ex"), """
      defmodule CheckFixture.Attr do
        use GenServer
        @spec_mod TLA.Conformance.Counter.Spec

        use TLA.GenServer,
          spec: @spec_mod,
          refinement: TLA.Conformance.Counter.Refinement,
          spec_version: "00000000"

        def init(a), do: {:ok, a}
      end
      """)

      # The task cannot check it...
      assert [state] = Stamp.states([dir])
      assert state.status == :unverifiable
      assert state.reason == :spec_not_a_literal_alias

      # ...and `--check` does not fail on it, because something else does.
      check_passes([dir, ctx.conformance])
    end
  end

  describe "the compile-time check, which is why there is no CI job" do
    # D-37 rests on these two facts, so they are measured here rather than described. If
    # either stops being true, `--check`'s rule is wrong and so is the decision not to gate.
    test "raises on a stale stamp given as a literal alias" do
      assert_raise TLA.Spec.CompileError, ~r/is stamped against/, fn ->
        compile_mapping("TLA.Conformance.Counter.Spec", ~s("deadbeef"))
      end
    end

    # The row `--check` deliberately passes: an attribute `spec:` is resolved at expansion,
    # so the stamp IS verified — by the compiler, not by the task.
    test "and raises just the same when the spec: is an attribute" do
      assert_raise TLA.Spec.CompileError, ~r/is stamped against/, fn ->
        compile_mapping("@spec_mod", ~s("deadbeef"))
      end
    end

    # Anti-vacuity: the same shapes with a correct stamp compile, so the two above are
    # failing on the stamp rather than on anything else about the fixture.
    test "and compiles either shape with the current stamp" do
      current = inspect(TLA.Spec.Hash.module_version(TLA.Conformance.Counter.Spec))

      assert [_ | _] = compile_mapping("TLA.Conformance.Counter.Spec", current)
      assert [_ | _] = compile_mapping("@spec_mod", current)
    end

    defp compile_mapping(spec, stamp) do
      name = "CompileProbe#{System.unique_integer([:positive])}"

      Code.compile_string("""
      defmodule #{name} do
        use GenServer
        @spec_mod TLA.Conformance.Counter.Spec

        use TLA.GenServer,
          spec: #{spec},
          refinement: TLA.Conformance.Counter.Refinement,
          spec_version: #{stamp}

        def init(a), do: {:ok, a}
      end
      """)
    end
  end
end
