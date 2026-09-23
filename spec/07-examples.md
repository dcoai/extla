# ExTLA Examples

End-to-end examples using the settled DSL of
[`02-dsl-semantics.md`](02-dsl-semantics.md): constants are pinned (`^name`),
variables are bare, action bodies are simultaneous assignments, and all nondeterminism
lives in `params:`.

These are not illustrations. They are the **acceptance corpus**: each one must compile,
model-check, and — for those with implementations — pass conformance, before the DSL is
considered settled. A construct no example needs is a construct the DSL does not get.

---

## Example 1: Distributed Lock

### Specification (Layer 2)

<!-- tla:spec -->
```elixir
defmodule Specs.DistributedLock do
  use TLA.Spec

  constant :processes
  constant :resources

  variable :owner, type: [^resources ~> (^processes | :none)]
  variable :waiting, type: [^resources ~> set(^processes)]

  variable :pc,
    type: [^processes ~> (:idle | :requesting | {:holding, ^resources} | :releasing)]

  init do
    owner = for_each(^resources, fn _ -> :none end)
    waiting = for_each(^resources, fn _ -> set() end)
    pc = for_each(^processes, fn _ -> :idle end)
  end

  action :request_lock, params: [p: ^processes, r: ^resources] do
    require pc[p] == :idle

    waiting = update(waiting, r, &put(&1, p))
    pc = update(pc, p, fn _ -> :requesting end)
  end

  action :acquire_lock, params: [p: ^processes, r: ^resources] do
    require pc[p] == :requesting
    require owner[r] == :none
    require member?(waiting[r], p)

    owner = update(owner, r, fn _ -> p end)
    waiting = update(waiting, r, &delete(&1, p))
    pc = update(pc, p, fn _ -> {:holding, r} end)
  end

  action :release_lock, params: [p: ^processes, r: ^resources] do
    require pc[p] == {:holding, r}
    require owner[r] == p

    owner = update(owner, r, fn _ -> :none end)
    pc = update(pc, p, fn _ -> :releasing end)
  end

  action :return_to_idle, params: [p: ^processes] do
    require pc[p] == :releasing

    pc = update(pc, p, fn _ -> :idle end)
  end

  # ── Safety ──

  # Stated over `pc`, which is per PROCESS, so two processes can in principle
  # both be `{:holding, r}` — that is what gives this invariant content.
  invariant :mutual_exclusion,
    desc: "at most one process holds any given resource — THE lock property" do
    Enum.all?(^resources, fn r ->
      Enum.count(^processes, fn p -> pc[p] == {:holding, r} end) <= 1
    end)
  end

  invariant :owner_is_valid do
    Enum.all?(^resources, fn r ->
      owner[r] == :none or MapSet.member?(^processes, owner[r])
    end)
  end

  invariant :holding_means_owner do
    Enum.all?(^processes, fn p ->
      case pc[p] do
        {:holding, r} -> owner[r] == p
        _ -> true
      end
    end)
  end

  action_property :lock_not_stolen do
    Enum.all?(^resources, fn r ->
      old.owner[r] == new.owner[r] or
        old.owner[r] == :none or new.owner[r] == :none
    end)
  end

  # ── Liveness (Phase 2) ──

  temporal :no_starvation,
    desc: "every requesting process eventually acquires; needs SF per process" do
    Enum.all?(^processes, fn p ->
      (pc[p] == :requesting) ~> match?({:holding, _}, pc[p])
    end)
  end

  temporal :lock_eventually_released do
    Enum.all?(^processes, fn p ->
      match?({:holding, _}, pc[p]) ~> (pc[p] == :idle)
    end)
  end

  fairness(:strong, acquire_lock: [:p])
  fairness(:weak, release_lock: [:p], return_to_idle: [:p])
end
```

### Implementation with Conformance (Layers 1 + 3)

<!-- tla:skip reason=blocked by #284: validate! probes concrete_message/2 with an empty binding and a param'd mapping cannot answer it. Remove this skip when #284 lands -->
```elixir
defmodule MyApp.LockServer do
  use GenServer
  use TLA.GenServer,
    spec: Specs.DistributedLock,
    refinement: __MODULE__.Refinement

  defmodule Refinement do
    use TLA.Refinement

    def abstract(state) do
      %{
        owner:   Map.new(state.locks, fn {r, info} -> {r, info.holder || :none} end),
        waiting: Map.new(state.locks, fn {r, info} -> {r, MapSet.new(:queue.to_list(info.queue))} end),
        pc:      Map.new(state.process_states, fn {p, ps} -> {p, map_process_state(ps)} end)
      }
    end

    defp map_process_state(:idle), do: :idle
    defp map_process_state(:waiting), do: :requesting
    defp map_process_state({:locked, r}), do: {:holding, r}
    defp map_process_state(:unlocking), do: :releasing

    # The params matter: `check_step!/5` applies the named action WITH these
    # params and compares its post-state to the implementation's. They are fully
    # bound here because the message carries them; a mapping may leave a param
    # unbound when the implementation resolves the choice itself, and the check
    # then searches for a binding (05-layer3-conformance.md §TLA.GenServer.Runtime).
    def abstract_action({:lock, pid, resource}),
      do: {:request_lock, %{p: pid, r: resource}}
    def abstract_action({:unlock, pid, resource}),
      do: {:release_lock, %{p: pid, r: resource}}
    def abstract_action(_), do: :unmapped

    def concrete_message(:request_lock, %{p: p, r: r}), do: {:lock, p, r}
    def concrete_message(:release_lock, %{p: p, r: r}), do: {:unlock, p, r}
  end

  def init(resources) do
    locks = Map.new(resources, fn r -> {r, %{holder: nil, queue: :queue.new()}} end)
    {:ok, %{locks: locks, process_states: %{}}}
  end

  def handle_call({:lock, pid, resource}, _from, state) do
    lock_info = state.locks[resource]

    if lock_info.holder == nil do
      new_locks = Map.put(state.locks, resource, %{lock_info | holder: pid})
      new_ps = Map.put(state.process_states, pid, {:locked, resource})
      {:reply, :acquired, %{state | locks: new_locks, process_states: new_ps}}
    else
      new_queue = :queue.in(pid, lock_info.queue)
      new_locks = Map.put(state.locks, resource, %{lock_info | queue: new_queue})
      new_ps = Map.put(state.process_states, pid, :waiting)
      {:reply, :queued, %{state | locks: new_locks, process_states: new_ps}}
    end
  end

  def handle_call({:unlock, pid, resource}, _from, state) do
    lock_info = state.locks[resource]

    if lock_info.holder == pid do
      case :queue.out(lock_info.queue) do
        {{:value, next_pid}, rest} ->
          new_locks = Map.put(state.locks, resource, %{holder: next_pid, queue: rest})
          new_ps = state.process_states
            |> Map.put(pid, :idle)
            |> Map.put(next_pid, {:locked, resource})
          {:reply, :released, %{state | locks: new_locks, process_states: new_ps}}

        {:empty, _} ->
          new_locks = Map.put(state.locks, resource, %{holder: nil, queue: :queue.new()})
          new_ps = Map.put(state.process_states, pid, :idle)
          {:reply, :released, %{state | locks: new_locks, process_states: new_ps}}
      end
    else
      {:reply, {:error, :not_holder}, state}
    end
  end
end
```

> **This implementation does not refine the spec, and Layer 3 now says so.**
>
> `handle_call({:lock, …})` on a free lock goes straight to `{:locked, resource}` —
> abstractly, `pc[p] = {:holding, r}` — in one step. The spec's `request_lock` produces
> `pc[p] = :requesting` and requires a separate `acquire_lock`. So `check_step!/5`
> reports `:diverged` on the very first acquisition, with a diff on `pc` and `owner`.
>
> Both readings are defensible: either the spec should model the fast path, or the
> implementation should not collapse two abstract steps into one callback. Which to
> change is a design decision. The point is that **the earlier design could not see the
> question** — the invariants all hold in the implementation's post-state, so the old
> Layer 3 reported conformance.

### Tests (All Layers)

<!-- tla:skip reason=an ExUnit module, run by your suite rather than by this page -->
```elixir
defmodule MyApp.LockServerTest do
  use ExUnit.Case
  import TLA.Spec.Test

  # Layer 2: model check the spec
  test "lock spec satisfies mutual exclusion" do
    assert_spec Specs.DistributedLock, %{
      constants: %{
        processes: MapSet.new([:p1, :p2, :p3]),
        resources: MapSet.new([:r1, :r2])
      },
      symmetry: [:processes, :resources],   # 3! * 2! fewer states...
      verify_symmetry: true,                # ...and prove the declaration sound on this model
      check_liveness: false,
      strict_coverage: true
    }
  end

  test "lock spec satisfies no-starvation with fairness" do
    assert_spec Specs.DistributedLock, %{
      constants: %{processes: MapSet.new([:p1, :p2]), resources: MapSet.new([:r1])},
      check_liveness: true
    }
  end

  # Layer 3: simulation against the real server
  test "lock server conforms to spec under random workload" do
    result = TLA.Simulation.run(MyApp.LockServer, %{
      traces: 1000,
      max_steps: 50,
      constants: %{processes: MapSet.new([:p1, :p2, :p3]), resources: MapSet.new([:r1])},
      inject_failures: false,
      seed: 12345
    })

    assert result.status == :ok
    assert result.traces_run == 1000
  end

  # Layer 3: replay a counterexample from the checker against the real server
  test "counterexample reproduces against the implementation" do
    {result, _graph} = TLA.ModelChecker.explore(Specs.DistributedLock, %{
      constants: %{processes: MapSet.new([:p1, :p2]), resources: MapSet.new([:r1])}
    })

    if result.violation do
      replay = TLA.Replay.counterexample(MyApp.LockServer, result.violation)
      assert replay.status == :violation,
             "the spec permits a behavior the implementation does not — one is wrong"
    end
  end
end
```

---

## Example 2: Raft Leader Election (Simplified)

Modeling a distributed consensus protocol. This is the example that most exercises
state-dependent `params:`, because nearly every action begins "pick a message from the
network".

### Specification

<!-- tla:spec -->
```elixir
defmodule Specs.RaftElection do
  use TLA.Spec

  constant :servers
  constant :max_term

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
```

Two notes on this spec:

- `state` was renamed to `srv_state`. `state` is bound implicitly in Layer 1 blocks
  (`03-layer1-invariants.md`), and a spec variable that shadows a reserved binding is a
  compile-time error rather than a subtle capture.
- `^max_term` is a **model bound**, not part of Raft. The coverage report will show
  `timeout` becoming disabled once every server reaches it; that is the bound working,
  not a bug, and it is why `bounded_by` appears in `TLA.Coverage`.
- `eventually_elect_leader` is **violated** in this bounded model: a split vote at
  `^max_term` ends in the `term_bound_exhausted` terminal state with no leader. The
  counterexample is the bound, not Raft — the real protocol times out again. TLC's Raft
  spec has the same property only under a constraint. The test below checks safety
  exhaustively and asserts that the liveness counterexample ends in that terminal state,
  which is more useful than deleting a property the model refutes.
- Both of the notes above are here because the differential corpus put them here. At
  `servers = {s1, s2, s3}, max_term = 2` this model has 58,359 reachable states and a
  diameter of 19, TLC and ExTLA agree on both, and the two bugs the entry found — the
  missing term check and the unreachable terminal predicate — are recorded in
  `test/differential/raft_election/`.

### Tests

<!-- tla:skip reason=an ExUnit module, run by your suite rather than by this page -->
```elixir
defmodule Specs.RaftElectionTest do
  use ExUnit.Case
  import TLA.Spec.Test

  @constants %{servers: MapSet.new([:s1, :s2, :s3]), max_term: 2}

  test "election safety holds" do
    assert_spec Specs.RaftElection, %{
      constants: @constants,
      symmetry: [:servers],
      verify_symmetry: true,
      check_liveness: false,
      strict_coverage: true
    }
  end

  test "leader election is refuted by the term bound, and only by it" do
    result =
      TLA.ModelChecker.run(Specs.RaftElection, %{constants: @constants, check_liveness: true})

    assert result.status == :violation
    assert result.violation.type == :liveness
    assert result.violation.property == :eventually_elect_leader

    # The trace ends where the model bound stops it: every server at `max_term`
    # and no leader. What is left in `messages` is the undeliverable residue the
    # `term_bound_exhausted` terminal describes, not an empty network.
    last = List.last(result.violation.states)
    assert Enum.all?(last.current_term, fn {_s, t} -> t == 2 end)
    refute Enum.any?(last.srv_state, fn {_s, st} -> st == :leader end)
  end
end
```

---

## Example 3: Producer-Consumer with Bounded Buffer

A classic concurrency problem exercising every property type.

### Specification

<!-- tla:spec -->
```elixir
defmodule Specs.BoundedBuffer do
  use TLA.Spec

  constant :producers
  constant :consumers
  constant :buffer_size
  constant :max_items

  # TLA+'s `Item`, element for element; the bound is one short of `^max_items`
  # because the first item produced is numbered 0.
  variable :buffer, type: seq(%{producer: ^producers, seq: 0..(^max_items - 1)})
  variable :produced_count, type: 0..^max_items
  variable :consumed_count, type: 0..^max_items
  variable :producer_pc, type: [^producers ~> [:ready, :waiting, :producing]]
  variable :consumer_pc, type: [^consumers ~> [:ready, :waiting, :consuming]]

  init do
    buffer = seq()
    produced_count = 0
    consumed_count = 0
    producer_pc = for_each(^producers, fn _ -> :ready end)
    consumer_pc = for_each(^consumers, fn _ -> :ready end)
  end

  action :produce, params: [p: ^producers] do
    require producer_pc[p] == :ready
    require len(buffer) < ^buffer_size
    require produced_count < ^max_items

    buffer = append(buffer, %{producer: p, seq: produced_count})
    produced_count = produced_count + 1
    producer_pc = update(producer_pc, p, fn _ -> :producing end)
  end

  action :producer_done, params: [p: ^producers] do
    require producer_pc[p] == :producing
    producer_pc = update(producer_pc, p, fn _ -> :ready end)
  end

  action :producer_wait, params: [p: ^producers] do
    require producer_pc[p] == :ready
    require len(buffer) >= ^buffer_size
    producer_pc = update(producer_pc, p, fn _ -> :waiting end)
  end

  action :producer_wake, params: [p: ^producers] do
    require producer_pc[p] == :waiting
    require len(buffer) < ^buffer_size
    producer_pc = update(producer_pc, p, fn _ -> :ready end)
  end

  action :consume, params: [c: ^consumers] do
    require consumer_pc[c] == :ready
    require len(buffer) > 0

    buffer = tail(buffer)
    consumed_count = consumed_count + 1
    consumer_pc = update(consumer_pc, c, fn _ -> :consuming end)
  end

  action :consumer_done, params: [c: ^consumers] do
    require consumer_pc[c] == :consuming
    consumer_pc = update(consumer_pc, c, fn _ -> :ready end)
  end

  action :consumer_wait, params: [c: ^consumers] do
    require consumer_pc[c] == :ready
    require len(buffer) == 0
    consumer_pc = update(consumer_pc, c, fn _ -> :waiting end)
  end

  action :consumer_wake, params: [c: ^consumers] do
    require consumer_pc[c] == :waiting
    require len(buffer) > 0
    consumer_pc = update(consumer_pc, c, fn _ -> :ready end)
  end

  # ── Safety ──

  invariant :buffer_bounded do
    len(buffer) >= 0 and len(buffer) <= ^buffer_size
  end

  invariant :counts_consistent do
    consumed_count <= produced_count and
      produced_count - consumed_count == len(buffer)
  end

  invariant :no_over_consumption do
    consumed_count <= ^max_items
  end

  # Legitimate end state (`02-dsl-semantics.md` §5.3): everything produced and
  # consumed, producers idle, consumers parked. Without this the checker reports
  # a deadlock — and it would be right to, since the spec had not said this
  # state was intended. TLC does report one, which is what the corpus compares.
  terminal :all_items_consumed do
    produced_count == ^max_items and consumed_count == ^max_items and
      Enum.all?(^producers, fn p -> producer_pc[p] == :ready end) and
      Enum.all?(^consumers, fn c -> consumer_pc[c] == :waiting end)
  end

  # ── Liveness (Phase 2) ──

  temporal :producers_make_progress do
    always(eventually(produced_count > 0))
  end

  temporal :consumers_make_progress do
    (len(buffer) > 0) ~> (consumed_count > 0)
  end

  temporal :no_producer_starvation do
    Enum.all?(^producers, fn p ->
      (producer_pc[p] == :waiting) ~> (producer_pc[p] == :ready)
    end)
  end

  # The bound shows through here. Once `^max_items` have been produced the
  # buffer drains and every consumer parks in :waiting for good — correctly, in
  # the spec's own terms. A starvation-freedom property has to except that end
  # state, or it is refuted by the model bound rather than by the design.
  temporal :no_consumer_starvation do
    Enum.all?(^consumers, fn c ->
      (consumer_pc[c] == :waiting)
      ~> (consumer_pc[c] == :ready or produced_count == ^max_items)
    end)
  end

  fairness(:weak, [:produce, :consume, :producer_done, :consumer_done])
  fairness(:weak, producer_wake: [:p])
  fairness(:strong, consumer_wake: [:c])
end
```

### Test Suite

<!-- tla:skip reason=an ExUnit module, run by your suite rather than by this page -->
```elixir
defmodule Specs.BoundedBufferTest do
  use ExUnit.Case
  import TLA.Spec.Test

  describe "safety properties" do
    test "2 producers, 2 consumers, buffer size 3" do
      assert_spec Specs.BoundedBuffer, %{
        constants: %{
          producers: MapSet.new([:p1, :p2]),
          consumers: MapSet.new([:c1, :c2]),
          buffer_size: 3,
          max_items: 6
        },
        symmetry: [:producers, :consumers],
        check_liveness: false,
        strict_coverage: true
      }
    end

    @tag timeout: 120_000
    test "3 producers, 3 consumers, buffer size 2" do
      assert_spec Specs.BoundedBuffer, %{
        constants: %{
          producers: MapSet.new([:p1, :p2, :p3]),
          consumers: MapSet.new([:c1, :c2, :c3]),
          buffer_size: 2,
          max_items: 4
        },
        symmetry: [:producers, :consumers],   # 3! * 3! = 36x fewer states
        check_liveness: false
      }
    end
  end

  describe "liveness properties" do
    @tag timeout: 300_000
    test "no starvation with small model" do
      assert_spec Specs.BoundedBuffer, %{
        constants: %{
          producers: MapSet.new([:p1, :p2]),
          consumers: MapSet.new([:c1]),
          buffer_size: 2,
          max_items: 3
        },
        check_liveness: true
      }
    end
  end
end
```

---

## Example 4: All three layers, and a conformance bug

The minimal boilerplate for full verification on a counter — and a demonstration of
exactly what Layer 3's step check buys.

<!-- tla:spec -->
```elixir
# ── Layer 2: Specification ──
defmodule Specs.Counter do
  use TLA.Spec

  constant :max_val

  variable :count,  type: 0..^max_val
  variable :status, type: [:ready, :incrementing]

  init do
    count  = 0
    status = :ready
  end

  action :increment do
    require status == :ready
    require count < ^max_val

    count  = count + 1
    status = :incrementing
  end

  action :done do
    require status == :incrementing
    status = :ready
  end

  action :reset do
    require status == :ready
    count = 0
  end

  invariant :in_bounds do
    count >= 0 and count <= ^max_val
  end

  temporal :always_returns_to_ready do
    (status == :incrementing) ~> (status == :ready)
  end

  fairness :weak, [:done]
end

# ── Layers 1 + 3: Implementation with conformance ──
defmodule MyApp.Counter do
  use GenServer
  use TLA.GenServer,
    spec: Specs.Counter,
    refinement: __MODULE__.Refinement

  defmodule Refinement do
    use TLA.Refinement

    def abstract(%{value: v, status: s}), do: %{count: v, status: s}

    def abstract_action(:increment), do: {:increment, %{}}
    def abstract_action(:done),      do: {:done, %{}}
    def abstract_action(:reset),     do: {:reset, %{}}
    def abstract_action(_),          do: :unmapped

    def concrete_message(:increment, _), do: :increment
    def concrete_message(:done, _),      do: :done
    def concrete_message(:reset, _),     do: :reset
  end

  def init(max), do: {:ok, %{value: 0, status: :ready, max: max}}

  def handle_call(:increment, _from, %{status: :ready, value: v, max: m} = state)
      when v < m do
    # BUG: the spec's `increment` moves status to :incrementing. This stays
    # :ready, collapsing `increment` and `done` into one step.
    {:reply, v + 1, %{state | value: v + 1, status: :ready}}
  end

  def handle_call(:increment, _from, state) do
    {:reply, {:error, :cannot_increment}, state}
  end

  def handle_call(:done, _from, state) do
    {:reply, :ok, %{state | status: :ready}}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | value: 0}}
  end

  # `:get` maps to no action, so it must not move the abstract state.
  # `check_stuttering!/3` enforces that.
  def handle_call(:get, _from, state) do
    {:reply, state.value, state}
  end
end
```

The first `handle_call(:increment, …)` clause produces the abstract post-state
`%{count: 1, status: :ready}`. The spec's `increment` produces
`%{count: 1, status: :incrementing}`. So:

```
** (TLA.Conformance.Error) step diverged from spec

  module:  MyApp.Counter
  action:  increment  (params: %{})
  message: :increment

  pre:     %{count: 0, status: :ready}

              spec expected        implementation produced
  count       1                    1
  status      :incrementing        :ready                   <-- differs

  The action's guard held, so `increment` was enabled — but applying it to the
  pre-state does not yield the state the implementation reached.
```

Every invariant in this spec holds in the implementation's post-state — `in_bounds`
is satisfied by `count: 1` — so a Layer 3 that checked only invariants and action
properties would report conformance here. This is the bug class that step legality
exists to catch, and it is the ordinary case, not a corner one: an implementation that
takes a shortcut the design did not sanction.

<!-- tla:skip reason=an ExUnit module, run by your suite rather than by this page -->
```elixir
# ── Tests ──
defmodule MyApp.CounterTest do
  use ExUnit.Case
  import TLA.Spec.Test

  test "spec is correct" do
    assert_spec Specs.Counter, %{constants: %{max_val: 5}, check_liveness: true}
  end

  test "implementation conforms to spec" do
    result = TLA.Simulation.run(MyApp.Counter, %{
      traces: 500,
      max_steps: 20,
      constants: %{max_val: 10},
      seed: 42
    })

    # Fails until either the spec models the fast path or the implementation
    # stops collapsing two abstract steps into one callback.
    assert result.status == :ok
  end
end
```
