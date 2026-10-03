defmodule ExTLA.ConfigTest do
  use ExUnit.Case, async: false

  require ExTLA.Config

  # In the module body, not in a test: `Application.compile_env/3` may only be
  # called there, so `ExTLA.Config.mode/0` must be resolved into a module attribute
  # by any module that instruments itself. The `@before_compile` hooks in Layers 1
  # and 3 have to do the same thing, which is why this test reads the way it does.
  @mode ExTLA.Config.mode()

  describe "mode/0" do
    # The macro expands in the CALLER, which is this module, so what it resolves to
    # here is what it would resolve to in a user's instrumented module.
    test "resolves at compile time to :enabled under MIX_ENV=test" do
      assert @mode == :enabled
    end

    test "expands to a compile_env call rather than a runtime lookup" do
      expanded =
        quote(do: ExTLA.Config.mode())
        |> Macro.expand_once(__ENV__)
        |> Macro.to_string()

      assert expanded =~ "Application.compile_env(:extla, :mode, :enabled)"
      refute expanded =~ "get_env"
    end
  end

  describe "max_states" do
    # `ExTLA.Config.max_states/0` was deleted at #317. It answered a number nothing read —
    # `ExTLA.ModelChecker` carries its own `max_states: 1_000_000` and every caller goes
    # through that — so the repository held two copies of one number, one of them dead.
    # This is what remains of its two tests: the one fact worth pinning is that the number
    # now lives in exactly one place.
    test "is the checker's own default, and only the checker's" do
      refute function_exported?(ExTLA.Config, :max_states, 0)

      assert ExTLA.ModelChecker.run(ExTLA.TestSpecs.Cube, %{max_states: 1}).status ==
               :max_states_reached

      refute ExTLA.ModelChecker.run(ExTLA.TestSpecs.Cube, %{}).status == :max_states_reached
    end
  end

  describe "workers/0" do
    test "defaults to the scheduler count" do
      # Derived rather than asked for: the number of schedulers is a property of the
      # machine, so the system holds the knowledge. Nothing reads it yet — `workers:` is
      # refused until `ExTLA.ModelChecker.Parallel` exists — and this is the only place it
      # is asserted, because a second async test reading it would race this one's
      # `put_env`.
      assert ExTLA.Config.workers() == System.schedulers_online()
    end

    test "reads application config" do
      Application.put_env(:extla, :workers, 2)
      on_exit(fn -> Application.delete_env(:extla, :workers) end)

      assert ExTLA.Config.workers() == 2
    end
  end
end
