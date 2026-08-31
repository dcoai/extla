--------------------------- MODULE RaftElection ----------------------------
(***************************************************************************)
(* Simplified Raft leader election: `spec/07-examples.md` Example 2, as TLC *)
(* checks it.                                                              *)
(*                                                                         *)
(* The fourth corpus entry, and the first where nearly every action begins  *)
(* "pick a message from the network".  That is a param drawn from the       *)
(* PRE-STATE rather than from a constant, and it is a different way for     *)
(* successor generation to be wrong: the set a param ranges over changes    *)
(* from state to state, so a generator that read the post-state, or that    *)
(* filtered on the wrong bound param, would still produce plausible         *)
(* successors -- just not these ones.                                       *)
(*                                                                         *)
(* It is also the first entry that ends somewhere.  A split vote at MaxTerm *)
(* leaves every server at the bound with nothing deliverable left, and TLC  *)
(* calls that a deadlock.  It is the model bound, not a Raft deadlock, and  *)
(* `terminal` (02-dsl-semantics.md 5.3) is how the ExTLA side says so.      *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

\* The tags are model values rather than strings, for the reason the corpus
\* README gives: TLC compares strings strictly and raises rather than returning
\* FALSE, and a model value reads as what it translates to -- an Elixir atom.
CONSTANTS
  Servers, MaxTerm,
  follower, candidate, leader, none,
  requestVote, voteResponse

VARIABLES
  currentTerm,    \* currentTerm[s] is the term server s believes it is in
  votedFor,       \* votedFor[s] is who s voted for in that term, or none
  srvState,       \* srvState[s] is follower, candidate or leader
  votesGranted,   \* votesGranted[s] is the set of servers that voted for s
  messages        \* the network: a set, so nothing is ordered or reliable

vars == <<currentTerm, votedFor, srvState, votesGranted, messages>>

Terms == 0..MaxTerm

Quorum == Cardinality(Servers) \div 2 + 1

Message ==
  [type : {requestVote},  term : Terms, from : Servers, to : Servers]
  \cup
  [type : {voteResponse}, term : Terms, from : Servers, to : Servers,
   granted : BOOLEAN]

TypeOK ==
  /\ currentTerm \in [Servers -> Terms]
  /\ votedFor \in [Servers -> Servers \cup {none}]
  /\ srvState \in [Servers -> {follower, candidate, leader}]
  /\ votesGranted \in [Servers -> SUBSET Servers]
  /\ messages \subseteq Message

Init ==
  /\ currentTerm = [s \in Servers |-> 0]
  /\ votedFor = [s \in Servers |-> none]
  /\ srvState = [s \in Servers |-> follower]
  /\ votesGranted = [s \in Servers |-> {}]
  /\ messages = {}

(***************************************************************************)
(* MaxTerm is a MODEL BOUND, not part of Raft: the real protocol times out  *)
(* again.  The bound is what makes the state space finite, and what makes   *)
(* the liveness property below refutable.                                   *)
(***************************************************************************)
Timeout(s) ==
  /\ srvState[s] \in {follower, candidate}
  /\ currentTerm[s] < MaxTerm
  /\ LET newTerm == currentTerm[s] + 1
         voteRequests ==
           {[type |-> requestVote, term |-> newTerm, from |-> s, to |-> t] :
              t \in Servers \ {s}}
     IN /\ currentTerm' = [currentTerm EXCEPT ![s] = newTerm]
        /\ srvState' = [srvState EXCEPT ![s] = candidate]
        /\ votedFor' = [votedFor EXCEPT ![s] = s]
        /\ votesGranted' = [votesGranted EXCEPT ![s] = {s}]
        /\ messages' = messages \cup voteRequests

(***************************************************************************)
(* Every right-hand side reads the PRE-state, so `currentTerm[s]` in the    *)
(* srvState' line below is the OLD term even though currentTerm is being    *)
(* assigned in the same step.  That is TLA+'s reading, and 02's             *)
(* simultaneous-assignment rule is what makes the ExTLA block mean the same. *)
(***************************************************************************)
HandleRequestVote(s, msg) ==
  /\ msg.type = requestVote
  /\ msg.to = s
  /\ LET grant ==
           /\ msg.term >= currentTerm[s]
           /\ (votedFor[s] = none \/ votedFor[s] = msg.from)
         response ==
           [type |-> voteResponse, term |-> msg.term, from |-> s,
            to |-> msg.from, granted |-> grant]
     IN /\ currentTerm' = IF msg.term > currentTerm[s]
                            THEN [currentTerm EXCEPT ![s] = msg.term]
                            ELSE currentTerm
        /\ votedFor' = IF grant
                         THEN [votedFor EXCEPT ![s] = msg.from]
                         ELSE votedFor
        /\ srvState' = IF msg.term > currentTerm[s]
                         THEN [srvState EXCEPT ![s] = follower]
                         ELSE srvState
        /\ messages' = (messages \ {msg}) \cup {response}
  /\ UNCHANGED votesGranted

\* The term check is what makes ElectionSafety hold.  Without it a candidate
\* that timed out twice counts a vote granted in the EARLIER term towards its
\* current candidacy, and two servers reach `leader` in the same term.
HandleVoteResponse(s, msg) ==
  /\ msg.type = voteResponse
  /\ msg.to = s
  /\ msg.granted
  /\ msg.term = currentTerm[s]
  /\ srvState[s] = candidate
  /\ LET newVotes == votesGranted[s] \cup {msg.from}
     IN /\ votesGranted' = [votesGranted EXCEPT ![s] = newVotes]
        /\ messages' = messages \ {msg}
        /\ srvState' = IF Cardinality(newVotes) >= Quorum
                         THEN [srvState EXCEPT ![s] = leader]
                         ELSE srvState
  /\ UNCHANGED <<currentTerm, votedFor>>

\* A server that sees a higher term abandons whatever it was doing.  The
\* message stays in the network: seeing a term is not consuming the message.
StepDown(s, msg) ==
  /\ msg.to = s
  /\ msg.term > currentTerm[s]
  /\ currentTerm' = [currentTerm EXCEPT ![s] = msg.term]
  /\ srvState' = [srvState EXCEPT ![s] = follower]
  /\ votedFor' = [votedFor EXCEPT ![s] = none]
  /\ UNCHANGED <<votesGranted, messages>>

Next ==
  \E s \in Servers :
    \/ Timeout(s)
    \/ \E msg \in messages :
         \/ HandleRequestVote(s, msg)
         \/ HandleVoteResponse(s, msg)
         \/ StepDown(s, msg)

(***************************************************************************)
(* The fairness the ExTLA spec declares, conjunct for conjunct. All three  *)
(* are WHOLE-ACTION: the ExTLA side names these actions without a param    *)
(* list, which is `WF_vars(\E params : A(params))` and not one constraint  *)
(* per server (02-dsl-semantics.md 5.2). That is the weaker reading, and   *)
(* the right one here -- EventuallyElectLeader is about the cluster, not   *)
(* about a particular server.                                              *)
(*                                                                         *)
(* Timing out is STRONG where message handling is WEAK. Timeout(s) is      *)
(* disabled the moment s reaches MaxTerm and re-enabled by a step-down, so *)
(* it flickers; a message in the network stays deliverable until it is     *)
(* delivered.                                                              *)
(*                                                                         *)
(* StepDown has no fairness on either side. Nothing here needs a server to *)
(* notice a higher term, and giving it fairness would be assuming something*)
(* the ExTLA spec does not.                                                *)
(***************************************************************************)
Fairness ==
  /\ SF_vars(\E s \in Servers : Timeout(s))
  /\ WF_vars(\E s \in Servers :
               \E msg \in messages : HandleRequestVote(s, msg))
  /\ WF_vars(\E s \in Servers :
               \E msg \in messages : HandleVoteResponse(s, msg))

Spec == Init /\ [][Next]_vars /\ Fairness

(***************************************************************************)
(* Raft's fundamental safety property, and the one this model exists to     *)
(* check: at most one leader per term.                                      *)
(***************************************************************************)
ElectionSafety ==
  \A t \in Terms :
    Cardinality({s \in Servers : srvState[s] = leader /\ currentTerm[s] = t}) <= 1

VoteIntegrity ==
  \A s \in Servers : votedFor[s] = none \/ votedFor[s] \in Servers

LeaderHasQuorum ==
  \A s \in Servers :
    srvState[s] # leader \/ Cardinality(votesGranted[s]) >= Quorum

(***************************************************************************)
(* Liveness, and the one property in the corpus that must come back        *)
(* VIOLATED. A split vote at MaxTerm leaves every server at the bound, no  *)
(* candidate holding a quorum and nothing deliverable left, and the        *)
(* behaviour stutters there forever without a leader. That is the model    *)
(* bound refuting the property, not Raft -- and an oracle in which every   *)
(* temporal property holds could not tell a working liveness checker from  *)
(* one that answers "holds" to everything.                                 *)
(***************************************************************************)
EventuallyElectLeader ==
  <>(\E s \in Servers : srvState[s] = leader)
=============================================================================
