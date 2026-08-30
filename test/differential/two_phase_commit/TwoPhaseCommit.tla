--------------------------- MODULE TwoPhaseCommit ---------------------------
(***************************************************************************)
(* The two-phase commit protocol, as in Lamport's TLA+ examples.  Resource *)
(* managers each prepare or spontaneously abort; a transaction manager     *)
(* commits once every one of them has prepared, and may abort until then.  *)
(*                                                                        *)
(* The second corpus entry, and the first with a CONSTANT.  Where die hard *)
(* pins the shortest counterexample, this one pins the state COUNT: the    *)
(* space grows quickly in |RM| and the invariant holds throughout, so a    *)
(* checker that quietly explores less of it still reports success.  That   *)
(* is the failure the distinct-state comparison exists to catch.           *)
(***************************************************************************)
EXTENDS Integers

CONSTANT RM

VARIABLES
  rmState,      \* rmState[rm] is the state of resource manager rm
  tmState,      \* the state of the transaction manager
  tmPrepared,   \* the set of RMs from which the TM has received Prepared
  msgs          \* messages in flight; a set, so they may be lost or reread

Message ==
  [type : {"Prepared"}, rm : RM] \cup [type : {"Commit", "Abort"}, rm : {"tm"}]

TPTypeOK ==
  /\ rmState \in [RM -> {"working", "prepared", "committed", "aborted"}]
  /\ tmState \in {"init", "done"}
  /\ tmPrepared \subseteq RM
  /\ msgs \subseteq Message

TPInit ==
  /\ rmState = [rm \in RM |-> "working"]
  /\ tmState = "init"
  /\ tmPrepared = {}
  /\ msgs = {}

TMRcvPrepared(rm) ==
  /\ tmState = "init"
  /\ [type |-> "Prepared", rm |-> rm] \in msgs
  /\ tmPrepared' = tmPrepared \cup {rm}
  /\ UNCHANGED <<rmState, tmState, msgs>>

TMCommit ==
  /\ tmState = "init"
  /\ tmPrepared = RM
  /\ tmState' = "done"
  /\ msgs' = msgs \cup {[type |-> "Commit", rm |-> "tm"]}
  /\ UNCHANGED <<rmState, tmPrepared>>

TMAbort ==
  /\ tmState = "init"
  /\ tmState' = "done"
  /\ msgs' = msgs \cup {[type |-> "Abort", rm |-> "tm"]}
  /\ UNCHANGED <<rmState, tmPrepared>>

RMPrepare(rm) ==
  /\ rmState[rm] = "working"
  /\ rmState' = [rmState EXCEPT ![rm] = "prepared"]
  /\ msgs' = msgs \cup {[type |-> "Prepared", rm |-> rm]}
  /\ UNCHANGED <<tmState, tmPrepared>>

RMChooseToAbort(rm) ==
  /\ rmState[rm] = "working"
  /\ rmState' = [rmState EXCEPT ![rm] = "aborted"]
  /\ UNCHANGED <<tmState, tmPrepared, msgs>>

RMRcvCommitMsg(rm) ==
  /\ [type |-> "Commit", rm |-> "tm"] \in msgs
  /\ rmState' = [rmState EXCEPT ![rm] = "committed"]
  /\ UNCHANGED <<tmState, tmPrepared, msgs>>

RMRcvAbortMsg(rm) ==
  /\ [type |-> "Abort", rm |-> "tm"] \in msgs
  /\ rmState' = [rmState EXCEPT ![rm] = "aborted"]
  /\ UNCHANGED <<tmState, tmPrepared, msgs>>

TPNext ==
  \/ TMCommit
  \/ TMAbort
  \/ \E rm \in RM :
       \/ TMRcvPrepared(rm)
       \/ RMPrepare(rm)
       \/ RMChooseToAbort(rm)
       \/ RMRcvCommitMsg(rm)
       \/ RMRcvAbortMsg(rm)

TPSpec == TPInit /\ [][TPNext]_<<rmState, tmState, tmPrepared, msgs>>

(***************************************************************************)
(* The point of the protocol: no resource manager commits while another    *)
(* has aborted.  Holds, so the state count is the whole comparison.        *)
(***************************************************************************)
TPConsistent ==
  \A rm1, rm2 \in RM :
    ~ /\ rmState[rm1] = "aborted"
      /\ rmState[rm2] = "committed"
=============================================================================
