defmodule ExTLA.Invariant.Agent do
  @moduledoc """
  Layer 1 for an `Agent`, whose transitions are functions its callers pass in.

      defmodule Counter do
        use ExTLA.Invariant

        invariant :never_negative, desc: "a counter may not go below zero" do
          state.count >= 0
        end
      end

      alias ExTLA.Invariant.Agent, as: Checked

      {:ok, pid} = Checked.start_link(Counter, fn -> %{count: 0} end)
      Checked.update(Counter, pid, &%{&1 | count: &1.count - 1})
      # ** (ExTLA.Invariant.Violation) ═══ INVARIANT VIOLATED: never_negative ═══

  ## Why the module is an argument

  An `Agent` has no callback module of its own — `Agent.start_link/2` takes a function,
  not a behaviour — so there is nothing for `@before_compile` to wrap and nothing to
  carry the declarations. They live in an ordinary module that `use`s `ExTLA.Invariant`,
  and each call names it.

  ## `:disabled` is not free here, and cannot be

  Everywhere else in Layer 1 the mode is resolved where the instrumented module compiles,
  and `:disabled` emits nothing. An `Agent` call site is not that place: the transition is
  a function the caller passes in, the module whose declarations apply is an *argument*,
  and `Application.compile_env/3` — which is how the mode is read at all — does not expand
  inside a function body. These were macros in a first draft for exactly that reason, and
  the draft does not compile.

  So under `:disabled` a checked `Agent` call costs one export lookup on the declaring
  module and then does what the plain `Agent` function does. That is the honest price of
  a behaviour with no callback module, and it is stated rather than papered over.

  ## `callbacks:` means nothing here

  It restricts a declaration to named OTP callbacks, and an `Agent`'s transition is not
  one — the caller's function runs inside `Agent`'s own `handle_call/3`. Every
  declaration in the named module applies to every checked `Agent` transition.
  """

  alias ExTLA.Invariant.Runtime

  @doc """
  `Agent.update/3`, with the invariants and action properties checked on the transition.

  The check runs inside the agent process, between the caller's function and the state it
  returns, so a violation raises where a GenServer's would: in the process that made the
  illegal move.
  """
  def update(module, agent, fun, timeout \\ 5_000) do
    Agent.update(
      agent,
      fn state -> Runtime.check_agent_step!(module, state, fun.(state)) end,
      timeout
    )
  end

  @doc """
  `Agent.cast/2`, checked. Asynchronous, so a violation reaches the caller only as the
  agent's exit — which is what a violated invariant in a `handle_cast/2` does too.
  """
  def cast(module, agent, fun) do
    Agent.cast(agent, fn state -> Runtime.check_agent_step!(module, state, fun.(state)) end)
  end

  @doc """
  `Agent.get_and_update/3`, checked. The caller's function returns `{reply, new_state}`;
  the transition checked is to that new state.
  """
  def get_and_update(module, agent, fun, timeout \\ 5_000) do
    Agent.get_and_update(
      agent,
      fn state ->
        {reply, new_state} = fun.(state)
        {reply, Runtime.check_agent_step!(module, state, new_state)}
      end,
      timeout
    )
  end

  @doc """
  `Agent.get/3`, with the invariants checked on the state that was read.

  A read is a stuttering step — nothing moved, so no action property applies — but the
  invariants must hold of it, exactly as they must of a callback that returns its state
  unchanged.
  """
  def get(module, agent, fun, timeout \\ 5_000) do
    Agent.get(agent, fn state -> fun.(Runtime.check_agent_state!(module, state)) end, timeout)
  end

  @doc """
  `Agent.start_link/2`, with the invariants checked on the initial state.

  The `Agent` counterpart of the `init/1` wrapper, and partial for the same reason: the
  function's result IS the first state, so there is no transition to check.
  """
  def start_link(module, fun, options \\ []) do
    Agent.start_link(fn -> Runtime.check_agent_state!(module, fun.()) end, options)
  end
end
