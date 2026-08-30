defmodule TLA.Spec.Test do
  @moduledoc """
  ExUnit helpers for model checking in tests.
  """

  @doc """
  Assert that a spec passes model checking with the given configuration.

  ## Options, beyond `TLA.ModelChecker.config/0`

  - `allow_incomplete: true` — pass even if the state limit was reached or a
    state constraint bounded the run. Default `false`.
  - `strict_coverage: true` — fail on a never-enabled action or a vacuous
    property. Default `false`: they are reported, not fatal.
  """
  defmacro assert_spec(spec_module, config \\ Macro.escape(%{})) do
    quote do
      TLA.Spec.Test.__assert__(unquote(spec_module), unquote(config), __ENV__)
    end
  end

  @doc false
  def __assert__(spec_module, config, env) do
    {allow_incomplete, config} = Map.pop(config, :allow_incomplete, false)
    {strict_coverage, config} = Map.pop(config, :strict_coverage, false)

    result = TLA.ModelChecker.run(spec_module, config)

    case result.status do
      :violation ->
        flunk(env, """
        Model checking violation in #{inspect(spec_module)}:

        #{TLA.Trace.format(result.violation)}\
        """)

      status when status in [:max_states_reached, :constrained] and not allow_incomplete ->
        # NOT a pass. An earlier draft warned here and let the test proceed,
        # which is how a suite goes green on a spec that was never verified --
        # the single most misleading thing this library could do.
        flunk(env, incomplete_message(spec_module, result, status))

      _ ->
        case TLA.Coverage.warn_unless_clean(result.coverage, strict_coverage: strict_coverage) do
          {:error, warnings} ->
            flunk(env, """
            Coverage failure in #{inspect(spec_module)} (strict_coverage: true):

            #{Enum.map_join(warnings, "\n", &("  " <> &1))}

            #{TLA.Coverage.format(result.coverage, title: "COVERAGE: #{inspect(spec_module)}")}\
            """)

          _ ->
            result
        end
    end
  end

  defp incomplete_message(spec_module, result, status) do
    bound =
      case status do
        :max_states_reached -> "hit the state limit"
        :constrained -> "was bounded by its state constraint"
      end

    """
    Model checking did NOT complete for #{inspect(spec_module)}.

    It explored #{result.distinct_states} distinct states and #{bound}.
    The spec is UNVERIFIED, not verified.

    Reduce the constants, adjust the :state_constraint, raise :max_states, or pass
    `allow_incomplete: true` to accept a bounded run deliberately.\
    """
  end

  defp flunk(env, message) do
    raise ExUnit.AssertionError, message: message, expr: nil, file: env.file, line: env.line
  end
end
