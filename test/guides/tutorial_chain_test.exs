defmodule TLA.Guides.TutorialChainTest do
  @moduledoc """
  The tutorial's forward chain: every page but the last hands the reader to the next one
  (#288, for #155).

  ## What went wrong

  Nine of eleven pages ended with a `Next:` line. `07-layer3.md` ended with a "Where to
  next" section listing four links into `spec/` — the same heading `getting-started.md`
  uses, where it genuinely *is* an ending — and `08-modelling.md` ended with three lines of
  closing prose. So a reader following the tutorial's own navigation finished page 07 and
  stopped.

  The three pages that stranded are `08-modelling.md`, `09-when-it-explodes.md` and
  `10-in-your-project.md`: how to get from a system you have to a specification worth
  checking, what to do when the state space explodes, and how to keep a specification in a
  project. They are the three a reader with a real codebase needs most, and they were
  reachable only from the ExDoc sidebar — which a reader of the repository does not have.

  ## Why a test rather than a review step

  The same argument `TLA.GuideCheck.Links` makes for anchors: a link that silently goes
  nowhere is drift, and a page that silently goes nowhere is the same thing one level up.
  Nothing here reads prose — only whether the last link forward exists and points at the
  successor in sorted order, which is a fact about the file names and needs no judgement.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # `Next: [Title](NN-name.md).` at the foot of a page — the form every page already uses.
  @next ~r/^Next: \[[^\]]+\]\(([^)]+)\)/m

  defp pages, do: @root |> Path.join("guides/tutorial/*.md") |> Path.wildcard() |> Enum.sort()

  defp forward_link(path) do
    case Regex.scan(@next, File.read!(path)) do
      [] -> nil
      matches -> matches |> List.last() |> Enum.at(1)
    end
  end

  describe "the tutorial's forward chain" do
    test "every page but the last hands the reader to its successor" do
      pages = pages()
      {body, [last]} = Enum.split(pages, -1)
      expected = Enum.zip(body, Enum.drop(pages, 1))

      broken =
        for {page, successor} <- expected,
            forward_link(page) != Path.basename(successor),
            do:
              "#{Path.basename(page)} → #{inspect(forward_link(page))}, " <>
                "expected #{Path.basename(successor)}"

      assert broken == [], """
      #{length(broken)} tutorial page(s) do not hand the reader to the next one:

        #{Enum.join(broken, "\n  ")}

      A reader following the tutorial's navigation stops at the first page that does not,
      and the pages after it are reachable only from the ExDoc sidebar — which a reader of
      the repository does not have. The form is `Next: [Title](NN-name.md).` at the foot of
      the page; #{Path.basename(last)} is the last page and carries none.
      """
    end

    test "and the last page carries no forward link" do
      last = pages() |> List.last()

      assert forward_link(last) == nil,
             "#{Path.basename(last)} is the last tutorial page and links forward to " <>
               "#{inspect(forward_link(last))}"
    end

    # Anti-vacuity. The assertions above are comprehensions over a glob: a wrong path yields
    # an empty list and reports green, which is the shape #164's layer 2 had.
    test "and the chain that is being checked is the whole tutorial" do
      pages = pages()

      assert length(pages) >= 11, "only #{length(pages)} tutorial pages found; the glob is wrong"
      assert Enum.any?(pages, &String.ends_with?(&1, "00-introduction.md"))
      assert Enum.any?(pages, &String.ends_with?(&1, "10-in-your-project.md"))

      # And that the reader is actually parsing links, not matching nothing everywhere.
      assert Enum.count(pages, &(forward_link(&1) != nil)) == length(pages) - 1
    end
  end

  describe "both contents lists describe the tutorial that exists" do
    # They each enumerated pages 02–07 and stopped, so the two lists a reader consults to
    # decide whether to start agreed with each other and with neither the tutorial nor the
    # sidebar.
    # Whitespace normalised on both sides: this is prose in a markdown file, wrapped at the
    # file's column, so "what to do when the state space explodes" arrives with a newline
    # inside it. Comparing raw is how #275's decision pins reported eight missing tests that
    # all existed.
    test "the introduction reaches the three pages about your own code" do
      introduction =
        @root |> Path.join("guides/tutorial/00-introduction.md") |> File.read!() |> squeeze()

      assert introduction =~ "mathematics"
      assert introduction =~ "state space explodes"
      assert introduction =~ "keep a specification in a project"
    end

    defp squeeze(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

    test "and getting-started links them" do
      getting_started = @root |> Path.join("guides/getting-started.md") |> File.read!()

      for page <- ~w(08-modelling.md 09-when-it-explodes.md 10-in-your-project.md) do
        assert getting_started =~ page,
               "getting-started.md's contents does not reach tutorial/#{page}"
      end
    end
  end
end
