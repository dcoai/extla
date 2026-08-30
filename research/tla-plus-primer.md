# TLA+ — Temporal Logic of Actions

A comprehensive guide to TLA+, a formal specification language for designing, modeling, and verifying systems — especially concurrent and distributed systems.

---

## Table of Contents

1. [What is TLA+?](#what-is-tla)
2. [History and Philosophy](#history-and-philosophy)
3. [Core Concepts](#core-concepts)
4. [Module Structure](#module-structure)
5. [Types and Values](#types-and-values)
6. [Operators](#operators)
7. [Sets](#sets)
8. [Functions](#functions)
9. [Records, Tuples, and Sequences](#records-tuples-and-sequences)
10. [Logic and Quantifiers](#logic-and-quantifiers)
11. [Actions and State](#actions-and-state)
12. [Temporal Logic](#temporal-logic)
13. [Safety and Liveness Properties](#safety-and-liveness-properties)
14. [Fairness](#fairness)
15. [PlusCal](#pluscal)
16. [Standard Modules Reference](#standard-modules-reference)
17. [TLC Model Checker](#tlc-model-checker)
18. [TLAPS Proof System](#tlaps-proof-system)
19. [Tooling and IDE Support](#tooling-and-ide-support)
20. [Real-World Usage](#real-world-usage)
21. [Complete Example: Two-Phase Commit](#complete-example-two-phase-commit)
22. [Best Practices](#best-practices)
23. [Resources](#resources)

---

## What is TLA+?

TLA+ is a **formal specification language** created by Leslie Lamport (Turing Award winner, 2013). It allows engineers to describe system designs as mathematical formulas and then mechanically verify that those designs satisfy desired properties.

TLA+ is not a programming language — it does not produce executable code. Instead, it provides a rigorous way to:

- **Model** a system's behavior as a state machine
- **Specify** correctness properties (invariants, safety, liveness)
- **Verify** the design via model checking (exhaustive state exploration) or formal proof
- **Find bugs** before writing a single line of implementation code

TLA+ stands for **Temporal Logic of Actions**, reflecting its two mathematical foundations:
- **Temporal logic** — reasoning about how properties hold over time
- **Actions** — describing state transitions as boolean predicates relating current and next states

---

## History and Philosophy

### Timeline

| Year | Event |
|------|-------|
| 1977 | Lamport begins work on temporal logic for concurrent systems |
| 1990 | Lamport begins publishing papers on TLA |
| 1994 | "The Temporal Logic of Actions" formally published |
| 1999 | TLA+ specification language introduced |
| 2002 | *Specifying Systems* book published |
| 2009 | PlusCal algorithm language created |
| 2011 | Amazon Web Services begins using TLA+ |
| 2012 | TLAPS proof system released |
| 2014 | AWS publishes landmark paper on formal methods |
| 2024+ | VS Code extension, continued development by TLA+ Foundation |

### Philosophy

Lamport's core insight: **"The best language for writing specifications is mathematics."**

Key design principles:

1. **Mathematics over programming** — TLA+ uses set theory and first-order logic rather than programming language constructs. No built-in I/O, threads, memory models, or type systems.

2. **Processes, not functions** — Unlike functional programming theory which identifies computation with functions, TLA+ treats computation as processes evolving through states.

3. **No special concurrency constructs** — Concurrent systems emerge naturally from the mathematical formalism. Sequential, parallel, and distributed systems use the same notation.

4. **Composition through conjunction** — System components compose via logical AND (`/\`), not function composition. Combined behavior is the intersection of all constraints.

5. **Abstraction through mathematics** — Specifications remain concise because they describe *what* a system does, not *how* it does it.

---

## Core Concepts

### State Machines

Every TLA+ specification describes a **state machine**:

- A **state** is an assignment of values to all variables
- A **behavior** is an infinite sequence of states
- A **step** is a pair of successive states
- A **specification** defines the set of all valid behaviors

### The Specification Formula

A complete TLA+ specification takes this canonical form:

```tla
Spec == Init /\ [][Next]_vars /\ Fairness
```

Where:
- `Init` — A predicate describing valid initial states
- `[][Next]_vars` — In every step, either `Next` happens or all variables remain unchanged (stuttering)
- `Fairness` — Optional constraints preventing the system from stopping forever

### Stuttering

TLA+ allows **stuttering steps** — steps where no variables change. This is essential because:
- It models real-world system crashes and pauses
- It enables compositional reasoning (adding more components doesn't break existing specs)
- The notation `[Next]_vars` means `Next \/ UNCHANGED vars`

---

## Module Structure

Every TLA+ specification lives inside a module:

```tla
---- MODULE MySystem ----
\* This is a comment

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS NumNodes, MaxVal

VARIABLES state, messages, clock

vars == <<state, messages, clock>>

\* Operator definitions go here

Init == ...
Next == ...
Spec == Init /\ [][Next]_vars

====
```

### Key Structural Elements

| Element | Purpose |
|---------|---------|
| `---- MODULE Name ----` | Module header (four or more dashes) |
| `====` | Module footer (four or more equals) |
| `EXTENDS Module1, Module2` | Import operators from other modules |
| `INSTANCE M WITH x <- expr` | Import with substitution |
| `CONSTANTS C1, C2` | Declare constant parameters |
| `VARIABLES v1, v2` | Declare state variables |
| `ASSUME P` | State assumptions about constants |
| `THEOREM P` | Declare a theorem to be proved |
| `\* comment` | Line comment |
| `(* block comment *)` | Block comment |

---

## Types and Values

TLA+ is **untyped** — variables can hold any value. The "types" are mathematical sets:

| Value Type | Example | Notes |
|-----------|---------|-------|
| Boolean | `TRUE`, `FALSE` | |
| Integer | `0`, `-3`, `42` | |
| String | `"hello"` | Limited operations |
| Set | `{1, 2, 3}` | Fundamental data structure |
| Function | `[x \in S \|-> expr]` | Maps domain to range |
| Record | `[name \|-> "Alice", age \|-> 30]` | Special case of function |
| Tuple | `<<1, "a", TRUE>>` | Special case of function (domain 1..n) |
| Sequence | `<<3, 1, 4, 1, 5>>` | Same as tuple, with sequence operators |
| Model Value | Uninterpreted constants | Used during model checking |

---

## Operators

### Defining Operators

Operators are the TLA+ equivalent of functions/macros:

```tla
\* Zero-argument operator (named constant)
MaxRetries == 3

\* Parameterized operator
Max(a, b) == IF a > b THEN a ELSE b

\* Higher-order operator (takes operator as argument)
Apply(Op(_), x) == Op(x)

\* Recursive operator
Factorial[n \in Nat] == IF n = 0 THEN 1 ELSE n * Factorial[n - 1]

\* LET-IN for local definitions
ThreeMax(a, b, c) ==
  LET
    TwoMax(x, y) == IF x > y THEN x ELSE y
  IN
    TwoMax(TwoMax(a, b), c)
```

### Conditionals

```tla
\* IF-THEN-ELSE (always requires ELSE)
Abs(x) == IF x < 0 THEN -x ELSE x

\* CASE (pattern matching)
TypeName(v) ==
  CASE v \in BOOLEAN -> "boolean"
    [] v \in Int      -> "integer"
    [] v \in STRING   -> "string"
    [] OTHER          -> "unknown"
```

### CHOOSE

The `CHOOSE` operator deterministically selects an element satisfying a predicate:

```tla
\* Pick the minimum element of a set
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

\* Pick any element (useful for non-empty sets)
Pick(S) == CHOOSE x \in S : TRUE
```

**Warning:** `CHOOSE` is deterministic — it always returns the same value for the same inputs. It raises an error if no matching element exists.

---

## Sets

Sets are the fundamental data structure in TLA+.

### Construction

```tla
\* Enumeration
{1, 2, 3}

\* Range (integers)
1..10                          \* {1, 2, 3, ..., 10}

\* Set mapping (transform)
{x * x : x \in 1..4}          \* {1, 4, 9, 16}

\* Set filtering
{x \in 1..10 : x % 2 = 0}    \* {2, 4, 6, 8, 10}

\* Power set (all subsets)
SUBSET {1, 2}                  \* {{}, {1}, {2}, {1, 2}}

\* Cartesian product
{"a", "b"} \X {1, 2}          \* {<<"a",1>>, <<"a",2>>, <<"b",1>>, <<"b",2>>}

\* UNION (flatten set of sets)
UNION {{1,2}, {2,3}, {3,4}}   \* {1, 2, 3, 4}
```

### Operations

| Operator | ASCII | Meaning |
|----------|-------|---------|
| `x \in S` | | Membership |
| `x \notin S` | | Non-membership |
| `S \subseteq T` | | Subset or equal |
| `S \union T` | `S \cup T` | Union |
| `S \intersect T` | `S \cap T` | Intersection |
| `S \ T` | | Set difference |
| `SUBSET S` | | Power set |
| `UNION S` | | Distributed union |
| `Cardinality(S)` | | Size (requires `FiniteSets`) |
| `IsFiniteSet(S)` | | Finiteness test (requires `FiniteSets`) |

---

## Functions

In TLA+, a function maps every element of its **domain** to a value.

```tla
\* Function construction
square == [x \in 1..5 |-> x * x]

\* Function application
square[3]                      \* 9

\* Function domain
DOMAIN square                  \* {1, 2, 3, 4, 5}

\* Set of all functions from S to T
[S -> T]

\* Function update with EXCEPT
square2 == [square EXCEPT ![3] = 0]    \* square but with 3 |-> 0

\* Multiple updates
f2 == [f EXCEPT ![1] = 10, ![2] = 20]

\* Self-referencing update (@ = old value)
f3 == [f EXCEPT ![1] = @ + 1]         \* increment f[1]

\* Nested update (for functions of functions)
f4 == [f EXCEPT ![1][2] = @ + 1]
```

### Function Set

`[S -> T]` is the set of **all** functions mapping elements of S to elements of T:

```tla
\* All functions from {1,2} to {TRUE, FALSE}
[{1, 2} -> BOOLEAN]
\* Contains: [1 |-> TRUE, 2 |-> TRUE], [1 |-> TRUE, 2 |-> FALSE], etc.
```

---

## Records, Tuples, and Sequences

### Records

Records are functions whose domain is a set of strings:

```tla
\* Construction
person == [name |-> "Alice", age |-> 30]

\* Access (dot notation)
person.name                    \* "Alice"
person["name"]                 \* equivalent

\* Update
older == [person EXCEPT !.age = @ + 1]

\* Record set (all possible records)
PersonType == [name: STRING, age: Nat]
```

### Tuples

Tuples are functions with domain `1..n`:

```tla
\* Construction
point == <<3, 7>>

\* Access (1-indexed)
point[1]                       \* 3
point[2]                       \* 7
```

### Sequences

Sequences are tuples with additional operators from the `Sequences` module:

```tla
EXTENDS Sequences

\* Construction
seq == <<3, 1, 4, 1, 5>>

\* Core operators
Len(seq)                       \* 5
Head(seq)                      \* 3
Tail(seq)                      \* <<1, 4, 1, 5>>
Append(seq, 9)                 \* <<3, 1, 4, 1, 5, 9>>
seq1 \o seq2                   \* Concatenation
SubSeq(seq, 2, 4)              \* <<1, 4, 1>>
SelectSeq(seq, LAMBDA x: x > 2) \* <<3, 4, 5>>

\* The set of all sequences over S
Seq(S)                         \* Warning: infinite, not enumerable by TLC
```

---

## Logic and Quantifiers

### Boolean Operators

| Operator | ASCII | Meaning |
|----------|-------|---------|
| `/\` | `\land` | Conjunction (AND) |
| `\/` | `\lor` | Disjunction (OR) |
| `~` | `\lnot`, `\neg` | Negation (NOT) |
| `=>` | | Implication |
| `<=>` | `\equiv` | Equivalence (iff) |
| `TRUE` | | Boolean true |
| `FALSE` | | Boolean false |
| `BOOLEAN` | | The set `{TRUE, FALSE}` |

### Bullet Notation

For readability, TLA+ supports vertically aligned conjunction and disjunction lists:

```tla
\* These are equivalent:
A /\ B /\ C

/\ A
/\ B
/\ C
```

**Important:** Whitespace matters here. The bullets must be vertically aligned.

### Quantifiers

```tla
\* Universal: "for all x in S, P(x) holds"
\A x \in S : P(x)

\* Existential: "there exists x in S such that P(x)"
\E x \in S : P(x)

\* Unbounded (rarely used, not checkable by TLC)
\A x : P(x)
\E x : P(x)
```

---

## Actions and State

An **action** is a boolean expression that relates the current state to the next state using **primed variables**.

### Primed Variables

```tla
\* x  = value of x in the current state
\* x' = value of x in the NEXT state

\* A simple clock action
Tick ==
  IF hr = 12
  THEN hr' = 1
  ELSE hr' = hr + 1
```

### Defining State Transitions

```tla
VARIABLES counter, lock

vars == <<counter, lock>>

Init ==
  /\ counter = 0
  /\ lock = NULL

Increment ==
  /\ lock = NULL          \* precondition
  /\ lock' = "held"       \* acquire lock
  /\ counter' = counter + 1

Release ==
  /\ lock = "held"
  /\ lock' = NULL
  /\ UNCHANGED counter    \* counter stays the same

Next ==
  \/ Increment
  \/ Release
```

### UNCHANGED

When an action doesn't modify certain variables, you must explicitly say so:

```tla
\* Single variable
UNCHANGED counter

\* Multiple variables (tuple notation)
UNCHANGED <<x, y, z>>
```

### ENABLED

`ENABLED A` is true if action `A` can occur in the current state (there exists a next state satisfying `A`):

```tla
\* "It is possible to increment"
ENABLED Increment
```

---

## Temporal Logic

Temporal logic reasons about properties that hold across **entire behaviors** (infinite sequences of states), not just individual states.

### Temporal Operators

| Operator | Name | Meaning |
|----------|------|---------|
| `[]P` | Always (Box) | P is true in **every** state of every behavior |
| `<>P` | Eventually (Diamond) | P is true in **at least one** state of every behavior |
| `<>[]P` | Eventually Always | P eventually becomes true and **stays true forever** |
| `[]<>P` | Always Eventually | P is true **infinitely often** |
| `P ~> Q` | Leads-To | Whenever P is true, Q is eventually true later |

### Examples

```tla
\* "The system never deadlocks"
[]~Deadlocked

\* "Every request eventually gets a response"
\A r \in Requests : (r.sent) ~> (r.responded)

\* "The counter eventually reaches 10 and stays there"
<>[](counter = 10)

\* "The lock is always eventually released"
[]<>(lock = NULL)
```

### Combining Temporal Operators

```tla
\* "Every behavior satisfies at least one invariant"
[]P \/ []Q

\* "If P is always true, then Q is always true"
[]P => []Q

\* "If we can always eventually make progress, we will"
[]<>(ENABLED Next) => []<>(counter' > counter)
```

---

## Safety and Liveness Properties

### Safety Properties

"Bad things **don't** happen."

Safety properties assert that every reachable state (or transition) satisfies some condition.

#### Invariants

An invariant is a predicate that must be true in every reachable state:

```tla
\* Type invariant — variables stay within expected types
TypeInvariant ==
  /\ counter \in Nat
  /\ lock \in {NULL, "held"}
  /\ messages \subseteq [sender: Nodes, body: STRING]

\* Application invariant
NoOverdraft == balance >= 0

\* Mutual exclusion
MutualExclusion == Cardinality({p \in Processes : pc[p] = "critical"}) <= 1
```

#### Action Properties

Action properties constrain **transitions** rather than individual states:

```tla
\* Counter never decreases
CounterOnlyIncreases == [][counter' >= counter]_counter

\* Lock cannot be stolen
LockIntegrity == [][lock # NULL => lock' = NULL \/ lock' = lock]_lock
```

The `[][P]_x` notation means: in every step, either P holds or x is unchanged.

### Liveness Properties

"Good things **eventually** happen."

Liveness properties assert that something desirable eventually occurs:

```tla
\* All threads eventually terminate
Termination == <>(counter = NumThreads)

\* System eventually stabilizes
Stabilization == <>[](stable = TRUE)

\* Every request gets a response
RequestResponse == \A r \in Requests : (r.pending) ~> (r.done)

\* No starvation
NoStarvation == \A p \in Processes : []<>(pc[p] = "critical")
```

### Key Distinction

| Property | Type | Checks | Speed |
|----------|------|--------|-------|
| Invariant | Safety | Individual states | Fast |
| Action Property | Safety | State transitions | Fast |
| Temporal Property | Liveness | Entire behaviors | Slow |

---

## Fairness

Without fairness constraints, TLA+ permits infinite stuttering (the system halts forever). Fairness prevents trivially passing liveness checks by requiring that enabled actions eventually execute.

### Weak Fairness (WF)

**"If an action is continuously enabled, it must eventually happen."**

```tla
\* Notation
WF_vars(Action)

\* Meaning: if Action is EVENTUALLY ALWAYS enabled, it WILL happen
\* Formally: []<>~(ENABLED <Action>_vars) \/ []<><Action>_vars
```

In PlusCal: `fair process`

Use for actions where once enabled, they stay enabled until they execute (e.g., a process ready to run without contention).

### Strong Fairness (SF)

**"If an action is repeatedly enabled (even intermittently), it must eventually happen."**

```tla
\* Notation
SF_vars(Action)

\* Meaning: if Action is ALWAYS EVENTUALLY enabled, it WILL happen
\* Formally: <>[]~(ENABLED <Action>_vars) \/ []<><Action>_vars
```

In PlusCal: `fair+ process`

Use for actions that face intermittent obstacles (e.g., acquiring a contested lock, where the lock may repeatedly become available and unavailable).

### Example

```tla
\* Specification with weak fairness on Next
Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* Per-process fairness
Fairness ==
  /\ \A self \in Producers : WF_vars(Produce(self))
  /\ \A self \in Consumers : SF_vars(Consume(self))

Spec == Init /\ [][Next]_vars /\ Fairness
```

---

## PlusCal

PlusCal is a **pseudocode-like language** that compiles (transpiles) to TLA+. It was created by Lamport in 2009 to make specification more accessible to programmers.

### When to Use PlusCal vs. Raw TLA+

| PlusCal | Raw TLA+ |
|---------|----------|
| Algorithms with clear sequential flow | Complex temporal properties |
| Multi-process concurrent systems | Specifications requiring full TLA+ power |
| Familiar imperative style | Declarative mathematical style |
| Quick prototyping | Fine-grained control |

### Basic Structure

PlusCal is embedded inside a TLA+ module comment:

```tla
---- MODULE Counter ----
EXTENDS Naturals, TLC

(*--algorithm Counter
variables
  counter = 0;

begin
  Increment:
    counter := counter + 1;
  Check:
    assert counter = 1;
end algorithm; *)

\* BEGIN TRANSLATION  (auto-generated TLA+ appears here)
\* END TRANSLATION

====
```

### Variables

```pluscal
variables
  x = 0;                      \* Fixed initial value
  y \in {1, 2, 3};            \* Nondeterministic: TLC checks ALL values
  seq = <<1, 2, 3>>;
  mapping = [a |-> 1, b |-> 2];
```

### Labels (Atomicity Boundaries)

Labels define **atomic steps** — everything within a label executes as one state transition:

```pluscal
\* Everything inside a label is atomic
Step1:
  x := x + 1;
  y := y * 2;    \* this happens simultaneously with x update

Step2:
  z := x + y;    \* sees the updated x and y from Step1
```

Rules:
- Every statement must be inside a label
- Each variable can only be assigned once per label
- `while` and `goto` targets need labels

### Simultaneous Assignment

```pluscal
\* Swap x and y atomically
Swap:
  x := y || y := x;
```

### Control Structures

```pluscal
\* If-elsif-else
if condition then
  skip;
elsif condition2 then
  skip;
else
  skip;
end if;

\* While loop
Loop:
  while counter < 10 do
    counter := counter + 1;
  end while;

\* Nondeterministic choice (TLC explores ALL branches)
either
  x := 1;
or
  x := 2;
or
  x := 3;
end either;

\* Nondeterministic selection from a set
with val \in {1, 2, 3} do
  x := val;
end with;

\* Goto
  goto Loop;
```

### Processes (Concurrency)

```pluscal
(*--algorithm ConcurrentCounter
variables counter = 0;

fair process thread \in 1..3
variables local = 0;
begin
  Read:
    local := counter;
  Write:
    counter := local + 1;
end process;

end algorithm; *)
```

Each process gets its own `pc` (program counter). TLC explores **all interleavings**.

### Macros and Procedures

```pluscal
\* Macros (textual substitution, no labels allowed inside)
macro increment(var) begin
  var := var + 1;
end macro;

\* Procedures (can contain labels, have their own stack frame)
procedure Reset(target)
begin
  DoReset:
    target := 0;
    return;
end procedure;
```

### Key Statements

| Statement | Meaning |
|-----------|---------|
| `skip` | No operation |
| `assert expr` | Fail model check if false |
| `print expr` | Debug output |
| `await expr` | Block until condition is true |
| `goto Label` | Jump to label |
| `return` | Return from procedure |
| `call Proc(args)` | Call procedure |

---

## Standard Modules Reference

### Naturals

```tla
EXTENDS Naturals

Nat                  \* The set {0, 1, 2, ...} (not enumerable by TLC)
a..b                 \* Integer range set {a, a+1, ..., b}
+  -  *  ^           \* Arithmetic
a \div b             \* Floor division (10 \div 3 = 3)
a % b                \* Modulo
<  >  <=  >=         \* Comparison
```

### Integers

```tla
EXTENDS Integers

Int                  \* All integers (not enumerable by TLC)
-a                   \* Negation
\* Inherits all Naturals operators
```

### Sequences

```tla
EXTENDS Sequences

<<a, b, c>>          \* Sequence literal
Seq(S)               \* Set of all sequences over S (infinite)
Len(seq)             \* Length
Head(seq)            \* First element
Tail(seq)            \* All but first
Append(seq, e)       \* Add to end
seq1 \o seq2         \* Concatenation
SubSeq(seq, m, n)    \* Subsequence from index m to n
SelectSeq(seq, Test) \* Filter by predicate
```

### FiniteSets

```tla
EXTENDS FiniteSets

IsFiniteSet(S)       \* TRUE if S is finite
Cardinality(S)       \* Number of elements
```

### Bags (Multisets)

```tla
EXTENDS Bags

IsABag(f)            \* Test bag validity
BagToSet(bag)        \* Domain of bag
SetToBag(set)        \* Convert (each count = 1)
BagIn(e, bag)        \* Membership
EmptyBag             \* Empty bag (== <<>>)
bag1 (+) bag2        \* Bag addition
bag1 (-) bag2        \* Bag difference
BagUnion(set)        \* Union of bags
B1 \sqsubseteq B2    \* Subbag relation
SubBag(bag)          \* All subbags
BagOfAll(Op, bag)    \* Transform
BagCardinality(bag)  \* Total count
CopiesIn(e, bag)     \* Count of element
```

### TLC (Model Checker Utilities)

```tla
EXTENDS TLC

a :> b               \* Single-element function (a |-> b)
f1 @@ f2             \* Function merge (f1 takes priority)
Permutations(set)    \* All permutations
SortSeq(seq, Op)     \* Sort with comparator
ToString(val)        \* String conversion
Print(val, out)      \* Print and return `out`
PrintT(val)          \* Print and return TRUE
Assert(bool, msg)    \* Halt with msg if false
RandomElement(set)   \* Random selection
TLCEval(v)           \* Force TLC to evaluate and cache
TLCGet(key)          \* Retrieve TLC statistics/cache
TLCSet(key, val)     \* Store in TLC cache
JavaTime             \* Current epoch time (ms)
Any                  \* A value that equals any value
```

### Community Modules (tlaplus/CommunityModules)

Additional modules contributed by the community:
- **Json** — `ToJson`, `JsonSerialize`, `JsonDeserialize`
- **TLCExt** — `AssertEq`, `Trace`
- **Randomization** — `RandomSubset`, `RandomSetOfSubsets`
- **IOUtils** — File I/O operations
- **SequencesExt** — Additional sequence operators
- **Functions** — Additional function operators

---

## TLC Model Checker

TLC is the primary verification tool for TLA+. It performs **exhaustive state-space exploration** (model checking).

### How It Works

1. TLC starts from all states satisfying `Init`
2. For each reachable state, it applies `Next` to find all successor states
3. It checks invariants and properties at each state
4. If a violation is found, it produces a **counterexample trace** — the shortest path from an initial state to the violating state
5. If all states are explored without violation, the property is verified (for the given model)

### Running TLC

```bash
# Command line
java -jar tla2tools.jar -config MySpec.cfg MySpec.tla

# With multiple worker threads
java -jar tla2tools.jar -workers 8 MySpec.tla

# Distributed mode (for large state spaces)
java -jar tla2tools.jar -workers 8 -cloud MySpec.tla
```

### Model Configuration

A `.cfg` file (or Toolbox model) specifies:

```
SPECIFICATION Spec

\* Assign values to constants
CONSTANTS
  NumNodes = 3
  MaxVal = 5
  NULL = NULL   \* Model value

\* Properties to check
INVARIANTS
  TypeInvariant
  NoOverdraft

PROPERTIES
  Liveness
  NoStarvation

\* State constraint (limit state space)
CONSTRAINT
  counter < 100

\* Symmetry optimization
SYMMETRY
  Permutations(Nodes)
```

### State Space Explosion

The number of reachable states grows exponentially with:
- Number of variables
- Size of variable domains
- Number of concurrent processes

Mitigation strategies:
- Use small constant values for initial exploration
- Apply state constraints to bound exploration
- Use symmetry sets to reduce equivalent states
- Separate safety and liveness checking (liveness is much slower)

### Interpreting Results

When TLC finds a violation:
- It displays the **error trace**: a sequence of states leading to the violation
- Each state shows the values of all variables
- For liveness violations, it shows a **lasso-shaped** trace (a prefix + a cycle)

---

## TLAPS Proof System

The TLA+ Proof System (TLAPS) mechanically checks formal proofs written in TLA+. Unlike TLC (which checks finite models), TLAPS can verify properties for **all possible parameter values**.

### Proof Structure

```tla
THEOREM Spec => []Safety
  <1>1. Init => Safety
    BY DEF Init, Safety
  <1>2. Safety /\ [Next]_vars => Safety'
    <2>1. CASE Action1
      BY <2>1 DEF Safety, Action1
    <2>2. CASE Action2
      BY <2>2 DEF Safety, Action2
    <2>3. CASE UNCHANGED vars
      BY <2>3 DEF Safety, vars
    <2>4. QED
      BY <2>1, <2>2, <2>3 DEF Next
  <1>3. QED
    BY <1>1, <1>2, PTL DEF Spec
```

### Back-End Provers

TLAPS delegates proof obligations to:
- **Isabelle/TLA+** — General-purpose proof assistant
- **Zenon** — First-order logic automated prover
- **SMT solvers** — CVC3, Yices, Z3
- **TLAPS built-in** — Simple propositional and arithmetic

### TLC vs. TLAPS

| Feature | TLC | TLAPS |
|---------|-----|-------|
| Verification type | Model checking (finite) | Theorem proving (general) |
| Automation | Fully automatic | Requires human-written proofs |
| Scope | Specific parameter values | All parameter values |
| Speed | Fast for small models | Depends on proof complexity |
| Counterexamples | Yes (error traces) | No |

---

## Tooling and IDE Support

### TLA+ Toolbox (Eclipse-based)

The original IDE for TLA+. Currently unmaintained but still functional:
- Spec editor with syntax highlighting
- Model configuration GUI
- TLC integration with trace explorer
- PlusCal translator
- TLAPS integration

### VS Code Extension (Recommended)

The actively maintained IDE option:
- Syntax highlighting and snippets
- PlusCal translation
- TLC model checker integration
- Error highlighting and navigation
- Available in VS Code marketplace

### Command-Line Tools

```bash
# Requirements: Java 11+

# Download tla2tools.jar from GitHub releases
# https://github.com/tlaplus/tlaplus/releases

# Translate PlusCal to TLA+
java -cp tla2tools.jar pcal.trans MySpec.tla

# Run TLC model checker
java -jar tla2tools.jar MySpec.tla

# Run SANY (syntax checker)
java -cp tla2tools.jar tla2sany.SANY MySpec.tla
```

### Apalache (Alternative Model Checker)

An alternative to TLC that uses **symbolic model checking** via SMT solvers. Better for some types of specifications where TLC's explicit state enumeration is too expensive.

---

## Real-World Usage

### Amazon Web Services

Since 2011, AWS engineers have used TLA+ to verify critical distributed systems:

| System | Finding |
|--------|---------|
| **DynamoDB** | Found subtle replication bugs requiring 35-step traces |
| **S3** | Verified consistency protocols |
| **EBS** | Found bugs in volume replication |
| **Internal lock manager** | Verified distributed locking correctness |
| **Aurora** | Optimized commit protocol from 2 to 1.5 network round-trips |

From the landmark 2014 paper: *"Formal methods have been a big success at AWS. They have helped prevent subtle, serious bugs from reaching production — bugs that would not have been found via any other technique."*

### Other Industry Adopters

| Company | Use Case |
|---------|----------|
| **Microsoft** | Xbox 360 memory system, Azure Cosmos DB |
| **CrowdStrike** | Security infrastructure verification |
| **Intel** | Hardware verification |
| **Elastic** | Elasticsearch data replication |
| **MongoDB** | Replication protocol verification |
| **CockroachDB** | Distributed transaction protocol |

### What TLA+ Catches

TLA+ excels at finding bugs in:
- **Race conditions** — subtle interleavings of concurrent operations
- **Distributed consensus** — edge cases in Paxos, Raft, etc.
- **Data loss scenarios** — specific failure + recovery sequences
- **Protocol violations** — cases where invariants are broken under specific conditions
- **Performance optimization validation** — proving that optimized protocols maintain safety

---

## Complete Example: Two-Phase Commit

A realistic example showing a transaction coordinator and multiple resource managers:

```tla
---- MODULE TwoPhaseCommit ----
EXTENDS Naturals, FiniteSets

CONSTANTS RM              \* Set of resource managers

VARIABLES
  rmState,                \* rmState[r] = state of resource manager r
  tmState,                \* State of the transaction manager
  tmPrepared,             \* Set of RMs the TM has heard "Prepared" from
  msgs                    \* Set of messages in transit

vars == <<rmState, tmState, tmPrepared, msgs>>

Messages ==
  [type: {"Prepared"}, rm: RM]
  \union
  [type: {"Commit", "Abort"}]

\* --- Type Invariant ---
TypeOK ==
  /\ rmState \in [RM -> {"working", "prepared", "committed", "aborted"}]
  /\ tmState \in {"init", "committed", "aborted"}
  /\ tmPrepared \subseteq RM
  /\ msgs \subseteq Messages

\* --- Initial State ---
Init ==
  /\ rmState = [r \in RM |-> "working"]
  /\ tmState = "init"
  /\ tmPrepared = {}
  /\ msgs = {}

\* --- TM Actions ---

TMRcvPrepared(r) ==
  /\ tmState = "init"
  /\ [type |-> "Prepared", rm |-> r] \in msgs
  /\ tmPrepared' = tmPrepared \union {r}
  /\ UNCHANGED <<rmState, tmState, msgs>>

TMCommit ==
  /\ tmState = "init"
  /\ tmPrepared = RM               \* All RMs prepared
  /\ tmState' = "committed"
  /\ msgs' = msgs \union {[type |-> "Commit"]}
  /\ UNCHANGED <<rmState, tmPrepared>>

TMAbort ==
  /\ tmState = "init"
  /\ tmState' = "aborted"
  /\ msgs' = msgs \union {[type |-> "Abort"]}
  /\ UNCHANGED <<rmState, tmPrepared>>

\* --- RM Actions ---

RMPrepare(r) ==
  /\ rmState[r] = "working"
  /\ rmState' = [rmState EXCEPT ![r] = "prepared"]
  /\ msgs' = msgs \union {[type |-> "Prepared", rm |-> r]}
  /\ UNCHANGED <<tmState, tmPrepared>>

RMChooseToAbort(r) ==
  /\ rmState[r] = "working"
  /\ rmState' = [rmState EXCEPT ![r] = "aborted"]
  /\ UNCHANGED <<tmState, tmPrepared, msgs>>

RMRcvCommitMsg(r) ==
  /\ [type |-> "Commit"] \in msgs
  /\ rmState' = [rmState EXCEPT ![r] = "committed"]
  /\ UNCHANGED <<tmState, tmPrepared, msgs>>

RMRcvAbortMsg(r) ==
  /\ [type |-> "Abort"] \in msgs
  /\ rmState' = [rmState EXCEPT ![r] = "aborted"]
  /\ UNCHANGED <<tmState, tmPrepared, msgs>>

\* --- Next-State Relation ---
Next ==
  \/ TMCommit
  \/ TMAbort
  \/ \E r \in RM :
       \/ TMRcvPrepared(r)
       \/ RMPrepare(r)
       \/ RMChooseToAbort(r)
       \/ RMRcvCommitMsg(r)
       \/ RMRcvAbortMsg(r)

\* --- Safety Property ---
\* No RM commits while another aborts
Consistency ==
  \A r1, r2 \in RM :
    ~ /\ rmState[r1] = "committed"
      /\ rmState[r2] = "aborted"

\* --- Specification ---
Spec == Init /\ [][Next]_vars

THEOREM Spec => []TypeOK
THEOREM Spec => []Consistency

====
```

### Model Configuration for This Example

```
SPECIFICATION Spec

CONSTANTS
  RM = {r1, r2, r3}

INVARIANTS
  TypeOK
  Consistency
```

---

## Best Practices

### When to Use TLA+

- **Do use** for: distributed protocols, consensus algorithms, concurrent data structures, lock-free algorithms, database transaction logic, cache coherence protocols, workflow engines
- **Don't use** for: simple CRUD applications, UI logic, single-threaded algorithms with obvious correctness, performance optimization

### Specification Tips

1. **Start with the type invariant** — Define `TypeOK` first. It catches most trivial bugs immediately and documents your data model.

2. **Keep constants small** — Start with 2-3 processes, values up to 5. Only increase when small models pass.

3. **Separate safety and liveness models** — Use larger constants for safety (fast), smaller for liveness (slow).

4. **Use PlusCal for algorithms, raw TLA+ for protocols** — PlusCal is faster to write for sequential/concurrent algorithms. Raw TLA+ gives more control for abstract protocol specs.

5. **Model the environment** — Specify what failures can occur (message loss, crashes, reordering). Your spec is only as good as your failure model.

6. **Write action properties** — `[][P]_vars` catches transition-level bugs that state invariants miss.

7. **Iterate** — Start with a simple model, verify it, then add complexity. Don't try to model everything at once.

### Common Pitfalls

- **Forgetting UNCHANGED** — Every action must specify the next value of every variable (or explicitly mark it unchanged)
- **Non-determinism confusion** — `\in` in PlusCal variables means TLC checks ALL values, not a random one
- **State space explosion** — Adding one boolean variable doubles the state space; be conscious of model size
- **Symmetry with liveness** — Symmetry optimizations cannot be used when checking liveness properties
- **CHOOSE is deterministic** — It always returns the same element; it is not random selection

---

## Resources

### Official

- [TLA+ Home Page](https://lamport.azurewebsites.net/tla/tla.html) — Leslie Lamport's official site
- [TLA+ GitHub](https://github.com/tlaplus/tlaplus) — Source code and releases
- [TLA+ Examples](https://github.com/tlaplus/Examples) — Collection of specifications
- [TLA+ Video Course](https://lamport.azurewebsites.net/video/videos.html) — Lamport's video lectures

### Learning

- [Learn TLA+](https://learntla.com/) — Interactive tutorial site by Hillel Wayne
- [TLA+ in Practice and Theory](https://pron.github.io/posts/tlaplus_part1) — Excellent multi-part series by Ron Pressler
- [A Primer on Formal Verification and TLA+](https://jack-vanlightly.com/blog/2023/10/10/a-primer-on-formal-verification-and-tla) — Practical introduction

### Books

- *Specifying Systems* by Leslie Lamport (2002) — The definitive reference (free PDF available)
- *Practical TLA+* by Hillel Wayne (2018) — Hands-on guide for software engineers

### Papers

- [How Amazon Web Services Uses Formal Methods](https://lamport.azurewebsites.net/tla/formal-methods-amazon.pdf) — The landmark AWS paper
- [The Temporal Logic of Actions](https://lamport.azurewebsites.net/pubs/lamport-actions.pdf) — Lamport's foundational paper
- [TLA+ Proofs](https://lamport.azurewebsites.net/pubs/tlaps.pdf) — TLAPS proof system paper

### Community

- [TLA+ Community Modules](https://github.com/tlaplus/CommunityModules)
- [Awesome TLA+](https://github.com/tlaplus/awesome-tlaplus) — Curated resource list
- [TLA+ Google Group](https://groups.google.com/g/tlaplus)

---

*TLA+ enables you to find bugs in system designs before writing implementation code — saving potentially enormous debugging costs. As Lamport says: "If you're thinking without writing, you only think you're thinking."*
