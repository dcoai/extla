defmodule ExTLA.CheckJsonSchemaTest do
  @moduledoc """
  The JSON result schema is a **contract with another project** (#66, and #1 section (d)).

  Every assertion here exists so that renaming or dropping a field fails in ExTLA's own suite
  rather than in a consumer's. Without that, the only way to discover that this output changed
  is for someone downstream to get a wrong answer from it — which is precisely the maintenance
  tax a stable schema is supposed to remove.
  """

  use ExUnit.Case, async: true

  @envelope_keys ~w(schema_version specs)
  @entry_keys ~w(
    spec status message distinct_states states_found transitions diameter deadlock
    duration_ms fingerprint_bits collision_estimate warnings coverage profile violation
  )
  @coverage_keys ~w(actions never_enabled invariants vacuous terminal_but_live terminals bounded_by)

  # The exit status is deliberately NOT asserted to be 0: `mix tla.check` exits non-zero when
  # it finds a violation, and a violating run is half of what this schema has to cover. Pinning
  # it to 0 would silently restrict these assertions to the happy path.
  defp emit(spec) do
    {output, _status} =
      System.cmd("mix", ["tla.check", spec, "--format", "json"],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: false
      )

    Jason.decode!(output)
  end

  # A clean run and a violating run, because a schema that only holds for the happy path is
  # not a schema.
  setup_all do
    %{
      ok: emit("ExTLA.Differential.TwoPhaseCommit"),
      violation: emit("ExTLA.Differential.DieHard")
    }
  end

  describe "the envelope" do
    test "leads with a schema version a reader can refuse on", %{ok: json} do
      assert json["schema_version"] == Mix.Tasks.Tla.Check.schema_version()
      assert is_integer(json["schema_version"])
    end

    test "carries exactly the documented top-level keys", %{ok: json} do
      assert Enum.sort(Map.keys(json)) == Enum.sort(@envelope_keys)
    end

    test "specs is a list of self-describing entries, not a map keyed by module", %{ok: json} do
      assert is_list(json["specs"])
      assert Enum.all?(json["specs"], &is_binary(&1["spec"]))
    end
  end

  describe "every entry carries every documented key" do
    test "on a clean run", %{ok: json} do
      for entry <- json["specs"], do: assert(Enum.sort(Map.keys(entry)) == Enum.sort(@entry_keys))
    end

    test "and on a violating run", %{violation: json} do
      for entry <- json["specs"], do: assert(Enum.sort(Map.keys(entry)) == Enum.sort(@entry_keys))
    end

    test "coverage carries exactly its documented keys", %{ok: json} do
      coverage = json["specs"] |> hd() |> Map.fetch!("coverage")

      assert Enum.sort(Map.keys(coverage)) == Enum.sort(@coverage_keys)
    end
  end

  describe "the facts a consumer reads" do
    test "a clean run and a violating run are distinguishable", %{ok: ok, violation: bad} do
      assert hd(ok["specs"])["status"] == "ok"
      assert hd(bad["specs"])["status"] == "violation"
    end

    test "a violation carries its counterexample; a clean run carries null", %{
      ok: ok,
      violation: bad
    } do
      assert hd(ok["specs"])["violation"] == nil
      assert is_map(hd(bad["specs"])["violation"])
    end

    # D-9: the counterexample's LENGTH is the comparable fact, not its route. Two checkers may
    # legitimately find different shortest paths of the same length.
    test "the counterexample's action list is present and non-empty", %{violation: bad} do
      assert hd(bad["specs"])["violation"]["actions"] != []
    end

    test "bounded_by marks a run whose counts are lower bounds", %{violation: bad} do
      assert hd(bad["specs"])["coverage"]["bounded_by"] in ~w(none state_constraint max_states violation)
    end
  end

  # The distinction that cannot be recovered downstream: `ExTLA.Coverage` reports `nil`
  # near-misses as "not measured", which is a different fact from a measured zero. Defaulting
  # it to 0 on the way out would erase that at the one boundary that cannot get it back.
  describe "absent is not zero" do
    test "an unmeasured near-miss count is null, never 0", %{ok: json} do
      invariants =
        json["specs"]
        |> Enum.flat_map(&Map.values(&1["coverage"]["invariants"]))

      assert invariants != [], "the corpus should exercise at least one invariant"

      for inv <- invariants do
        assert inv["near_misses"] == nil or is_integer(inv["near_misses"])
      end
    end
  end
end
