defmodule ExTLA.ConformanceTest do
  use ExUnit.Case, async: true

  alias ExTLA.Conformance.Counter.{Mutants, Refinement, Spec}
  alias ExTLA.Refinement, as: R

  @constants %{max_val: 5}

  describe "the mapping that conforms" do
    test "is accepted, and says which rules it could not decide" do
      assert {:ok, deferred} = R.validate!(Refinement, Spec, @constants)

      # Not a shortfall to be embarrassed about: there is no concrete state at compile
      # time to map, so these are checked on every mapping instead. Saying so is the
      # difference between a validator with limits and one that overstates itself.
      # Each entry is tagged since #169: `:always` for a rule no compile can decide, and
      # `:for_this_mapping` for one that went unchecked for this mapping in particular.
      # `use ExTLA.GenServer` prints only the second kind, so the tag is what keeps a
      # compile-time message from firing on every module and being learned as noise.
      assert length(deferred) == 2
      assert Enum.all?(deferred, &match?({:always, _rule}, &1))
      assert Enum.any?(deferred, fn {_tag, rule} -> rule =~ "abstract/1" end)
      assert Enum.any?(deferred, fn {_tag, rule} -> rule =~ "permitted state term" end)
    end

    test "maps a concrete state onto exactly the spec's variables" do
      concrete = %{value: 2, status: :ready, max: 5}

      assert R.abstract!(Refinement, compiled(), concrete) == %{count: 2, status: :ready}
    end

    test "resolves the spec's constants the way mix tla.check does when given none" do
      assert {:ok, _deferred} = R.validate!(Refinement, Spec)
    end
  end

  # The corpus's oracle. Every one of these must fail, and fail for the stated reason: a
  # validator that accepts a broken mapping is worse than no validator, because the
  # conformance report that follows carries its authority.
  describe "the mutants" do
    test "a mapping that forgets a variable is named, with the variable" do
      error =
        assert_raise R.Error, fn ->
          R.abstract!(Mutants.MissingVariable, compiled(), %{value: 1, status: :ready})
        end

      assert Exception.message(error) =~ "missing: [:status]"
      assert Exception.message(error) =~ "every predicate reading it fails"
    end

    test "a mapping that invents a variable is named, with the variable" do
      error =
        assert_raise R.Error, fn ->
          R.abstract!(Mutants.ExtraVariable, compiled(), %{value: 1, status: :ready})
        end

      assert Exception.message(error) =~ "extra:   [:max]"
      assert Exception.message(error) =~ "every step diverges"
    end

    test "a mapping with no catch-all is reported as not total, rather than crashing" do
      error = assert_raise R.Error, fn -> R.validate!(Mutants.NotTotal, Spec, @constants) end

      assert Exception.message(error) =~ "is not total"
      assert Exception.message(error) =~ "def abstract_action(_), do: :unmapped"
    end

    # The complement of the one above, and the reason the probe's rescue was narrowed
    # (#315). The probe was scoped to the whole of `total!/1`, so a `FunctionClauseError`
    # from any helper beneath it was read as the mapping's own missing catch-all — the one
    # thing this mapping demonstrably does not lack. It now leaves by `reraise`, naming the
    # helper, which is where the bug actually is.
    test "a mapping whose own helper is partial is reported as that, not as a missing catch-all" do
      error =
        assert_raise FunctionClauseError, fn ->
          R.validate!(Mutants.PartialHelper, Spec, @constants)
        end

      assert Exception.message(error) =~ "Mutants.PartialHelper.classify/1"
      refute Exception.message(error) =~ "is not total"
    end

    test "a mapping whose two directions disagree is caught by the round trip" do
      error =
        assert_raise R.Error, fn -> R.validate!(Mutants.WrongWayRound, Spec, @constants) end

      assert Exception.message(error) =~ "does not round-trip increment"
      assert Exception.message(error) =~ ":done"
    end

    test "an action no message can produce is named as dead in this implementation" do
      error =
        assert_raise R.Error, fn -> R.validate!(Mutants.ActionNeverNamed, Spec, @constants) end

      assert Exception.message(error) =~ "names no message for [:reset]"
      assert Exception.message(error) =~ "dead in this implementation"
    end

    # The mutant one door over, and the one the corpus lacked: `ActionNeverNamed` names
    # `reset` WRONGLY, this one does not name it at all. Until #321 the second raised
    # `FunctionClauseError` from inside `validate!/3`, because the rule was answered by
    # calling the callback rather than by reading which actions its clauses cover (#299).
    test "an action with no clause at all is named, rather than crashed on" do
      error =
        assert_raise R.Error, fn -> R.validate!(Mutants.NoClauseForAction, Spec, @constants) end

      assert Exception.message(error) =~ "has no clause for [:reset]"
      assert Exception.message(error) =~ "a mapping that defines none is legal"
    end

    test "a module that is not a refinement mapping at all is refused" do
      error =
        assert_raise R.Error, fn -> R.validate!(Mutants.NoAbstractAction, Spec, @constants) end

      assert Exception.message(error) =~ "does not define abstract_action/1"
      assert Exception.message(error) =~ "invariant checking on a projection"
    end
  end

  describe "the spec side of the entry" do
    # The corpus is only worth having if the specification half is right, so the entry
    # carries the same assertion `mix tla.check` would make about it.
    test "the specification itself verifies, liveness included" do
      result =
        ExTLA.ModelChecker.run(Spec, %{constants: @constants, check_liveness: true})

      assert result.status == :ok
      assert result.distinct_states == 11
    end
  end

  # #213. The runtime's per-process spec cache matched on the module name alone, so a server
  # that outlived a recompile of its spec kept the STRUCTURE it first loaded: the compiled
  # closures are remote captures and follow a recompile on their own, but the list of
  # invariants does not, so an invariant added to the spec was never checked by a running
  # server. The cache is keyed on the module's md5 now. A throwaway module, so the recompile
  # touches nothing else.
  describe "the runtime's spec cache" do
    test "a recompiled spec is picked up by a process that had cached the old one" do
      name = "ExTLA.ConformanceTest.Recompiled#{System.unique_integer([:positive])}"

      source = fn invariants ->
        """
        defmodule #{name} do
          use ExTLA.Spec
          variable :n, type: 0..5
          init do
            n = 0
          end
          action :tick do
            require n < 5
            n = n + 1
          end
          #{invariants}
        end
        """
      end

      ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_string(source.("")) end)
      module = String.to_existing_atom("Elixir." <> name)

      first = ExTLA.GenServer.Runtime.context(module)
      assert Enum.map(first.spec.invariants, & &1.name) == []

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string(source.("invariant :small do\n  n < 3\nend"))
      end)

      second = ExTLA.GenServer.Runtime.context(module)

      assert Enum.map(second.spec.invariants, & &1.name) == [:small],
             "the invariant added by the recompile is missing: the cache served the old spec"
    end
  end

  defp compiled, do: ExTLA.Spec.Compiled.from_module(Spec)
end
