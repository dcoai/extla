------------------------------- MODULE Paxos --------------------------------
(***************************************************************************)
(* Paxos, after Lamport's TLA+ specification of the algorithm in *Paxos     *)
(* Made Simple*: the consensus half, without the leader election that makes *)
(* it terminate.                                                           *)
(*                                                                         *)
(* The sixth and last corpus entry, and the one that ends the D-9           *)
(* acceptance gate.  What it adds over the other five is a guard that       *)
(* quantifies over a SUBSET of the messages in flight -- "some set of       *)
(* promises covering a quorum" -- so enabling an action means searching a   *)
(* powerset of a state-dependent set rather than testing a field.  An       *)
(* enabling check that is subtly too permissive shows up nowhere except in  *)
(* the state count, which is what this entry measures.                     *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

\* Model values rather than strings, per the corpus README: TLC compares
\* strings strictly, and a model value reads as the atom it translates to.
CONSTANTS
  Acceptors, Values, Quorums, MaxBallot,
  phase1a, phase1b, phase2a, phase2b, none

Ballots == 0..MaxBallot

\* Any two quorums intersect.  That is the whole reason Paxos is safe, and
\* stating it here means a .cfg that gets it wrong fails loudly.
ASSUME QuorumAssumption ==
  /\ Quorums \subseteq SUBSET Acceptors
  /\ \A Q1, Q2 \in Quorums : Q1 \cap Q2 # {}

VARIABLES
  maxBal,    \* maxBal[a] is the highest ballot a has promised to, or -1
  maxVBal,   \* maxVBal[a] is the ballot of a's latest acceptance, or -1
  maxVal,    \* maxVal[a] is the value a accepted at maxVBal, or none
  msgs       \* the network: a set, so nothing is ordered, lost or consumed

vars == <<maxBal, maxVBal, maxVal, msgs>>

Message ==
       [type : {phase1a}, bal : Ballots]
  \cup [type : {phase1b}, acc : Acceptors, bal : Ballots,
        mbal : Ballots \cup {-1}, mval : Values \cup {none}]
  \cup [type : {phase2a}, bal : Ballots, val : Values]
  \cup [type : {phase2b}, acc : Acceptors, bal : Ballots, val : Values]

TypeOK ==
  /\ maxBal \in [Acceptors -> Ballots \cup {-1}]
  /\ maxVBal \in [Acceptors -> Ballots \cup {-1}]
  /\ maxVal \in [Acceptors -> Values \cup {none}]
  /\ msgs \subseteq Message

Init ==
  /\ maxBal = [a \in Acceptors |-> -1]
  /\ maxVBal = [a \in Acceptors |-> -1]
  /\ maxVal = [a \in Acceptors |-> none]
  /\ msgs = {}

\* Nothing ever leaves `msgs`.  A message that has been read is still there to
\* be read again, which is how the model says the network may duplicate and
\* reorder, and why no action here is "receive".
Send(m) == msgs' = msgs \cup {m}

Phase1a(b) ==
  /\ Send([type |-> phase1a, bal |-> b])
  /\ UNCHANGED <<maxBal, maxVBal, maxVal>>

Phase1b(a, m) ==
  /\ m.type = phase1a
  /\ m.bal > maxBal[a]
  /\ maxBal' = [maxBal EXCEPT ![a] = m.bal]
  /\ Send([type |-> phase1b, acc |-> a, bal |-> m.bal,
           mbal |-> maxVBal[a], mval |-> maxVal[a]])
  /\ UNCHANGED <<maxVBal, maxVal>>

(***************************************************************************)
(* The heart of the algorithm.  A value may be proposed at ballot b if some *)
(* set of phase-1b messages covering a quorum either reports no acceptance  *)
(* at all, or reports one at some highest ballot c whose value is v.  The   *)
(* proposer is not free to pick: if anyone might already have chosen, it    *)
(* must propose what they had.                                              *)
(***************************************************************************)
Phase2a(b, v) ==
  /\ ~\E m \in msgs : m.type = phase2a /\ m.bal = b
  /\ \E Q \in Quorums :
       \E S \in SUBSET {m \in msgs : m.type = phase1b /\ m.bal = b} :
         /\ \A a \in Q : \E m \in S : m.acc = a
         /\ \/ \A m \in S : m.mbal = -1
            \/ \E c \in 0..(b - 1) :
                 /\ \A m \in S : m.mbal =< c
                 /\ \E m \in S : m.mbal = c /\ m.mval = v
  /\ Send([type |-> phase2a, bal |-> b, val |-> v])
  /\ UNCHANGED <<maxBal, maxVBal, maxVal>>

Phase2b(a, m) ==
  /\ m.type = phase2a
  /\ m.bal >= maxBal[a]
  /\ maxBal' = [maxBal EXCEPT ![a] = m.bal]
  /\ maxVBal' = [maxVBal EXCEPT ![a] = m.bal]
  /\ maxVal' = [maxVal EXCEPT ![a] = m.val]
  /\ Send([type |-> phase2b, acc |-> a, bal |-> m.bal, val |-> m.val])

Next ==
  \/ \E b \in Ballots :
       \/ Phase1a(b)
       \/ \E v \in Values : Phase2a(b, v)
  \/ \E a \in Acceptors :
       \E m \in msgs :
         \/ Phase1b(a, m)
         \/ Phase2b(a, m)

Spec == Init /\ [][Next]_vars

VotedFor(a, b, v) ==
  [type |-> phase2b, acc |-> a, bal |-> b, val |-> v] \in msgs

ChosenAt(b, v) == \E Q \in Quorums : \A a \in Q : VotedFor(a, b, v)

Chosen == {v \in Values : \E b \in Ballots : ChosenAt(b, v)}

(***************************************************************************)
(* The point of the algorithm: at most one value is ever chosen.  It holds, *)
(* so the state count carries the whole comparison.                         *)
(***************************************************************************)
Consistency == Cardinality(Chosen) =< 1

\* Nothing is accepted that was not proposed at that ballot, which is what
\* makes Consistency an argument about proposals rather than about votes.
AcceptedWasProposed ==
  \A m \in msgs :
    m.type = phase2b =>
      \E p \in msgs : p.type = phase2a /\ p.bal = m.bal /\ p.val = m.val
=============================================================================
