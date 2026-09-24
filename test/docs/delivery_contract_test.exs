defmodule TLA.DeliveryContractTest do
  @moduledoc """
  The delivery contract is stated the same way in every place that states it (#305, for #172).

  ## What the contract is

  `concrete_message/2` may return `{:call, msg}`, `{:cast, msg}` or `{:info, msg}`; a bare
  term is a **call**. A cast completes when a `:sys.get_state/2` behind it replies. D-36
  records the reasoning.

  ## Why a gate, when nothing is implemented yet

  Because this is the interval in which a documented contract most easily becomes a lie. It
  lives in three documents — `spec/05-layer3-conformance.md`, `usage-rules.md` and
  `spec/08-decisions.md` — and until #306 lands, **none of it is true of the code**. Both
  reader-facing documents therefore carry a "not yet delivered" marker naming #306, and
  this file asserts:

  * all three state the same forms, so one cannot be edited and the others forgotten;
  * both markers name the issue that removes them, so "not yet" cannot outlive its plan;
  * the driver really does still send a call unconditionally — because a marker saying
    "not yet" after the work has landed is the same defect pointing the other way.

  The third assertion is what makes this file self-retiring: when #306 changes the driver,
  it fails, and whoever lands #306 removes the markers as part of the same change. The
  precedent is `--init-arg` in `spec/05`, documented as accepted and not read (#165) and
  held by the options gate.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  @forms ["{:call, msg}", "{:cast, msg}", "{:info, msg}"]

  defp read(relative), do: @root |> Path.join(relative) |> File.read!()

  defp squeeze(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp spec, do: read("spec/05-layer3-conformance.md")
  defp rules, do: read("usage-rules.md")
  defp decisions, do: read("spec/08-decisions.md")

  describe "the three delivery forms" do
    test "are named in spec/05, usage-rules.md and the decision log alike" do
      for form <- @forms do
        assert spec() =~ form, "spec/05 does not name #{form}"
        assert rules() =~ form, "usage-rules.md does not name #{form}"
        assert decisions() =~ form, "D-36 does not name #{form}"
      end
    end

    test "and all three say a bare term is a call" do
      assert squeeze(spec()) =~ "a call. What a bare term has always meant"
      assert squeeze(rules()) =~ "A bare term is a call."
      assert squeeze(decisions()) =~ "a bare term is a call"
    end

    # The ambiguity the tagging introduces, and the escape from it. Stating the forms
    # without it would leave a mapping whose literal message is a tagged tuple with no way
    # to say so — which is the objection a reader will have, answered where they will have it.
    test "and both reader-facing documents give the escape for a literal tagged tuple" do
      assert squeeze(spec()) =~ "{:call, {:cast, 5}}"
      assert squeeze(rules()) =~ "{:call, {:cast, 5}}"
    end
  end

  describe "the cast-completion decision" do
    test "is recorded as D-36, with its cost" do
      assert decisions() =~ "## D-36 —"

      d36 = decisions() |> String.split("## D-36 —") |> List.last() |> squeeze()

      assert d36 =~ ":sys.get_state"
      assert d36 =~ "no additional round-trip"

      # The reason the cost is nothing, which is the part a reader has to be able to check:
      # both drivers already make that call once per step.
      assert d36 =~ "TLA.Replay"
      assert d36 =~ "TLA.Simulation"
    end

    # A decision recording only what was chosen is half a decision.
    test "and says what was rejected" do
      d36 = decisions() |> String.split("## D-36 —") |> List.last() |> squeeze()

      assert d36 =~ "Considered and rejected"
      assert d36 =~ "bounded wait"
    end
  end

  describe "the 'not yet delivered' markers" do
    test "name the issue that removes them" do
      assert squeeze(spec()) =~ "Not yet delivered (#306)"
      assert squeeze(rules()) =~ "Not yet delivered (#306)"
    end

    # Self-retiring, and the reason this file can exist before the code does. A marker that
    # outlives the work it points at is the same defect as an undocumented change, pointing
    # the other way — so the marker is held to the code it describes.
    test "and are still true: the driver sends a call unconditionally" do
      driver = read("lib/tla/gen_server/driver.ex")

      assert driver =~ ~s|send(pid, {:"$gen_call", {self(), ref}, message})|,
             """
             `TLA.GenServer.Driver` no longer sends `{:"$gen_call", …}` unconditionally, so
             #306 has landed — and the "not yet delivered (#306)" markers in
             `spec/05-layer3-conformance.md` and `usage-rules.md` are now false. Remove
             them, and replace this test with one that asserts the delivery forms behave
             as D-36 says.
             """

      refute driver =~ ~s|{:"$gen_cast"|,
             "the driver can send a cast; see the message above"
    end
  end
end
