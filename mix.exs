defmodule ExTLA.MixProject do
  use Mix.Project

  @version "0.5.1-dev"
  @source_url "https://github.com/dcoai/extla"

  def project do
    [
      app: :extla,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "ExTLA",
      description:
        "Describe your system's states, find the invalid ones automatically, and check that your GenServers behave as described.",
      # GitHub is the public home (#402). Day-to-day work happens on a private GitLab
      # instance that a reader of the docs or the package can't reach, so nothing that ships
      # names it: "View source", the package links and the install instruction (held to
      # `source_url` by the guide harness's `tla:deps`) all point here.
      source_url: @source_url,
      homepage_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{
          "GitHub" => @source_url,
          "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
        },
        files: packaged_files()
      ],
      # `guides/` ships and renders beside `spec/` (#94): the guides teach, the spec is the
      # authority they link to. Every code block in a guide is compiled and its claimed verdict
      # asserted by `test/guides/`, so a guide that drifts from the code it teaches fails the
      # build rather than teaching an API that does not exist.
      docs: [
        main: "readme",
        # "View source" links resolve at the release the docs describe. A `-dev` version has
        # no tag, so docs built between releases link `main`.
        source_ref: if(String.ends_with?(@version, "-dev"), do: "main", else: "v#{@version}"),
        # The published docs advertise only what the package ships (#274).
        #
        # `mix docs` runs under `MIX_ENV=dev`, because `ex_doc` is a dev dependency, and
        # `elixirc_paths(:dev)` includes `ledger/` — so until this filter the published
        # documentation carried `ExTLA.Ledger`, `ExTLA.Spec.Version` and `mix extla.coverage`,
        # eleven modules in all, to a reader whose `mix deps.get` brings them `lib/` only.
        # Nobody decided to document the ledger: the docs job's environment did, and the
        # `consumer-compile` job that proves the package is right cannot see the docs.
        #
        # Derived from `files:` rather than listed, so the two cannot disagree — an explicit
        # list here would be a fourth hand-kept answer to "what is ExTLA". The same predicate
        # renders `PACKAGE_SURFACE.md`'s `packaged?` column.
        filter_modules: &ExTLA.MixProject.packaged?/2,
        # `CHANGELOG.md` names functions that no longer exist, and must (#291).
        #
        # D-30 states the rule — prose about an internal names it without the backticked
        # `Mod.fun/arity` form, which ExDoc reads as a link claim — and states this exemption
        # in the same breath: *a changelog that cannot name a removed function cannot record a
        # removal*. `Coverage.observe_action/5` was removed by #135, `Parallel.merge/2` made
        # private, `ExTLA.Mix.TraceFile` hidden; each is named in the entry that did it, which is
        # exactly where a reader looking for it will be.
        #
        # So the exemption is declared here rather than the history being reworded to suit a
        # linter. It is scoped to the one file: every other page is held to D-30 by
        # `--warnings-as-errors` in the `docs` job.
        skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
        # The ledger's own modules, named in prose and not linked.
        #
        # `skip_undefined_reference_warnings_on` above does not cover these: they are not
        # undefined, they are **filtered** — real modules that `filter_modules` keeps out of
        # the published docs because a consumer's `mix deps.get` does not bring them. So the
        # backticks are code formatting and ExDoc reads them as a link request, to a page it
        # was told not to generate.
        #
        # A short hand-kept list, which is usually this project's least favourite thing — but
        # it is self-maintaining in the only way that matters: naming another ledger module in
        # prose fails the `docs` job with a warning that says which one. The list cannot go
        # stale silently, which is the property that makes a hand-kept list acceptable.
        skip_code_autolink_to: ["ExTLA.Ledger", "mix extla.coverage"],
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
          ["README.md", "usage-rules.md", "CHANGELOG.md"] ++
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

  # `mix extla.mutants` lives in `test/support/` — it mutates ExTLA's own source, so it is a
  # tool of this checkout rather than of the library, and it must not ship in the package.
  # Declaring its environment here is what lets it be invoked as `mix extla.mutants` instead
  # of `MIX_ENV=test mix extla.mutants`, which is a prefix everyone forgets once.
  def cli, do: [preferred_envs: ["extla.mutants": :test]]

  @doc """
  Whether the package ships the module a doc chunk came from (#274).

  ExDoc hands `filter_modules` the module and its doc metadata, and the metadata carries
  `source_path` — so "would a consumer receive this?" is answerable from the same `files:`
  list the package is built from, rather than from a second list that would drift from it.

  A module with no `source_path` is kept: that is a module ExDoc could not locate, and
  dropping it silently would hide it from the docs on a technicality rather than a rule.
  """
  def packaged?(_module, %{source_path: source_path}) do
    relative = Path.relative_to(to_string(source_path), File.cwd!())

    Enum.any?(packaged_files(), fn entry ->
      relative == entry or String.starts_with?(relative, entry <> "/")
    end)
  end

  def packaged?(_module, _metadata), do: true

  defp packaged_files do
    ~w(lib mix.exs README.md CHANGELOG.md LICENSE usage-rules.md spec guides
       research/tla-plus-primer.md)
  end

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
      #
      # From Hex since #333; it was a GitLab git dependency before, and the only one.
      {:surfex, "~> 0.8.0", only: [:dev, :test], runtime: false},
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
