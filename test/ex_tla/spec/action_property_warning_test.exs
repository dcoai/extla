defmodule ExTLA.Spec.ActionPropertyWarningTest do
  @moduledoc """
  A one-sided `action_property` must compile without warning about a variable the author
  never wrote (#32).

  **These tests are about the compiler's output, not about the checker's.** Every corpus
  entry and every fixture in `test/support/specs.ex` references both `old` and `new`, which
  is exactly why this went unnoticed until `extc` hit it — so another fixture would prove
  nothing. What proves it is compiling a one-sided property and reading stderr.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ExTLA.ModelChecker

  # A fresh module name per compile: compiling two modules with the same name in one run
  # warns about redefinition, which would be indistinguishable from the warning under test.
  defp compile(body) do
    name = "OneSided#{System.unique_integer([:positive])}"

    capture_io(:stderr, fn ->
      Code.compile_string("""
      defmodule #{name} do
        use ExTLA.Spec
        variable :n
        init do
          n = 0
        end
        action :tick do
          require n < 3
          n = n + 1
        end
        #{body}
      end
      """)
    end)
  end

  describe "a property that constrains only one side" do
    # "However it got here, it arrives like this" is an ordinary thing to want to say —
    # it is how you state that every transition INTO a state establishes something — so
    # this is a shape people will write often rather than rarely.
    test "referencing only `new` compiles without a warning" do
      stderr =
        compile("""
        action_property :new_only do
          new.n >= 0
        end
        """)

      refute stderr =~ "unused",
             "a one-sided property warned about a binding the author never wrote:\\n#{stderr}"

      assert stderr == ""
    end

    test "referencing only `old` compiles without a warning" do
      stderr =
        compile("""
        action_property :old_only do
          old.n < 3
        end
        """)

      refute stderr =~ "unused"
      assert stderr == ""
    end

    test "and one referencing both still compiles clean" do
      stderr =
        compile("""
        action_property :both do
          new.n >= old.n
        end
        """)

      assert stderr == ""
    end
  end

  describe "suppressing the warning does not suppress the check" do
    defmodule NewOnly do
      @moduledoc false
      use ExTLA.Spec

      variable :n

      init do
        n = 0
      end

      action :tick do
        require n < 3
        n = n + 1
      end

      # False as soon as `tick` produces n = 1, so a run must refute it. A property that
      # compiled quietly and was then ignored would pass every test above.
      action_property :never_moves do
        new.n == 0
      end
    end

    test "a one-sided property is still evaluated, and still refutes" do
      result = ModelChecker.run(NewOnly, %{check_deadlock: false})

      assert result.status == :violation
      assert result.violation.property == :never_moves
    end
  end

  describe "what must still be an error" do
    # `02-dsl-semantics.md` §4: a bare variable in an `action_property` is a compile error,
    # because `n` alone cannot say which of the two states it means. Marking the bindings
    # generated must not make that ambiguity acceptable.
    test "a bare variable is still rejected" do
      assert_raise ExTLA.Spec.CompileError, fn ->
        Code.compile_string("""
        defmodule BareVar#{System.unique_integer([:positive])} do
          use ExTLA.Spec
          variable :n
          init do
            n = 0
          end
          action :tick do
            require n < 3
            n = n + 1
          end
          action_property :bare do
            n >= 0
          end
        end
        """)
      end
    end
  end
end
