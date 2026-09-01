# `:mutation` is excluded by default. Those tests copy the project, compile it, and run a
# gate against the copy -- the corpus gate alone is 45 s -- so they belong to the sweep's
# CI job rather than to `mix test`, which #46 requires to stay near its current runtime.
#
#     mix test --include mutation
ExUnit.start(exclude: [:mutation])
