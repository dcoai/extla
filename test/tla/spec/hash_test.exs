defmodule TLA.Spec.HashTest do
  @moduledoc """
  The shipped content hash (#67), and its agreement with surfex.

  The algorithm is `Surfex.SourceScan.definition_hash/1`'s, re-implemented here because this
  module ships from `lib/` to a consumer's compile and surfex is a dev/test dependency, which
  is not transitive. Two implementations of one algorithm, by design — and the conformance
  test below is what makes that safe. If it is ever deleted or excluded from the default run,
  the decision recorded on #67 is void: two implementations that agree only because both were
  written from the same paragraph will drift, and the symptom would be a stamp that is wrong
  for no visible reason.

  This is also the ledger's `Version` column (#201): there is no second, ledger-side
  implementation any more, so the tests that once lived beside one are here.
  """

  use ExUnit.Case, async: true

  alias TLA.Spec.Hash

  @definition """
  action :tick do
    require n < 3
    n = n + 1
  end
  """

  describe "definition_hash/1 is a function of structure, not position" do
    test "a blank line above does not change it" do
      assert Hash.definition_hash("\n\n" <> @definition) == Hash.definition_hash(@definition)
    end

    test "a comment inside the body does not change it" do
      with_comment = String.replace(@definition, "  require n < 3", "  # why\n  require n < 3")

      assert Hash.definition_hash(with_comment) == Hash.definition_hash(@definition)
    end

    test "but changing the body does" do
      changed = String.replace(@definition, "n = n + 1", "n = n + 2")

      refute Hash.definition_hash(changed) == Hash.definition_hash(@definition)
    end

    test "is 8 lowercase hex" do
      assert Hash.definition_hash(@definition) =~ ~r/^[0-9a-f]{8}$/
    end

    test "accepts a quoted node and a binary, and agrees on both" do
      quoted = Code.string_to_quoted!(@definition)

      assert Hash.definition_hash(quoted) == Hash.definition_hash(@definition)
    end
  end

  describe "module_version/1" do
    test "is 8 hex over a spec's items" do
      assert Hash.module_version(TLA.Conformance.Counter.Spec) =~ ~r/^[0-9a-f]{8}$/
    end

    test "is stable across calls" do
      assert Hash.module_version(TLA.Conformance.Counter.Spec) ==
               Hash.module_version(TLA.Conformance.Counter.Spec)
    end

    test "two different specs have different versions" do
      refute Hash.module_version(TLA.Conformance.Counter.Spec) ==
               Hash.module_version(TLA.Conformance.Counter.BuggySpec)
    end

    # Derived from item versions rather than file bytes, so reformatting a spec does not
    # invalidate every mapping written against it.
    test "is insensitive to formatting, being derived from item versions" do
      source = """
      defmodule VersionShape do
        use TLA.Spec
        action :a do
          n = 1
        end
        invariant :i do
          n >= 0
        end
      end
      """

      shifted = String.replace(source, "  action :a do", "\n  # a comment\n  action :a do")

      assert Hash.scan(shifted) == Hash.scan(source)
    end

    test "a module with no source on disk has no version" do
      assert Hash.module_version(:erlang) == nil
    end
  end

  describe "an item's version" do
    @sample """
    defmodule Sample do
      use TLA.Spec

      variable :n, type: 0..3

      init do
        n = 0
      end

      action :tick do
        require n < 3
        n = n + 1
      end

      invariant :in_range do
        n <= 3
      end
    end
    """

    # The reason position-insensitivity is required rather than merely nice: without it, an
    # edit at the top of a file restamps every item below it and the ledger reports drift
    # where there is none.
    test "editing one item leaves the others alone" do
      edited = String.replace(@sample, "require n < 3", "require n < 5")

      assert Hash.scan(edited)[{:invariant, :in_range}] ==
               Hash.scan(@sample)[{:invariant, :in_range}]

      refute Hash.scan(edited)[{:action, :tick}] == Hash.scan(@sample)[{:action, :tick}]
    end

    test "renaming an item gives the new name a different version" do
      renamed = String.replace(@sample, "action :tick do", "action :tock do")

      refute Hash.scan(renamed)[{:action, :tock}] == Hash.scan(@sample)[{:action, :tick}]
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

      versions = Hash.scan(source)

      refute versions[{:action, :left}] == versions[{:action, :right}]
    end

    # #201. The ledger's versions came from a scan of the whole FILE keyed by `{kind, name}`,
    # so two modules in one file that both declare `tick` — `test/support/specs.ex` has seven
    # — collapsed onto the last one's hash. Editing `Broken.tick` moved nothing; editing the
    # last `tick` in the file moved seven rows. The golden was stable while wrong.
    test "same-named items in different modules of one file have their own versions" do
      source = """
      defmodule Neighbours.First do
        use TLA.Spec
        action :tick do
          n = n + 1
        end
      end

      defmodule Neighbours.Second do
        use TLA.Spec
        action :tick do
          n = n + 2
        end
      end
      """

      first = Hash.scan(source, Neighbours.First)[{:action, :tick}]
      second = Hash.scan(source, Neighbours.Second)[{:action, :tick}]

      refute first == second
      assert first == Hash.definition_hash("action :tick do\n  n = n + 1\nend")
    end

    test "item_versions/1 reads the module's own source, scoped to the module" do
      versions = Hash.item_versions(TLA.TestSpecs.Broken)

      assert versions[{:action, :tick}] =~ ~r/^[0-9a-f]{8}$/

      refute versions[{:action, :tick}] ==
               Hash.item_versions(TLA.TestSpecs.Unbounded)[{:action, :tick}]
    end

    test "a module with no source on disk yields no versions rather than raising" do
      assert Hash.item_versions(:erlang) == %{}
    end
  end

  describe "what carries a version" do
    test "verified item kinds are scanned, declarations are not" do
      versions = Hash.scan(File.read!("test/conformance/counter/spec.ex"))

      assert Enum.any?(Map.keys(versions), &match?({:action, _}, &1))
      assert Enum.any?(Map.keys(versions), &match?({:invariant, _}, &1))
      refute Enum.any?(Map.keys(versions), &match?({:variable, _}, &1))
    end
  end

  # #194. The module version hashed the item kinds alone, so changing an `init` value, a
  # variable's `type:`, a constant's `default:` or the fairness kind produced the IDENTICAL
  # version — and a `spec_version:` stamp stayed fresh across every one of them. Seven
  # variants, each verified to leave the version unmoved before the fix.
  describe "module_version/2 moves on every declaration, not only the items" do
    @source """
    defmodule VersionMoves do
      use TLA.Spec

      constant :max, default: 3
      variable :n, type: 0..3
      variable :flag, type: [false, true]

      init do
        n = 0
        flag = false
      end

      action :bump do
        require n < ^max
        n = n + 1
      end

      temporal :eventually_max do
        eventually(n == ^max)
      end

      fairness(:weak, [:bump])
    end
    """

    @edits [
      init_value: {"    n = 0\n", "    n = 1\n"},
      variable_type: {"variable :n, type: 0..3", "variable :n, type: 0..4"},
      constant_default: {"constant :max, default: 3", "constant :max, default: 4"},
      fairness_kind: {"fairness(:weak, [:bump])", "fairness(:strong, [:bump])"},
      added_variable:
        {"  variable :flag, type: [false, true]\n",
         "  variable :flag, type: [false, true]\n  variable :extra, type: 0..1\n"},
      removed_variable: {"  variable :flag, type: [false, true]\n", ""},
      action_body: {"n = n + 1", "n = n + 2"}
    ]

    for {edit, {from, to}} <- @edits do
      test "#{edit} moves the module version" do
        {from, to} = unquote(Macro.escape({from, to}))
        edited = String.replace(@source, from, to)

        assert edited != @source, "the edit did not apply"

        refute Hash.module_version(edited, VersionMoves) ==
                 Hash.module_version(@source, VersionMoves),
               "#{unquote(edit)} left the module version unmoved"
      end
    end

    test "a comment and whitespace do not" do
      edited =
        @source
        |> String.replace("  init do", "\n  # the starting state\n  init do")
        |> String.replace("fairness(:weak, [:bump])", "fairness(  :weak,  [:bump]  )")

      assert Hash.module_version(edited, VersionMoves) ==
               Hash.module_version(@source, VersionMoves)
    end

    # Bounded buffer declares `fairness(:weak, …)` twice. A map keyed by `{kind, name}` would
    # keep one and lose the other, so removing the second would leave the version unmoved.
    test "a second fairness declaration of the same kind is not lost" do
      two =
        String.replace(
          @source,
          "fairness(:weak, [:bump])",
          "fairness(:weak, [:bump])\n  fairness(:weak, [:other])"
        )

      refute Hash.module_version(two, VersionMoves) == Hash.module_version(@source, VersionMoves)
    end

    test "a source that does not define the module has no version" do
      assert Hash.module_version(@source, SomethingElse) == nil
    end

    test "module_version/1 and module_version/2 agree on a spec on disk" do
      path = TLA.Conformance.Counter.Spec.module_info(:compile)[:source] |> List.to_string()

      assert Hash.module_version(TLA.Conformance.Counter.Spec) ==
               Hash.module_version(File.read!(path), TLA.Conformance.Counter.Spec)
    end

    # `kinds/0` ++ `declarations/0` must be every declaration macro the DSL has. A macro added
    # to the DSL and to neither list would be a declaration the module version is blind to,
    # which is the defect this describe block exists to close — so the check enumerates the
    # DSL's macros rather than repeating a list.
    test "kinds/0 and declarations/0 together are every DSL declaration macro" do
      dsl_macros =
        TLA.Spec.DSL.__info__(:macros)
        |> Enum.map(fn {name, _arity} -> name end)
        |> Enum.uniq()
        |> Enum.sort()

      assert Enum.sort(Hash.kinds() ++ Hash.declarations()) == dsl_macros
    end
  end

  describe "conformance with surfex — the test that makes two implementations safe" do
    # Per item, over every spec source in the corpus. A per-item comparison localises a
    # divergence to the construct that caused it; comparing only module versions would say
    # "these disagree" and leave the reason to be found by hand.
    test "the shipped hash and Surfex.SourceScan.definition_hash/1 agree everywhere" do
      sources =
        Path.wildcard("test/**/*.ex") ++
          Path.wildcard("lib/**/*.ex") ++ Path.wildcard("specs/**/*.ex")

      compared =
        for path <- sources,
            source = File.read!(path),
            {item, shipped} <- Hash.scan(source),
            reduce: 0 do
          count ->
            {_, [node]} = locate(source, item)

            assert shipped == Surfex.SourceScan.definition_hash(node),
                   "#{path} #{inspect(item)}: shipped #{shipped} vs surfex " <>
                     "#{Surfex.SourceScan.definition_hash(node)}"

            count + 1
        end

      assert compared > 50, "the corpus should offer a substantial sample, got #{compared}"
    end
  end

  # The AST node `Hash.scan/1` hashed for a given item, so the two implementations are compared
  # on identical input rather than on their own idea of what the item is.
  defp locate(source, {kind, name}) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {^kind, _, [^name | _]} = node, acc -> {node, [node | acc]}
      node, acc -> {node, acc}
    end)
    |> then(fn {ast, nodes} -> {ast, [List.last(nodes)]} end)
  end
end
