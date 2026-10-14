defmodule ExTLA.OptionsDocTest do
  @moduledoc """
  `run/2`'s rendered Options list every config key, with the default the code uses (#407, for
  #399).

  ## What was wrong

  `ExTLA.ModelChecker.run/2` and `ExTLA.Simulation.run/2` take a config map whose keys were
  documented only in comments inside `@type config`, which ExDoc does not render. A user had
  to read the source to learn that `max_states:` exists, that it defaults to a million, or that
  liveness is off unless asked for.

  ## What this holds

  Three things that can each drift on their own: the `@type config` keys, the `@defaults`
  values, and the `## Options` section of `run/2`'s `@doc`. Every typed key is documented and
  every documented key is typed; and where the code has a default, the documented one
  evaluates to the same term.
  """
  use ExUnit.Case, async: true

  @modules [ExTLA.ModelChecker, ExTLA.Simulation]

  # `* \`invariants:\`, \`action_properties:\`, \`temporals:\` — …`: the keys before the dash,
  # and the rest of the bullet up to the next one.
  defp documented(module) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(module)

    {_, _, _, %{"en" => doc}, _} =
      Enum.find(docs, &match?({{:function, :run, 2}, _, _, _, _}, &1))

    [_, options] = String.split(doc, "## Options\n", parts: 2)
    [options | _] = String.split(options, ~r/\n\S/, parts: 2)

    options
    |> String.split(~r/^\s*\* /m, trim: true)
    |> Enum.flat_map(fn bullet ->
      [keys, text] = String.split(bullet, " — ", parts: 2)
      for [_, key] <- Regex.scan(~r/`(\w+):`/, keys), do: {String.to_atom(key), text}
    end)
    |> Map.new()
  end

  defp typed(module) do
    {:ok, types} = Code.Typespec.fetch_types(module)

    {:type, {:config, {:type, _, :map, fields}, []}} =
      Enum.find(types, &match?({:type, {:config, _, _}}, &1))

    for {:type, _, _, [{:atom, _, key}, _]} <- fields, do: key
  end

  defp documented_default(text) do
    case Regex.run(~r/Default `([^`]+)`|`([^`]+)` \(the default\)/, text) do
      [_, value] -> value
      [_, "", value] -> value
      nil -> nil
    end
  end

  for module <- @modules do
    describe inspect(module) do
      test "documents every config key, and no key the type does not have" do
        documented = documented(unquote(module)) |> Map.keys() |> Enum.sort()
        typed = typed(unquote(module)) |> Enum.sort()

        assert typed -- documented == [], "undocumented: #{inspect(typed -- documented)}"

        assert documented -- typed == [],
               "documented but not typed: #{inspect(documented -- typed)}"
      end

      test "states each default the code uses" do
        documented = documented(unquote(module))

        wrong =
          for {key, default} <- unquote(module).__defaults__(),
              text = Map.fetch!(documented, key),
              stated = documented_default(text),
              stated == nil or elem(Code.eval_string(stated), 0) != default,
              do: {key, default, stated}

        assert wrong == [], "documented defaults that differ from @defaults: #{inspect(wrong)}"
      end
    end
  end

  # Anti-vacuity: the parse found real lists, not an empty section that both sides agree on.
  test "the parse reads the real Options sections" do
    assert map_size(documented(ExTLA.ModelChecker)) >= 14
    assert map_size(documented(ExTLA.Simulation)) >= 10
    assert :max_states in typed(ExTLA.ModelChecker)
    assert documented_default(documented(ExTLA.ModelChecker).max_states) == "1_000_000"
  end
end
