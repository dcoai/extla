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

    # #173's defect 4, recorded rather than merely happening. `spec_of/1` returns `nil` for
    # a `spec:` that is not a literal alias and `mappings/1` rejects the entry, so the
    # mapping never reaches `state/2` to be given ANY status -- *cannot be checked*
    # collapsed into *absent*, which the four-status design exists to prevent.
    #
    # **#310 fixes this, and this assertion is what fails when it does.** That is the
    # intent: the wrong behaviour is pinned so that changing it is deliberate.
    test "and a mapping whose spec: is not a literal alias is SILENTLY DROPPED (#310)" do
      modules = Enum.map(states(), & &1.module)

      refute StampFixture.Dropped in modules,
             """
             `StampFixture.Dropped` now has a status, so #310 has landed. Replace this test
             with one asserting which status it gets, and say in `dropped.ex` that it is no
             longer dropped.
             """

      # And it is a real file the task really read, not a name nobody parsed -- otherwise
      # this test would pass for a fixture that does not exist.
      assert StampFixture.Dropped in Map.keys(Stamp.module_index(@roots))
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
end
