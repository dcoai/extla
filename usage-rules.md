# Using ExTLA

ExTLA's DSL is written in Elixir syntax and **is not Elixir**. Inside `init`, `action`,
`invariant` and the other declarations, familiar constructs mean different things, and the
difference is the point: these blocks describe a *specification*, which a model checker
enumerates, not a program that runs.

Every rule below is enforced at compile time and names a diagnostic you will see if you
break it. The full table, keyed by kind, is
[`spec/02-dsl-semantics.md` §7](spec/02-dsl-semantics.md), which is also the normative
semantics. (This repository generates `DIAGNOSTICS.md` from the raise sites and holds §7's
table to it, but that golden is not part of the package — the specification is.)

## The eight things that look like Elixir and are not

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
`:duplicate_declaration` — not last-write-wins, because there is no "last" in a conjunction.

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
coverage report, not by an error — which is why `mix tla.check` prints one.

### 4. Guards and `let`s evaluate in source order

<!-- tla:skip reason=an action body on its own, not a compilable module -->
```elixir
action :consume, params: [c: ^clients] do
  require Map.has_key?(inbox, c)   # guard FIRST
  let msg = inbox[c]               # then the lookup is safe
  inbox = delete(inbox, c)
end
```

Order decides between a **disabled action** and a **raised `TLA.Spec.DomainError`**. `f[x]`
outside the domain of `f` raises (D-20) rather than answering `nil`, so a `let` that reads
before its guard has run turns a state the action should skip into a crash. Put the guard
above the read.

### 5. Reserved names

`:state`, `:old` and `:new` are the DSL's own bindings — `state` inside a Layer 1
`invariant`, `old` and `new` inside an `action_property`. Declaring a variable or constant
with one of those names is refused.

`:type_ok` is reserved: it is the implicit invariant compiled from your `type:` annotations,
and declaring it yourself is `:implicit_invariant_redeclared`.

### 6. Liveness is refused alongside symmetry and alongside `workers:`

<!-- tla:skip reason=shell invocations, not Elixir; the refusal they describe is asserted by parallel_test -->
```elixir
mix tla.check MySpec --workers 8           # fine
mix tla.check MySpec --workers 8 --check-liveness   # REFUSED, with the reason
```

Not weakened, not silently ignored — refused, because the combination is unsound. Symmetry
reduction collapses states that a temporal property may distinguish (D-22), and the liveness
edge table and ENABLED bits are per-struct maps, so under workers each process would hold a
fragment and a cycle spanning two of them would not exist to be found (D-27).

A refusal you can act on is the point. If you need both, run them as two checks.

### 7. `mode` and `telemetry` are compile-time

<!-- tla:skip reason=config lines, not a spec; the modes are asserted by invariant_modes_test -->
```elixir
config :extla, mode: :disabled       # recompiles every module that uses TLA.Invariant
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
| `mix tla.check` | the usual one: explore the state space, check invariants, report coverage |
| `mix tla.explore` | evaluate your own expressions over a counterexample the checker produced |
| `mix tla.simulate` | drive a real GenServer against the spec and see whether it conforms |
| `mix tla.replay` | replay a counterexample against real code |
| `mix tla.visualize` | the state graph as DOT |
| `mix tla.stamp` | record which spec version a refinement mapping was read against |

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
server dies, and `mix tla.replay` reports `:not_followed` — "the spec permits a behaviour
the implementation does not take" — about a server that is correct. Write `{:cast,
:process_next}`.

The one ambiguity has a total escape: to send the literal two-tuple `{:cast, 5}` as a call,
write `{:call, {:cast, 5}}`.

A cast completes when a `:sys.get_state/2` behind it replies, which both drivers already
make, so this costs no extra round-trip. A cast that never completes is a named finding,
not a silent pass (D-36).

> **Not yet delivered (#306).** The driver sends a call unconditionally today, so a mapping
> naming a cast is checked and not drivable. The contract above is decided; #306 implements
> it.

## What a verdict does and does not say

`mix tla.check` exits **2** when the run was bounded — `max_states` was hit, or a
`state_constraint` held states back. That is not a pass. A bounded run has verified
*nothing* about the states it did not reach, and the exit code says so; `allow_incomplete:
true` turns it into a pass when you have decided a partial answer is worth having (D-10).

A temporal property is `:inconclusive` rather than `:holds` where the run could not settle
it. Three verdicts, not two, and the third is the honest one (D-23).

## Writing specifications with an agent

The rules above are the ones an agent gets wrong, because each looks like ordinary Elixir
and compiles to something else. Two more that are worth stating outright:

- **Do not add `@spec` annotations to a spec module.** They are not checked and they drift
  (D-31); the DSL's `type:` annotations are the checked ones.
- **A specification that verifies is not a specification that is right.** The coverage report
  is where a spec that checks nothing announces itself — a never-enabled action, a vacuous
  `~>`, an invariant never at risk. Read it.
