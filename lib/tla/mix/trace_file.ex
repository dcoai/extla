defmodule TLA.Mix.TraceFile do
  @moduledoc false
  # Reading a counterexample `mix tla.check --format json` wrote.
  #
  # Shared by `mix tla.replay` and `mix tla.explore`, which read the same file and must fail
  # the same way on it. They differ only in how they arrive at the spec name — `tla.replay`
  # takes a `TLA.GenServer` and asks it for `__tla_spec_module__/0`, `tla.explore` is handed
  # the spec module itself — so that is the argument, and everything downstream of it is one
  # copy rather than two that drift.
  #
  # Not in `TLA.Mix.SpecTarget`: that module names and prepares the spec modules a task was
  # pointed at, which is a question about the project, and this is a question about a file.

  alias TLA.Trace

  @doc """
  The trace in `path`, for the spec named `spec` (as `inspect/1` writes a module).

  Three shapes are accepted, because three are what a caller plausibly has:

    * the versioned envelope `mix tla.check --format json` writes (#66);
    * a single trace object lifted out of it, which is what someone who has already found
      the counterexample they care about will have;
    * a lasso, `%{"prefix" => …, "cycle" => …}`.

  Every failure is a `Mix.raise` naming the file and what was wrong with it.
  """
  def read!(path, spec) do
    case decode!(path) do
      %{"states" => _} = trace ->
        Trace.from_json!(trace)

      %{"prefix" => _} = lasso ->
        Trace.from_json!(lasso)

      # The version is CHECKED rather than ignored, which is the entire reason it exists. A
      # reader that parses optimistically discovers a shape change by getting a wrong answer
      # from it; refusing an unknown version turns that into a message naming both versions.
      %{"schema_version" => version, "specs" => specs} when is_list(specs) ->
        unless version == Mix.Tasks.Tla.Check.schema_version() do
          Mix.raise(
            "#{path} was written by schema version #{version}; this ExTLA reads version " <>
              "#{Mix.Tasks.Tla.Check.schema_version()}. Re-run `mix tla.check --format json`."
          )
        end

        violation!(path, spec, specs)

      %{} = results ->
        Mix.raise(
          "#{path} has no result for #{spec}. It carries: " <>
            "#{results |> Map.keys() |> Enum.join(", ")}."
        )

      _other ->
        Mix.raise("#{path} is not a trace written by `mix tla.check --format json`.")
    end
  end

  defp violation!(path, spec, specs) do
    case Enum.find(specs, &(&1["spec"] == spec)) do
      nil ->
        Mix.raise(
          "#{path} has no result for #{spec}. It carries: " <>
            "#{specs |> Enum.map_join(", ", & &1["spec"])}."
        )

      %{"violation" => nil} ->
        Mix.raise("#{path} records no counterexample for #{spec}: the spec was verified.")

      %{"violation" => violation} ->
        Trace.from_json!(violation)
    end
  end

  defp decode!(path) do
    unless File.exists?(path), do: Mix.raise("#{path} does not exist.")

    case Jason.decode(File.read!(path)) do
      {:ok, data} -> data
      {:error, error} -> Mix.raise("#{path} is not JSON: #{Exception.message(error)}")
    end
  end
end
