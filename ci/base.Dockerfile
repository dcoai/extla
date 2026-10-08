# The image every Elixir CI job runs in (#309, #364).
#
# Everything a job used to fetch for itself before running a line of the project's code,
# fetched once here instead: `git` from the Debian archive, and Hex and Rebar from
# builds.hex.pm. Each was a network call on every job of every pipeline, and the archive one
# failed whole pipelines on a runner that could not reach it (#309). Built only when this file
# or `ELIXIR_IMAGE` changes (the `ci-base-image` job), and pinned by digest where it is used.
ARG ELIXIR_IMAGE
FROM ${ELIXIR_IMAGE}

RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

# The dependency is checked where it is satisfied, not where it is used: a build that lost
# any of these fails here, before anything is pushed.
RUN git --version \
 && mix archive | grep "hex-" >/dev/null \
 && ls "$HOME"/.mix/elixir/*/rebar3 >/dev/null
