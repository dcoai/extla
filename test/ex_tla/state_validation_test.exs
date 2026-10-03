defmodule ExTLA.StateValidationTest do
  @moduledoc """
  §6's term restriction as the *checker* enforces it, rather than as
  `ExTLA.State.validate!/1` enforces it in isolation (`state_test.exs`).

  `#33` moved that call from every generated successor to every newly discovered state.
  These tests are about the two things that move could have broken and the unit tests
  cannot see: that the guarantee still fires, and that it still fires *before* anything
  else looks at the state.
  """

  # `async: false`: the validation-count test sets a global trace pattern on
  # `ExTLA.State.validate!/1`. The trace *flags* are on this process alone, so no other
  # test's calls are counted, but the pattern itself is VM-wide and must not be installed
  # and removed underneath a concurrent test doing the same.
  use ExUnit.Case, async: false

  alias ExTLA.ModelChecker
  alias ExTLA.TestSpecs.{Cube, Tainted, TaintedWithProperty}

  describe "§6 during exhaustive search" do
    test "a forbidden term produced by an action raises, naming the variable" do
      assert_raise ExTLA.State.InvalidTermError, ~r/spec variable :mark holds a float/, fn ->
        ModelChecker.run(Tainted, %{})
      end
    end

    # The state `taint` produces has two distinct in-paths — from (1, 0) and from (0, 1).
    # Validating only newly discovered states could in principle let the second path
    # register a state the first never vetted; it cannot, because a forbidden term never
    # dedups, so the state is new on whichever path reaches it first and raises there.
    test "a forbidden state reachable by two paths raises on the first one reached" do
      error =
        assert_raise ExTLA.State.InvalidTermError, fn ->
          ModelChecker.run(Tainted, %{})
        end

      message = Exception.message(error)
      assert message =~ "spec variable :mark"
      assert message =~ "02-dsl-semantics.md §6"
    end

    # The discriminating test for the ordering `#33` introduced. `never_fractional` is
    # false of the tainted step, so a checker that evaluated action properties before
    # registering (and therefore validating) the successor would return a violation
    # result. Raising is the correct answer: the spec is outside the language, which is
    # not the same finding as a property being false.
    test "an action property never observes a state the checker has not validated" do
      assert_raise ExTLA.State.InvalidTermError, ~r/spec variable :n holds a float/, fn ->
        ModelChecker.run(TaintedWithProperty, %{})
      end
    end
  end

  describe "how often validation runs" do
    # `explore/2` and not `run/2`, since #316: `run/2` now searches in a process of its own
    # so that the process's exit releases the graph's ETS tables, which puts the validations
    # one level below the pid this test traces. `explore/2` is the same search in the
    # caller — it is what `run/2` calls — so it is the one that can be counted, and it is
    # also the one whose graph the caller owns, hence the release below.
    test "once per distinct state, not once per transition" do
      {{result, graph}, validations} =
        counting_validations(fn -> ModelChecker.explore(Cube, %{}) end)

      on_exit(fn -> ExTLA.StateGraph.delete(graph) end)

      # A 3-cube is small enough to state both numbers and shaped so that they differ:
      # 8 distinct states, 12 transitions. That gap is the whole of this change —
      # `raft_election` runs 255,270 transitions over 58,359 states, and validating the
      # former rather than the latter was 77.9% of its search.
      assert result.distinct_states == 8
      assert result.transitions == 12

      assert validations == result.distinct_states
    end
  end

  # Counts calls to `ExTLA.State.validate!/1` made while `fun` runs.
  #
  # `fun` runs in a child process and this one is its tracer, because a process cannot
  # receive its own call traces — `:erlang.trace(self(), true, [:call])` installs
  # cleanly and then delivers nothing. Tracing one known pid is also what keeps the
  # count honest: `ModelChecker.run/2` is a plain recursive search in its caller, so
  # every validation the run performs happens in that child and no other process's do.
  defp counting_validations(fun) do
    parent = self()
    worker = spawn(fn -> receive(do: (:go -> send(parent, {:result, fun.()}))) end)

    # The pattern matches nothing on a module that has not been loaded, and returns 0
    # rather than failing — so a missing `ensure_loaded!/1` here reads as "validation
    # never ran" instead of as a broken test.
    Code.ensure_loaded!(ExTLA.State)
    assert :erlang.trace_pattern({ExTLA.State, :validate!, 1}, true, [:local]) == 1
    :erlang.trace(worker, true, [:call])
    send(worker, :go)

    # Signals from one process to another keep their order, and the VM emits the worker's
    # call traces as signals from the worker — so every trace message it generated is
    # already queued ahead of this one, and draining with no timeout is not a race.
    assert_receive {:result, result}, 5_000

    # Only the pattern is cleared. The worker has already exited by the time its result
    # arrives, and untracing a dead pid raises rather than being a no-op.
    :erlang.trace_pattern({ExTLA.State, :validate!, 1}, false, [:local])

    {result, drain_calls(0)}
  end

  defp drain_calls(count) do
    receive do
      {:trace, _pid, :call, {ExTLA.State, :validate!, _}} -> drain_calls(count + 1)
    after
      0 -> count
    end
  end
end
