defmodule ExTLA.Differential.TwoPhaseCommit do
  @moduledoc """
  `TwoPhaseCommit.tla`, in the ExTLA DSL.

  TLA+ strings become atoms and TLA+ records become maps; nothing else is
  restated, so a disagreement with TLC points at the checker rather than at a
  translation choice.

  `type_ok` checks what TLA+'s `TPTypeOK` checks, field for field: §1.5's
  `set(t)` and record forms say `msgs \\subseteq Message` in the DSL. Until they
  existed this entry declared `msgs` as `:set` and checked strictly less than TLC
  did — an entry that can agree with the oracle for the wrong reason.
  """
  use ExTLA.Spec

  constant :rms, default: MapSet.new([:r1, :r2, :r3])

  variable :rm_state, type: [^rms ~> [:working, :prepared, :committed, :aborted]]
  variable :tm_state, type: [:init, :done]
  variable :tm_prepared, type: set(^rms)

  # TLA+'s `Message`, element for element:
  #   [type : {"Prepared"}, rm : RM] \\cup [type : {"Commit", "Abort"}, rm : {"tm"}]
  variable :msgs,
    type: set(%{type: :prepared, rm: ^rms} | %{type: [:commit, :abort], rm: :tm})

  init do
    rm_state = for_each(^rms, fn _ -> :working end)
    tm_state = :init
    tm_prepared = set()
    msgs = set()
  end

  # The transaction manager notices that a resource manager has prepared. The
  # message stays in `msgs`, so it can be delivered again — which is what makes
  # the message set a set rather than a queue.
  action :tm_rcv_prepared, params: [rm: ^rms] do
    require tm_state == :init
    require member?(msgs, %{type: :prepared, rm: rm})

    tm_prepared = put(tm_prepared, rm)
  end

  action :tm_commit do
    require tm_state == :init
    require tm_prepared == ^rms

    tm_state = :done
    msgs = put(msgs, %{type: :commit, rm: :tm})
  end

  action :tm_abort do
    require tm_state == :init

    tm_state = :done
    msgs = put(msgs, %{type: :abort, rm: :tm})
  end

  action :rm_prepare, params: [rm: ^rms] do
    require rm_state[rm] == :working

    rm_state = update(rm_state, rm, fn _ -> :prepared end)
    msgs = put(msgs, %{type: :prepared, rm: rm})
  end

  action :rm_choose_to_abort, params: [rm: ^rms] do
    require rm_state[rm] == :working

    rm_state = update(rm_state, rm, fn _ -> :aborted end)
  end

  action :rm_rcv_commit_msg, params: [rm: ^rms] do
    require member?(msgs, %{type: :commit, rm: :tm})

    rm_state = update(rm_state, rm, fn _ -> :committed end)
  end

  action :rm_rcv_abort_msg, params: [rm: ^rms] do
    require member?(msgs, %{type: :abort, rm: :tm})

    rm_state = update(rm_state, rm, fn _ -> :aborted end)
  end

  # The point of the protocol: no resource manager commits while another has
  # aborted. It holds, so the state count carries the whole comparison.
  invariant :tp_consistent, desc: "no RM commits while another has aborted" do
    let states = values(rm_state)

    not (Enum.any?(states, &(&1 == :aborted)) and Enum.any?(states, &(&1 == :committed)))
  end
end
