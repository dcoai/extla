defmodule ExTLA.ProductShapeTest do
  @moduledoc """
  The n-ary product is written out in `lib/` only where it is meant to be (#350, #368).

  Four copies of one fold had accumulated, in `ExTLA.Set`, `ExTLA.Function` (twice) and
  `ExTLA.Symmetry`: each a reduce seeded with one empty combination, extending every partial
  combination by every option. Nothing compared them, because each was locally reasonable
  and none named the others. #368 left one, `ExTLA.Product.fold/3`, which the others call.

  This holds that. The shape is read from the AST: an `Enum.reduce/3` whose seed is a
  one-element list, and whose function's body is a `for` whose first generator walks the
  accumulator. It is allowed at exactly two sites:

  - `ExTLA.Product.fold/3`, the one implementation;
  - `ExTLA.ModelChecker.bindings/3`, which has the same shape but is a different operation.
    Its later choices depend on the bindings before them, a dependent product (#324).

  A new copy fails here, naming the file and line. The answer is to call
  `ExTLA.Product.fold/3`, or to add a site to `@allowed` with the reason it is a different
  operation.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # file => why the fold's shape is allowed there.
  @allowed %{
    "lib/ex_tla/product.ex" => "the one implementation",
    "lib/ex_tla/model_checker.ex" =>
      "bindings/3: a dependent product, each generator reading the bindings before it"
  }

  test "the product's shape appears only where it is allowed" do
    found =
      for path <- Path.wildcard(Path.join(@root, "lib/**/*.ex")) |> Enum.sort(),
          line <- product_folds(File.read!(path)),
          do: {Path.relative_to(path, @root), line}

    offenders = for {file, line} <- found, not Map.has_key?(@allowed, file), do: "#{file}:#{line}"

    assert offenders == [], """
    the independent n-ary product is written out again at:

    #{Enum.map_join(offenders, "\n", &"  - #{&1}")}

    Call `ExTLA.Product.fold/3` (choices, seed, combine) instead. If this is a different
    operation (as `ModelChecker.bindings/3` is), add it to `@allowed` with the reason.
    """

    # Anti-vacuity: both allowed sites are found, so a reader that matched nothing fails.
    assert Enum.sort(Enum.map(found, &elem(&1, 0))) == Enum.sort(Map.keys(@allowed))
  end

  test "the reader finds a pre-#368 copy, and leaves an ordinary reduce alone" do
    copy = """
    defmodule Copy do
      def cross_many(sets) do
        sets
        |> Enum.reduce([[]], fn set, acc -> for tail <- acc, x <- set, do: [x | tail] end)
      end
    end
    """

    assert product_folds(copy) == [4]

    ordinary = "Enum.reduce(xs, [], fn x, acc -> for y <- x, do: [y | acc] end)"
    assert product_folds(ordinary) == []
  end

  @doc false
  def product_folds(source) do
    {_, lines} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn node, acc ->
        if product_fold?(node), do: {node, [line(node) | acc]}, else: {node, acc}
      end)

    Enum.sort(lines)
  end

  # `Enum.reduce(_, [seed], fn _, acc -> for _ <- acc, … end)`, piped or called directly.
  defp product_fold?({{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, args})
       when is_list(args) do
    case Enum.take(args, -2) do
      [[_seed], {:fn, _, [{:->, _, [[_option, {acc, _, nil}], body]}]}] -> walks?(body, acc)
      _ -> false
    end
  end

  defp product_fold?(_node), do: false

  defp walks?({:for, _, [{:<-, _, [_pattern, {acc, _, nil}]} | _]}, acc), do: true
  defp walks?(_body, _acc), do: false

  defp line({_, meta, _}), do: meta[:line]
end
