# Layer 1 — invariants on a running GenServer

Part 6 of 7 of the ExTLA tutorial. Previous: [Symmetry, and who is responsible for it](05-symmetry.md).

Everything so far has been about the specification. The implementation has not existed. Layer 1
is the smallest step towards it: state a property of a GenServer's state *in the GenServer*, and
have it checked after every callback.

<!-- tla:spec -->
```elixir
defmodule Tutorial.LockServer do
  use GenServer
  use TLA.Invariant

  invariant :holder_is_not_waiting do
    state.holder == nil or state.holder not in state.waiting
  end

  precondition {:release, c}, desc: "only the holder releases" do
    state.holder == c
  end

  postcondition {:acquire, c} do
    new.holder == c and c not in new.waiting
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts), do: {:ok, %{holder: nil, waiting: []}}

  @impl true
  def handle_call({:request, c}, _from, s), do: {:reply, :ok, %{s | waiting: s.waiting ++ [c]}}

  def handle_call({:acquire, c}, _from, %{holder: nil} = s),
    do: {:reply, :ok, %{s | holder: c, waiting: List.delete(s.waiting, c)}}

  def handle_call({:release, c}, _from, s),
    do: {:reply, :ok, %{s | holder: nil, waiting: List.delete(s.waiting, c)}}
end
```

The blocks are bare boolean expressions, the same shape as a spec's, with one difference: `state`
is written explicitly. A spec has `variable` declarations to resolve a bare name against, and an
arbitrary GenServer has none, so Layer 1 does not guess
([`03-layer1-invariants.md`](../../spec/03-layer1-invariants.md)). An `invariant` is checked after
every callback; a `precondition` is matched against the incoming message — its pattern binds `c` —
and checked before the callback runs; a `postcondition` sees `old`, `new` and the pattern's
bindings after it returns. `action_property` is there too, with `old` and `new`.

Used correctly, nothing is different:

<!-- tla:run expect=ok -->
```elixir
{:ok, pid} = Tutorial.LockServer.start_link()
:ok = GenServer.call(pid, {:request, :alice})
:ok = GenServer.call(pid, {:acquire, :alice})
:ok = GenServer.call(pid, {:release, :alice})
```

Used wrongly, the callback never runs. Bob releasing a lock Alice holds:

<!-- tla:run expect=raise match="only the holder releases" -->
```elixir
{:ok, pid} = Tutorial.LockServer.start_link()
:ok = GenServer.call(pid, {:request, :alice})
:ok = GenServer.call(pid, {:acquire, :alice})
GenServer.call(pid, {:release, :bob})
```

```
** (TLA.Invariant.Violation) ═══ PRECONDITION VIOLATED: handle_call ═════════════════════════════
  only the holder releases
  module: Tutorial.LockServer
  message: {:release, :bob}
  state:
    holder  = :alice
    waiting = []
```

The server raises, which in a supervised system means it restarts and the caller's `call` exits
with the violation as its reason. That is the `:enabled` mode. `:log_only` logs the same report and
lets the callback proceed, and `:disabled` — the default under `MIX_ENV=prod` — compiles the checks
out entirely: a module compiled `:disabled` is the module its author wrote, which is what "zero
production cost" means. The mode is `config :extla, mode: …`, read at compile time.

Layer 1 knows nothing about `Tutorial.Lock`. It checks the properties you wrote *about the
implementation*, in the implementation's own terms, which is useful and is also the limit of it:
`holder_is_not_waiting` could hold forever in a server that never lets anyone acquire. Relating the
code to the specification is Layer 3.

---

Next: [Layer 3 — does the implementation conform?](07-layer3.md).
