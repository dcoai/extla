defmodule ExTLA.Mix.TraceFile do
  @moduledoc false
  # Reading a counterexample `mix extla.check --format json` wrote.
  #
  # Shared by `mix extla.replay` and `mix extla.explore`, which read the same file and must fail
  # the same way on it. They differ only in how they arrive at the spec name — `extla.replay`
  # takes a `ExTLA.GenServer` and asks it for `__tla_spec_module__/0`, `extla.explore` is handed
  # the spec module itself — so that is the argument, and everything downstream of it is one
  # copy rather than two that drift.
  #
  # Not in `ExTLA.Mix.SpecTarget`: that module names and prepares the spec modules a task was
  # pointed at, which is a question about the project, and this is a question about a file.

  alias ExTLA.Trace

  @doc """
  The trace in `path`, for the spec named `spec` (as `inspect/1` writes a module).

  Three shapes are accepted, because three are what a caller plausibly has:

    * the versioned envelope `mix extla.check --format json` writes (#66);
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
        unless version == Mix.Tasks.Extla.Check.schema_version() do
          Mix.raise(
            "#{path} was written by schema version #{version}; this ExTLA reads version " <>
              "#{Mix.Tasks.Extla.Check.schema_version()}. Re-run `mix extla.check --format json`."
          )
        end

        violation!(path, spec, specs)

      %{} = results ->
        Mix.raise(
          "#{path} has no result for #{spec}. It carries: " <>
            "#{results |> Map.keys() |> Enum.join(", ")}."
        )

      _other ->
        Mix.raise("#{path} is not a trace written by `mix extla.check --format json`.")
    end
  end

  defp violation!(path, spec, specs) do
    case Enum.find(specs, &(&1["spec"] == spec)) do
      nil ->
        Mix.raise(
          "#{path} has no result for #{spec}. It carries: " <>
            "#{specs |> Enum.map_join(", ", & &1["spec"])}."
        )

      # No counterexample is not the same as verified, and the document says which: a bounded
      # or constrained run stopped before it could find one. This used to say "the spec was
      # verified" for both (#205), on a status the reader had in hand and did not read.
      %{"violation" => nil} = entry ->
        Mix.raise("#{path} records no counterexample for #{spec}: #{no_counterexample(entry)}")

      %{"violation" => violation} ->
        Trace.from_json!(violation)

      # An entry with no `violation` key at all is not a result `mix extla.check` wrote; it used
      # to be a `CaseClauseError` here (#211).
      entry ->
        Mix.raise(
          "#{path}'s entry for #{spec} has no \"violation\" key (it carries: " <>
            "#{entry |> Map.keys() |> Enum.join(", ")}), so it is not a result " <>
            "`mix extla.check --format json` wrote."
        )
    end
  end

  defp no_counterexample(%{"status" => "ok"}), do: "the spec was verified."

  defp no_counterexample(%{"status" => "max_states_reached"} = entry) do
    "the search was bounded at #{entry["distinct_states"]} states by the state limit, so " <>
      "nothing is verified. Re-run `mix extla.check --format json` with a higher --max-states."
  end

  defp no_counterexample(%{"status" => "constrained"} = entry) do
    "a `state_constraint:` held states back after #{entry["distinct_states"]} states, so " <>
      "nothing is verified. Re-run `mix extla.check --format json` without the constraint."
  end

  defp no_counterexample(%{"status" => status}),
    do: "the run's status is #{inspect(status)}, which is not verified."

  defp no_counterexample(_entry), do: "the entry carries no status, so nothing is known."

  defp decode!(path) do
    unless File.exists?(path), do: Mix.raise("#{path} does not exist.")

    case Jason.decode(File.read!(path)) do
      {:ok, data} -> data
      {:error, error} -> Mix.raise("#{path} is not JSON: #{Exception.message(error)}")
    end
  end
end
