defmodule Mix.Tasks.Tla.ApiSurface do
  @shortdoc "Render what lib/ declares to API_SURFACE.md"

  @moduledoc """
  Scan `lib/` for every public function head and every named type, and render the result to
  `API_SURFACE.md` (#270, #271).

      mix tla.api_surface           # print the golden
      mix tla.api_surface --write   # regenerate API_SURFACE.md
      mix tla.api_surface --check   # fail if the golden has drifted from the source

  ## Why `--check` is HARD

  The golden is the code's side of a comparison the specification's API blocks are held to
  (#164). A drift means a signature or a type changed and the document that lists it was not
  regenerated — which is exactly the moment the spec block that cites it may have gone stale
  too. An advisory gate on that document is the D-10 mistake `mix tla.coverage` refuses.

  It reads source, not compiled modules (`Surfex.SourceScan`), so it runs before the build and
  lists what a reader of `lib/` would find.
  """

  use Mix.Task

  alias ExTLA.ApiSurface

  @golden "API_SURFACE.md"
  @switches [write: :boolean, check: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    rendered = ApiSurface.run() |> ApiSurface.render()
    path = Path.join(File.cwd!(), @golden)

    cond do
      opts[:write] ->
        File.write!(path, rendered)
        Mix.shell().info("wrote #{path}")

      opts[:check] ->
        ExTLA.Surface.check!(@golden, "tla.api_surface", path, rendered)

      true ->
        Mix.shell().info(rendered)
    end
  end

  @doc false
  # Exposed for `ExTLA.SpecOptionsTest` / `CLI_SURFACE.md`, which hold a task's switches and its
  # documentation to each other.
  def switches, do: @switches
end
