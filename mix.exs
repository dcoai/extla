defmodule ExTLA.MixProject do
  use Mix.Project

  @version "0.2.0"

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
      package: [
        licenses: ["MIT"],
        files:
          ~w(lib mix.exs README.md CHANGELOG.md LICENSE spec guides research/tla-plus-primer.md)
      ],
      # `guides/` ships and renders beside `spec/` (#94): the guides teach, the spec is the
      # authority they link to. Every code block in a guide is compiled and its claimed verdict
      # asserted by `test/guides/`, so a guide that drifts from the code it teaches fails the
      # build rather than teaching an API that does not exist.
      docs: [
        main: "readme",
        # Concatenated rather than one brace wildcard: `filelib` rejects a `/` inside braces,
        # and the order here is the order the sidebar lists them in.
        #
        # `filename:` rather than title alone, because the id -- and so the output filename -- is
        # what `main:` and every generated link name. `README.md` and `spec/README.md` both derive
        # `readme`, ExDoc disambiguates them to `readme-1`/`readme-2`, and `main: "readme"` then
        # named a page no build produced: the sidebar's home link 404'd on every page (#102).
        # Naming the spec index explicitly leaves `readme` to the one page that should own it.
        #
        # LICENSE is here because README.md links it. ExDoc renders an extension-less file as
        # preformatted text; without it that link is a 404 in the published docs, which is the
        # second defect the built-docs gate found.
        extras:
          ["README.md", "CHANGELOG.md"] ++
            Path.wildcard("guides/*.md") ++
            Path.wildcard("guides/tutorial/*.md") ++
            Enum.map(Path.wildcard("spec/*.md"), fn
              "spec/README.md" ->
                {:"spec/README.md", filename: "spec-readme", title: "Specification index"}

              path ->
                path
            end) ++
            [
              "research/tla-plus-primer.md",
              {:LICENSE, filename: "license", title: "License"}
            ],
        # `Guides` matches only the TOP level of `guides/`, so the list can be in reading order
        # -- getting-started, then the tutorial -- rather than in the order the patterns have to
        # be tried in. A bare `^guides\//` here would swallow every tutorial page.
        groups_for_extras: [
          Guides: ~r/^guides\/[^\/]+\.md$/,
          Tutorial: ~r/^guides\/tutorial\//,
          Specification: ~r/^spec\//,
          # The primer ships so that the introduction's links into it resolve for a reader of the
          # published docs. It is background on TLA+ itself rather than an ExTLA specification,
          # which is why it has a group of its own and lives outside `spec/`.
          Background: ~r/^research\//,
          License: ~r/^LICENSE$/
        ]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  # `mix tla.mutants` lives in `test/support/` — it mutates ExTLA's own source, so it is a
  # tool of this checkout rather than of the library, and it must not ship in the package.
  # Declaring its environment here is what lets it be invoked as `mix tla.mutants` instead
  # of `MIX_ENV=test mix tla.mutants`, which is a prefix everyone forgets once.
  def cli, do: [preferred_envs: ["tla.mutants": :test]]

  # `ledger/` is the verification ledger's tooling (#1): the content-version scan, the
  # coverage golden and its mix task. Dev and test only, and never shipped — it depends on
  # `surfex`, which is itself dev/test only, so a `lib/` placement would break a consumer's
  # prod compile. `consumer-compile` (#63) is the job that proves this stays true.
  defp elixirc_paths(:test),
    do: ["lib", "ledger", "test/support", "test/differential", "test/conformance"]

  defp elixirc_paths(:dev), do: ["lib", "ledger"]
  defp elixirc_paths(_), do: ["lib"]

  # spec/06-architecture.md §Dependencies. Zero runtime dependencies.
  defp deps do
    [
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      # The verification ledger's renderer and source-scan primitives (#1), shared with
      # agentronic and extc so one convention serves all three.
      #
      # `only: [:dev, :test]` is load-bearing, not hygiene: dev/test deps are NOT transitive,
      # so nothing here reaches anyone who depends on ExTLA. That is what answers #1 section
      # (c)'s objection that consumers would inherit a documentation framework.
      {:surfex,
       git: "git@gitlab.conet.yarina.org:dco-tek/surfex.git",
       tag: "v0.1.0",
       only: [:dev, :test],
       runtime: false},
      {:jason, "~> 1.4", optional: true},
      # Layer 1's violation events. Optional for the same reason jason is: a consumer
      # who attaches no handler should not be made to carry it, and whether it was
      # present is decided when ExTLA compiles rather than on every check.
      {:telemetry, "~> 1.0", optional: true},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
