defmodule Mix.Tasks.Extla.Exercise do
  @shortdoc "Render what mix test exercises in each shipped module to EXERCISE.md"

  @moduledoc """
  Read a `mix test` coverage export and render, per shipped module, the executable lines, the
  ones never reached and the functions never entered, to `EXERCISE.md` (#323, #370).

      mix test --cover --export-coverage test
      mix extla.exercise                    # print the golden
      mix extla.exercise --write            # regenerate EXERCISE.md
      mix extla.exercise --check            # fail if the golden has drifted

  `--coverdata PATH` reads another export; the default is `cover/test.coverdata`, which the
  first command writes.

  ## Why it runs in the `test` job

  The data is that job's own run. Checking it there needs nothing carried between jobs, and the
  other goldens' job (`surface-drift`) would have to run the whole suite again to have it.

  ## Why `--check` is HARD

  A row that moved is coverage gained or lost. Gained and not recorded can be lost again with
  nothing noticing; lost and not regenerated is a module the suite stopped reaching.
  """

  use Mix.Task

  alias ExTLA.{ApiSurface, Exercise}

  @golden "EXERCISE.md"
  @default_coverdata "cover/test.coverdata"
  @switches [write: :boolean, check: :boolean, coverdata: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)
    coverdata = Keyword.get(opts, :coverdata, @default_coverdata)

    unless File.exists?(coverdata) do
      Mix.raise(
        "no coverage export at #{coverdata}. Run `mix test --cover --export-coverage test` " <>
          "first: this golden is what that run exercised."
      )
    end

    modules = Enum.map(ApiSurface.run(), fn {module, _items} -> module end)
    rendered = coverdata |> Exercise.run(modules) |> Exercise.render()
    path = Path.join(File.cwd!(), @golden)

    cond do
      opts[:write] ->
        File.write!(path, rendered)
        Mix.shell().info("wrote #{path}")

      opts[:check] ->
        ExTLA.Surface.check!(@golden, "extla.exercise", path, rendered)

      true ->
        Mix.shell().info(rendered)
    end
  end

  @doc false
  def switches, do: @switches
end
