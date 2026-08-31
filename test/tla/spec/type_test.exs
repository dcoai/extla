defmodule TLA.Spec.TypeTest do
  @moduledoc """
  The §1.5 type grammar, resolved against constants at model-check time and
  checked as the implicit `:type_ok` invariant.

  D-19: types are checked as an invariant rather than used to prune, so a state
  outside its type is a *reported violation* and not a silently narrower search.
  """
  use ExUnit.Case, async: true

  alias TLA.ModelChecker
  alias TLA.Spec.Type

  defp resolve(quoted, constants \\ %{}), do: Type.resolve!(quoted, constants, :x)

  describe "literals and lists" do
    test "a literal matches only itself" do
      assert Type.member?(resolve(quote(do: :idle)), :idle)
      refute Type.member?(resolve(quote(do: :idle)), :busy)
      assert Type.member?(resolve(quote(do: 0)), 0)
      refute Type.member?(resolve(quote(do: 0)), 1)
    end

    test "a list is one of the listed literals" do
      type = resolve(quote(do: [:idle, :busy]))

      assert Type.member?(type, :idle)
      assert Type.member?(type, :busy)
      refute Type.member?(type, :done)
    end

    # `:set` bare means any MapSet, but inside a list there is nothing for the
    # special form to be ambiguous with.
    test "a special atom inside a list is the literal atom" do
      assert Type.member?(resolve(quote(do: [:set, :seq])), :set)
      refute Type.member?(resolve(quote(do: [:set, :seq])), MapSet.new())
    end
  end

  describe "ranges" do
    test "are inclusive and integer-only" do
      type = resolve(quote(do: 0..3))

      assert Type.member?(type, 0)
      assert Type.member?(type, 3)
      refute Type.member?(type, 4)
      refute Type.member?(type, -1)
      refute Type.member?(type, :zero)
    end

    test "resolve constant bounds at check time" do
      type = resolve(quote(do: 0..^cap), %{cap: 5})

      assert Type.member?(type, 5)
      refute Type.member?(type, 6)
    end

    test "say so when a bound's constant is not an integer" do
      assert_raise ArgumentError, ~r/not an integer/, fn ->
        resolve(quote(do: 0..^cap), %{cap: :five})
      end
    end

    # `-1` is unary minus applied to 1 in the AST, not an integer literal, so
    # this had to be spelled out. Paxos's `maxBal` is -1 until the acceptor
    # promises something, and a grammar that cannot say so cannot type the spec.
    test "a bound may be negative" do
      type = resolve(quote(do: -1..^cap), %{cap: 2})

      assert Type.member?(type, -1)
      assert Type.member?(type, 2)
      refute Type.member?(type, -2)
      refute Type.member?(type, 3)
    end
  end

  describe "constants" do
    test "^name is any element of the constant set" do
      type = resolve(quote(do: ^accounts), %{accounts: MapSet.new([:alice, :bob])})

      assert Type.member?(type, :alice)
      refute Type.member?(type, :carol)
    end

    test "a constant that is not a set is an error, not a silent mismatch" do
      assert_raise ArgumentError, ~r/which is not a set/, fn ->
        resolve(quote(do: ^cap), %{cap: 3})
      end
    end

    test "a constant the run did not assign is an error" do
      assert_raise ArgumentError, ~r/did not assign/, fn ->
        resolve(quote(do: ^missing), %{})
      end
    end
  end

  describe "compound types" do
    test "union accepts either side" do
      type = resolve(quote(do: :none | 0..2))

      assert Type.member?(type, :none)
      assert Type.member?(type, 2)
      refute Type.member?(type, 3)
    end

    test "tuples are checked element-wise, arity included" do
      type = resolve(quote(do: {:ok, 0..2}))

      assert Type.member?(type, {:ok, 1})
      refute Type.member?(type, {:ok, 9})
      refute Type.member?(type, {:error, 1})
      refute Type.member?(type, {:ok, 1, :extra})
    end

    test "int and nat" do
      assert Type.member?(resolve(quote(do: :int)), -3)
      assert Type.member?(resolve(quote(do: :nat)), 0)
      refute Type.member?(resolve(quote(do: :nat)), -1)
      refute Type.member?(resolve(quote(do: :int)), :three)
    end

    test "set and seq" do
      assert Type.member?(resolve(quote(do: :set)), MapSet.new([1]))
      refute Type.member?(resolve(quote(do: :set)), [1])
      assert Type.member?(resolve(quote(do: :seq)), [1])
      refute Type.member?(resolve(quote(do: :seq)), MapSet.new([1]))
    end
  end

  describe "function types" do
    setup do
      %{type: resolve(quote(do: [^accounts ~> 0..2]), %{accounts: MapSet.new([:alice, :bob])})}
    end

    test "require the domain to be exactly the declared keys", %{type: type} do
      assert Type.member?(type, %{alice: 1, bob: 2})

      # TLA+ functions are total. A map missing a key its domain declares is what
      # an action that forgot to extend it produces, and it is the failure the
      # domain check exists to catch.
      refute Type.member?(type, %{alice: 1})
      refute Type.member?(type, %{alice: 1, bob: 2, carol: 0})
    end

    test "check every value against the range", %{type: type} do
      refute Type.member?(type, %{alice: 1, bob: 9})
    end

    test "reject a non-map", %{type: type} do
      refute Type.member?(type, alice: 1, bob: 2)
      refute Type.member?(type, MapSet.new())
    end

    test "a domain that does not denote a set is an error" do
      assert_raise ArgumentError, ~r/domain has to denote a set/, fn ->
        resolve(quote(do: [:set ~> 0..2]))
      end
    end
  end

  describe "the implicit type_ok invariant" do
    test "is checked in every reachable state, ahead of the declared invariants" do
      spec = TLA.Spec.Compiled.from_module(TLA.TestSpecs.Counter)
      [first | _] = ModelChecker.checked_invariants(spec, %{max: 2})

      assert first.name == :type_ok
    end

    test "is absent when no variable is typed" do
      spec = TLA.Spec.Compiled.from_module(TLA.TestSpecs.Swap)

      refute Enum.any?(ModelChecker.checked_invariants(spec, %{}), &(&1.name == :type_ok))
    end

    test "reports a state outside its type rather than pruning it" do
      defmodule Overflows do
        use TLA.Spec

        variable :n, type: 0..2

        init do
          n = 0
        end

        action :tick do
          require n < 5
          n = n + 1
        end
      end

      result = ModelChecker.run(Overflows, %{})

      assert result.status == :violation
      assert result.violation.property == :type_ok
      assert List.last(result.violation.states) == %{n: 3}
    end

    test "names the variable, its value and its declared type" do
      defmodule Wrong do
        use TLA.Spec

        variable :status, type: [:idle, :busy]

        init do
          status = :idle
        end

        action :break do
          status = :exploded
        end
      end

      message = ModelChecker.run(Wrong, %{}).violation.message

      assert message =~ "type_ok"
      assert message =~ "status = :exploded"
      assert message =~ ":idle | :busy"
    end

    test "can be selected and deselected like any other invariant" do
      defmodule Overflows2 do
        use TLA.Spec

        variable :n, type: 0..2

        init do
          n = 0
        end

        action :tick do
          require n < 5
          n = n + 1
        end
      end

      assert ModelChecker.run(Overflows2, %{invariants: [:type_ok]}).status == :violation
      assert ModelChecker.run(Overflows2, %{invariants: [], check_deadlock: false}).status == :ok
    end

    test "cannot be declared, because it is already checked" do
      assert_raise TLA.Spec.CompileError, ~r/checked implicitly and cannot be declared/, fn ->
        Code.compile_string("""
        defmodule TLA.TypeOkClash#{System.unique_integer([:positive])} do
          use TLA.Spec
          variable :n
          init do
            n = 0
          end
          invariant :type_ok do
            n >= 0
          end
        end
        """)
      end
    end
  end
end
