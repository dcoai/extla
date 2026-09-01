defmodule ExTLA.MixProject do
  use Mix.Project

  @version "0.1.0-dev"

  def project do
    [
      app: :extla,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "ExTLA",
      description: "TLA+-inspired formal verification for Elixir/OTP systems",
      package: [licenses: ["MIT"], files: ~w(lib mix.exs README.md LICENSE spec)],
      docs: [main: "readme", extras: ["README.md" | Path.wildcard("spec/*.md")]]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  # `mix tla.mutants` lives in `test/support/` — it mutates ExTLA's own source, so it is a
  # tool of this checkout rather than of the library, and it must not ship in the package.
  # Declaring its environment here is what lets it be invoked as `mix tla.mutants` instead
  # of `MIX_ENV=test mix tla.mutants`, which is a prefix everyone forgets once.
  def cli, do: [preferred_envs: ["tla.mutants": :test]]

  defp elixirc_paths(:test), do: ["lib", "test/support", "test/differential", "test/conformance"]
  defp elixirc_paths(_), do: ["lib"]

  # spec/06-architecture.md §Dependencies. Zero runtime dependencies.
  defp deps do
    [
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:jason, "~> 1.4", optional: true},
      # Layer 1's violation events. Optional for the same reason jason is: a consumer
      # who attaches no handler should not be made to carry it, and whether it was
      # present is decided when ExTLA compiles rather than on every check.
      {:telemetry, "~> 1.0", optional: true},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
