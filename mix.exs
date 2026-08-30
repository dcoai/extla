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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # spec/06-architecture.md §Dependencies. Zero runtime dependencies.
  defp deps do
    [
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:jason, "~> 1.4", optional: true},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
