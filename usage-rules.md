# Using ExTLA

ExTLA's DSL is written in Elixir syntax and **is not Elixir**. Inside `init`, `action`,
`invariant` and the other declarations, familiar constructs mean different things, and the
difference is the point: these blocks describe a *specification*, which a model checker
enumerates, not a program that runs.

Every rule below is enforced at compile time and names a diagnostic you will see if you
break it. The full table, keyed by the diagnostic's `kind`, is §7 of
[the DSL reference](spec/02-dsl-semantics.md), which is also the normative semantics.

## The nine things that look like Elixir and are not

### 1. Assignment is a next-state relation, not a rebinding

<!-- tla:skip reason=an action body on its own, not a compilable module -->
```elixir
action :transfer, params: [amount: 1..10] do
  require balance >= amount
  balance = balance - amount      # the NEXT state's balance
  log = append(log, amount)       # and the next state's log
end
```

A bare name on the right reads the **pre-state**; a name on the left names the **post-state**.
So `x = x + 1` is not a mutation, it is a relation between two states, and the order of the
assignments in the block does not matter. Assigning the same variable twice is
`:variable_assigned_twice` — not last-write-wins, because there is no "last" in a conjunction.

Outside `init` and `action`, assignment is `:assignment_outside_init_or_action`. Assigning a
name that no `variable` declares is `:assignment_to_undeclared_variable`.

### 2. `^name` is a constant, not a match pin

<!-- tla:skip reason=declarations shown on their own, not a compilable module -->
```elixir
constant :accounts
variable :balances, type: [^accounts ~> 0..100]

action :pay, params: [to: ^accounts] do
  require balances[to] < ^max_balance
end
```

`^` marks a **constant reference**. A bare name that happens to match a constant is
`:constant_without_pin` — the compiler refuses it rather than guessing, because a bare name
is how a variable is read.

### 3. `require` is an enabling condition, not `Kernel.SpecialForms.require/2`

<!-- tla:skip reason=an action body on its own, not a compilable module -->
```elixir
action :withdraw, params: [n: 1..5] do
  require balance >= n     # this action is DISABLED where this is false
  balance = balance - n
end
```

A false `require` does not raise and does not fail the check: the action is simply not
available in that state. An action that is never enabled anywhere is reported by the
coverage report, not by an error — which is why `mix extla.check` prints one.

### 4. Guards and `let`s evaluate in source order

<!-- tla:skip reason=an action body on its own, not a compilable module -->
```elixir
action :consume, params: [c: ^clients] do
  require Map.has_key?(inbox, c)   # guard FIRST
  let msg = inbox[c]               # then the lookup is safe
  inbox = delete(inbox, c)
end
```

Order decides between a **disabled action** and a **raised `ExTLA.Spec.DomainError`**. `f[x]`
outside the domain of `f` raises rather than answering `nil`, so a `let` that reads
before its guard has run turns a state the action should skip into a crash. Put the guard
above the read.

### 5. Reserved names

`:state`, `:old` and `:new` are the DSL's own bindings — `state` inside a Layer 1
`invariant`, `old` and `new` inside an `action_property`. Declaring a variable or constant
with one of those names is refused.

`:type_ok` is reserved: it is the implicit invariant compiled from your `type:` annotations,
and declaring it yourself is `:implicit_invariant_redeclared`.

### 6. Liveness is skipped under symmetry and `--workers`, and refused by the API

`mix extla.check` checks every `temporal` the spec declares, and skips liveness, with a
warning that names the reason, in three cases: `--safety-only`, a `symmetry:` in the spec's
configuration, and `--workers` above one. The safety properties are still checked.

<!-- tla:skip reason=shell invocations, not Elixir -->
```elixir
mix extla.check MySpec               # safety and liveness
mix extla.check MySpec --workers 8   # safety in parallel; warns that liveness was skipped
```

`ExTLA.ModelChecker.run/2` infers nothing: `check_liveness:` defaults to `false`, and
`check_liveness: true` together with `symmetry:` or `workers:` above one **raises**, because
neither combination gives a sound answer. Symmetry reduction merges states a temporal
property can tell apart, so the reduced graph can hold cycles the real one does not; and
under workers each process holds only part of the graph, so a cycle spanning two of them
cannot be found.

If you need both, run two checks: one with the reduction or the workers, one without.
`ExTLA.Spec.Test.assert_spec/2` passes its config straight to `run/2`, so a test that should
check a temporal property says `check_liveness: true`.

### 7. `mode` and `telemetry` are compile-time

<!-- tla:skip reason=config lines, not a spec; the modes are asserted by invariant_modes_test -->
```elixir
config :extla, mode: :disabled       # recompiles every module that uses ExTLA.Invariant
config :extla, telemetry: :verbose
```

Both are read with `Application.compile_env/2`, so changing either **recompiles your
modules**, not just ExTLA's. `mode: :disabled` emits no wrapper at all — the module compiles
as though the invariants were not there — which is what makes it free rather than cheap.

An `invariant :x, enabled: false` removes that one declaration at compile time. A module
whose invariants are all removed cannot be asserted about: `assert_invariants/2` raises
rather than passing for every state.

### 8. Choosing a task

| Task | When |
|---|---|
| `mix extla.check` | the usual one: explore the state space, check invariants, report coverage |
| `mix extla.explore` | evaluate your own expressions over a counterexample the checker produced |
| `mix extla.simulate` | drive a real GenServer against the spec and see whether it conforms |
| `mix extla.replay` | replay a counterexample against real code |
| `mix extla.visualize` | the state graph as DOT |
| `mix extla.stamp` | record which spec version a refinement mapping was read against |

### 9. The set vocabulary is in scope, and two operators are renamed

All of TLA+'s set theory is callable **unqualified** inside a spec block — `powerset`,
`cross`, `cross_many`, `distributed_union`, `for_all?`, `exists?`, `range`, `choose`,
`for_each`, `update`, `except`, `domain`, `function_set`, `record_set`, plus `union`,
`intersection`, `difference`, `subset?`, `member?`, `size` and the sequence operators. There
is nothing to import and nothing to qualify: `ExTLA.Set` and `ExTLA.Function` hold the one
implementation of each, and `ExTLA.Spec.Helpers`, which every spec imports, delegates to them.

**Two are renamed, and only two.** `{f(x) : x \in S}` is `set_map/2` and `{x \in S : P(x)}`
is `set_filter/2`, not `map/2` and `filter/2` — an unqualified `map(xs, f)` in a spec block
reads as `Enum.map/2` to every Elixir programmer, and these return a **set**, possibly a
smaller one, since a non-injective function collapses elements exactly as in TLA+.

**`for_each/2` takes a set, not a sequence.** `[x \in S |-> e]` ranges over a set. A list is
a *sequence* — a function on `1..Len(s)` already — and building a function over one would
silently deduplicate it, so it raises `ArgumentError` by name instead of answering. Pass a
`MapSet` or a range. For the same reason `domain/1` of a sequence is its **indices**,
`MapSet.new(1..Len(s))`, not its elements; `domain/1` of a set is refused, because a set is
neither a function nor a sequence.

## Writing a refinement mapping: a bare term is a call

`concrete_message/2` returns the message that causes an action, and a message does not
carry how it arrives. So the mapping says:

| Return | Delivered as | Handled by |
|---|---|---|
| `{:call, msg}` | `{:"$gen_call", from, msg}` | `handle_call/3` |
| `{:cast, msg}` | `{:"$gen_cast", msg}` | `handle_cast/2` |
| `{:info, msg}` | `msg` | `handle_info/2` |
| `msg` | a **call** | `handle_call/3` |

**A bare term is a call.** That is what it has always meant, so no existing mapping changes
— but it is the trap: map an action to `:process_next` when the server takes it in
`handle_cast/2`, and the message arrives at `handle_call/3`, which has no clause for it. The
server dies, and `mix extla.replay` reports `:not_followed` — "the spec permits a behaviour
the implementation does not take" — about a server that is correct. Write `{:cast,
:process_next}`.

The one ambiguity has a total escape: to send the literal two-tuple `{:cast, 5}` as a call,
write `{:call, {:cast, 5}}`.

A cast completes when a `:sys.get_state/2` behind it replies, which both drivers already
make, so this costs no extra round-trip. A cast that never completes is a named finding,
not a silent pass.

## Wiring it into a project

- **`use ExTLA.Invariant` goes directly after `use GenServer`, before the callbacks.** The
  order is load-bearing: only callbacks defined after it are wrapped, which is what keeps the
  defaults `use GenServer` injects unwrapped.
- **`use ExTLA.GenServer, spec: Specs.Counter, refinement: __MODULE__.Refinement`** puts a
  server under Layer 3: `spec:` is the specification it claims to refine, `refinement:` the
  module that maps its state and messages onto the spec's.
- **Configuration.** `config :extla, mode: :enabled | :log_only | :disabled` and
  `telemetry: :quiet | :verbose` are compile-time (§7 above). `config :extla, workers: n`
  is what `ExTLA.Config.workers/0` answers, and `trace_buffer: n` bounds the trace a Layer 3
  server records. Per spec, `config :extla, Specs.Counter, constants: %{max: 3}` assigns
  constants for `mix extla.check`, `mix extla.simulate` and Layer 3, and `symmetry:
  [:procs]` there turns on the reduction for `mix extla.check`.
- **`jason` is optional.** Add `{:jason, "~> 1.4"}` for `--format json` and for the saved
  counterexamples `mix extla.explore` and `mix extla.replay --trace` read.

## What a verdict does and does not say

`mix extla.check` exits **2** when the run was bounded — `max_states` was hit, or a
`state_constraint` held states back. That is not a pass. A bounded run has verified
*nothing* about the states it did not reach, and the exit code says so. `--allow-incomplete`
(`allow_incomplete: true` for `assert_spec/2`) turns it into a pass when you have decided a
partial answer is worth having.

Checking a recorded trace is different from model checking. Over a finite trace, a temporal
property can be `:inconclusive` rather than `:holds` or `:violated`: a prefix can refute
`always P` but cannot prove it. `ExTLA.Temporal` returns three verdicts for that reason, and
a lasso (a prefix plus a repeating cycle) is what lets every operator answer definitely.

## Writing specifications with an agent

The rules above are the ones an agent gets wrong, because each looks like ordinary Elixir
and compiles to something else. Two more that are worth stating outright:

- **Do not add `@spec` annotations to a spec module.** They are not checked and they drift; the DSL's `type:` annotations are the checked ones.
- **A specification that verifies is not a specification that is right.** The coverage report
  is where a spec that checks nothing announces itself — a never-enabled action, a vacuous
  `~>`, an invariant never at risk. Read it.
