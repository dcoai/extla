defmodule TLA.LedgerTest do
  @moduledoc """
  What the verification ledger has to promise before a HARD gate can rest on it (#1).

  Two classes of claim. The first is that it is a **stable function of source** — a golden that
  moves on its own produces drift with no spec changing, and a gate that cries wolf is one
  somebody switches off. The second is that it is **honest about what it does not know**: a
  coverage document that quietly omits the specs it could not check is worse than no document,
  because it reads as completeness.
  """

  use ExUnit.Case, async: false

  alias TLA.Ledger

  setup_all do
    sections = Ledger.run()
    %{sections: sections, rendered: sections |> Ledger.render() |> IO.iodata_to_binary()}
  end

  describe "stability — the property the gate rests on" do
    test "rendering the same ledger twice produces identical bytes", %{sections: sections} do
      assert IO.iodata_to_binary(Ledger.render(sections)) ==
               IO.iodata_to_binary(Ledger.render(sections))
    end

    test "two independent runs agree" do
      assert IO.iodata_to_binary(Ledger.render(Ledger.run())) ==
               IO.iodata_to_binary(Ledger.render(Ledger.run()))
    end

    test "no date or clock time reaches the output", %{rendered: rendered} do
      refute rendered =~ ~r/\d{4}-\d{2}-\d{2}/
      refute rendered =~ ~r/\d{2}:\d{2}:\d{2}/
    end

    # `distinct_generated` attributes each state to whichever action reached it first, so it is
    # a function of the SEARCH ORDER and moves under `workers:` while the total does not.
    # `TLA.Coverage` documents this and says nothing in the report is derived from it; a golden
    # carrying it would drift with no spec changing, which is the subtlest way to break a gate.
    test "an action's Exercised reports enabled_in, not distinct_generated", %{sections: sections} do
      row =
        sections
        |> Enum.find(&(&1.runnable? and &1.error == nil))
        |> Map.fetch!(:rows)
        |> Enum.find(&(&1.kind == :action and &1.evidence == :model_checked))

      assert row.exercised =~ ~r/^enabled in \d+$/
    end
  end

  describe "honesty condition 1 — a spec that cannot run still gets rows" do
    test "an unassigned-constant spec is present, not omitted", %{sections: sections} do
      section = Enum.find(sections, &(&1.module == TLA.TestSpecs.Counter))

      assert section, "a spec with no constant assignment must appear"
      refute section.runnable?
      assert section.missing != []
      assert section.rows != [], "its items must be listed, or the ledger implies completeness"
      assert Enum.all?(section.rows, &(&1.evidence == :nothing))
    end

    test "and says so in its heading, not only in its cells", %{rendered: rendered} do
      assert rendered =~ "CANNOT RUN: no assignment for"
    end
  end

  describe "honesty condition 2 — a bounded run's numbers are lower bounds" do
    test "a truncated section is marked", %{sections: sections, rendered: rendered} do
      bounded = Enum.filter(sections, &(&1.bounded_by != :none))

      assert bounded != [], "the corpus should contain at least one bounded run"
      assert rendered =~ "LOWER BOUNDS"
    end

    test "and the marker travels with the number, not only with the section", %{
      sections: sections
    } do
      row =
        sections
        |> Enum.filter(&(&1.bounded_by != :none))
        |> Enum.flat_map(& &1.rows)
        |> Enum.find(&(&1.evidence == :model_checked))

      assert row.bounded?
    end
  end

  describe "a spec whose check raises is a finding, not a lost run" do
    # Process isolation rather than a rescue: the exit is observed and recorded, and — the part
    # that matters — every OTHER spec still gets its rows. An unisolated crash would end the
    # run and leave a ledger that looks like it simply found less.
    test "the raising spec is recorded with its exception", %{sections: sections} do
      section = Enum.find(sections, &(&1.module == TLA.TestSpecs.OutsideDomain))

      assert section
      assert section.error == "TLA.Spec.DomainError"
      assert Enum.all?(section.rows, &(&1.evidence == :nothing))
    end

    test "and the specs around it are unaffected", %{sections: sections} do
      verified =
        sections
        |> Enum.filter(&(&1.error == nil and &1.runnable?))
        |> Enum.flat_map(& &1.rows)
        |> Enum.filter(&(&1.evidence == :model_checked))

      assert length(verified) > 50, "a crash must not truncate the rest of the ledger"
    end

    # The message carries state values that vary with search order; the module name does not.
    test "only the exception's module reaches the output", %{rendered: rendered} do
      assert rendered =~ "RAISED TLA.Spec.DomainError"
      refute rendered =~ "is not in the domain"
    end
  end

  describe "what counts as verified" do
    test "NOTHING is the backlog and it is non-empty here", %{sections: sections} do
      gaps = Ledger.gaps(sections)

      assert gaps != []
      assert Enum.all?(gaps, &(&1.evidence == :nothing))
    end

    test "every row carries a content version or an explicit absence", %{sections: sections} do
      for row <- Ledger.rows(sections) do
        assert row.version == nil or row.version =~ ~r/^[0-9a-f]{8}$/
      end
    end

    # Superseded by #67, which introduced the stamps this column reports. It previously
    # asserted every row was `unstamped`, which was the honest value while nothing could
    # stamp anything.
    test "freshness reflects the spec_version stamps mappings carry", %{sections: sections} do
      by_status = sections |> Ledger.rows() |> Enum.frequencies_by(& &1.fresh)

      assert by_status[:fresh] > 0, "the corpus stamps at least one mapping (#67)"
      assert by_status[:unstamped] > 0, "and deliberately leaves others unstamped"
      assert Enum.all?(Map.keys(by_status), &(&1 in [:fresh, :stale, :unstamped, :unverifiable]))
    end

    # A stamp names a spec, so only the items of THAT spec become fresh. If freshness leaked
    # across specs the column would claim re-confirmation nobody made — the precise dishonesty
    # the ledger exists to prevent.
    test "a stamp freshens only its own spec's items", %{sections: sections} do
      stamped = Enum.find(sections, &(&1.module == TLA.Conformance.Counter.Spec))
      unstamped = Enum.find(sections, &(&1.module == TLA.Conformance.Counter.BuggySpec))

      assert Enum.all?(stamped.rows, &(&1.fresh == :fresh))
      assert Enum.all?(unstamped.rows, &(&1.fresh == :unstamped))
    end
  end

  describe "the checked-in golden" do
    test "matches what the code produces", %{rendered: rendered} do
      assert File.read!("TLA_COVERAGE.md") == rendered,
             "TLA_COVERAGE.md has drifted — regenerate with `MIX_ENV=test mix tla.coverage --write`"
    end
  end
end
