[
  # Every Elixir file this repository tracks, held to that by
  # `test/docs/formatter_inputs_test.exs` (#317). `bin/` and `ledger/` were outside this
  # list while holding real Elixir — the surface-drift ledger, its six Mix tasks and the
  # CHANGELOG guard — and one of those files was unformatted while the `format` job passed.
  inputs: [
    "{mix,.formatter,.surfex}.exs",
    "{bench,bin,config,ledger,lib,scripts,test}/**/*.{ex,exs}"
  ],
  locals_without_parens: [
    constant: 1,
    constant: 2,
    variable: 1,
    variable: 2,
    action: 2,
    action: 3,
    invariant: 2,
    invariant: 3,
    action_property: 2,
    action_property: 3,
    temporal: 2,
    temporal: 3,
    terminal: 2,
    terminal: 3,
    fairness: 2,
    precondition: 2,
    precondition: 3,
    postcondition: 2,
    postcondition: 3,
    require: 1,
    let: 1,
    assert_spec: 2
  ]
]
