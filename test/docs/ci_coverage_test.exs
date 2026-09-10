defmodule TLA.CiCoverageTest do
  @moduledoc """
  Every directory of tests is run by some CI job (#175).

  **Nothing in this repository read `.gitlab-ci.yml` before this.** No test asserted that the
  set of jobs covers the test tree, so "this check lives in a directory the job that could run
  it does not run" was undetectable by construction — and it had already happened twice.

  `test/guides/guide_links_test.exs`'s slug cross-check is the sharper instance. It validates
  `Links.slug/1` against ExDoc's real generated ids, which is the only thing proving the link
  gate asserts something true. It lives in `test/guides/`; the `docs` job runs only
  `mix test test/docs`; and `doc/` never exists in the `test` job. So it always took its
  else-branch, asserted `not File.dir?("doc")`, and passed — having never run.

  The pattern is this project's own cardinal sin arriving through directory layout rather
  than through anyone's decision. A test that reads the pipeline is the cheapest guard for it.

  ## What this catches, and what it does not

  It catches a directory reached by **no job** — the shape that arrives when someone narrows
  the `test` job to a path, or adds a directory the pipeline was never told about. Today the
  `test` job runs a bare `mix test`, so the tree is covered and this passes; the value is that
  narrowing it fails here instead of silently shrinking the suite.

  It does **not** catch the `guide_links_test.exs` case, and the distinction is worth stating
  rather than letting the citation above imply otherwise. That test *is* run by the `test`
  job. Its problem is different: it needs a built `doc/`, and only the `docs` job builds one,
  so it runs where the artifact is absent and takes its else-branch every time. Detecting
  "this test needs an artifact another job produces" is not something a coverage check can
  see. #156 fixes that one by moving it into the job that has the artifact.

  It also says nothing about whether a directory's tests are meaningful. The rest of the
  suite is where that question lives.
  """
  use ExUnit.Case, async: true

  @ci Path.expand("../../.gitlab-ci.yml", __DIR__)
  @test_root Path.expand("../..", __DIR__) |> Path.join("test")

  # Directories that hold support code rather than tests, and are compiled into the test
  # environment instead of being run. Listed rather than inferred, so adding one is a
  # deliberate act.
  @not_test_directories ~w(support mutation)

  defp test_directories do
    @test_root
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(@test_root, &1)))
    |> Enum.reject(&(&1 in @not_test_directories))
    |> Enum.sort()
  end

  defp mix_test_invocations do
    @ci
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    # A `script:` line, not a comment. The file discusses `mix test` in prose repeatedly, and
    # counting those would make this pass on a pipeline that runs nothing.
    |> Enum.filter(&String.starts_with?(&1, "- mix test"))
    |> Enum.map(&String.replace_prefix(&1, "- ", ""))
  end

  test "the pipeline actually invokes mix test" do
    invocations = mix_test_invocations()

    # Without this the coverage assertion below iterates an empty set of jobs and finds
    # everything uncovered — or, worse, a future refactor that renames the script key makes
    # it find nothing and report nothing.
    assert invocations != [], """
    No `- mix test …` line found in #{@ci}.

    Either the pipeline no longer runs the suite, or the script lines are written differently
    and this parser now reads nothing — which would make the coverage check below vacuous.
    """
  end

  test "every test directory is run by some job" do
    invocations = mix_test_invocations()

    # A bare `mix test` runs the whole tree. `mix test --only mutation` does NOT: it walks the
    # tree and runs only the tagged tests, so it covers a tag rather than a directory. An
    # earlier draft of this check treated any flag-only invocation as full coverage, which made
    # the mutation job satisfy it and the whole assertion vacuous — the defect this file exists
    # to prevent, in the file itself.
    covers_everything? =
      Enum.any?(invocations, fn line ->
        args = line |> String.replace_prefix("mix test", "") |> String.split(" ", trim: true)

        args == [] or
          (not Enum.any?(args, &String.starts_with?(&1, "test/")) and
             not Enum.any?(args, &(&1 in ~w(--only --exclude --include))))
      end)

    named =
      invocations
      |> Enum.flat_map(&String.split/1)
      |> Enum.filter(&String.starts_with?(&1, "test/"))
      |> MapSet.new()

    uncovered =
      if covers_everything? do
        []
      else
        Enum.reject(test_directories(), fn dir ->
          Enum.any?(named, &String.starts_with?(&1, "test/#{dir}"))
        end)
      end

    assert uncovered == [], """
    These test directories are run by no CI job:

    #{Enum.map_join(uncovered, "\n", &"  test/#{&1}")}

    A test in an unrun directory passes locally and never runs where it counts, and the suite
    simply gets smaller with nothing failing.

    Add the directory to a job, or move the tests to one that is already covered.
    """
  end
end
