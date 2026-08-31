defmodule TLA.Spec.DiagnosticsTest do
  @moduledoc """
  The §7 compile-time validation table, one test per diagnostic.

  These matter more than they look. "The quality of these messages is most of the
  difference between a DSL people adopt and one they bounce off; they are a
  deliverable, not a nicety" (`02-dsl-semantics.md` §7) — so each test asserts
  both that the spec is rejected and that the message says something an author
  can act on.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "names" do
    test "an undeclared variable read names the declared ones" do
      error =
        refuse("""
        variable :x
        init do
          x = 0
        end
        action :bump do
          require y > 0
          x = x + 1
        end
        """)

      assert error =~ "undeclared variable: y"
      assert error =~ "Declared: :x."
    end

    test "an assignment to an undeclared variable is caught" do
      assert refuse("""
             variable :x
             init do
               x = 0
               y = 1
             end
             """) =~ "assignment to undeclared variable: y"
    end

    test "an undeclared constant is caught" do
      assert refuse("""
             variable :x
             init do
               x = ^limit
             end
             """) =~ "undeclared constant: ^limit"
    end

    # The likeliest typo in the whole DSL, so it gets its own message rather than
    # falling through to "undeclared variable".
    test "a constant referenced without the pin says so" do
      error =
        refuse("""
        constant :limit
        variable :x
        init do
          x = limit
        end
        """)

      assert error =~ "constant :limit referenced without `^`"
      assert error =~ "Write `^limit`"
    end

    test "assigning to a constant is caught" do
      assert refuse("""
             constant :limit
             variable :x
             init do
               x = 0
               limit = 1
             end
             """) =~ "limit is a constant"
    end

    test "a reserved name is rejected at the declaration" do
      for name <- [:state, :old, :new] do
        assert refuse("variable :#{name}") =~ "is a reserved name"
      end
    end

    test "a second declaration of one name is rejected" do
      assert refuse("""
             variable :x
             variable :x
             """) =~ ":x is already declared"

      assert refuse("""
             constant :c
             variable :c
             """) =~ ":c is already declared"
    end
  end

  describe "action bodies" do
    test "a variable assigned twice is rejected, not resolved last-write-wins" do
      error =
        refuse("""
        variable :x
        init do
          x = 0
        end
        action :broken do
          x = 1
          x = 2
        end
        """)

      assert error =~ "variable :x assigned 2 times"
      assert error =~ "conjunction, not a sequence"
    end

    test "a destructuring assignment without let points at let" do
      assert refuse("""
             variable :x
             init do
               x = 0
             end
             action :a do
               {a, b} = {1, 2}
               x = a + b
             end
             """) =~ "destructuring assignment without `let`"
    end

    test "a statement that is neither guard, let nor assignment is rejected" do
      assert refuse("""
             variable :x
             init do
               x = 0
             end
             action :a do
               IO.puts("hello")
               x = 1
             end
             """) =~ "unexpected statement"
    end

    test "a let may shadow nothing" do
      assert refuse("""
             variable :x
             init do
               x = 0
             end
             action :a do
               let x = 1
               x = 2
             end
             """) =~ "`let` binds :x, which is a declared variable"

      assert refuse("""
             constant :c
             variable :x
             init do
               x = 0
             end
             invariant :i do
               let c = 1
               c > 0
             end
             """) =~ "`let` binds :c, which is a declared constant"
    end
  end

  describe "init" do
    test "cannot read a variable" do
      assert refuse("""
             variable :x
             variable :y
             init do
               x = 0
               y = x
             end
             """) =~ "`init` cannot read variable :x"
    end

    test "must assign every declared variable" do
      error =
        refuse("""
        variable :x
        variable :y
        init do
          x = 0
        end
        """)

      assert error =~ "`init` does not assign :y"
      assert error =~ "KeyError"
    end

    test "cannot be guarded" do
      assert refuse("""
             variable :x
             init do
               require true
               x = 0
             end
             """) =~ "`require` is not permitted in `init`"
    end

    # A spec with variables and no init has no reachable states, and a checker
    # would report "no violations" over an empty search.
    test "is required when there are variables" do
      assert refuse("variable :x") =~ "no `init` block"
    end
  end

  describe "invariants, terminals and action properties" do
    test "an invariant may not assign a variable" do
      assert refuse("""
             variable :x
             init do
               x = 0
             end
             invariant :i do
               x = 1
               true
             end
             """) =~ "assignment to variable :x outside `init`/`action`"
    end

    test "a bare variable in an action_property names old. and new." do
      error =
        refuse("""
        variable :x
        init do
          x = 0
        end
        action_property :p do
          x >= 0
        end
        """)

      assert error =~ "bare variable :x in an action_property"
      assert error =~ "old.x"
      assert error =~ "new.x"
    end
  end

  describe "params" do
    test "a param that draws from neither a set, a literal nor a function is rejected" do
      error =
        refuse("""
        variable :x
        init do
          x = 0
        end
        action :a, params: [p: MapSet.new([1, 2])] do
          x = p
        end
        """)

      assert error =~ "param :p draws from a non-set"
      assert error =~ "fn s ->"
    end

    test "a generator of the wrong arity is rejected" do
      assert refuse("""
             variable :x
             init do
               x = 0
             end
             action :a, params: [p: fn s, bound, extra -> [s, bound, extra] end] do
               x = p
             end
             """) =~ "generator takes 3 arguments"
    end

    test "a param may not shadow a declared variable" do
      assert refuse("""
             variable :x
             init do
               x = 0
             end
             action :a, params: [x: [1, 2]] do
               x = 1
             end
             """) =~ "param :x has the same name as a declared variable"
    end

    test "a generator may not read bare variables" do
      assert refuse("""
             variable :queue
             init do
               queue = []
             end
             action :a, params: [item: fn _s -> queue end] do
               queue = []
             end
             """) =~ "bare variable :queue in a `params:` generator"
    end
  end

  describe "types" do
    test "an ill-formed type is rejected with the grammar" do
      error =
        refuse("""
        variable :x, type: (fn -> 1 end)
        init do
          x = 0
        end
        """)

      assert error =~ "ill-formed type"
      assert error =~ "[dom ~> rng]"
    end

    test "a type naming an undeclared constant is rejected" do
      assert refuse("""
             variable :x, type: 0..^cap
             init do
               x = 0
             end
             """) =~ "^cap, which is not a declared constant"
    end

    # Deferred to @before_compile precisely so this compiles: a type may name a
    # constant declared further down the module.
    test "a type may name a constant declared after it" do
      assert accepts("""
             variable :x, type: 0..^cap
             constant :cap
             init do
               x = 0
             end
             """)
    end
  end

  describe "temporal formulas" do
    test "a conjunction of formulas is rejected, naming the operator" do
      error =
        refuse("""
        variable :x
        init do
          x = 0
        end
        temporal :t do
          eventually(x == 1) and eventually(x == 2)
        end
        """)

      assert error =~ "unsupported temporal operator: eventually/1"
      assert error =~ "no negation, conjunction or disjunction OF FORMULAS"
    end

    test "a formula where a state predicate is required is rejected" do
      assert refuse("""
             variable :x
             init do
               x = 0
             end
             temporal :t do
               (x == 0) ~> always(x == 1)
             end
             """) =~ "where a state predicate is required"
    end

    test "a quantifier over a state-dependent set is rejected" do
      assert refuse("""
             variable :xs
             init do
               xs = []
             end
             temporal :t do
               Enum.all?(xs, fn x -> eventually(x == 1) end)
             end
             """) =~ "must range over a constant or a literal list"
    end

    test "a multi-statement temporal block is rejected" do
      assert refuse("""
             variable :x
             init do
               x = 0
             end
             temporal :t do
               let y = 1
               eventually(x == y)
             end
             """) =~ "single formula"
    end
  end

  describe "fairness" do
    test "an unknown action lists the declared ones" do
      error =
        refuse("""
        variable :x
        init do
          x = 0
        end
        action :bump do
          x = x + 1
        end
        fairness :weak, [:typo]
        """)

      assert error =~ "unknown action in fairness: :typo"
      assert error =~ "Declared actions: :bump."
    end

    test "params that are not a leading prefix are rejected" do
      assert refuse("""
             constant :ps
             variable :x
             init do
               x = 0
             end
             action :a, params: [p: ^ps, q: ^ps] do
               x = 1
             end
             fairness :weak, a: [:q]
             """) =~ "are not a leading prefix"
    end

    # A state function returns a different set in every state, so there is no
    # fixed collection of bindings to attach one constraint each to.
    test "a state-drawn param cannot be quantified over" do
      assert refuse("""
             variable :pending
             init do
               pending = []
             end
             action :take, params: [t: fn s -> s.pending end] do
               pending = []
             end
             fairness :weak, take: [:t]
             """) =~ "fairness over a state-drawn param"
    end

    test "a kind other than :weak or :strong is rejected" do
      assert refuse("""
             variable :x
             init do
               x = 0
             end
             action :a do
               x = 1
             end
             fairness :eventual, [:a]
             """) =~ "fairness kind must be :weak or :strong"
    end
  end

  describe "duplicate declarations" do
    test "two actions of one name are rejected" do
      assert refuse("""
             variable :x
             init do
               x = 0
             end
             action :a do
               x = 1
             end
             action :a do
               x = 2
             end
             """) =~ "action :a is declared 2 times"
    end

    test "two invariants of one name are rejected" do
      assert refuse("""
             variable :x
             init do
               x = 0
             end
             invariant :i do
               true
             end
             invariant :i do
               false
             end
             """) =~ "invariant :i is declared 2 times"
    end
  end

  describe "warnings" do
    # `let` binds a name, and a name the compiled function never reads is an
    # unused-variable warning the spec author cannot silence: they cannot
    # underscore it, because the OTHER function does read it. So the block
    # compiler drops what each function does not read.
    test "a let read by only one of the two compiled functions warns in neither" do
      warnings =
        capture_io(:stderr, fn ->
          Code.compile_string(
            source("""
            variable :n, type: 0..3
            variable :log, type: :seq
            init do
              n = 0
              log = seq()
            end
            action :bump do
              let room = 3 - n
              require room > 0
              let entry = %{was: n}
              n = n + 1
              log = append(log, entry)
            end
            """)
          )
        end)

      refute warnings =~ "unused"
    end
  end

  describe "diagnostic shape" do
    test "carries the module, the line and the declaration" do
      error =
        assert_raise TLA.Spec.CompileError, fn ->
          capture_io(:stderr, fn ->
            Code.compile_string(
              source("""
              variable :x
              init do
                x = 0
              end
              action :bump do
                x = nope
              end
              """)
            )
          end)
        end

      assert error.declaration == "action :bump"
      assert is_integer(error.line)
      assert Exception.message(error) =~ "in action :bump:"
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp refuse(body) do
    error =
      assert_raise TLA.Spec.CompileError, fn ->
        capture_io(:stderr, fn -> Code.compile_string(source(body)) end)
      end

    Exception.message(error)
  end

  defp accepts(body) do
    capture_io(:stderr, fn -> Code.compile_string(source(body)) end)
    true
  end

  defp source(body) do
    """
    defmodule TLA.Diagnostics.Case#{System.unique_integer([:positive])} do
      use TLA.Spec
    #{body}
    end
    """
  end
end
