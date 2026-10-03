defmodule ExTLA.Spec.OperatorAgreementTest do
  @moduledoc """
  There is one implementation of each TLA+ operator, and a spec body can reach all of them
  (#318, #319, D-38, for #183).

  ## What this file was, and what it is now

  #318 established that two implementations of the same operators shipped side by side and
  **disagreed**. `ExTLA.Spec.Helpers.for_each/2` refused a sequence by name — building a
  function over one deduplicated it silently (#211) — while `ExTLA.Function.construct/2`
  still did exactly that. `Helpers.domain/1` read a sequence as the function on `1..Len(s)`
  that `at/2` applies it as, while `ExTLA.Function.domain/1` raised `BadMapError` on one and,
  because a `MapSet` is a struct and therefore a map, answered a **set** with the struct's
  own field names.

  #319 removed the duplicates. The foundation holds the implementation; `ExTLA.Spec.Helpers`
  is a façade over it. So the divergences below are pinned the other way up — as the
  agreement that now holds, on the semantics that won.

  ## What is gated, and all of it is derived

  - **What a spec body can reach** is read out of `lib/ex_tla/spec.ex`'s own `__using__`
    imports. The proposal's inventory was wrong twice, which is why nothing here is written
    from a reading of the source.
  - **Every operator the foundation defines is reachable**, under its own name or a
    written-down alias. Four are aliased: `for_each/2` and `update/3` are the DSL's own
    long-standing spellings of `ExTLA.Function.construct/2` and `except_with/3`, and
    `ExTLA.Set.map/2` and `filter/2` are `set_map/2` and `set_filter/2` there, because an
    unqualified `map/2` in a spec body reads as `Enum.map/2` to everyone.
  - **The façade holds no second implementation.** `lib/ex_tla/spec/helpers.ex`'s AST is read
    and every definition classified: the names defined with `def` are exactly the thin
    `MapSet`/`Enum` wrappers, and every operator the foundation defines arrives by
    `defdelegate`. A re-implementation reddens here, which is the drift #183 was about.
  - **The agreement properties stay.** They run over one implementation now, and would be
    trivial if the façade could not decay — the gate above is what keeps them meaningful,
    and together they are what would have caught #211 being fixed in one copy.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExTLA.Function, as: F
  alias ExTLA.Set, as: S
  alias ExTLA.Spec.Helpers, as: H

  @spec_source Path.expand("../../../lib/ex_tla/spec.ex", __DIR__)
  @helpers_source Path.expand("../../../lib/ex_tla/spec/helpers.ex", __DIR__)
  @external_resource @spec_source
  @external_resource @helpers_source

  # One TLA+ operator per row, with the spec body's spelling and the foundation function it
  # names. Every row agrees, because every row is one function reached two ways.
  @correspondence [
    %{
      tla: "CHOOSE x \\in S : P(x)",
      operator: :choose,
      spec_body: {H, :choose, 1},
      foundation: {S, :choose, 1}
    },
    %{
      tla: "CHOOSE x \\in S : P(x)",
      operator: :choose,
      spec_body: {H, :choose, 2},
      foundation: {S, :choose, 2}
    },
    %{
      tla: "DOMAIN f",
      operator: :domain,
      spec_body: {H, :domain, 1},
      foundation: {F, :domain, 1}
    },
    %{
      tla: "[x \\in S |-> f(x)]",
      operator: :for_each,
      spec_body: {H, :for_each, 2},
      foundation: {F, :construct, 2}
    },
    %{
      tla: "[f EXCEPT ![k] = g(@)]",
      operator: :update,
      spec_body: {H, :update, 3},
      foundation: {F, :except_with, 3}
    }
  ]

  # What `ExTLA.Spec.Helpers` implements itself: one-line covers over `MapSet` and `Enum`
  # with no counterpart in the foundation. Anything else it defines with `def` is a second
  # implementation of an operator that already has one — which is what D-38 forbids.
  @thin_wrappers ~w(append at delete difference head intersection is_set keys len member?
                    put seq set size subseq subset? sum tail union values)a

  # The operators a spec body reaches under another name, and what that name is. Written
  # down because a silent rename is exactly the drift the rest of this file exists to
  # catch. `for_each` and `update` are the DSL's own long-standing spellings of
  # `[x \\in S |-> f(x)]` and `[f EXCEPT ![k] = g(@)]`; `set_map` and `set_filter` say out
  # loud that they are set operations, because an unqualified `map/2` in a spec body reads
  # as `Enum.map/2` to everyone.
  @aliases %{
    for_each: {F, :construct},
    update: {F, :except_with},
    set_map: {S, :map},
    set_filter: {S, :filter}
  }

  # Reachable from a spec body, and named by #183 as absent from one.
  @proposal_corrections [:union, :intersection, :difference, :subset?, :size, :choose]

  # ── Reading ExTLA.Spec's own imports ──────────────────────────────────────────

  defp using_imports do
    {_, imports} =
      @spec_source
      |> File.read!()
      |> Code.string_to_quoted!()
      |> using_ast!()
      |> Macro.prewalk([], fn
        {:import, _, [{:__aliases__, _, parts} | opts]} = node, acc ->
          {node, [{Module.concat(parts), List.first(opts) || []} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(imports)
  end

  defp using_ast!(ast) do
    {_, found} =
      Macro.prewalk(ast, nil, fn
        {:defmacro, _, [{:__using__, _, _} | _]} = node, nil -> {node, node}
        node, acc -> {node, acc}
      end)

    found || flunk("lib/ex_tla/spec.ex no longer defines `defmacro __using__`")
  end

  defp reachable do
    for {module, opts} <- using_imports(),
        true = Code.ensure_loaded?(module),
        {name, arity} <- module.__info__(:functions) ++ module.__info__(:macros),
        selected?({name, arity}, opts),
        into: MapSet.new(),
        do: {name, arity}
  end

  defp reachable_names, do: MapSet.new(reachable(), &elem(&1, 0))

  defp selected?(function_arity, opts) do
    cond do
      only = opts[:only] -> function_arity in only
      except = opts[:except] -> function_arity not in except
      true -> true
    end
  end

  defp exports(module) do
    true = Code.ensure_loaded?(module)
    module.__info__(:functions)
  end

  # `function_exported?/3` does NOT load a module, so on a cold VM it answers `false` for a
  # module nothing has called yet — a genuinely flaky assertion, and one #318 hit on its
  # second run. Every membership question here goes through `exports/1` instead.
  defp exported?(module, name, arity), do: {name, arity} in exports(module)

  # ── Reading the façade's own definitions ────────────────────────────────────

  # Each public definition in `lib/ex_tla/spec/helpers.ex`, as `{:def, name}` or
  # `{:defdelegate, name, {module, target_name}}`. The AST, not a `grep`: the file
  # discusses both forms in prose.
  defp helpers_definitions do
    {_, definitions} =
      @helpers_source
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:def, _, [head | _]} = node, acc ->
          {node, [{:def, definition_name(head)} | acc]}

        {:defdelegate, _, [head, opts]} = node, acc ->
          {node, [{:defdelegate, definition_name(head), delegate_target(opts)} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(definitions)
  end

  defp definition_name({:when, _, [head | _]}), do: definition_name(head)
  defp definition_name({name, _, _args}) when is_atom(name), do: name

  defp delegate_target(opts) do
    {:__aliases__, _, parts} = Keyword.fetch!(opts, :to)
    {Module.concat(parts), Keyword.get(opts, :as)}
  end

  defp defined_with_def, do: for({:def, name} <- helpers_definitions(), uniq: true, do: name)

  defp delegations do
    for {:defdelegate, name, {module, as}} <- helpers_definitions(),
        into: %{},
        do: {name, {module, as || name}}
  end

  # ── What a spec body can reach ──────────────────────────────────────────────

  describe "the reachable vocabulary, derived from ExTLA.Spec's imports" do
    test "a spec body imports ExTLA.Spec.Helpers whole, and neither foundation module" do
      imports = using_imports()
      modules = Enum.map(imports, &elem(&1, 0))

      assert {ExTLA.Spec.Helpers, []} in imports,
             "ExTLA.Spec.Helpers is imported with an :only/:except list; " <>
               "the derivation below assumes the whole module. Got: #{inspect(imports)}"

      refute ExTLA.Set in modules
      refute ExTLA.Function in modules
    end

    # Why the façade rather than a second `import` — option 1 in #183. The collision the
    # proposal asked us to check is real, and it is between the two modules rather than
    # with `Kernel`: importing either foundation module alongside the façade would make
    # every one of these names ambiguous at its call site, in every spec.
    test "importing a foundation module directly would collide with the façade" do
      helper_names = MapSet.new(exports(ExTLA.Spec.Helpers))

      collisions =
        for module <- [S, F],
            {name, arity} <- exports(module),
            {name, arity} in helper_names,
            do: {module, name, arity}

      assert length(collisions) >= 5,
             "the façade is supposed to cover the foundation; it shares only " <>
               "#{inspect(collisions)}"
    end

    test "the derivation is not vacuous" do
      assert MapSet.size(reachable()) >= length(exports(ExTLA.Spec.Helpers))
      assert {:for_each, 2} in reachable()
    end

    # #183's inventory named these as absent from a spec body. They are not, and a wrong
    # inventory is what the proposal is about — so the correction is asserted, not merely
    # written on the issue.
    test "the proposal's inventory was wrong: these were always reachable" do
      names = reachable_names()

      for name <- @proposal_corrections do
        assert name in names, "#{name} was expected to be reachable from a spec body"
      end
    end

    # The acceptance criterion, derived rather than declared: every operator
    # `01-foundation.md` specifies is now callable unqualified from a spec body.
    test "every operator the foundation defines is reachable from a spec body" do
      names = reachable_names()

      aliased =
        Map.new(@aliases, fn {spelling, {module, name}} -> {{module, name}, spelling} end)

      unreachable =
        for module <- [S, F],
            {name, _arity} <- exports(module),
            name not in names,
            not Map.has_key?(aliased, {module, name}),
            uniq: true,
            do: {module, name}

      assert unreachable == [], """
      #{length(unreachable)} foundation operators are not reachable from a spec body:

        #{Enum.map_join(unreachable, "\n  ", fn {m, n} -> "#{inspect(m)}.#{n}" end)}

      Either delegate it from `ExTLA.Spec.Helpers`, or add it to `@aliases` with the name a
      spec body reaches it by. `01-foundation.md` specifies this vocabulary as the
      foundation everything else builds on; a name only a fully-qualified call can reach is
      the gap #183 was filed about.
      """
    end

    test "the aliased operators are reachable under the names written down" do
      names = reachable_names()

      for {spelling, {module, name} = target} <- @aliases do
        assert spelling in names, "#{spelling} is not reachable from a spec body"

        assert Enum.any?(exports(module), &(elem(&1, 0) == name)),
               "#{inspect(module)}.#{name} no longer exists"

        assert delegations()[spelling] == target
      end
    end
  end

  # ── The façade holds no second implementation ───────────────────────────────

  describe "ExTLA.Spec.Helpers as a façade (D-38)" do
    test "reads as a mixture of both forms, so neither branch below is vacuous" do
      definitions = helpers_definitions()

      assert length(for({:def, _} <- definitions, do: 1)) > 10
      assert map_size(delegations()) > 10
    end

    test "implements only the thin wrappers itself" do
      assert Enum.sort(defined_with_def()) == Enum.sort(@thin_wrappers)
    end

    test "and none of those has a counterpart in the foundation" do
      foundation = for module <- [S, F], {name, _} <- exports(module), uniq: true, do: name

      duplicated = Enum.filter(defined_with_def(), &(&1 in foundation))

      assert duplicated == [], """
      #{inspect(duplicated)} is implemented in `ExTLA.Spec.Helpers` AND defined by the
      foundation. That is the shape #318 measured: `for_each/2` and
      `ExTLA.Function.construct/2` disagreed about a sequence for as long as both existed,
      because #211's fix landed in one copy. Delegate instead.
      """
    end

    test "every delegation points at a function that exists" do
      for {spelling, {module, name}} <- delegations() do
        arities = for {exported, arity} <- exports(module), exported == name, do: arity

        assert arities != [],
               "ExTLA.Spec.Helpers.#{spelling} delegates to #{inspect(module)}.#{name}, " <>
                 "which is not exported"
      end
    end

    test "and every one of them targets the foundation, not a third place" do
      targets = delegations() |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      assert Enum.sort(targets) == Enum.sort([S, F])
    end
  end

  # ── The correspondence table, asserted against both spellings ───────────────

  describe "the correspondence table" do
    test "is not empty, and holds one row per operator reachable two ways" do
      assert length(@correspondence) == 5

      assert @correspondence |> Enum.map(& &1.operator) |> Enum.uniq() |> Enum.sort() ==
               [:choose, :domain, :for_each, :update]
    end

    test "every function it names is exported by the module it names" do
      for row <- @correspondence, {module, name, arity} <- [row.spec_body, row.foundation] do
        assert exported?(module, name, arity),
               "#{inspect(module)}.#{name}/#{arity} is named in the correspondence table " <>
                 "for #{row.tla} and is not exported"
      end
    end

    test "and the spec body's spelling is a delegation to the foundation's" do
      for %{spec_body: {_, spelling, _}, foundation: {module, name, _}} <- @correspondence do
        assert delegations()[spelling] == {module, name},
               "ExTLA.Spec.Helpers.#{spelling} is not a delegation to " <>
                 "#{inspect(module)}.#{name}"
      end
    end
  end

  # ── Agreement over generated inputs ─────────────────────────────────────────

  property "CHOOSE returns the same element for the same set and predicate" do
    check all(
            elements <- list_of(integer(), min_length: 1),
            set = MapSet.new(elements),
            threshold <- member_of(Enum.to_list(set))
          ) do
      assert H.choose(set) == S.choose(set)
      assert H.choose(set, &(&1 >= threshold)) == S.choose(set, &(&1 >= threshold))
    end
  end

  property "DOMAIN f agrees on a function" do
    check all(map <- map_of(atom(:alphanumeric), integer())) do
      assert H.domain(map) == F.domain(map)
    end
  end

  property "DOMAIN f agrees on a sequence, which is a function on 1..Len(s)" do
    check all(elements <- list_of(atom(:alphanumeric))) do
      assert H.domain(elements) == F.domain(elements)
      assert H.domain(elements) == MapSet.new(1..length(elements)//1)
    end
  end

  property "[x \\in S |-> f(x)] agrees on a set" do
    check all(
            elements <- list_of(integer(), min_length: 1),
            set = MapSet.new(elements)
          ) do
      assert H.for_each(set, &(&1 * 2)) == F.construct(set, &(&1 * 2))
    end
  end

  property "[x \\in S |-> f(x)] agrees on a range" do
    check all(
            a <- integer(1..5),
            b <- integer(1..5),
            range = a..b//1
          ) do
      assert H.for_each(range, &(&1 * 2)) == F.construct(range, &(&1 * 2))
    end
  end

  property "[f EXCEPT ![k] = g(@)] agrees on a point in the domain" do
    check all(
            map <- map_of(atom(:alphanumeric), integer(), min_length: 1),
            key <- member_of(Map.keys(map))
          ) do
      assert H.update(map, key, &(&1 + 1)) == F.except_with(map, key, &(&1 + 1))
    end
  end

  test "the agreement properties are not vacuous on the empty and singleton cases" do
    assert H.for_each(MapSet.new(), & &1) == F.construct(MapSet.new(), & &1)
    assert H.domain(%{}) == F.domain(%{})
    assert H.for_each(MapSet.new([:a]), fn _ -> 0 end) == %{a: 0}
    assert F.construct(MapSet.new([:a]), fn _ -> 0 end) == %{a: 0}
  end

  test "[f EXCEPT ![k] = g(@)] agrees on a point outside the domain, including the raise" do
    assert_raise KeyError, fn -> H.update(%{a: 1}, :b, &(&1 + 1)) end
    assert_raise KeyError, fn -> F.except_with(%{a: 1}, :b, &(&1 + 1)) end
  end

  # ── The semantics that won. #318 pinned these as divergences. ───────────────

  describe "[x \\in S |-> f(x)] — #211's fix, now in the only copy" do
    test "refuses a sequence by name, under both spellings" do
      for build <- [&H.for_each/2, &F.construct/2] do
        error = assert_raise ArgumentError, fn -> build.([:a, :a, :b], & &1) end
        message = Exception.message(error)

        assert message =~ "for_each/2 builds a function over a set"
        assert message =~ "a sequence"
      end
    end

    # What the refusal is for: `construct/2` used to answer a sequence, and the answer had
    # a different cardinality than its argument, silently.
    test "rather than deduplicating it silently" do
      sequence = [:a, :a, :b]
      assert length(sequence) == 3
      assert map_size(F.construct(MapSet.new(sequence), & &1)) == 2
    end

    test "and refuses a map, which is a function already" do
      error = assert_raise ArgumentError, fn -> F.construct(%{a: 1}, & &1) end
      assert Exception.message(error) =~ "a function already"
    end
  end

  describe "DOMAIN f — one reading of a sequence" do
    test "a sequence's domain is 1..Len(s), under both spellings" do
      assert H.domain([:x, :y, :z]) == MapSet.new([1, 2, 3])
      assert F.domain([:x, :y, :z]) == MapSet.new([1, 2, 3])
      assert H.domain([]) == MapSet.new()
      assert F.domain([]) == MapSet.new()
    end

    # The D-20 shape `ExTLA.Function.domain/1` used to have: not a raise against an answer,
    # but an answer against a WRONG answer. A `MapSet` is a struct and therefore a map, so
    # `Map.keys/1` read the struct's own fields and reported them as the function's domain.
    test "a set is refused by name rather than answered with the struct's fields" do
      set = MapSet.new([1, 2])

      for domain <- [&H.domain/1, &F.domain/1] do
        error = assert_raise ArgumentError, fn -> domain.(set) end
        message = Exception.message(error)

        assert message =~ "domain/1 takes a function (a map) or a sequence"
        refute message =~ "__struct__"
      end
    end
  end
end
