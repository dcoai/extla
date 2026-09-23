# Generated from spec/07-examples.md Example 2 — do not edit.
#
# Regenerate with `mix tla.examples --write`; the `surface-drift` job fails on a
# difference. The specification is the page's fence: editing this file is editing a
# copy, which is the drift D-21 introduced and #280 closed.
defmodule TLA.Differential.RaftElection do
  @moduledoc """
  `RaftElection.tla`, in the ExTLA DSL — generated from `spec/07-examples.md` Example
  2, so "verbatim" holds by construction rather than by discipline.

  What this entry adds over the others is in `test/differential/README.md`. What it
  *specifies* is the page, and only the page.
  """
  use TLA.Spec

  constant :servers, default: MapSet.new([:s1, :s2, :s3])
  constant :max_term, default: 2

  variable :current_term, type: [^servers ~> 0..^max_term]
  variable :voted_for, type: [^servers ~> (^servers | :none)]
  variable :srv_state, type: [^servers ~> [:follower, :candidate, :leader]]
  variable :votes_granted, type: [^servers ~> set(^servers)]

  # TLA+'s `Message`, element for element.
  variable :messages,
    type:
      set(
        %{type: :request_vote, term: 0..^max_term, from: ^servers, to: ^servers}
        | %{
            type: :vote_response,
            term: 0..^max_term,
            from: ^servers,
            to: ^servers,
            granted: [true, false]
          }
      )

  init do
    current_term = for_each(^servers, fn _ -> 0 end)
    voted_for = for_each(^servers, fn _ -> :none end)
    srv_state = for_each(^servers, fn _ -> :follower end)
    votes_granted = for_each(^servers, fn _ -> set() end)
    messages = set()
  end

  # ── Actions ──

  # `^max_term` is a model bound, not part of Raft: the real protocol times out
  # again. The bound is what makes the state space finite.
  action :timeout, params: [s: ^servers] do
    require srv_state[s] in [:follower, :candidate]
    require current_term[s] < ^max_term

    let new_term = current_term[s] + 1

    let vote_requests =
          set(
            for t <- ^servers, t != s do
              %{type: :request_vote, term: new_term, from: s, to: t}
            end
          )

    current_term = update(current_term, s, fn _ -> new_term end)
    srv_state = update(srv_state, s, fn _ -> :candidate end)
    voted_for = update(voted_for, s, fn _ -> s end)
    votes_granted = update(votes_granted, s, fn _ -> set([s]) end)
    messages = union(messages, vote_requests)
  end

  # `msg` draws from the PRE-state. Params bind left to right, so `msg`'s
  # function receives `s` and can filter on it — one successor per matching
  # message, which is exactly `\\E msg \\in messages`.
  action :handle_request_vote,
    params: [
      s: ^servers,
      msg: fn st, %{s: s} ->
        Enum.filter(st.messages, &(&1.type == :request_vote and &1.to == s))
      end
    ] do
    let grant =
          msg.term >= current_term[s] and
            (voted_for[s] == :none or voted_for[s] == msg.from)

    let response = %{
          type: :vote_response,
          term: msg.term,
          from: s,
          to: msg.from,
          granted: grant
        }

    # Every RHS reads the PRE-state, so `current_term[s]` below is the old term
    # even though `current_term` is assigned in this same block (§2).
    current_term =
      if msg.term > current_term[s],
        do: update(current_term, s, fn _ -> msg.term end),
        else: current_term

    voted_for =
      if grant, do: update(voted_for, s, fn _ -> msg.from end), else: voted_for

    srv_state =
      if msg.term > current_term[s],
        do: update(srv_state, s, fn _ -> :follower end),
        else: srv_state

    messages = messages |> delete(msg) |> put(response)
  end

  # The term check is what makes `election_safety` hold. Without it a candidate
  # that timed out twice counts a vote granted in the EARLIER term towards its
  # current candidacy, and two servers reach `:leader` in the same term — an
  # 8-state counterexample TLC hands back in under a second.
  action :handle_vote_response,
    params: [
      s: ^servers,
      msg: fn st, %{s: s} ->
        Enum.filter(
          st.messages,
          &(&1.type == :vote_response and &1.to == s and &1.granted)
        )
      end
    ] do
    require msg.term == current_term[s]
    require srv_state[s] == :candidate

    let quorum = div(MapSet.size(^servers), 2) + 1
    let new_votes = put(votes_granted[s], msg.from)

    votes_granted = update(votes_granted, s, fn _ -> new_votes end)
    messages = delete(messages, msg)

    srv_state =
      if size(new_votes) >= quorum,
        do: update(srv_state, s, fn _ -> :leader end),
        else: srv_state
  end

  # Seeing a higher term is not consuming the message: `messages` is unchanged.
  action :step_down,
    params: [
      s: ^servers,
      msg: fn st, %{s: s} ->
        Enum.filter(st.messages, &(&1.to == s and &1.term > st.current_term[s]))
      end
    ] do
    current_term = update(current_term, s, fn _ -> msg.term end)
    srv_state = update(srv_state, s, fn _ -> :follower end)
    voted_for = update(voted_for, s, fn _ -> :none end)
  end

  # A split vote at `^max_term` leaves every server at the bound with nothing
  # deliverable left: the vote responses still in the network are refusals, or
  # grants to a server that is no longer a candidate, or grants for a term it
  # has moved past. That is the model bound, not a Raft deadlock
  # (`02-dsl-semantics.md` §5.3).
  terminal :term_bound_exhausted do
    Enum.all?(^servers, fn s -> current_term[s] == ^max_term end) and
      Enum.all?(messages, fn m ->
        m.type == :vote_response and
          not (m.granted and srv_state[m.to] == :candidate and
                 m.term == current_term[m.to])
      end)
  end

  # ── Safety ──

  invariant :election_safety,
    desc: "at most one leader per term — Raft's fundamental property" do
    Enum.all?(0..^max_term, fn term ->
      Enum.count(^servers, fn s ->
        srv_state[s] == :leader and current_term[s] == term
      end) <= 1
    end)
  end

  invariant :vote_integrity do
    Enum.all?(^servers, fn s ->
      voted_for[s] == :none or MapSet.member?(^servers, voted_for[s])
    end)
  end

  invariant :leader_has_quorum do
    let quorum = div(MapSet.size(^servers), 2) + 1

    Enum.all?(^servers, fn s ->
      srv_state[s] != :leader or size(votes_granted[s]) >= quorum
    end)
  end

  # ── Liveness (Phase 2) ──

  # Refuted by the term bound, by design: the split vote above ends in
  # `term_bound_exhausted` with no leader. The counterexample is the bound, not
  # Raft.
  temporal :eventually_elect_leader do
    eventually(Enum.any?(^servers, fn s -> srv_state[s] == :leader end))
  end

  fairness(:weak, [:handle_request_vote, :handle_vote_response])
  fairness(:strong, [:timeout])
end
