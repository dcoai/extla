defmodule ExTLA.CiPipelineTest do
  @moduledoc """
  What a CI job may fetch and when it may run (#309, #364, #365).

  ## What is checked

  - **No job runs `apt-get`.** Every Elixir job used to fetch `git` from an unpinned Debian
    archive before running a line of this project's code, and the archive call failed whole
    pipelines on a runner that could not reach it (#309). `git`, Hex and Rebar are now in
    `CI_BASE_IMAGE`, so a returning `apt-get` is the regression. Comments may mention it.
  - **The base image is pinned by digest, under a tag that matches its inputs.**
    `CI_BASE_IMAGE` is `…/ci-base:<tag>@sha256:<digest>`. A tag alone can be pushed over, and
    the same inputs built twice gave two digests (#364), so the digest is the pin. The tag
    must equal the hash `ci-base-image` computes from `ELIXIR_IMAGE` and
    `ci/base.Dockerfile`. Bumping either without rebuilding and re-pinning fails here rather
    than running the old image unnoticed. `.elixir` must use it.
  - **Every rule of every job names `$CI_PIPELINE_SOURCE`.** A `changes:` rule with no source
    condition also matches merge-request events. On !236 that made GitLab open a second, MR
    pipeline holding only that job, which stood as the MR's head pipeline, green on one job
    while the real pipeline still ran (pipeline 4645).

  Read as text, line by line, like `ci_coverage_test.exs`: the project has no YAML parser,
  and these are claims about the file as written.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @ci Path.join(@root, ".gitlab-ci.yml")
  @dockerfile Path.join(@root, "ci/base.Dockerfile")

  describe ".gitlab-ci.yml" do
    test "no job runs apt-get" do
      assert apt_calls(File.read!(@ci)) == []
    end

    test "the base image is pinned by digest, under a tag that matches its inputs" do
      ci = File.read!(@ci)

      assert {:ok, %{tag: tag}} = base_image(ci)
      assert tag == input_hash(variable!(ci, "ELIXIR_IMAGE"), File.read!(@dockerfile))
      assert ".elixir" |> job_body(ci) |> Enum.any?(&(&1 == "  image: $CI_BASE_IMAGE"))
    end

    test "every rule of every job names the pipeline source" do
      ci = File.read!(@ci)
      rules = rules(ci)

      # Anti-vacuity: ci-base-image has two rules, so a reader that found none is broken.
      assert length(Map.get(rules, "ci-base-image", [])) == 2
      assert unsourced_rules(ci) == []
    end
  end

  describe "the checks themselves" do
    test "find an apt-get in a script, and not in a comment" do
      ci = """
      job:
        script:
          # apt-get used to run here
          - apt-get update -qq
      """

      assert [{4, "    - apt-get update -qq"}] = apt_calls(ci)
    end

    test "refuse a tag-only pin, and a tag that does not match the inputs" do
      assert {:error, _} =
               base_image("variables:\n  CI_BASE_IMAGE: reg/x/ci-base:0123456789abcdef\n")

      ci = "  CI_BASE_IMAGE: reg/x/ci-base:0123456789abcdef@sha256:" <> String.duplicate("a", 64)
      assert {:ok, %{tag: "0123456789abcdef"}} = base_image(ci)
      refute input_hash("hexpm/elixir:1", "FROM x\n") == "0123456789abcdef"
    end

    test "flag a changes: rule with no source condition" do
      ci = """
      build:
        rules:
          - if: $CI_PIPELINE_SOURCE == "web"
          - changes:
              - ci/base.Dockerfile
        script:
          - true
      """

      assert [{"build", rule}] = unsourced_rules(ci)
      assert rule =~ "changes:"
    end
  end

  # ── The checks ──

  # Every non-comment line that runs apt-get, as {line number, line}.
  defp apt_calls(ci) do
    for {line, n} <- Enum.with_index(String.split(ci, "\n"), 1),
        not String.match?(line, ~r/^\s*#/),
        String.match?(line, ~r/\bapt-get\b/),
        do: {n, line}
  end

  defp base_image(ci) do
    case Regex.run(~r/^\s*CI_BASE_IMAGE:\s*(\S+)\s*$/m, ci) do
      [_, ref] ->
        case Regex.run(~r/^\S+\/ci-base:([0-9a-f]{16})@sha256:[0-9a-f]{64}$/, ref) do
          [_, tag] -> {:ok, %{tag: tag}}
          nil -> {:error, "CI_BASE_IMAGE is not ci-base:<16-hex tag>@sha256:<digest>: #{ref}"}
        end

      nil ->
        {:error, "no CI_BASE_IMAGE variable"}
    end
  end

  # What `ci-base-image` computes: `{ echo "$ELIXIR_IMAGE"; cat ci/base.Dockerfile; } |
  # sha256sum | cut -c1-16`. `echo` adds the newline.
  defp input_hash(elixir_image, dockerfile) do
    :crypto.hash(:sha256, elixir_image <> "\n" <> dockerfile)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp variable!(ci, name) do
    [_, value] = Regex.run(~r/^\s*#{name}:\s*(\S+)\s*$/m, ci)
    value
  end

  # A top-level key's lines, up to the next top-level key.
  defp job_body(name, ci) do
    ci
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != "#{name}:"))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.match?(&1, ~r/^[^\s#][^:]*:\s*$/)))
  end

  defp jobs(ci) do
    for line <- String.split(ci, "\n"),
        [_, name] <- [Regex.run(~r/^([^\s#][^:]*):\s*$/, line)],
        do: name
  end

  # Each job's rules: a rule is a `- ` item under `rules:` and the lines indented under it.
  defp rules(ci) do
    for name <- jobs(ci), into: %{} do
      body = job_body(name, ci)

      rules =
        body
        |> Enum.drop_while(&(&1 != "  rules:"))
        |> Enum.drop(1)
        |> Enum.take_while(&(&1 == "" or String.match?(&1, ~r/^\s{3,}/)))
        |> Enum.reject(&String.match?(&1, ~r/^\s*(#|$)/))
        |> Enum.chunk_while(
          [],
          fn line, acc ->
            if String.match?(line, ~r/^    - /) and acc != [],
              do: {:cont, Enum.join(Enum.reverse(acc), "\n"), [line]},
              else: {:cont, [line | acc]}
          end,
          fn
            [] -> {:cont, []}
            acc -> {:cont, Enum.join(Enum.reverse(acc), "\n"), []}
          end
        )

      {name, rules}
    end
  end

  defp unsourced_rules(ci) do
    for {job, rules} <- rules(ci),
        rule <- rules,
        not String.contains?(rule, "CI_PIPELINE_SOURCE"),
        do: {job, rule}
  end
end
