defmodule ExTLA.SpecVersionStampTest do
  @moduledoc """
  `use ExTLA.GenServer, spec_version:` — the compile-time staleness check (#67).

  This closes #1's failure mode 2, which is the sharpest of the three. A refinement mapping is
  written against a set of spec variables; rename one and `abstract_action/1` still compiles
  and still returns an action name. The mapping is wrong, and the only symptom is a
  `:diverged` at runtime on a path that may not run for months.

  Compile time is the right moment to complain because it is the only moment the author is
  present with the context to re-confirm.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @spec_module ExTLA.Conformance.Counter.Spec
  @refinement ExTLA.Conformance.Counter.Refinement

  defp compile(stamp_line) do
    name = "Stamped#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{name} do
      use GenServer

      use ExTLA.GenServer,
        spec: #{inspect(@spec_module)},
        refinement: #{inspect(@refinement)}#{stamp_line}

      def init(arg), do: {:ok, arg}
    end
    """)
  end

  defp current, do: ExTLA.Spec.Hash.module_version(@spec_module)

  describe "the stamp is opt-in" do
    # A mechanism that forced every mapping to carry a hash on day one would be adopted by
    # pasting hashes, which is the failure it exists to prevent.
    test "a mapping with no spec_version compiles exactly as before" do
      assert [_ | _] =
               capture_io(:stderr, fn -> send(self(), compile("")) end) && receive_modules()
    end

    test "and reports itself unstamped rather than fresh" do
      states = Mix.Tasks.Extla.Stamp.states()

      unstamped = Enum.filter(states, &(&1.status == :unstamped))

      assert unstamped != [], "the corpus keeps unstamped mappings on purpose"
    end
  end

  describe "a matching stamp" do
    test "compiles" do
      capture_io(:stderr, fn ->
        send(self(), compile(",\n    spec_version: #{inspect(current())}"))
      end)

      assert [_ | _] = receive_modules()
    end
  end

  describe "a moved spec version" do
    test "is a compile error" do
      assert_raise ExTLA.Spec.CompileError, fn ->
        capture_io(:stderr, fn -> compile(",\n    spec_version: \"deadbeef\"") end)
      end
    end

    # The message has to be actionable on its own: someone reading a build log must be able to
    # tell what moved and what to do, without re-deriving the hash by hand.
    test "and the message names both versions" do
      error =
        assert_raise ExTLA.Spec.CompileError, fn ->
          capture_io(:stderr, fn -> compile(",\n    spec_version: \"deadbeef\"") end)
        end

      assert error.message =~ "deadbeef"
      assert error.message =~ current()
    end

    # The one thing the message must NOT do is invite a blind fix. A stamp applied without
    # re-reading manufactures assurance, which is worse than having no stamp.
    test "and tells the reader to re-read the mapping, not just to paste the new hash" do
      error =
        assert_raise ExTLA.Spec.CompileError, fn ->
          capture_io(:stderr, fn -> compile(",\n    spec_version: \"deadbeef\"") end)
        end

      assert error.message =~ "RE-READ"
      assert error.message =~ "not a way to skip it"
    end
  end

  describe "the corpus exercises the mechanism" do
    test "Conforming carries a stamp, and it is fresh" do
      state =
        Mix.Tasks.Extla.Stamp.states()
        |> Enum.find(&(&1.module == ExTLA.Conformance.Counter.Impl.Conforming))

      assert state.status == :fresh
      assert state.stamp == current()
    end

    # The bug that made this test necessary: `item_versions/1` scanned the whole FILE, so two
    # specs sharing a file shared a version — and editing one would have marked mappings
    # stamped against the other stale, for no change.
    test "two specs in one file have different versions" do
      refute ExTLA.Spec.Hash.module_version(ExTLA.Conformance.Counter.Spec) ==
               ExTLA.Spec.Hash.module_version(ExTLA.Conformance.Counter.BuggySpec)
    end
  end

  describe "mix extla.stamp reads source, not loaded modules" do
    # A stale stamp is a compile error, so a task needing the project to compile before it
    # could report or fix one would be useless in the only situation it is for.
    test "states/0 answers without the project being loaded" do
      states = Mix.Tasks.Extla.Stamp.states()

      assert states != []
      assert Enum.all?(states, &(&1.status in [:fresh, :stale, :unstamped, :unverifiable]))
      assert Enum.all?(states, &is_binary(&1.path))
    end

    test "the index resolves nested and dotted module names alike" do
      index = Mix.Tasks.Extla.Stamp.module_index()

      assert Map.has_key?(index, ExTLA.Conformance.Counter.Spec)
      assert Map.has_key?(index, ExTLA.Conformance.Counter.Impl.Conforming)
    end
  end

  defp receive_modules do
    receive do
      modules when is_list(modules) -> modules
    after
      0 -> []
    end
  end
end
