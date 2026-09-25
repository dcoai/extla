defmodule TLA.Spec.OperatorAgreementTest do
  @moduledoc """
  Two implementations of the same TLA+ operators ship side by side, and nothing compared
  them (#318, for #183).

  `TLA.Spec.Helpers` is what a spec body imports — `TLA.Spec.__using__/1` imports it and
  nothing else from the set-theoretic layer. `TLA.Set` and `TLA.Function` are what
  `01-foundation.md` §307-403 specifies as the foundation everything else builds on, and
  `06-architecture.md` §76-78 places there. Four operators are defined in both.

  ## What this file establishes

  **They disagree, and on the case the project has already fixed once.**
  `Helpers.for_each/2` and `TLA.Function.construct/2` are the same operator —
  `[x \\in S |-> f(x)]` — and both say so in their docs. `for_each/2` refuses a list by
  name because building a function over a *sequence* deduplicated it silently (#211, with
  the reason in a comment above the clause). `construct/2` still does exactly that: a
  three-element sequence becomes a two-element function and nothing says so. The fix landed
  in one copy.

  `domain/1` is the second, and it is worse than a raise-versus-answer. `Helpers.domain/1`
  reads a sequence as the function on `1..Len(s)` that `at/2` applies it as, and refuses
  anything else by name. `TLA.Function.domain/1` is `Map.keys |> MapSet.new`, so a list
  raises `BadMapError` — and a `MapSet`, which *is* a struct and therefore a map, is
  answered with **the struct's own field names**. That is the D-20 defect class exactly: a
  wrong answer that looks like an answer.

  ## What is derived rather than written down

  - **What a spec body can reach** is read out of `lib/tla/spec.ex`'s own `__using__`
    imports, not from a list here. The proposal's inventory was wrong about this in two
    places, which is the reason it is derived: `union`, `intersection`, `difference`,
    `subset?` and `size` are reachable, and so is `choose`, which `Helpers` already
    delegates to `TLA.Set`.
  - **Which foundation operators are unreachable** is the remainder of that derivation
    against each module's actual exports, checked against a written list — so an operator
    added to one module and not the other reddens here instead of quietly joining the gap.

  The agreement properties run over generated inputs, which is the half that outlives this
  issue: they are what would have caught #211 being fixed in one copy. #319 removes the
  duplicate implementations, at which point the divergences pinned at the bottom of this
  file go with them.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias TLA.Function, as: F
  alias TLA.Set, as: S
  alias TLA.Spec.Helpers, as: H

  @spec_source Path.expand("../../../lib/tla/spec.ex", __DIR__)
  @external_resource @spec_source

  # One TLA+ operator per row, with the two implementations that claim it. `:verdict` is
  # the finding: `:agree` is asserted by a property below, `:diverge` is pinned by a test
  # at the bottom, and the two sets are cross-checked against each other so neither can be
  # edited alone.
  @correspondence [
    %{
      tla: "CHOOSE x \\in S : P(x)",
      operator: :choose,
      spec_body: {H, :choose, 1},
      foundation: {S, :choose, 1},
      verdict: :agree,
      note: "Helpers delegates; the arity-1 head is the default predicate"
    },
    %{
      tla: "CHOOSE x \\in S : P(x)",
      operator: :choose,
      spec_body: {H, :choose, 2},
      foundation: {S, :choose, 2},
      verdict: :agree,
      note: "Helpers delegates"
    },
    %{
      tla: "DOMAIN f",
      operator: :domain,
      spec_body: {H, :domain, 1},
      foundation: {F, :domain, 1},
      verdict: :diverge,
      note:
        "a sequence is 1..Len(s) in one and a BadMapError in the other; a set is " <>
          "refused by one and answered with the struct's fields by the other"
    },
    %{
      tla: "[x \\in S |-> f(x)]",
      operator: :for_each,
      spec_body: {H, :for_each, 2},
      foundation: {F, :construct, 2},
      verdict: :diverge,
      note:
        "#211's fix landed in one copy: a sequence is refused by one and silently " <>
          "deduplicated by the other"
    },
    %{
      tla: "[f EXCEPT ![k] = g(@)]",
      operator: :update,
      spec_body: {H, :update, 3},
      foundation: {F, :except_with, 3},
      verdict: :agree,
      note: "both are Map.update!/3, which is why they agree including on the raise"
    }
  ]

  # Everything each side defines that the other does not. Written down so that adding an
  # operator to one module without pairing or listing it is red — that is the drift this
  # proposal is about, arriving one function at a time.
  @spec_body_only [
    {:append, 2},
    {:at, 2},
    {:at, 3},
    {:delete, 2},
    {:difference, 2},
    {:head, 1},
    {:intersection, 2},
    {:is_set, 1},
    {:keys, 1},
    {:len, 1},
    {:member?, 2},
    {:put, 2},
    {:seq, 0},
    {:seq, 1},
    {:set, 0},
    {:set, 1},
    {:size, 1},
    {:subseq, 3},
    {:subset?, 2},
    {:sum, 1},
    {:sum, 2},
    {:tail, 1},
    {:union, 2},
    {:values, 1}
  ]

  @foundation_only [
    {S, :cross, 2},
    {S, :cross_many, 1},
    {S, :distributed_union, 1},
    {S, :exists?, 2},
    {S, :filter, 2},
    {S, :for_all?, 2},
    {S, :map, 2},
    {S, :powerset, 1},
    {S, :range, 2},
    {F, :except, 2},
    {F, :function_set, 2},
    {F, :record_set, 1}
  ]

  # Reachable from a spec body, and named in the proposal as absent from one. Both halves
  # of the correction: the five set operators, and `choose`, which #318 itself got wrong.
  @proposal_corrections [:union, :intersection, :difference, :subset?, :size, :choose]

  # ── Reading TLA.Spec's own imports ──────────────────────────────────────────

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

    found || flunk("lib/tla/spec.ex no longer defines `defmacro __using__`")
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
  # module nothing has called yet — a genuinely flaky assertion, and one this file hit on
  # its second run. Every membership question here goes through `exports/1` instead.
  defp exported?(module, name, arity), do: {name, arity} in exports(module)

  # `TLA.Function.domain/1` is `Map.keys/1`, so the type checker warns at a call site
  # holding a literal list — which is precisely the call this file pins. A spec author's
  # sequence arrives in a variable, not a literal, so the argument comes through here.
  defp as_term(value), do: Enum.random([value])

  # ── What a spec body can reach ──────────────────────────────────────────────

  describe "the reachable vocabulary, derived from TLA.Spec's imports" do
    test "a spec body imports TLA.Spec.Helpers whole, and neither foundation module" do
      imports = using_imports()
      modules = Enum.map(imports, &elem(&1, 0))

      assert {TLA.Spec.Helpers, []} in imports,
             "TLA.Spec.Helpers is imported with an :only/:except list; " <>
               "the derivation below assumes the whole module. Got: #{inspect(imports)}"

      refute TLA.Set in modules
      refute TLA.Function in modules
    end

    test "the derivation is not vacuous" do
      assert MapSet.size(reachable()) >= length(exports(TLA.Spec.Helpers))
      assert {:for_each, 2} in reachable()
    end

    # The proposal's inventory named these as absent from a spec body. They are not, and a
    # wrong inventory is what #183 is about — so the correction is asserted, not just
    # written on the issue.
    test "the proposal's inventory was wrong: these are reachable" do
      names = reachable_names()

      for name <- @proposal_corrections do
        assert name in names,
               "#{name} was expected to be reachable from a spec body; the correction " <>
                 "recorded on #183 and #318 is itself wrong"
      end
    end

    test "the unreachable foundation operators are exactly the ones written down" do
      names = reachable_names()

      unreachable = fn module ->
        module
        |> exports()
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()
        |> Enum.reject(&(&1 in names))
        |> Enum.sort()
      end

      # `TLA.Set.choose/1,2` is reachable because Helpers delegates it, and `domain/1` is
      # reachable by NAME while resolving to the other implementation — which is the
      # divergence, not a gap in the vocabulary.
      assert unreachable.(TLA.Set) ==
               ~w(cross cross_many distributed_union exists? filter for_all? map powerset range)a

      assert unreachable.(TLA.Function) ==
               ~w(construct except except_with function_set record_set)a
    end

    test "domain/1 is reachable by name, and the name resolves to the other implementation" do
      assert {:domain, 1} in reachable()
      assert exported?(F, :domain, 1)

      # Same name, same arity, same answer on a map — and different answers on everything
      # else, which is what the pinned divergence at the bottom of this file records.
      assert H.domain(%{x: 1, y: 2}) == F.domain(%{x: 1, y: 2})
      refute H.domain([:x, :y]) == MapSet.new([:x, :y])
    end
  end

  # ── The correspondence table, asserted against both modules ─────────────────

  describe "the correspondence table" do
    test "is not empty, and holds one row per implementation pair" do
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

    test "what only the spec body defines is written down" do
      paired = MapSet.new(@correspondence, fn %{spec_body: {_, n, a}} -> {n, a} end)

      unpaired =
        TLA.Spec.Helpers |> exports() |> Enum.reject(&(&1 in paired)) |> Enum.sort()

      assert unpaired == Enum.sort(@spec_body_only)
    end

    test "what only the foundation defines is written down" do
      paired = MapSet.new(@correspondence, fn %{foundation: {m, n, a}} -> {m, n, a} end)

      unpaired =
        for module <- [S, F],
            {name, arity} <- exports(module),
            {module, name, arity} not in paired,
            do: {module, name, arity}

      assert Enum.sort(unpaired) == Enum.sort(@foundation_only)
    end

    test "the rows marked :diverge are exactly the ones pinned below" do
      diverging =
        @correspondence
        |> Enum.filter(&(&1.verdict == :diverge))
        |> Enum.map(& &1.operator)
        |> Enum.uniq()
        |> Enum.sort()

      assert diverging == [:domain, :for_each]
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

  property "DOMAIN f agrees on a function — the shape both accept" do
    check all(map <- map_of(atom(:alphanumeric), integer())) do
      assert H.domain(map) == F.domain(map)
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

  # ── Where they disagree today. #319 removes one of the two. ─────────────────

  describe "[x \\in S |-> f(x)] — the disagreement #211 fixed in one copy only" do
    test "the spec body's for_each/2 refuses a sequence, by name" do
      error = assert_raise ArgumentError, fn -> H.for_each([:a, :a, :b], & &1) end
      message = Exception.message(error)

      assert message =~ "for_each/2 builds a function over a set"
      assert message =~ "a sequence"
    end

    test "the foundation's construct/2 deduplicates the same sequence silently" do
      sequence = [:a, :a, :b]
      assert length(sequence) == 3

      function = F.construct(sequence, & &1)

      assert function == %{a: :a, b: :b}
      assert map_size(function) == 2
    end

    # The deeper half: even without duplicates, a sequence is a function on 1..Len(s)
    # everywhere else in the DSL — `at/2` applies it that way and `Helpers.domain/1` reads
    # it that way — and `construct/2` builds a function on its ELEMENTS instead.
    test "construct/2 builds a function on a sequence's elements, not on 1..Len(s)" do
      assert F.construct([:x, :y], & &1) == %{x: :x, y: :y}
      assert H.domain([:x, :y]) == MapSet.new([1, 2])
    end
  end

  describe "DOMAIN f — the second disagreement" do
    test "a sequence is a function on 1..Len(s) in the spec body and a BadMapError in the foundation" do
      assert H.domain([:x, :y, :z]) == MapSet.new([1, 2, 3])
      assert_raise BadMapError, fn -> F.domain(as_term([:x, :y, :z])) end
    end

    # The D-20 shape: not a raise against an answer, but an answer against a WRONG answer.
    # `MapSet` is a struct and therefore a map, so `Map.keys/1` reads the struct's own
    # fields and `domain/1` reports them as the function's domain.
    test "a set is refused by name in the spec body and answered with the struct's fields" do
      set = MapSet.new([1, 2])

      error = assert_raise ArgumentError, fn -> H.domain(set) end
      assert Exception.message(error) =~ "domain/1 takes a function (a map) or a sequence"

      answer = F.domain(set)

      assert MapSet.size(answer) > 0, "it does not raise — it answers"
      refute MapSet.member?(answer, 1), "and the answer is not the set's elements"
      refute MapSet.member?(answer, 2)
    end
  end
end
