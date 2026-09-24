defmodule TLA.DeliveryContractTest do
  @moduledoc """
  The delivery contract is stated the same way in every place that states it (#305, for #172).

  ## What the contract is

  `concrete_message/2` may return `{:call, msg}`, `{:cast, msg}` or `{:info, msg}`; a bare
  term is a **call**. A cast completes when a `:sys.get_state/2` behind it replies. D-36
  records the reasoning.

  ## Why a gate

  The contract lives in three documents — `spec/05-layer3-conformance.md`, `usage-rules.md`
  and `spec/08-decisions.md` — so one can be edited and the others forgotten. This file
  holds them to the same forms and the same meaning for a bare term.

  It was written at #305, before the driver could honour any of it, and asserted then that
  the driver *still* sent a call unconditionally — so the "not yet delivered (#306)"
  markers could not outlive the work they pointed at. #306 landed, that assertion fired as
  designed, and the markers came out. What remains is the agreement between the documents
  and the code; the behaviour itself is `test/conformance/cast_delivery_test.exs`.
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

  describe "the documents and the code" do
    # The inverse of what this file asserted at #305, against the same line of source. A
    # document describing a capability the code does not have is this project's signature
    # defect; a "not yet" that outlived its plan is the same defect pointing the other way.
    test "agree that a cast is delivered as a cast" do
      driver = read("lib/tla/gen_server/driver.ex")

      assert driver =~ ~s|{:"$gen_cast", message}|,
             "`TLA.GenServer.Driver` cannot send a cast, so spec/05 and usage-rules.md " <>
               "describe a capability that does not exist."
    end

    test "and no 'not yet delivered' marker is left over" do
      refute squeeze(spec()) =~ "Not yet delivered",
             "spec/05 still says the delivery contract is undelivered, and #306 has landed."

      refute squeeze(rules()) =~ "Not yet delivered",
             "usage-rules.md still says the delivery contract is undelivered."
    end
  end
end
