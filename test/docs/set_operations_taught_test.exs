defmodule ExTLA.SetOperationsTaughtTest do
  @moduledoc """
  The guides teach set **operations** wherever they teach set **types** (#320, for #183).

  ## The gap this closes

  `type: set(t)` told a reader that a variable can *be* a set. Nothing told them how to take
  a union of one. Neither `ExTLA.Set` nor `ExTLA.Function` was named anywhere in `guides/`,
  `README.md` or `usage-rules.md` — only in `spec/` — so the whole of TLA+'s set theory was
  reachable from a spec body (#319) and invisible to the reader who needed it. Anything past
  a map-keyed lock — a queue, a quorum, a set of messages in flight — had nothing to reach
  for and no signal that it existed.

  ## Two claims, and both are links between facts about the document

  1. **The page that introduces `set(t)` as a `type:` form is the page that teaches an
     operation on one.** Both halves are found rather than named: the page by the type form
     it introduces, the operations by the calls in its prose.

  2. **It names every operator a spec body reaches for sets and functions.** That list is
     derived from `lib/ex_tla/spec/helpers.ex`'s own `defdelegate`s — the façade D-38 describes
     — so an operator added to the vocabulary and not taught reddens here. This is the half
     that keeps the page from drifting back into types-only one function at a time.

  The blocks themselves are not this file's business: `ExTLA.GuideCheck` compiles them and
  asserts their verdicts, and an unannotated block is already red under #156's rule.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @helpers Path.join(@root, "lib/ex_tla/spec/helpers.ex")
  @external_resource @helpers

  # The type form whose page this is about. `02-dsl-semantics.md` §1.5 is the normative
  # list; the guide introduces it, and this finds the guide by the form rather than by name.
  @type_form "`set(t)`"

  # Four operations a reader needs the moment they have a set and a map-keyed lock is no
  # longer enough: combine two sets, ask whether one covers another, quantify over one, and
  # build a function over one.
  @headline ~w(union subset? exists? for_each)a

  defp guides do
    @root
    |> Path.join("guides/**/*.md")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&{Path.relative_to(&1, @root), File.read!(&1)})
  end

  defp pages_introducing_set_types,
    do: for({path, body} <- guides(), String.contains?(body, @type_form), do: path)

  defp page!(path) do
    {_, body} = Enum.find(guides(), &(elem(&1, 0) == path))
    body
  end

  # Every operator `ExTLA.Spec.Helpers` delegates to the foundation — the vocabulary D-38 made
  # reachable from a spec body, read from the façade's own AST rather than written here.
  defp delegated_operators do
    {_, names} =
      @helpers
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:defdelegate, _, [head | _]} = node, acc -> {node, [name_of(head) | acc]}
        node, acc -> {node, acc}
      end)

    names |> Enum.uniq() |> Enum.sort()
  end

  defp name_of({:when, _, [head | _]}), do: name_of(head)
  defp name_of({name, _, _}) when is_atom(name), do: name

  # Every `name(` inside backticks on the page — what the prose claims a reader can call.
  defp names_called(body), do: names_in(body, ~r/`([a-z_]+[a-z_0-9]*\??)\(/)

  # The same, but only inside the page's ```elixir fences — what the guide harness actually
  # compiles and runs. A table row is a claim; a block is a checked one, and §Operations has
  # to do the second.
  defp names_in_blocks(body) do
    ~r/^```elixir\n(.*?)^```$/ms
    |> Regex.scan(body)
    |> Enum.map_join("\n", fn [_, code] -> code end)
    |> names_in(~r/(?:^|[^.\w])([a-z_]+[a-z_0-9]*\??)\(/m)
  end

  defp names_in(text, pattern) do
    pattern
    |> Regex.scan(text)
    |> Enum.map(fn [_, name] -> String.to_atom(name) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  describe "the page that introduces a set type" do
    test "is found, and there is exactly one of it" do
      assert pages_introducing_set_types() == ["guides/tutorial/02-dsl.md"], """
      The page introducing #{@type_form} as a `type:` form moved, or a second one appeared.
      This file is about that page teaching an operation on a set; point it at the new one.
      """
    end

    test "teaches an operation on one, in a block the harness compiles" do
      [path] = pages_introducing_set_types()
      called = names_in_blocks(page!(path))

      assert called != [], "no ```elixir fences found on #{path}; the block reader is wrong"

      missing = Enum.reject(@headline, &(&1 in called))

      assert missing == [], """
      #{path} introduces #{@type_form} and no code block on it uses #{inspect(missing)}.

      That is the shape #183 was filed about: a reader learns a variable can BE a set and
      leaves without an operation to perform on one. A table row is a claim; the operation
      has to appear in a block `ExTLA.GuideCheck` compiles and asserts a verdict for, or the
      page can teach an operation that stopped working.
      """
    end

    test "names every operator a spec body reaches for sets and functions" do
      [path] = pages_introducing_set_types()
      called = names_called(page!(path))
      operators = delegated_operators()

      assert operators != [], "the façade's AST yielded no delegations; the reader is wrong"

      untaught = Enum.reject(operators, &(&1 in called))

      assert untaught == [], """
      #{length(untaught)} operators are reachable from a spec body and not named on #{path}:

        #{Enum.map_join(untaught, ", ", &to_string/1)}

      `ExTLA.Spec.Helpers` delegates each of these to `ExTLA.Set` or `ExTLA.Function` (D-38), so a
      spec author can call it unqualified — and will not, having never been told it exists.
      Add it to the table in §Operations on sets and functions.
      """
    end

    test "and every operator it names is one a spec body can actually call" do
      [path] = pages_introducing_set_types()
      reachable = MapSet.new(ExTLA.Spec.Helpers.__info__(:functions), &elem(&1, 0))

      # Names on the page that are neither a helper nor ordinary Elixir. The second list is
      # short on purpose: a page that drifts into teaching `Enum` as the DSL's vocabulary is
      # exactly what this catches.
      elixir = ~w(fn inspect length count all? any? filter map new size member?)a

      invented =
        path
        |> page!()
        |> names_called()
        |> Enum.reject(&(&1 in reachable or &1 in elixir))

      assert invented == [], """
      #{path} names #{inspect(invented)} as callable from a spec block, and
      `ExTLA.Spec.Helpers` does not export it. A reader gets `UndefinedFunctionError` on the
      first call.
      """
    end
  end
end
