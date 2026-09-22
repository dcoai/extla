defmodule TLA.GenServer.Runtime do
  @moduledoc """
  The engine behind Layer 3's callback wrappers. Not called directly.

  `check_step!/5` is the refinement check, and it is what makes the layer a conformance
  check rather than an invariant check on a projection: an implementation can reach a
  state every invariant admits by a route the specification forbids, and only comparing
  the *step* against the spec's action catches that (`05-layer3-conformance.md` §What
  conformance means here).

  ## The compiled spec and the constants are memoized per process

  Both are needed on every transition. `__tla_spec__/0` builds its struct on each call and
  the constants come from application config, so each would be re-derived per callback.
  They are resolved once per process and kept in the process dictionary beside the trace —
  which is where a GenServer's per-process state belongs, and the wrapper always runs
  inside the server.
  """

  alias TLA.GenServer.Violation
  alias TLA.ModelChecker
  alias TLA.ModelChecker.Safety
  alias TLA.{Spec, State, Temporal}

  @typedoc """
  What a check found: nothing, or the violation it would have raised.
  """
  @type finding :: :ok | {:violation, Violation.t()}

  @context_key {__MODULE__, :context}
  @trace_key {__MODULE__, :trace}
  @default_trace_buffer 1000

  @doc """
  The refinement mapping applied, against the memoized compiled spec.

  `TLA.Refinement.abstract!/3` takes the compiled struct rather than the module, because
  it checks the mapping's result against the spec's declared variables. The wrapper has
  only the module — so it comes through here, where the compiled spec is already resolved
  for the process rather than rebuilt per callback.
  """
  def abstract!(spec_module, refinement, concrete) do
    %{spec: spec} = context(spec_module)
    TLA.Refinement.abstract!(refinement, spec, concrete)
  end

  @doc """
  The first abstract state: mapped, checked against the spec's invariants, and recorded.

  Takes the raw `init/1` return rather than a state, for the reason
  `TLA.Invariant.Runtime.check_initial_invariants!/4` does: `:ignore` and a bare
  `{:stop, reason}` produce no state, and a `case` on that tag in the emitted wrapper has a
  clause the compiler can prove unreachable — a warning in the user's module about code the
  user did not write.

  There is no step to check. A first state is not a transition, and the trace has to start
  at it: a temporal property over a behaviour that begins at the second state is a property
  of a different behaviour.
  """
  def record_initial!(spec_module, refinement, result) do
    case TLA.Invariant.Runtime.initial_state(result) do
      {:ok, concrete} ->
        abstract = abstract!(spec_module, refinement, concrete)
        check_spec_invariants!(spec_module, abstract)
        record_transition!(spec_module, :init, abstract, abstract)

      :none ->
        :ok
    end
  end

  @doc """
  THE refinement check. Applies the named spec action to `pre` and compares the result
  with what the implementation produced.

  `params` may be PARTIAL. An implementation frequently resolves the spec's nondeterminism
  itself — it pops its own queue, picks its own message — so the binding is not in the
  message and `abstract_action/1` cannot supply it. Every binding of the action's params
  that extends the given ones is a candidate, and the step is legal if any *enabled*
  candidate reproduces `post`. That is still refinement: the spec permits the step via
  that binding.

  Fails `:not_enabled` when no candidate binding has a true guard, and `:diverged` when
  one does and none reproduces the post-state — with a variable-by-variable diff against
  the closest candidate.
  """
  def check_step!(spec_module, action_name, params, pre, post) do
    raising(check_step(spec_module, action_name, params, pre, post))
  end

  @doc "The refinement check, returning the finding instead of raising it."
  def check_step(spec_module, action_name, params, pre, post) do
    %{spec: spec, constants: constants} = context(spec_module)
    action = action!(spec, action_name)
    :ok = params!(action, params, spec)

    candidates =
      action
      |> ModelChecker.bindings(constants, pre)
      |> Enum.filter(&Temporal.extends?(&1, params))

    enabled = Enum.filter(candidates, &action.guard.(constants, pre, &1))

    cond do
      enabled == [] ->
        {:violation, not_enabled(spec, action, params, pre, candidates)}

      Enum.any?(enabled, &(action.transition.(constants, pre, &1) == post)) ->
        :ok

      true ->
        {:violation, diverged(spec, action, constants, enabled, pre, post)}
    end
  end

  @doc """
  One transition, checked: the step against the action the mapping names, or the
  stuttering claim `:unmapped` makes.

  The dispatch is here rather than in the emitted wrapper for the same reason the `init/1`
  tag test is. In a module whose messages the compiler can enumerate — a server with one
  callback clause, which is most mutants and some real servers —
  `refinement.abstract_action(msg)` has a known return, and one arm of the `case` is then
  provably unreachable. That is a warning in the user's module about code the user did not
  write. Behind a `module()` argument there is nothing to infer.
  """
  def check_transition!(spec_module, refinement, message, pre, post) do
    raising(check_transition(spec_module, refinement, message, pre, post))
  end

  @doc """
  The same, returning the finding instead of raising it.

  Every check in this module has this pair, and the reason is `TLA.Replay`: a replay
  reports *which step* failed and carries on being a value, which is not something that
  can be built out of an exception without catching one. So the checks return findings and
  the `!` forms raise them — the wrapper needs the raise, the report needs the value, and
  neither is derived from the other by rescuing.
  """
  def check_transition(spec_module, refinement, message, pre, post) do
    case refinement.abstract_action(message) do
      {action, params} -> check_step(spec_module, action, params, pre, post)
      :unmapped -> check_stuttering(spec_module, pre, post)
    end
  end

  @doc """
  Assert that an `:unmapped` message left the abstract state unchanged.

  `:unmapped` is a positive claim rather than an absence of one: a message with no spec
  counterpart must not move the abstract state, and a mapping that is merely incomplete is
  caught here rather than passing silently.
  """
  def check_stuttering!(spec_module, pre, post) do
    raising(check_stuttering(spec_module, pre, post))
  end

  @doc "The same, returning the finding instead of raising it."
  def check_stuttering(spec_module, pre, post) do
    if pre == post do
      :ok
    else
      {:violation,
       %Violation{
         kind: :unmapped_but_moved,
         spec: spec_module,
         pre: pre,
         post: post,
         diff: for(var <- State.changed_vars({pre, post}), do: {var, pre[var], post[var]})
       }}
    end
  end

  @doc "Check the spec's invariants against an abstract state."
  def check_spec_invariants!(spec_module, abstract) do
    raising(check_spec_invariants(spec_module, abstract))
  end

  @doc "The same, returning the finding instead of raising it."
  def check_spec_invariants(spec_module, abstract) do
    %{spec: spec, constants: constants} = context(spec_module)

    case Safety.check_invariants(spec, constants, abstract) do
      :ok ->
        :ok

      {:violation, name} ->
        {:violation, %Violation{kind: :invariant, spec: spec_module, name: name, post: abstract}}
    end
  end

  @doc "Check the spec's action properties against an abstract transition."
  def check_action_properties!(spec_module, pre, post) do
    raising(check_action_properties(spec_module, pre, post))
  end

  @doc "The same, returning the finding instead of raising it."
  def check_action_properties(spec_module, pre, post) do
    %{spec: spec, constants: constants} = context(spec_module)

    case Safety.check_action_properties(spec, constants, pre, post) do
      :ok ->
        :ok

      {:violation, name} ->
        {:violation,
         %Violation{
           kind: :action_property,
           spec: spec_module,
           name: name,
           pre: pre,
           post: post
         }}
    end
  end

  @doc """
  Record a transition in the CALLING process's behaviour trace.

  There is no pid argument. A process dictionary is writable only by its own process, so a
  signature taking one could not be implemented as `05-layer3-conformance.md` first
  described it; the wrapper runs inside the GenServer, so recording is always a
  self-write.

  The buffer is bounded (`config :extla, trace_buffer: n`, default #{@default_trace_buffer})
  and drops oldest-first: an unbounded per-process trace is a memory leak in any long-lived
  GenServer, which is most of them.
  """
  def record_transition!(_spec_module, _message, pre, post) do
    trace = Process.get(@trace_key, [])
    trace = if trace == [], do: [pre], else: trace

    Process.put(@trace_key, bound([post | trace]))
    :ok
  end

  @doc "The behaviour recorded by THIS process, oldest state first."
  def trace, do: @trace_key |> Process.get([]) |> Enum.reverse()

  @doc """
  Retrieve another process's accumulated behaviour trace.

  Asks the process itself, through `:sys`, rather than reaching into its dictionary — for
  the same reason `record_transition!/4` takes no pid. The function runs inside the target
  and returns its state unchanged; only the trace travels back.
  """
  def get_trace(pid) do
    caller = self()
    ref = make_ref()

    :sys.replace_state(pid, fn state ->
      send(caller, {ref, trace()})
      state
    end)

    receive do
      {^ref, behavior} -> behavior
    after
      5_000 -> raise "#{inspect(pid)} did not answer a :sys request for its trace"
    end
  end

  @doc """
  Check the spec's temporal properties against an accumulated trace. Called at the end of
  a simulation run, not per transition.

  A finite trace can refute `always(P)` and can satisfy `eventually(P)`, and can do
  neither the other way round, so the verdicts are `:holds | :violated | :inconclusive`
  (`08-decisions.md` D-23). A real trace has no lasso — nothing says the process would
  have repeated that cycle forever — so the properties that need one are `:inconclusive`
  by construction rather than by accident.
  """
  def check_temporal_properties(spec_module, behavior) do
    %{spec: spec, constants: constants} = context(spec_module)

    Map.new(spec.temporals, fn temporal ->
      {temporal.name, verdict(temporal.formula.(constants), behavior, constants)}
    end)
  end

  # ── The formula fragment (02-dsl-semantics.md §5.1) ─────────────────────────

  defp verdict({:for_all, set, instance}, behavior, constants) do
    constants
    |> set.()
    |> Enum.map(&verdict(instance.(&1), behavior, constants))
    |> combine()
  end

  defp verdict({:always, {:eventually, {:predicate, p}}}, behavior, _constants),
    do: Temporal.always_eventually(behavior, p)

  defp verdict({:eventually, {:always, {:predicate, p}}}, behavior, _constants),
    do: Temporal.eventually_always(behavior, p)

  defp verdict({:always, {:predicate, p}}, behavior, _constants),
    do: Temporal.always(behavior, p)

  defp verdict({:eventually, {:predicate, p}}, behavior, _constants),
    do: Temporal.eventually(behavior, p)

  defp verdict({:leads_to, p, q}, behavior, _constants), do: Temporal.leads_to(behavior, p, q)

  defp verdict({:predicate, p}, [first | _], _constants),
    do: if(p.(first), do: :holds, else: :violated)

  defp verdict({:predicate, _p}, [], _constants), do: :inconclusive

  # Without this clause the same off-fragment formulas that raised in the model checker died
  # HERE with a `FunctionClauseError` printing three closures and no property name, under
  # `mix tla.simulate` and Layer 3's conformance run (#277). The compile-time refusal means
  # neither can happen now; this says so rather than leaving the second door unlabelled.
  defp verdict(formula, _behavior, _constants) do
    raise ArgumentError,
          "a temporal formula reached the runtime checker as a shape it does not evaluate: " <>
            "#{inspect(formula)}. This is a bug in ExTLA, not in the specification: " <>
            "`TLA.Spec.Temporal` refuses a formula outside 02-dsl-semantics.md §5.1 at " <>
            "compile time, so nothing should build this. Please report it."
  end

  # A `for_all` holds only if every instance does, and one violated instance refutes the
  # whole — the same rule the model checker applies, one verdict wider.
  defp combine(verdicts) do
    cond do
      Enum.any?(verdicts, &(&1 == :violated)) -> :violated
      Enum.any?(verdicts, &(&1 == :inconclusive)) -> :inconclusive
      verdicts == [] -> :inconclusive
      true -> :holds
    end
  end

  defp raising(:ok), do: :ok
  defp raising({:violation, violation}), do: raise(violation)

  # ── Candidates, and the two ways a step fails ───────────────────────────────

  defp action!(spec, name) do
    case Spec.Compiled.action(spec, name) do
      nil ->
        raise ArgumentError,
              "the refinement mapping named the action #{inspect(name)}, which " <>
                "#{inspect(spec.module)} does not declare. It declares: " <>
                inspect(Enum.map(spec.actions, & &1.name))

      action ->
        action
    end
  end

  # A param the action does not take is a mapping fault, not a conformance one: no binding
  # could ever extend it, so reporting it as `:not_enabled` would blame the implementation
  # for a mistake in the mapping.
  defp params!(action, params, spec) do
    declared = Enum.map(action.params, &elem(&1, 0))

    case Map.keys(params) -- declared do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "the refinement mapping bound #{inspect(unknown)} for " <>
                "#{inspect(spec.module)}.#{action.name}, which takes #{inspect(declared)}."
    end
  end

  defp not_enabled(spec, action, params, pre, candidates) do
    detail =
      if candidates == [] and params != %{} do
        "  No binding of #{inspect(action.name)} extends the params the mapping supplied,\n" <>
          "  #{inspect(params)} — the values are outside the generators the action draws from."
      else
        "  The guard is false in this state for every binding the mapping admits."
      end

    %Violation{
      kind: :not_enabled,
      spec: spec.module,
      action: action.name,
      params: params,
      pre: pre,
      detail: detail
    }
  end

  # The closest candidate is the one differing in the fewest variables. With one enabled
  # binding that is simply it; with several — an action whose nondeterminism the
  # implementation resolved — it is the one the author most likely meant, and the diff is
  # what makes the message worth reading.
  defp diverged(spec, action, constants, enabled, pre, post) do
    {params, diff} =
      enabled
      |> Enum.map(fn binding ->
        produced = action.transition.(constants, pre, binding)

        {binding,
         for(var <- State.changed_vars({produced, post}), do: {var, produced[var], post[var]})}
      end)
      |> Enum.min_by(fn {_binding, diff} -> length(diff) end)

    %Violation{
      kind: :diverged,
      spec: spec.module,
      action: action.name,
      params: params,
      pre: pre,
      post: post,
      diff: diff
    }
  end

  # ── Per-process context and trace ───────────────────────────────────────────

  # Keyed on the module AND its `module_info(:md5)` (#213): a server that outlives a
  # recompile of its spec — the shape a dev session has — used to keep checking against the
  # spec it first loaded, since the cache matched on the module name alone. The md5 read is
  # a lookup on the loaded module, cheap enough for every callback; a recompiled spec is
  # picked up on the next one.
  @doc false
  def context(spec_module) do
    md5 = spec_module.module_info(:md5)

    case Process.get(@context_key) do
      %{spec: %Spec.Compiled{module: ^spec_module}, md5: ^md5} = context ->
        context

      _other ->
        spec = Spec.Compiled.from_module(spec_module)
        context = %{spec: spec, constants: constants(spec), md5: md5}
        Process.put(@context_key, context)
        context
    end
  end

  # The resolution `mix tla.check` performs, without its Mix-flavoured error: a spec
  # checked against an implementation and a spec model checked have to be given the same
  # constants, or the two verdicts are about different specifications.
  defp constants(spec) do
    case Spec.Compiled.resolve_constants(spec) do
      {:ok, constants} ->
        constants

      {:error, missing} ->
        raise ArgumentError,
              "#{inspect(spec.module)} has no assignment for " <>
                "#{Enum.map_join(missing, ", ", &inspect/1)}. Supply them beside the " <>
                "declaration with `constant #{inspect(hd(missing))}, default: …`, or in " <>
                "config: `config :extla, #{inspect(spec.module)}, constants: %{…}`."
    end
  end

  defp bound(trace) do
    limit = Application.get_env(:extla, :trace_buffer, @default_trace_buffer)
    if length(trace) > limit, do: Enum.take(trace, limit), else: trace
  end
end
