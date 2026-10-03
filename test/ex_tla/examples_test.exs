defmodule ExTLA.ExamplesTest do
  @moduledoc """
  The generator that makes `spec/07-examples.md`'s "verbatim" claim true by construction
  (#280).

  The claim was in three corpus moduledocs — "Example N verbatim, which is the point: the
  corpus checks the documentation, not a paraphrase of it" — and D-21 falsified all three
  forty-three minutes later by rewriting the corpus's types and leaving the page. These
  tests are about the machinery; that the *page* is now right is asserted by the
  differential corpus itself, which runs the generated specs against TLC's `expected.json`.
  """
  use ExUnit.Case, async: true

  alias ExTLA.Examples

  @root Path.expand("../..", __DIR__)

  describe "the fence" do
    test "is located by the module it declares, not by a line number" do
      body = Examples.fence!(File.read!(Examples.page(@root)), Specs.DistributedLock)

      assert body =~ "use ExTLA.Spec"
      assert body =~ "constant :processes"
      refute body =~ "defmodule"
      refute body =~ "Specs.RaftElection"
    end

    test "and a module the page does not declare is an error naming the page" do
      error =
        assert_raise ArgumentError, fn ->
          Examples.fence!(File.read!(Examples.page(@root)), Specs.NotOnThePage)
        end

      assert Exception.message(error) =~ "has no ```elixir block defining"
      assert Exception.message(error) =~ "Specs.NotOnThePage"
    end

    # The reader walks fences by their opening line, so a non-elixir block — `spec/07` has
    # several holding shell output — must not be mistaken for one.
    test "reader skips blocks that are not elixir" do
      markdown = """
      ```
      $ mix extla.check Specs.NotAFence
      defmodule Specs.NotAFence do
      ```

      ```elixir
      defmodule Specs.RealFence do
        use ExTLA.Spec
      end
      ```
      """

      assert Examples.fence!(markdown, Specs.RealFence) == "  use ExTLA.Spec"
    end
  end

  describe "every generated entry" do
    test "is byte-identical to the file in the tree" do
      for entry <- Examples.entries(@root) do
        assert File.read!(entry.path) == Examples.render(entry, @root),
               "#{entry.name} has drifted from the page. Regenerate: mix extla.examples --write"
      end
    end

    test "says it is generated, and from where" do
      for entry <- Examples.entries(@root) do
        source = File.read!(entry.path)

        assert source =~ "Generated from spec/07-examples.md Example #{entry.example}"
        assert source =~ "do not edit"
        assert source =~ "mix extla.examples --write"
      end
    end

    test "declares the module the corpus names, not the page's" do
      for entry <- Examples.entries(@root) do
        assert File.read!(entry.path) =~ "defmodule #{inspect(entry.module)} do"
      end
    end
  end

  describe "the constants the generator supplies" do
    # The one place the generated file is NOT the page, so it is the one place two models
    # could diverge: the ledger resolves a spec through its `default:`, and the corpus runs
    # it against the constants TLC was given. Different values would mean `TLA_COVERAGE.md`
    # reporting on a model the oracle never saw.
    test "are the constants the differential corpus runs against" do
      corpus =
        @root
        |> Path.join("test/differential/differential_test.exs")
        |> File.read!()
        |> Code.string_to_quoted!()
        |> entries_ast()

      for entry <- Examples.entries(@root) do
        generated = Map.new(entry.constants, fn {name, ast} -> {name, Macro.to_string(ast)} end)

        assert generated == Map.fetch!(corpus, entry.name),
               "#{entry.name}: the ledger's defaults and the corpus's constants differ, so " <>
                 "the two are checking different models"
      end
    end
  end

  # `entries = [%{name: "...", constants: %{...}}, ...]` from the corpus table, as
  # `%{name => %{constant => source}}`. Read from the AST rather than by importing the
  # file, because the file is an ExUnit script that defines modules when loaded.
  defp entries_ast(ast) do
    {_ast, found} =
      Macro.prewalk(ast, %{}, fn
        {:%{}, _, pairs} = node, acc when is_list(pairs) ->
          with {:ok, name} <- Keyword.fetch(pairs, :name),
               true <- is_binary(name),
               {:ok, {:%{}, _, constants}} <- Keyword.fetch(pairs, :constants) do
            {node,
             Map.put(acc, name, Map.new(constants, fn {k, v} -> {k, Macro.to_string(v)} end))}
          else
            _other -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end
end
