defmodule TLA.Spec.VersionTest do
  @moduledoc """
  What a content version has to promise before a `Fresh` column or a `spec_version:` stamp can
  rest on it (#1, scope item 3).

  Two failure modes, opposite and equally fatal. A version that moves when nothing changed
  makes every edit restamp the items below it, and a ledger that cries wolf is one somebody
  switches off. A version that does NOT move when the definition changed silently blesses a
  stale verdict, which is the exact hole #1 exists to close.
  """

  use ExUnit.Case, async: true

  alias TLA.Spec.Version

  @spec_source """
  defmodule Sample do
    use TLA.Spec

    variable :n

    init do
      n = 0
    end

    action :tick do
      require n < 3
      n = n + 1
    end

    invariant :in_range, desc: "n stays bounded" do
      n >= 0 and n <= 3
    end
  end
  """

  defp version_of(source, item), do: source |> Version.scan() |> Map.get(item)

  describe "a version is a function of structure, not position" do
    test "a blank line above an item does not move it" do
      shifted = String.replace(@spec_source, "  action :tick do", "\n\n  action :tick do")

      assert version_of(shifted, {:action, :tick}) == version_of(@spec_source, {:action, :tick})
    end

    test "a comment inside a body does not move it" do
      commented =
        String.replace(@spec_source, "    require n < 3", "    # why\n    require n < 3")

      assert version_of(commented, {:action, :tick}) == version_of(@spec_source, {:action, :tick})
    end

    test "reindenting does not move it" do
      reindented = String.replace(@spec_source, "      n = n + 1", "        n = n + 1")

      assert version_of(reindented, {:action, :tick}) ==
               version_of(@spec_source, {:action, :tick})
    end

    # The reason position-insensitivity is required rather than merely nice: without it, an
    # edit at the top of a file restamps every item below it and the ledger reports drift
    # where there is none.
    test "editing one item leaves the others alone" do
      edited = String.replace(@spec_source, "require n < 3", "require n < 5")

      assert version_of(edited, {:invariant, :in_range}) ==
               version_of(@spec_source, {:invariant, :in_range})

      refute version_of(edited, {:action, :tick}) == version_of(@spec_source, {:action, :tick})
    end
  end

  describe "a version moves when the definition does" do
    test "changing a guard moves it" do
      changed = String.replace(@spec_source, "require n < 3", "require n < 4")

      refute version_of(changed, {:action, :tick}) == version_of(@spec_source, {:action, :tick})
    end

    test "changing a post-state moves it" do
      changed = String.replace(@spec_source, "n = n + 1", "n = n + 2")

      refute version_of(changed, {:action, :tick}) == version_of(@spec_source, {:action, :tick})
    end

    test "renaming an item gives the new name a different version" do
      renamed = String.replace(@spec_source, "action :tick do", "action :tock do")

      refute version_of(renamed, {:action, :tock}) == version_of(@spec_source, {:action, :tick})
    end

    test "two items with identical bodies but different names differ" do
      source = """
      defmodule Twins do
        use TLA.Spec
        action :left do
          n = n + 1
        end
        action :right do
          n = n + 1
        end
      end
      """

      versions = Version.scan(source)

      refute versions[{:action, :left}] == versions[{:action, :right}]
    end
  end

  describe "shape and agreement" do
    test "is 8 lowercase hex" do
      for {_item, v} <- Version.scan(@spec_source) do
        assert v =~ ~r/^[0-9a-f]{8}$/
      end
    end

    test "is stable across repeated scans" do
      assert Version.scan(@spec_source) == Version.scan(@spec_source)
    end

    # The cross-project claim. agentronic, extc and ExTLA all stamp rows with a "content
    # version", and that word is only worth anything if the three compute the same number.
    # A divergence must fail here, not surface later as a stamp that is wrong for no visible
    # reason.
    test "agrees with Surfex.SourceScan.definition_hash/1, the shared algorithm" do
      {:defmodule, _, _} = ast = Code.string_to_quoted!(@spec_source)

      {_, [action_node]} =
        Macro.prewalk(ast, [], fn
          {:action, _, [:tick | _]} = node, acc -> {node, [node | acc]}
          node, acc -> {node, acc}
        end)

      assert version_of(@spec_source, {:action, :tick}) ==
               Surfex.SourceScan.definition_hash(action_node)
    end
  end

  describe "what carries a version, and what does not" do
    test "every verified item kind is scanned" do
      versions = Version.scan(@spec_source)

      assert Map.has_key?(versions, {:action, :tick})
      assert Map.has_key?(versions, {:invariant, :in_range})
    end

    # `variable` and `init` are not independently verified, so there is no verdict for them to
    # go stale against. Versioning them would put rows in the ledger that no evidence column
    # could ever fill.
    test "declarations that carry no verdict are not versioned" do
      versions = Version.scan(@spec_source)

      refute Map.has_key?(versions, {:variable, :n})
      refute Enum.any?(Map.keys(versions), &match?({:init, _}, &1))
    end

    test "kinds/0 states exactly what is scanned" do
      kinds = Version.kinds()

      assert :action in kinds
      assert :invariant in kinds
      assert :temporal in kinds
      refute :variable in kinds
    end
  end

  describe "versions/1 against a real module" do
    test "reads the module's own source" do
      versions = Version.versions(TLA.Spec.VersionTest.Fixture)

      assert versions[{:action, :step}] =~ ~r/^[0-9a-f]{8}$/

      assert Version.version(TLA.Spec.VersionTest.Fixture, :action, :step) ==
               versions[{:action, :step}]
    end

    # A released consumer has no source on disk. "Cannot version this" is a different fact
    # from "this has no version", and the ledger renders it differently, so it must not raise.
    test "a module with no source on disk yields no versions rather than raising" do
      assert Version.versions(:erlang) == %{}
    end
  end

  defmodule Fixture do
    @moduledoc false
    use TLA.Spec

    variable :n

    init do
      n = 0
    end

    action :step do
      require n < 2
      n = n + 1
    end
  end
end
