defmodule ExTLA.DeclarationShapesTest do
  @moduledoc """
  What the wrapper does with the declarations it is given — every combination of them, and
  every shape of answer they can return (#317).

  Two defects of the same kind: the four declaration kinds are documented as one thing
  (02-dsl-semantics.md §4.2 says "a boolean expression" for all of them, and notes no
  difference) and behaved as four.

  - **A non-boolean.** The invariant path used `unless`, so a `nil` was a violation of the
    declaration the user wrote. The condition paths matched `true` and `false` exactly, so
    the same `nil` — `Map.get/2` on a key that is not there is the ordinary way to get one —
    killed the server with a `CaseClauseError` naming a generated function. The `:verbose`
    paths diverged a third way, treating a truthy non-boolean as a violation, so telemetry
    could change a verdict.
  - **The unused binding.** A module carrying *only* preconditions got
    `warning: variable "tla_new_state" is unused` about code it did not write, and paid an
    extraction call per transition for a value nothing downstream wanted.

  The second is why this file enumerates: one combination was wrong, and a test of one
  combination is what let it be. There are sixteen, and all sixteen are compiled here.
  """
  use ExUnit.Case, async: true

  alias ExTLA.Invariant.Runtime

  # The four declaration kinds, each written so its predicate answers `nil` — the value the
  # wrapper used to disagree about.
  @declarations %{
    # Guarded on `:n`, which only the transition sets: an invariant that answered `nil` at
    # `init/1` too would kill the server inside `start_link/3`, and the test would be about
    # a server that never started.
    invariant:
      ~s|invariant :i, desc: "i" do\n  if Map.has_key?(state, :n), do: state[:absent], else: true\nend|,
    action_property: ~s|action_property :p, desc: "p" do\n  new[:absent]\nend|,
    precondition: ~s|precondition {:go, n}, desc: "pre" do\n  state[:absent] && n\nend|,
    postcondition: ~s|postcondition {:go, n}, desc: "post" do\n  new[:absent] && n\nend|
  }

  describe "a declaration that answers a non-boolean" do
    # One test over all four, because the claim is that they agree. Asserting them
    # separately is what let them drift.
    for kind <- [:invariant, :action_property, :precondition, :postcondition] do
      test "#{kind}: `nil` is a violation, not a CaseClauseError" do
        kind = unquote(kind)
        module = compile!([kind], "NonBoolean#{Macro.camelize(to_string(kind))}")

        assert {:violation, violation} = go(module)
        assert violation.type == kind
      end
    end

    test "and the four agree, which is the whole point" do
      types =
        for kind <- Map.keys(@declarations) do
          module = compile!([kind], "Agree#{Macro.camelize(to_string(kind))}")
          {:violation, violation} = go(module)
          violation.type
        end

      assert Enum.sort(types) == Enum.sort(Map.keys(@declarations)), """
      one of the four declaration kinds did not report a violation for a `nil` predicate.
      The specification says "a boolean expression" for all four and notes no difference
      between them, so a difference here is one path diverging silently.
      """
    end

    # `Runtime` is where the reading lives, so it is also where it can be asked directly.
    #
    # A truthy non-boolean used to HOLD here, while Layer 2 refused the same predicate with a
    # `PredicateError` — one predicate, two verdicts, against 02-dsl-semantics.md §5 (#418,
    # for #401). It is now a finding under both telemetry settings, and the report names the
    # value, so the reader learns the predicate is malformed rather than that it was false.
    test "a truthy non-boolean is reported, naming the value, under both telemetry settings" do
      module = compile!([:invariant], "TruthyInvariant", ~s|invariant :i do\n  :yes\nend|)

      for verbose <- [[], [:verbose]] do
        violation =
          assert_raise ExTLA.Invariant.Violation, fn ->
            apply(Runtime, :check_invariants!, [module, [:i], %{}] ++ verbose)
          end

        assert Exception.message(violation) =~ "returned :yes, which is not a boolean"
      end
    end

    test "and `nil` says it is not a boolean, while `false` is an ordinary violation" do
      module =
        compile!([:invariant], "NilOrFalse", ~s|invariant :i do\n  state[:answer]\nend|)

      nil_report =
        assert_raise ExTLA.Invariant.Violation, fn ->
          Runtime.check_invariants!(module, [:i], %{answer: nil})
        end

      false_report =
        assert_raise ExTLA.Invariant.Violation, fn ->
          Runtime.check_invariants!(module, [:i], %{answer: false})
        end

      assert Exception.message(nil_report) =~ "returned nil, which is not a boolean"
      refute Exception.message(false_report) =~ "not a boolean"
      assert Runtime.check_invariants!(module, [:i], %{answer: true}) == :ok
    end
  end

  # The guard against the two layers drifting apart again: one predicate body, declared once
  # as a Layer 1 invariant and once as a Layer 2 invariant, and both refuse it (#418).
  describe "Layer 1 and Layer 2 on the same non-boolean predicate" do
    test "both refuse it" do
      layer1 = compile!([:invariant], "SharedLayer1", ~s|invariant :i do\n  :yes\nend|)

      assert_raise ExTLA.Invariant.Violation, ~r/not a boolean/, fn ->
        Runtime.check_invariants!(layer1, [:i], %{})
      end

      layer2 = Module.concat(__MODULE__, "SharedLayer2#{System.unique_integer([:positive])}")

      Code.compile_string("""
      defmodule #{inspect(layer2)} do
        use ExTLA.Spec
        variable :n, type: 0..0
        init do
          n = 0
        end
        invariant :i do
          :yes
        end
      end
      """)

      assert_raise ExTLA.Spec.PredicateError, ~r/:yes/, fn ->
        ExTLA.ModelChecker.run(layer2, %{})
      end
    end
  end

  describe "the instrumented module" do
    # The enumeration IS the test. #317's defect was in exactly one of these sixteen — the
    # one with preconditions and nothing else — and it survived because nothing compiled the
    # combinations, only the modules the suite happened to need.
    test "compiles warning-free in every combination of declarations" do
      kinds = Map.keys(@declarations)

      combinations =
        for n <- 0..length(kinds), combination <- comb(kinds, n), do: Enum.sort(combination)

      assert length(combinations) == 16

      noisy =
        for combination <- combinations,
            warnings = compile_warnings(combination),
            warnings != [],
            do: "#{inspect(combination)} → #{Enum.join(warnings, "; ")}"

      assert noisy == [], """
      #{length(noisy)} declaration combination(s) made the compiler warn about code the
      user did not write:

        #{Enum.join(noisy, "\n  ")}

      The wrapper binds `tla_new_state` for the post-state. Only postconditions, invariants
      and action properties read it, so a module declaring none of those must not be given
      the binding — nor pay the extraction call that produces it.
      """
    end

    # Anti-vacuity: the detector must see a warning where there is one, or the assertion
    # above passes by compiling nothing.
    test "and the warning detector sees one when there is one" do
      warnings =
        warnings_of("""
        defmodule #{unique("Unused")} do
          def f(x) do
            unused = x + 1
            :ok
          end
        end
        """)

      assert Enum.any?(warnings, &(&1 =~ "unused"))
    end
  end

  # ── Compiling ───────────────────────────────────────────────────────────────

  defp source(kinds, name, override) do
    declarations =
      kinds
      |> Enum.map(fn kind -> override || Map.fetch!(@declarations, kind) end)
      |> Enum.join("\n\n")

    """
    defmodule #{name} do
      use GenServer
      use ExTLA.Invariant

    #{declarations}

      @impl true
      def init(state), do: {:ok, state}

      @impl true
      def handle_call({:go, n}, _from, state), do: {:reply, n, Map.put(state, :n, n)}
    end
    """
  end

  defp compile!(kinds, name, override \\ nil) do
    name = unique(name)
    [{module, _binary} | _] = Code.compile_string(source(kinds, name, override))
    module
  end

  defp compile_warnings(kinds) do
    kinds
    |> source(unique("Combination"), nil)
    |> warnings_of()
  end

  # `Code.with_diagnostics/1` rather than `capture_io(:stderr, …)`: a warning is a
  # diagnostic, and reading it as one keeps this from depending on where the compiler
  # happens to print.
  #
  # No `Code.put_compiler_option(:ignore_module_conflict, true)` here, though this used to
  # set one. It is a compiler-global — set anywhere, read everywhere — and this file is
  # `async: true`, so it suppressed module-conflict warnings across every test running
  # beside it (#322). It was also never needed: `unique/1` names every module after a fresh
  # `System.unique_integer/1`, so nothing here is ever a redefinition.
  defp warnings_of(code) do
    {_result, diagnostics} =
      Code.with_diagnostics(fn ->
        Code.compile_string(code)
      end)

    for %{severity: :warning, message: message} <- diagnostics, do: message
  end

  defp unique(prefix),
    do: :"ExTLA.DeclarationShapes.#{prefix}#{System.unique_integer([:positive])}"

  defp comb(_list, 0), do: [[]]
  defp comb([], _n), do: []
  defp comb([head | tail], n), do: Enum.map(comb(tail, n - 1), &[head | &1]) ++ comb(tail, n)

  # ── Driving ─────────────────────────────────────────────────────────────────

  defp go(module) do
    {:ok, pid} = GenServer.start_link(module, %{})
    Process.unlink(pid)
    ExTLA.TestCall.call(pid, {:go, 1})
  end
end
