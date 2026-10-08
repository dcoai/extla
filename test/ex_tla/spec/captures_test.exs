defmodule ExTLA.Spec.CapturesTest do
  @moduledoc """
  A function capture in a spec body names a function, never a state variable (#359, #369).

  `&abs/1`'s name node has a variable's shape, so the rewriter resolved it as one and refused
  the block as "undeclared variable: abs", with advice to declare `variable :abs`. Every
  form a spec author might write is used below in every kind of block, and the spec is
  model-checked, so a capture that compiled to the wrong thing would show in the verdict
  and the counts, not only in whether the module compiles.
  """
  use ExUnit.Case, async: true

  alias ExTLA.Spec.Compiled

  # `size` is a state variable AND `ExTLA.Spec.Helpers.size/1`. A bare `size` reads the
  # variable; `&size/1` is the function. That is the case the rule is for.
  defmodule Everywhere do
    use ExTLA.Spec

    variable :n, type: 0..3
    variable :size, type: 0..2

    init do
      # operator capture
      n = Enum.reduce([0, 0], 0, &+/2)
      # helper capture, while a variable of the same name exists
      size = [set([])] |> Enum.map(&size/1) |> hd()
    end

    action :step, params: [k: fn _s -> Enum.map([-1], &abs/1) end] do
      # bare Kernel capture in a guard
      require Enum.all?([n], &is_integer/1)
      require n < 3
      # qualified capture in a let
      let m = Enum.reduce([n, k], 0, &Kernel.+/2)
      n = m
      size = [set([1, 2])] |> Enum.map(&size/1) |> hd()
    end

    invariant :bounded do
      # `&(&1 …)` shorthand, which reads a variable through the normal path
      Enum.all?([n], &(&1 <= 3)) and Enum.map([size], &abs/1) == [size]
    end

    action_property :rises do
      Enum.reduce([old.n], new.n, &min/2) == old.n
    end

    terminal :at_top do
      Enum.any?([n], &(&1 == 3))
    end

    temporal :reaches_top do
      eventually(Enum.member?(Enum.map([n], &abs/1), 3))
    end

    fairness :weak, [:step]
  end

  test "every capture form compiles in every block kind, and the spec checks as written" do
    result = ExTLA.ModelChecker.run(Everywhere, %{check_liveness: true})

    assert result.status == :ok
    # n runs 0..3; size is 0 initially and 2 after any step. So the states are {0,0}, then
    # {1,2}, {2,2}, {3,2}: four. A capture compiled to anything else changes this.
    assert result.distinct_states == 4
  end

  test "the captures compute what Elixir means by them" do
    spec = Compiled.from_module(Everywhere)
    [init] = spec.init
    assert init.(%{}) == %{n: 0, size: 0}

    step = Compiled.action(spec, :step)
    assert [%{k: 1}] = ExTLA.ModelChecker.bindings(step, %{}, %{n: 0, size: 0})
    assert step.transition.(%{}, %{n: 1, size: 0}, %{k: 1}) == %{n: 2, size: 2}

    [bounded] = spec.invariants -- Enum.filter(spec.invariants, &(&1.name == :type_ok))
    assert bounded.predicate.(%{}, %{n: 3, size: 2})
    refute bounded.predicate.(%{}, %{n: 4, size: 2})
  end
end

defmodule ExTLA.Spec.CapturesTypoTest do
  @moduledoc """
  The other half of `ExTLA.Spec.CapturesTest` (#369), on its own because it reads stderr.

  `async: false` because `capture_io(:stderr)` captures the VM's standard-error device, not
  this process's: run concurrently, it would take other tests' output too. The diagnostic it
  reads is the point. The exception only says errors were logged.
  """
  use ExUnit.Case, async: false

  # Leaving a capture's name alone must not turn a typo into a silent pass: an undefined
  # function is still refused, by Elixir's own compiler, naming the function.
  test "a capture of a function that does not exist is still a compile error" do
    source = """
    defmodule ExTLA.Spec.CapturesTest.Typo do
      use ExTLA.Spec
      variable :n, type: 0..1
      init do
        n = 0
      end
      invariant :typo do
        Enum.all?([n], &no_such_function/1)
      end
    end
    """

    # The name is in the diagnostic Elixir writes, not in the exception, which only says
    # errors were logged.
    diagnostic =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise CompileError, fn -> Code.compile_string(source, "typo.ex") end
      end)

    assert diagnostic =~ "undefined function no_such_function/1"
    refute diagnostic =~ "undeclared variable"
  end
end
