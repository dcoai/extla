--------------------------- MODULE DistributedLock --------------------------
(***************************************************************************)
(* The distributed lock of spec/07-examples.md Example 1, as TLC checks it. *)
(*                                                                        *)
(* The third corpus entry, and the first with TWO constants and a          *)
(* structured value in state (`<<holding, r>>`).  Both matter: the       *)
(* product of two param sets is where successor generation gets a chance   *)
(* to be wrong in a way one set cannot expose, and a tuple in state is     *)
(* where a fingerprint that flattened structure would stop distinguishing  *)
(* states.                                                                 *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

\* The control-state tags are model values rather than strings. TLC raises on
\* `"idle" = <<holding, r>>` -- it compares strings strictly -- while a model
\* value is simply unequal to anything it is not. They also read as what they
\* translate to: Elixir atoms.
CONSTANTS Procs, Resources, idle, requesting, releasing, holding, none

VARIABLES
  owner,     \* owner[r] is the process holding r, or "none"
  waiting,   \* waiting[r] is the set of processes queued for r
  pc         \* pc[p] is the control state of process p

PcStates == {idle, requesting, releasing} \cup ({holding} \X Resources)

TypeOK ==
  /\ owner \in [Resources -> Procs \cup {none}]
  /\ waiting \in [Resources -> SUBSET Procs]
  /\ pc \in [Procs -> PcStates]

Init ==
  /\ owner = [r \in Resources |-> none]
  /\ waiting = [r \in Resources |-> {}]
  /\ pc = [p \in Procs |-> idle]

RequestLock(p, r) ==
  /\ pc[p] = idle
  /\ waiting' = [waiting EXCEPT ![r] = @ \cup {p}]
  /\ pc' = [pc EXCEPT ![p] = requesting]
  /\ UNCHANGED owner

AcquireLock(p, r) ==
  /\ pc[p] = requesting
  /\ owner[r] = none
  /\ p \in waiting[r]
  /\ owner' = [owner EXCEPT ![r] = p]
  /\ waiting' = [waiting EXCEPT ![r] = @ \ {p}]
  /\ pc' = [pc EXCEPT ![p] = <<holding, r>>]

ReleaseLock(p, r) ==
  /\ pc[p] = <<holding, r>>
  /\ owner[r] = p
  /\ owner' = [owner EXCEPT ![r] = none]
  /\ pc' = [pc EXCEPT ![p] = releasing]
  /\ UNCHANGED waiting

ReturnToIdle(p) ==
  /\ pc[p] = releasing
  /\ pc' = [pc EXCEPT ![p] = idle]
  /\ UNCHANGED <<owner, waiting>>

Next ==
  \E p \in Procs :
    \/ ReturnToIdle(p)
    \/ \E r \in Resources :
         \/ RequestLock(p, r)
         \/ AcquireLock(p, r)
         \/ ReleaseLock(p, r)

Spec == Init /\ [][Next]_<<owner, waiting, pc>>

(***************************************************************************)
(* Stated over `pc`, which is per PROCESS, so two processes can in         *)
(* principle both be <<holding, r>> — that is what gives the invariant   *)
(* content.  Counting processes equal to owner[r], a single-valued field,  *)
(* can never exceed one and would be a tautology of the model's type.      *)
(***************************************************************************)
MutualExclusion ==
  \A r \in Resources : Cardinality({p \in Procs : pc[p] = <<holding, r>>}) <= 1

OwnerIsValid ==
  \A r \in Resources : owner[r] = none \/ owner[r] \in Procs

HoldingMeansOwner ==
  \A p \in Procs :
    \A r \in Resources : pc[p] = <<holding, r>> => owner[r] = p
=============================================================================
