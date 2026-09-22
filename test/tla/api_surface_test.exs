defmodule TLA.ApiSurfaceTest do
  @moduledoc """
  `API_SURFACE.md`'s scanner and the two properties its drift gate rests on (#270, #271).

  The first class of claim is that the scanner reads what a reader of the file would: every
  public head, every named type, nothing a macro generated, arities as defaults imply. That is
  asserted on a fixture module whose shape is known exactly, because "the count matched the
  compiled module" would pass a scanner that missed one item and invented another.

  The second is that the golden is a **stable function of source** — two renders agree byte for
  byte, a blank line above an item moves nothing, and a changed body moves the version. A gate
  that drifts with no code changing is one somebody switches off.
  """
  use ExUnit.Case, async: true

  alias TLA.ApiSurface

  @fixture """
  defmodule Fixture.Outer do
    @type t :: %__MODULE__{status: :ok | :stale, count: non_neg_integer(), tag: nil}
    @type config :: %{optional(:workers) => pos_integer(), required(:name) => atom() | nil}
    @type index :: %{atom() => String.t()}
    @opaque token :: reference()
    @typep hidden :: term()

    defstruct status: :ok, count: 0, tag: nil

    def plain(a, b), do: {a, b}
    def defaulted(a, b \\\\ 1, c \\\\ 2), do: {a, b, c}
    def guarded(x) when is_integer(x), do: x
    def guarded(x) when is_binary(x), do: x
    def bare, do: :bare
    def patterned(%{} = map, [h | _]), do: {map, h}
    defp private(x), do: x
    defmacro macro(ast), do: ast
    defguard is_small(n) when n < 10
    defdelegate size(set), to: MapSet

    defmodule Inner do
      def inner(x), do: x
    end
  end
  """

  defp scan(source \\ @fixture) do
    source |> Code.string_to_quoted!() |> ApiSurface.scan("lib/fixture/outer.ex")
  end

  defp item(items, module, name) do
    Enum.find(items, &(&1.module == module and &1.name == name)) ||
      flunk("#{inspect(module)}.#{name} not scanned; got #{inspect(Enum.map(items, & &1.name))}")
  end

  describe "what the scanner reads" do
    setup do
      %{items: scan()}
    end

    test "every public head, with the arities its defaults imply", %{items: items} do
      assert item(items, Fixture.Outer, :plain).arities == [2]
      assert item(items, Fixture.Outer, :defaulted).arities == [1, 2, 3]
      assert item(items, Fixture.Outer, :bare).arities == [0]
      assert item(items, Fixture.Outer, :patterned).arities == [2]
    end

    test "a multi-clause function is one item", %{items: items} do
      guarded = item(items, Fixture.Outer, :guarded)
      assert guarded.arities == [1]
      assert Enum.count(items, &(&1.name == :guarded)) == 1
    end

    test "macros, guards and delegates are public heads with their own kind", %{items: items} do
      assert item(items, Fixture.Outer, :macro).kind == :defmacro
      assert item(items, Fixture.Outer, :is_small).kind == :defguard
      assert item(items, Fixture.Outer, :size).kind == :defdelegate
    end

    test "private functions, typep and defstruct are not items", %{items: items} do
      refute Enum.any?(items, &(&1.name in [:private, :hidden, :__struct__]))
    end

    test "a nested module's items belong to the nested module", %{items: items} do
      assert item(items, Fixture.Outer.Inner, :inner).arities == [1]
      refute Enum.any?(items, &(&1.module == Fixture.Outer and &1.name == :inner))
    end

    test "the shape names the arguments and marks a default", %{items: items} do
      assert item(items, Fixture.Outer, :defaulted).shape == "(a, b \\\\ …, c \\\\ …)"
      assert item(items, Fixture.Outer, :patterned).shape == "(map, _)"
      assert item(items, Fixture.Outer, :bare).shape == "()"
    end

    test "a record type's shape is its key set with atom unions, an optional key marked",
         %{items: items} do
      assert item(items, Fixture.Outer, :t).shape == "status: :ok | :stale, count, tag: nil"
      assert item(items, Fixture.Outer, :config).shape == "workers?, name"
      assert item(items, Fixture.Outer, :token).kind == :opaque
    end

    test "a map whose keys are types is not a record, and is shown as written", %{items: items} do
      assert item(items, Fixture.Outer, :index).shape == "%{atom() => String.t()}"
    end
  end

  describe "the golden is a stable function of source" do
    test "rendering twice produces identical bytes" do
      groups = scan() |> Enum.group_by(& &1.module) |> Enum.sort()
      assert ApiSurface.render(groups) == ApiSurface.render(groups)
    end

    test "a blank line and a comment above an item leave every version unchanged" do
      moved = String.replace(@fixture, "  def plain(a, b)", "\n  # moved down\n  def plain(a, b)")
      before = scan() |> Enum.map(&{&1.module, &1.name, &1.version}) |> Enum.sort()
      after_move = scan(moved) |> Enum.map(&{&1.module, &1.name, &1.version}) |> Enum.sort()
      assert before == after_move
    end

    test "a changed body moves that item's version and no other" do
      changed = String.replace(@fixture, "do: {a, b}", "do: {b, a}")
      before = scan() |> Map.new(&{{&1.module, &1.name}, &1.version})
      after_change = scan(changed) |> Map.new(&{{&1.module, &1.name}, &1.version})

      assert before[{Fixture.Outer, :plain}] != after_change[{Fixture.Outer, :plain}]

      assert Map.delete(before, {Fixture.Outer, :plain}) ==
               Map.delete(after_change, {Fixture.Outer, :plain})
    end

    test "no date or clock time reaches the output" do
      rendered = ApiSurface.run() |> ApiSurface.render()
      refute rendered =~ ~r/\d{4}-\d{2}-\d{2}/
      refute rendered =~ ~r/\d{2}:\d{2}:\d{2}/
    end

    test "a pipe in a shape is escaped, so a union does not end its table cell" do
      rendered = ApiSurface.run() |> ApiSurface.render()

      # `TLA.ModelChecker.result()`'s status is a union of atoms; unescaped it would split the row.
      assert rendered =~ "status: :constrained \\| :deadlock"
    end
  end

  describe "against the real tree" do
    # The scanner may not invent an item: everything it lists under `lib/` must be a function
    # the compiled module exports. The converse — that it misses nothing — is asserted on the
    # fixture above, because the compiled module also carries what macros generated.
    test "every scanned function is exported by its compiled module" do
      for {module, items} <- ApiSurface.run(),
          %{kind: kind, name: name, arities: arities} <- items,
          kind not in [:type, :opaque],
          arity <- arities do
        assert Code.ensure_loaded?(module), "#{inspect(module)} does not compile"

        assert function_exported?(module, name, arity) or macro_exported?(module, name, arity),
               "#{inspect(module)}.#{name}/#{arity} is in API_SURFACE.md and not exported"
      end
    end

    test "every scanned type is a type the compiled module declares" do
      for {module, items} <- ApiSurface.run(),
          %{kind: kind, name: name} <- items,
          kind in [:type, :opaque] do
        {:ok, types} = Code.Typespec.fetch_types(module)
        declared = for {k, {n, _, _}} <- types, k in [:type, :opaque], do: n

        assert name in declared,
               "#{inspect(module)}.#{name}() is in API_SURFACE.md and not a public type"
      end
    end

    test "the committed golden is current — the same equality the surface-drift job asserts" do
      path = Path.expand("../../API_SURFACE.md", __DIR__)
      assert File.read!(path) == ApiSurface.run() |> ApiSurface.render()
    end
  end
end
