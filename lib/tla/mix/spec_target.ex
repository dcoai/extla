defmodule TLA.Mix.SpecTarget do
  @moduledoc false
  # Naming and preparing the `TLA.Spec` modules a mix task was pointed at.
  #
  # Shared by `mix tla.check` and `mix tla.visualize`, which resolve the same thing and
  # must fail the same way when they cannot: a task that says "no such module" where its
  # sibling says "does not `use TLA.Spec`" teaches two different mental models of one
  # error. `mix tla.simulate` and `mix tla.replay` are deliberately NOT here — they
  # resolve a `TLA.GenServer`, which is a different question with a different diagnostic.

  alias TLA.Spec

  @doc """
  The spec modules named on the command line, or every one in the project when none were.
  """
  @spec resolve!([String.t()]) :: [module()]
  def resolve!([]) do
    Mix.Project.config()
    |> Keyword.fetch!(:app)
    |> :application.get_key(:modules)
    |> case do
      {:ok, modules} -> Enum.filter(modules, &spec?/1)
      :undefined -> []
    end
    |> Enum.sort()
  end

  def resolve!(names) do
    Enum.map(names, fn name ->
      module = Module.concat([name])

      unless spec?(module) do
        Mix.raise("#{inspect(module)} is not a TLA spec: it does not `use TLA.Spec`.")
      end

      module
    end)
  end

  @doc """
  The constant assignment for a spec, or an error naming both places it could come from.
  """
  @spec constants!(Spec.Compiled.t()) :: map()
  def constants!(spec) do
    case Spec.Compiled.resolve_constants(spec) do
      {:ok, constants} ->
        constants

      {:error, missing} ->
        Mix.raise("""
        #{inspect(spec.module)} has no assignment for \
        #{Enum.map_join(missing, ", ", &inspect/1)}.

        Supply them either beside the declaration:

            constant #{inspect(hd(missing))}, default: …

        or in config/config.exs:

            config :extla, #{inspect(spec.module)}, constants: %{#{hd(missing)}: …}
        """)
    end
  end

  @doc """
  Whether a module carries a compiled specification.
  """
  @spec spec?(module()) :: boolean()
  def spec?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__tla_spec__, 0)
  end
end
