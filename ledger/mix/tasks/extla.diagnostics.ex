defmodule Mix.Tasks.Extla.Diagnostics do
  @shortdoc "Render every mix extla.* task's switches and exit codes to DIAGNOSTICS.md"

  @moduledoc """
  Scan every `mix extla.*` task for its switches, its documented exit codes and the
  specification section that reproduces it, and render the result to `DIAGNOSTICS.md`
  (#270, #272).

      mix extla.diagnostics           # print the golden
      mix extla.diagnostics --write   # regenerate DIAGNOSTICS.md
      mix extla.diagnostics --check   # fail if the golden has drifted from the source

  ## Why `--check` is HARD

  The golden is the set `spec_options_test` iterates. A drift means a switch, an exit code or
  a task appeared or moved and the document that lists it was not regenerated — and the row a
  gate reads would then be describing a task that no longer looks like that. An advisory gate
  on the input to another gate is worse than no gate, because the second one keeps passing.

  It reads source, not compiled modules (`Surfex.SourceScan`), so it runs before the build,
  and the set of tasks is the directory rather than a list somebody maintains.
  """

  use Mix.Task

  alias ExTLA.Diagnostics

  @golden "DIAGNOSTICS.md"
  @switches [write: :boolean, check: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    rendered = Diagnostics.run() |> Diagnostics.render()
    path = Path.join(File.cwd!(), @golden)

    cond do
      opts[:write] ->
        File.write!(path, rendered)
        Mix.shell().info("wrote #{path}")

      opts[:check] ->
        ExTLA.Surface.check!(@golden, "extla.diagnostics", path, rendered)

      true ->
        Mix.shell().info(rendered)
    end
  end

  @doc false
  # Exposed for `ExTLA.SpecOptionsTest` / `DIAGNOSTICS.md`, which hold a task's switches and its
  # documentation to each other.
  def switches, do: @switches
end
