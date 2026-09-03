defmodule TLA.GuideCheckTest do
  @moduledoc """
  The harness that keeps `guides/` honest, checked against guides written to lie (#94, #95).

  Every test here writes a small guide whose prose makes a **false** claim and asserts the harness
  rejects it. A gate nobody has seen fail is not known to be a gate — the standard #58, #60, #84
  and #90 were held to, applied to the gate that will guard the tutorial.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias TLA.GuideCheck

  defp guide(tmp, body) do
    path = Path.join(tmp, "guide-#{System.unique_integer([:positive])}.md")
    File.write!(path, body)
    path
  end

  # A spec with an invariant a reachable state refutes, at a known depth.
  defp broken_spec(name) do
    """
    ```elixir tla:spec
    defmodule #{name} do
      use TLA.Spec

      variable :n, type: 0..10

      init do
        n = 0
      end

      action :tick do
        require n < 10
        n = n + 1
      end

      invariant :at_most_two do
        n <= 2
      end
    end
    ```
    """
  end

  defp working_spec(name) do
    """
    ```elixir tla:spec
    defmodule #{name} do
      use TLA.Spec

      variable :n, type: 0..2

      init do
        n = 0
      end

      action :tick do
        require n < 2
        n = n + 1
      end

      invariant :in_range do
        n >= 0 and n <= 2
      end

      # Without this the spec DEADLOCKS at n = 2 -- `tick` is disabled and nothing admits the
      # end state. The harness caught that when this fixture was written, which is the harness
      # working: a "working example" that does not work is exactly what it exists to reject.
      terminal :done do
        n == 2
      end
    end
    ```
    """
  end

  describe "a guide that tells the truth" do
    test "passes when a working example is claimed to work", %{tmp_dir: tmp} do
      m = "GuideTruth.Works#{System.unique_integer([:positive])}"

      path =
        guide(tmp, working_spec(m) <> "\n```elixir tla:check module=#{m} expect=ok\n```\n")

      assert GuideCheck.check(path) == []
    end

    test "passes when a failing example is claimed to fail, at the right depth and property",
         %{tmp_dir: tmp} do
      m = "GuideTruth.Breaks#{System.unique_integer([:positive])}"

      path =
        guide(
          tmp,
          broken_spec(m) <>
            "\n```elixir tla:check module=#{m} expect=violation invariant=at_most_two\n```\n"
        )

      assert GuideCheck.check(path) == []
    end
  end

  describe "a guide that lies — the tests this harness exists for" do
    test "rejects claiming :ok for a spec that is violated", %{tmp_dir: tmp} do
      m = "GuideLies.NotOk#{System.unique_integer([:positive])}"

      path = guide(tmp, broken_spec(m) <> "\n```elixir tla:check module=#{m} expect=ok\n```\n")

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims this reports :ok"
      assert failure =~ "at_most_two is violated"
    end

    test "rejects claiming a violation for a spec that holds", %{tmp_dir: tmp} do
      m = "GuideLies.NotViolated#{System.unique_integer([:positive])}"

      path =
        guide(tmp, working_spec(m) <> "\n```elixir tla:check module=#{m} expect=violation\n```\n")

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims a violation"
      assert failure =~ ":ok"
    end

    test "rejects a wrong counterexample length", %{tmp_dir: tmp} do
      m = "GuideLies.WrongLength#{System.unique_integer([:positive])}"

      path =
        guide(
          tmp,
          broken_spec(m) <>
            "\n```elixir tla:check module=#{m} expect=violation length=99\n```\n"
        )

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims a 99-step counterexample"
    end

    test "rejects naming the wrong violated invariant", %{tmp_dir: tmp} do
      m = "GuideLies.WrongInvariant#{System.unique_integer([:positive])}"

      path =
        guide(
          tmp,
          broken_spec(m) <>
            "\n```elixir tla:check module=#{m} expect=violation invariant=something_else\n```\n"
        )

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims something_else is violated"
      assert failure =~ "at_most_two"
    end

    test "rejects a tla:spec that does not compile", %{tmp_dir: tmp} do
      path =
        guide(tmp, """
        ```elixir tla:spec
        defmodule Guide.Nonsense do
          use TLA.Spec
          variable :n, type: 0..2
          init do
            n = 0
          end
          action :tick do
            n = undeclared_variable_here
          end
        end
        ```
        """)

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "does not compile"
    end

    test "rejects a tla:compile_error block that actually compiles", %{tmp_dir: tmp} do
      m = "GuideLies.Compiles#{System.unique_integer([:positive])}"

      path =
        guide(tmp, """
        ```elixir tla:compile_error match="something"
        defmodule #{m} do
          def fine, do: :ok
        end
        ```
        """)

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "compiled successfully"
    end

    test "rejects a compile error whose message is not the one claimed", %{tmp_dir: tmp} do
      path =
        guide(tmp, """
        ```elixir tla:compile_error match="a message it will never produce"
        defmodule Guide.AlsoNonsense do
          use TLA.Spec
          variable :n, type: 0..2
          init do
            n = 0
          end
          action :tick do
            n = undeclared_variable_here
          end
        end
        ```
        """)

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "expected the error to contain"
    end
  end

  describe "the real guides/" do
    # This is the test that will matter once #96 and #97 land. It is written now so the harness
    # is wired before the prose exists -- nobody retrofits a gate to a guide that already passes.
    test "every guide in guides/ tells the truth" do
      guides = Path.wildcard("guides/*.md")

      if guides == [] do
        # Stated rather than skipped. A silently vacuous test is the "gate that cannot fail"
        # this project keeps rejecting; saying so out loud is the same move TLA_COVERAGE.md
        # makes when it records an item as NOTHING instead of omitting it.
        assert not File.dir?("guides"),
               "guides/ exists but holds no .md files — this check would be silently vacuous"
      else
        failures = Enum.flat_map(guides, &GuideCheck.check/1)

        assert failures == [],
               "guides make claims the code does not support:\n\n" <> Enum.join(failures, "\n")
      end
    end
  end

  describe "deadlock is its own claim" do
    test "a spec that deadlocks can say so, and is accepted", %{tmp_dir: tmp} do
      m = "GuideDeadlock.Stuck#{System.unique_integer([:positive])}"

      path =
        guide(tmp, """
        ```elixir tla:spec
        defmodule #{m} do
          use TLA.Spec
          variable :n, type: 0..2
          init do
            n = 0
          end
          action :tick do
            require n < 2
            n = n + 1
          end
        end
        ```

        ```elixir tla:check module=#{m} expect=deadlock
        ```
        """)

      assert GuideCheck.check(path) == []
    end

    test "claiming a deadlock for a spec that has none is rejected", %{tmp_dir: tmp} do
      m = "GuideDeadlock.Fine#{System.unique_integer([:positive])}"

      path =
        guide(tmp, working_spec(m) <> "\n```elixir tla:check module=#{m} expect=deadlock\n```\n")

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims a deadlock"
    end
  end

  describe "an unannotated block is an unchecked claim" do
    test "a bare elixir block is rejected", %{tmp_dir: tmp} do
      path = guide(tmp, "```elixir\n:this_is_never_checked\n```\n")

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "unchecked claim"
      assert failure =~ "tla:skip"
    end

    test "tla:skip is accepted, so a gap is visible on the page rather than silent",
         %{tmp_dir: tmp} do
      path = guide(tmp, "```elixir tla:skip reason=illustrative-pseudocode\n:whatever\n```\n")

      assert GuideCheck.check(path) == []
    end
  end
end
