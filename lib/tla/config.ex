defmodule TLA.Config do
  @moduledoc """
  Global configuration for ExTLA behavior.
  """

  @type mode :: :enabled | :log_only | :disabled

  @doc """
  Checking mode, resolved at COMPILE time.

  - `:enabled`   — raise on violation (default in dev/test)
  - `:log_only`  — log violation but continue (useful for staging)
  - `:disabled`  — emit no checking code at all (default in prod)

  This is `compile_env`, not `get_env`, for two reasons:

  1. **`:disabled` must be genuinely free.** The `@before_compile` hooks in Layers 1
     and 3 read this value and, when it is `:disabled`, emit no wrapper at all. A
     runtime `get_env` lookup could not do that — it would leave an
     `Application.get_env/2` call on every callback, which alone consumes most of the
     Layer 1 per-check budget.
  2. **`Mix` does not exist in a release.** An earlier draft defaulted via
     `Mix.env()` evaluated at runtime, which raises `UndefinedFunctionError` in any
     assembled release. Compile-time resolution removes the dependency entirely.

  Changing the mode changes what the instrumented modules compile to, and Mix knows
  it: `compile_env` registers a compile-time dependency on the config key in the
  CALLING module, so a `config :extla, mode: ...` edit recompiles exactly those
  modules. That is the intended trade: the production default is zero code, not
  cheap code.

  The `compile_env` call is inside the `quote`, not in the macro body. In the body
  it would run once, while ExTLA itself compiles — baking the value into the
  dependency's build and attaching the config dependency to `TLA.Config` instead of
  to the user's module. Inside the quote it expands in the caller, which is where
  both the value and the dependency belong.
  """
  defmacro mode do
    default = default_mode()

    quote do
      Application.compile_env(:extla, :mode, unquote(default))
    end
  end

  # Runs while the CALLER compiles (a macro body executes at expansion time), where
  # Mix is normally present. `Code.ensure_loaded?/1`, not `function_exported?/3`:
  # the latter answers false for a module that exists but is not loaded yet, which
  # would silently select :enabled in a fresh VM.
  defp default_mode do
    if Code.ensure_loaded?(Mix) and Mix.env() == :prod, do: :disabled, else: :enabled
  end

  @doc """
  Maximum states to explore during model checking before aborting.
  Prevents runaway exploration.
  """
  def max_states do
    Application.get_env(:extla, :max_states, 1_000_000)
  end

  @doc """
  Number of workers for parallel state exploration.

  Derived rather than asked for: the number of schedulers is a property of the machine, so
  the system holds the knowledge and this answers it.

  `TLA.ModelChecker.Parallel` honours `workers:`, and `TLA.ModelChecker`'s own default is
  nonetheless **1**. A parallel search is exhaustive exactly as a single-threaded one is,
  so the cores buy speed and not a better answer — and how much of the machine to spend on
  a run is a decision about the machine, held by whoever is running the checker. Pass
  `workers: TLA.Config.workers()` to take this answer; nothing takes it for a caller who
  did not ask.

  Set higher than the machine has schedulers, a run is slower rather than wrong — the
  degradation is visible, which is the property a derived default should keep.
  """
  def workers do
    Application.get_env(:extla, :workers, System.schedulers_online())
  end
end
