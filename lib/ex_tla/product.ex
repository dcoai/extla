defmodule ExTLA.Product do
  @moduledoc false

  # The independent n-ary product, written once (#350, #368).
  #
  # `ExTLA.Set.cross_many/1`, `ExTLA.Function.record_set/1` (and through it `function_set/2`)
  # and `ExTLA.Symmetry.mappings/2` each wrote this fold out for themselves. They differed only
  # in a seed and a combiner: a list of tuple elements, `Map.put` of one field, `Map.merge` of a
  # whole substitution. So this takes both. Hidden because it is plumbing, not a TLA+ operator:
  # `ExTLA.Set` holds the operators a spec body can reach.
  #
  # `ExTLA.ModelChecker.bindings/3` is deliberately NOT this: its later choices depend on the
  # bindings made before them (a dependent product, #324). `test/docs/product_shape_test.exs`
  # allows the fold's shape here and there only.

  @doc false
  @spec fold([Enumerable.t()], acc, (acc, term() -> acc)) :: [acc] when acc: term()
  def fold(choices, seed, combine) do
    Enum.reduce(choices, [seed], fn options, partials ->
      for partial <- partials, option <- options, do: combine.(partial, option)
    end)
  end
end
