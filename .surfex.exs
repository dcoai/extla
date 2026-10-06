# surfex's relation log, piloted on spec/04 (#336). `mix surfex.info config` lists every key.
[
  sources: ["spec/04-layer2-model-checker.md"],
  tests: ["test/**/*_test.exs"],
  # The default is the app name camelized, "Extla", which is not the modules' casing.
  namespace: "ExTLA",
  # A type is not an item in surfex 0.5.24, so `ExTLA.State.t()` would be a broken
  # citation although the type exists. The module's version covers its `@type`s, so a type
  # citation names its module until surfex resolves types itself (surfex#137). A project
  # `normalise` replaces the default, so the default (drop a call's arguments) is restated.
  normalise: [{~r/\.t\(\)$/, ""}, {~r/\(.*\)$/s, ""}],
  # An established suite: trusted once, at `mix surfex.baseline`, after spec/04's
  # `verifies` tags are written (#354). `require:` and `triangle: :fail` are decided after
  # the pilot, on its friction log.
  adoption: :trust,
  goldens: [:status]
]
