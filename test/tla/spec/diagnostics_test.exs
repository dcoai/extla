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
        refuse(
          """
          variable :x
          init do
            x = 0
          end
          action :bump do
            require y > 0
            x = x + 1
          end
          """,
          :undeclared_variable
        )

      assert error =~ "undeclared variable: y"
      assert error =~ "Declared: :x."
    end

    test "an assignment to an undeclared variable is caught" do
      assert refuse(
               """
               variable :x
               init do
                 x = 0
                 y = 1
               end
               """,
               :assignment_to_undeclared_variable
             ) =~ "assignment to undeclared variable: y"
    end

    test "an undeclared constant is caught" do
      assert refuse(
               """
               variable :x
               init do
                 x = ^limit
               end
               """,
               :undeclared_constant
             ) =~ "undeclared constant: ^limit"
    end

    # The likeliest typo in the whole DSL, so it gets its own message rather than
    # falling through to "undeclared variable".
    test "a constant referenced without the pin says so" do
      error =
        refuse(
          """
          constant :limit
          variable :x
          init do
            x = limit
          end
          """,
          :constant_without_pin
        )

      assert error =~ "constant :limit referenced without `^`"
      assert error =~ "Write `^limit`"
    end

    test "assigning to a constant is caught" do
      assert refuse(
               """
               constant :limit
               variable :x
               init do
                 x = 0
                 limit = 1
               end
               """,
               :assignment_to_undeclared_variable
             ) =~ "limit is a constant"
    end

    test "a reserved name is rejected at the declaration" do
      for name <- [:state, :old, :new] do
        assert refuse("variable :#{name}", :reserved_name) =~ "is a reserved name"
      end
    end

    test "a second declaration of one name is rejected" do
      assert refuse(
               """
               variable :x
               variable :x
               """,
               :already_declared
             ) =~ ":x is already declared"

      assert refuse(
               """
               constant :c
               variable :c
               """,
               :already_declared
             ) =~ ":c is already declared"
    end
  end

  describe "action bodies" do
    test "a variable assigned twice is rejected, not resolved last-write-wins" do
      error =
        refuse(
          """
          variable :x
          init do
            x = 0
          end
          action :broken do
            x = 1
            x = 2
          end
          """,
          :variable_assigned_twice
        )

      assert error =~ "variable :x assigned 2 times"
      assert error =~ "conjunction, not a sequence"
    end

    test "a destructuring assignment without let points at let" do
      assert refuse(
               """
               variable :x
               init do
                 x = 0
               end
               action :a do
                 {a, b} = {1, 2}
                 x = a + b
               end
               """,
               :destructuring_without_let
             ) =~ "destructuring assignment without `let`"
    end

    test "a statement that is neither guard, let nor assignment is rejected" do
      assert refuse(
               """
               variable :x
               init do
                 x = 0
               end
               action :a do
                 IO.puts("hello")
                 x = 1
               end
               """,
               :unexpected_statement
             ) =~ "unexpected statement"
    end

    test "a let may shadow nothing" do
      assert refuse(
               """
               variable :x
               init do
                 x = 0
               end
               action :a do
                 let x = 1
                 x = 2
               end
               """,
               :binder_shadows_variable
             ) =~ "`let` binds :x, which is a declared variable"

      assert refuse(
               """
               constant :c
               variable :x
               init do
                 x = 0
               end
               invariant :i do
                 let c = 1
                 c > 0
               end
               """,
               :binder_shadows_constant
             ) =~ "`let` binds :c, which is a declared constant"
    end

    # #210. §1.3's rule covers three cases and the check enforced two: `let k = 100` under
    # `params: [k: [1, 2]]` compiled, and both bindings produced the same successor.
    test "a let may not shadow a params: name or old/new either" do
      assert refuse(
               """
               variable :x
               init do
                 x = 0
               end
               action :a, params: [k: [1, 2]] do
                 let k = 100
                 x = k
               end
               """,
               :binder_shadows_binding
             ) =~ "`let` binds :k, which this declaration already binds"

      assert refuse(
               """
               variable :x
               init do
                 x = 0
               end
               action_property :p do
                 let old = 1
                 new.x >= old
               end
               """,
               :binder_shadows_binding
             ) =~ "`let` binds :old, which this declaration already binds"
    end
  end

  describe "init" do
    test "cannot read a variable" do
      assert refuse(
               """
               variable :x
               variable :y
               init do
                 x = 0
                 y = x
               end
               """,
               :variable_not_readable_here
             ) =~ "`init` cannot read variable :x"
    end

    test "must assign every declared variable" do
      error =
        refuse(
          """
          variable :x
          variable :y
          init do
            x = 0
          end
          """,
          :init_does_not_assign
        )

      assert error =~ "`init` does not assign :y"
      assert error =~ "KeyError"
    end

    test "cannot be guarded" do
      assert refuse(
               """
               variable :x
               init do
                 require true
                 x = 0
               end
               """,
               :require_in_init
             ) =~ "`require` is not permitted in `init`"
    end

    # A spec with variables and no init has no reachable states, and a checker
    # would report "no violations" over an empty search.
    test "is required when there are variables" do
      assert refuse("variable :x", :no_init_block) =~ "no `init` block"
    end
  end

  # #160. Options were popped by name and the remainder discarded or stored unread, so a key
  # nobody reads and a key nobody wrote were the same thing: `variable :n, type: :nat, bogus: 1`
  # compiled. The accepted set records CONSUMPTION rather than intent — an option accepted and
  # ignored is the same defect one step subtler.
  describe "declaration options" do
    test "an unknown option names the key and what the declaration accepts" do
      error =
        refuse(
          """
          variable :x, type: :nat, bogus: 1
          init do
            x = 0
          end
          """,
          :unknown_option
        )

      assert error =~ "variable :x"
      assert error =~ "unknown option: :bogus"
      assert error =~ "`variable` accepts :type"
    end

    test "several unknown keys are all named" do
      error =
        refuse(
          """
          constant :c, default: 1, one: 2, two: 3
          variable :x
          init do
            x = 0
          end
          """,
          :unknown_option
        )

      assert error =~ "unknown options: :one, :two"
      assert error =~ "`constant` accepts :default"
    end

    # #209. `init` was the eighth options-taking macro and the one without a check, so
    # `init desc: "x", do: …` compiled with the keyword dropped by `pop_do!/3`.
    test "init takes no options, and says so" do
      error =
        refuse(
          """
          variable :x
          init desc: "the start" do
            x = 0
          end
          """,
          :unknown_option
        )

      assert error =~ "in init:"
      assert error =~ "unknown option: :desc"
      assert error =~ "`init` takes no options"

      # The one-list spelling the review found compiling: `init desc: "x", do: …`.
      assert refuse(
               """
               variable :x
               init desc: "the start", do: x = 0
               """,
               :unknown_option
             ) =~ "unknown option: :desc"
    end

    # A block reaches these macros as a `do:` entry in the same keyword list, so a check that
    # ran before `pop_do!/3` would reject every declaration in the project.
    test "the block itself is not mistaken for an unknown option" do
      assert accepts("""
             variable :x, type: :nat
             init do
               x = 0
             end
             action :bump do
               x = x + 1
             end
             invariant :nonneg, desc: "never below zero" do
               x >= 0
             end
             terminal :done, desc: "finished" do
               x == 1
             end
             """)
    end

    # `temporal` used to discard its options entirely, so `desc:` there was accepted and
    # ignored. It is now stored the way the other predicate forms store theirs, which is what
    # makes accepting it honest rather than silence.
    test "a temporal carries its description rather than dropping it" do
      assert accepts("""
             variable :x, type: :nat
             init do
               x = 0
             end
             action :bump do
               x = x + 1
             end
             temporal :eventually_one, desc: "x reaches one" do
               eventually(x == 1)
             end
             """)
    end
  end

  describe "invariants, terminals and action properties" do
    test "an invariant may not assign a variable" do
      assert refuse(
               """
               variable :x
               init do
                 x = 0
               end
               invariant :i do
                 x = 1
                 true
               end
               """,
               :assignment_outside_init_or_action
             ) =~ "assignment to variable :x outside `init`/`action`"
    end

    # #150. `temporal` reaches `TLA.Spec.Temporal.parse!/2`, which does not desugar, so it
    # never saw the check above and a temporal whose body was an assignment COMPILED.
    #
    # This is the one declaration whose failure has no symptom. An invariant that never
    # fires shows up in the coverage report; a temporal formula built from `=` is not
    # refutable, so the run reports that the property HOLDS having checked nothing. The
    # only evidence the gap is closed is a test that fails without the fix, which is why
    # this exists rather than a runtime assertion.
    test "a temporal may not assign a variable either, with the same message" do
      error =
        refuse(
          """
          variable :x
          init do
            x = 0
          end
          temporal :t do
            x = 1
          end
          """,
          :assignment_outside_init_or_action
        )

      assert error =~ "assignment to variable :x outside `init`/`action`"
      assert error =~ "temporal :t"
    end

    # The rule is shared rather than duplicated (`TLA.Spec.Block.reject_assignment!/2`), so
    # the two forms cannot drift apart into two dialects again.
    test "the temporal and invariant messages are the same text" do
      body = fn declaration ->
        """
        variable :x
        init do
          x = 0
        end
        #{declaration}
        """
      end

      invariant =
        refuse(body.("invariant :i do\n  x = 1\n  true\nend"), :assignment_outside_init_or_action)

      temporal = refuse(body.("temporal :t do\n  x = 1\nend"), :assignment_outside_init_or_action)

      hint = "there is no post-state here"
      assert invariant =~ hint
      assert temporal =~ hint
    end

    # #192. The check above stopped at the statement level, so it caught `temporal :t do
    # x = 1 end` — the one shape nobody writes — and not `always(x = 1)`, which compiled
    # and reported that the property holds. `=` on a declared variable is forbidden
    # everywhere outside `init`/`action`, nested or not, so the walk goes all the way down.
    test "an assignment nested under a temporal operator is refused" do
      for formula <- ["always(x = 1)", "eventually(x = 1)", "(x == 0) ~> (x = 1)"] do
        error =
          refuse(
            """
            variable :x
            init do
              x = 0
            end
            action :bump do
              x = x + 1
            end
            temporal :t do
              #{formula}
            end
            """,
            :assignment_outside_init_or_action
          )

        assert error =~ "assignment to variable :x outside `init`/`action`", formula
        assert error =~ "temporal :t", formula
      end
    end

    test "an assignment nested inside an invariant's expression is refused" do
      error =
        refuse(
          """
          variable :n
          variable :status
          init do
            n = 0
            status = :idle
          end
          invariant :i do
            n >= 0 and (status = :done)
          end
          """,
          :assignment_outside_init_or_action
        )

      assert error =~ "assignment to variable :status outside `init`/`action`"
      assert error =~ "invariant :i"
    end

    test "a let that shadows a declared variable is still reported as shadowing" do
      error =
        refuse(
          """
          variable :n
          init do
            n = 0
          end
          invariant :i do
            let n = 1
            n > 0
          end
          """,
          :binder_shadows_variable
        )

      refute error =~ "assignment to variable"
    end

    test "a bare variable in an action_property names old. and new." do
      error =
        refuse(
          """
          variable :x
          init do
            x = 0
          end
          action_property :p do
            x >= 0
          end
          """,
          :variable_not_readable_here
        )

      assert error =~ "bare variable :x in an action_property"
      assert error =~ "old.x"
      assert error =~ "new.x"
    end
  end

  describe "params" do
    test "a param that draws from neither a set, a literal nor a function is rejected" do
      error =
        refuse(
          """
          variable :x
          init do
            x = 0
          end
          action :a, params: [p: MapSet.new([1, 2])] do
            x = p
          end
          """,
          :param_draws_from_a_non_set
        )

      assert error =~ "param :p draws from a non-set"
      assert error =~ "fn s ->"
    end

    test "a generator of the wrong arity is rejected" do
      assert refuse(
               """
               variable :x
               init do
                 x = 0
               end
               action :a, params: [p: fn s, bound, extra -> [s, bound, extra] end] do
                 x = p
               end
               """,
               :param_generator_arity
             ) =~ "generator takes 3 arguments"
    end

    test "a param may not shadow a declared variable" do
      assert refuse(
               """
               variable :x
               init do
                 x = 0
               end
               action :a, params: [x: [1, 2]] do
                 x = 1
               end
               """,
               :param_shadows_a_variable
             ) =~ "param :x has the same name as a declared variable"
    end

    test "a generator may not read bare variables" do
      assert refuse(
               """
               variable :queue
               init do
                 queue = []
               end
               action :a, params: [item: fn _s -> queue end] do
                 queue = []
               end
               """,
               :variable_not_readable_here
             ) =~ "bare variable :queue in a `params:` generator"
    end
  end

  describe "types" do
    test "an ill-formed type is rejected with the grammar" do
      error =
        refuse(
          """
          variable :x, type: (fn -> 1 end)
          init do
            x = 0
          end
          """,
          :ill_formed_type
        )

      assert error =~ "ill-formed type"
      assert error =~ "[dom ~> rng]"
    end

    # #196. A stepped range is in the grammar now; a zero step is the one shape that is not,
    # and refusing it here names the type rather than letting `Range.new/3` refuse it later.
    test "a range step of zero is rejected at the declaration" do
      error =
        refuse(
          """
          variable :x, type: 0..10//0
          init do
            x = 0
          end
          """,
          :type_range_step_zero
        )

      assert error =~ "a range step of 0 is not a range"
      assert error =~ "§1.5"
    end

    test "a type naming an undeclared constant is rejected" do
      assert refuse(
               """
               variable :x, type: 0..^cap
               init do
                 x = 0
               end
               """,
               :type_names_undeclared_constant
             ) =~ "^cap, which is not a declared constant"
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
        refuse(
          """
          variable :x
          init do
            x = 0
          end
          temporal :t do
            eventually(x == 1) and eventually(x == 2)
          end
          """,
          :unsupported_temporal_operator
        )

      assert error =~ "unsupported temporal operator: eventually/1"
      assert error =~ "no negation, conjunction or disjunction OF FORMULAS"
    end

    # #277. §5.1 promised "a compile error naming the unsupported operator", and every
    # operator here IS supported — it is the NESTING that is outside the fragment. That was
    # enforced at run time, by `Liveness.shape/4`, only under `check_liveness: true`, in an
    # `ArgumentError` carrying no module, declaration or line. Under the default configuration
    # the formula was never looked at and the run reported `:ok`.
    test "a nesting deeper than the fragment evaluates is refused, at compile time" do
      nested = fn formula ->
        refuse(
          """
          variable :x
          init do
            x = 0
          end
          temporal :t do
            #{formula}
          end
          """,
          :temporal_nesting_outside_fragment
        )
      end

      assert nested.("always(always(x == 1))") =~ "`always` directly inside `always(…)`"
      assert nested.("eventually(eventually(x == 1))") =~ "`eventually` directly inside"
      assert nested.("always(eventually(always(x == 1)))") =~ "only a state predicate"
      assert nested.("eventually((x == 0) ~> (x == 1))") =~ "`~>` directly inside"
    end

    test "and the refusal names the declaration and the line, as §7 requires" do
      error =
        refuse(
          """
          variable :x
          init do
            x = 0
          end
          temporal :deep do
            always(always(x == 1))
          end
          """,
          :temporal_nesting_outside_fragment
        )

      assert error =~ "temporal :deep"
      assert error =~ ~r/:\d+, in temporal :deep/
      assert error =~ "nests at most two operators deep"
    end

    # The half that is NOT an error, and the reason this fix is not simply a stricter
    # grammar. `always(Enum.all?(^c, fn p -> pred end))` is `always(pred)`: a quantifier over
    # a constant with a boolean body is an ordinary state predicate, which an `invariant` has
    # accepted all along. Read as a formula-level `\A` it built `{:always, {:for_all, …}}`,
    # which died in `TLA.Coverage.walk/3` — under the DEFAULT configuration, on a formula
    # that means exactly what it looks like.
    test "a quantifier under a temporal operator is a predicate, not a refusal" do
      accepts("""
      constant :procs, default: [:p1, :p2]
      variable :done, type: [^procs ~> [false, true]]
      init do
        done = Map.new(^procs, fn p -> {p, false} end)
      end
      temporal :all_done do
        always(Enum.all?(^procs, fn p -> is_boolean(done[p]) end))
      end
      """)
    end

    test "a formula where a state predicate is required is rejected" do
      assert refuse(
               """
               variable :x
               init do
                 x = 0
               end
               temporal :t do
                 (x == 0) ~> always(x == 1)
               end
               """,
               :temporal_operator_in_state_predicate
             ) =~ "where a state predicate is required"
    end

    test "a quantifier over a state-dependent set is rejected" do
      assert refuse(
               """
               variable :xs
               init do
                 xs = []
               end
               temporal :t do
                 Enum.all?(xs, fn x -> eventually(x == 1) end)
               end
               """,
               :temporal_quantifier_domain
             ) =~ "must range over a constant or a literal list"
    end

    # #210. A literal list containing a variable passed the shape check and then hit a rewrite
    # mode no clause handles: `FunctionClauseError` from inside the compiler, not a diagnostic.
    test "a variable inside a quantifier's literal list is a diagnostic, not a crash" do
      error =
        refuse(
          """
          variable :x
          init do
            x = 0
          end
          temporal :t do
            Enum.all?([x, 1], fn v -> eventually(v == 1) end)
          end
          """,
          :variable_not_readable_here
        )

      assert error =~ "variable :x in a temporal quantifier's set"
      assert error =~ "§5.1"
    end

    # #195. The rewriter resolves a declared variable before a bound name, so a quantifier
    # named after one compiled — and every instance of the body read `state.p`, never the
    # bound value. The instance for `p = 2` came out true on a state where `pc[2]` was wrong.
    # Only a compiler "unused variable" warning marked it.
    test "a quantifier named after a declared variable is rejected, naming both" do
      error =
        refuse(
          """
          constant :procs
          variable :p
          variable :pc
          init do
            p = 1
            pc = %{}
          end
          temporal :t do
            Enum.all?(^procs, fn p -> eventually(pc[p] == :b) end)
          end
          """,
          :binder_shadows_variable
        )

      assert error =~ "the quantifier binds :p, which is a declared variable"
      assert error =~ "may shadow nothing"
      assert error =~ "temporal :t"
    end

    test "a quantifier named after a declared constant is rejected" do
      assert refuse(
               """
               constant :procs
               variable :pc
               init do
                 pc = %{}
               end
               temporal :t do
                 Enum.all?(^procs, fn procs -> eventually(pc[procs] == :b) end)
               end
               """,
               :binder_shadows_constant
             ) =~ "the quantifier binds :procs, which is a declared constant"
    end

    test "a multi-statement temporal block is rejected" do
      assert refuse(
               """
               variable :x
               init do
                 x = 0
               end
               temporal :t do
                 let y = 1
                 eventually(x == y)
               end
               """,
               :temporal_block_not_one_formula
             ) =~ "single formula"
    end
  end

  describe "fairness" do
    test "an unknown action lists the declared ones" do
      error =
        refuse(
          """
          variable :x
          init do
            x = 0
          end
          action :bump do
            x = x + 1
          end
          fairness :weak, [:typo]
          """,
          :unknown_action_in_fairness
        )

      assert error =~ "unknown action in fairness: :typo"
      assert error =~ "Declared actions: :bump."
    end

    test "params that are not a leading prefix are rejected" do
      assert refuse(
               """
               constant :ps
               variable :x
               init do
                 x = 0
               end
               action :a, params: [p: ^ps, q: ^ps] do
                 x = 1
               end
               fairness :weak, a: [:q]
               """,
               :fairness_params_not_a_prefix
             ) =~ "are not a leading prefix"
    end

    # A state function returns a different set in every state, so there is no
    # fixed collection of bindings to attach one constraint each to.
    test "a state-drawn param cannot be quantified over" do
      assert refuse(
               """
               variable :pending
               init do
                 pending = []
               end
               action :take, params: [t: fn s -> s.pending end] do
                 pending = []
               end
               fairness :weak, take: [:t]
               """,
               :fairness_over_a_state_drawn_param
             ) =~ "fairness over a state-drawn param"
    end

    test "a kind other than :weak or :strong is rejected" do
      assert refuse(
               """
               variable :x
               init do
                 x = 0
               end
               action :a do
                 x = 1
               end
               fairness :eventual, [:a]
               """,
               :fairness_kind
             ) =~ "fairness kind must be :weak or :strong"
    end
  end

  describe "duplicate declarations" do
    test "two actions of one name are rejected" do
      assert refuse(
               """
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
               """,
               :duplicate_declaration
             ) =~ "action :a is declared 2 times"
    end

    test "two invariants of one name are rejected" do
      assert refuse(
               """
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
               """,
               :duplicate_declaration
             ) =~ "invariant :i is declared 2 times"
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

      # `is_integer(error.line)` is what stood here, and line 0 satisfies it (#175) — which
      # matters because this is the only line assertion in the tree, so every diagnostic's
      # line number rests on it. The source is built by `source/1` with a fixed preamble, so
      # the offending `x = nope` sits at a known line and the number can be asserted.
      assert error.line == line_of(source_fixture(), "x = nope"),
             "the error points at line #{error.line}, and `x = nope` is on line " <>
               "#{line_of(source_fixture(), "x = nope")}"

      assert Exception.message(error) =~ "in action :bump:"
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  # The `kind` is required, not optional (#273). A test that asserts only on a message
  # substring pins the prose and not the diagnostic: the message can be reworded, or the
  # spec can start failing a *different* rule that happens to share a phrase, and the test
  # stays green either way. The kind is the identifier §7's table and `DIAGNOSTICS.md`
  # share, so pinning it here is what makes those three documents one claim.
  # The exact source the test above compiles, so its line numbers can be asserted rather
  # than merely typed as integers.
  defp source_fixture do
    source("""
    variable :x
    init do
      x = 0
    end
    action :bump do
      x = nope
    end
    """)
  end

  defp line_of(text, needle) do
    text
    |> String.split("\n")
    |> Enum.find_index(&String.contains?(&1, needle))
    |> Kernel.+(1)
  end

  defp refuse(body, kind) do
    error =
      assert_raise TLA.Spec.CompileError, fn ->
        capture_io(:stderr, fn -> Code.compile_string(source(body)) end)
      end

    assert error.kind == kind,
           "expected #{inspect(kind)}, got #{inspect(error.kind)}: #{Exception.message(error)}"

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
