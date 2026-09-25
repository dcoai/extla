----------------------------- MODULE SetVocabulary -----------------------------
(***************************************************************************)
(* A quorum acknowledgement, written for one purpose: to use the set-      *)
(* theoretic vocabulary 01-foundation.md specifies, so that the ExTLA side *)
(* exercises it the way a spec author would -- unqualified, in an action   *)
(* body -- and TLC says whether the two agree about what it means.         *)
(*                                                                        *)
(* Every operator here is one #319 made reachable from a spec body, or one *)
(* whose two implementations #318 found disagreeing:                       *)
(*                                                                        *)
(*   SUBSET S     powerset/1        \E x \in S   exists?/2                 *)
(*   \A x \in S   for_all?/2        S \cup T     union/2                   *)
(*   S \subseteq T  subset?/2       Cardinality  size/1                    *)
(*   [x \in S |-> e]  for_each/2    [f EXCEPT ![k] = v]  update/3          *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANT Nodes

VARIABLES acked, votes, committed

Quorum(s) == Cardinality(s) * 2 > Cardinality(Nodes)

TypeOK == /\ acked \subseteq Nodes
          /\ votes \in [Nodes -> 0..1]
          /\ committed \in BOOLEAN

Init == /\ acked = {}
        /\ votes = [n \in Nodes |-> 0]
        /\ committed = FALSE

Ack(n) == /\ n \notin acked
          /\ acked' = acked \cup {n}
          /\ votes' = [votes EXCEPT ![n] = 1]
          /\ UNCHANGED committed

(***************************************************************************)
(* The guard quantifies over a SUBSET of the nodes rather than testing      *)
(* Cardinality(acked) directly.  The two are equivalent, which is the       *)
(* point: the equivalent form is the one that exercises SUBSET and \E, and  *)
(* the invariant below states the cardinality form, so the two must agree.  *)
(*                                                                         *)
(* Commit is NOT guarded on ~committed.  A repeated Commit is a self-loop   *)
(* rather than a new state, and it keeps the final state from being a       *)
(* deadlock -- which this entry is not about.                               *)
(***************************************************************************)
Commit == /\ \E q \in SUBSET Nodes : Quorum(q) /\ q \subseteq acked
          /\ committed' = TRUE
          /\ UNCHANGED <<acked, votes>>

Next == \/ \E n \in Nodes : Ack(n)
        \/ Commit

Spec == Init /\ [][Next]_<<acked, votes, committed>>

CommittedNeedsQuorum == committed => Quorum(acked)

VotesMatchAcks == \A n \in Nodes : (n \in acked) <=> (votes[n] = 1)
================================================================================
