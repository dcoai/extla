# `:mutation` is excluded by default. Those tests copy the project, compile it, and run a
# gate against the copy -- the corpus gate alone is 45 s -- so they belong to the sweep's
# CI job rather than to `mix test`, which #46 requires to stay near its current runtime.
#
#     mix test --include mutation
# `:needs_built_docs` marks a test that reads `doc/`, which only the `docs` job builds. A
# DIRECTORY cannot express that — `test/docs/` is run by the `test` job too, where `doc/` does
# not exist — and a test that handles the absence by passing is the vacuous guard #156 found
# next door to it. So the requirement is a tag: excluded here, included by the job that has the
# artifact, and failing loudly there when it does not.
#
#     MIX_ENV=dev mix docs && mix test test/docs --include needs_built_docs
#
# `Surfex.ExUnitFormatter` records each test's result at its exact version in
# `_build/surfex/evidence.jsonl`, which is what validates spec/04's relations (#336).
#
# `assert_receive_timeout` is 5 s rather than ExUnit's 100 ms (#366). A passing `assert_receive`
# returns the moment its message arrives, so the bound only matters when it never comes, and a
# long one costs a passing test nothing. A short one fails a correct test on an oversubscribed
# host. `refute_receive` keeps its default, since a refute always waits its whole window.
ExUnit.start(
  exclude: [:mutation, :needs_built_docs],
  assert_receive_timeout: 5_000,
  formatters: [ExUnit.CLIFormatter, Surfex.ExUnitFormatter]
)
