------------------------------ MODULE AuditLog ------------------------------
(***************************************************************************)
(* The smallest model in the corpus, and deliberately so.  It is not here   *)
(* to be an interesting system -- it is here to give an `action_property` a *)
(* TLC oracle, and to make ONE specific wrong answer detectable (#114).     *)
(*                                                                         *)
(* This is #112's reproduction, promoted into the corpus.  A log is         *)
(* appended to and then compacted, and `LogOnlyGrows` is refuted by the     *)
(* compaction.                                                             *)
(*                                                                         *)
(* What earns it a directory is the DECOY.  `Compact` empties the log, so   *)
(* its post-state IS the initial state -- reachable at depth 1 by a route   *)
(* that never touches the offending step.  A checker that builds an         *)
(* action-property counterexample by walking parent pointers back from the  *)
(* POST-state, which is what ExTLA did until #113, therefore hands back a   *)
(* one-state trace containing no violation at all; a correct one hands back *)
(* four states ending in `Compact`.  The LENGTHS differ, which is what      *)
(* D-9's comparison can see.  Without the decoy both answers are four and   *)
(* the test passes on the defect it was written to catch.                   *)
(*                                                                         *)
(* Every additional variable would break that mechanism, by making the      *)
(* post-state distinct from `Init`.  That is why this model is a line and   *)
(* not a system, and why it should stay one.                                *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANT MaxEntries

VARIABLE log

vars == <<log>>

\* Elements only.  The LENGTH bound is `BoundedLog` below rather than part of
\* this, so that TypeOK says exactly what the ExTLA side's `seq(1..MaxEntries)`
\* declaration says and no more: a corpus entry typing a variable more tightly
\* on one side than the other is a difference the comparison cannot see.
TypeOK == \A i \in 1..Len(log) : log[i] \in 1..MaxEntries

BoundedLog == Len(log) <= MaxEntries

Init == log = << >>

\* Not `Append`: that is the Sequences operator this module extends.
Record ==
  /\ Len(log) < MaxEntries
  /\ log' = Append(log, Len(log) + 1)

Compact ==
  /\ Len(log) = MaxEntries
  /\ log' = << >>

Next == Record \/ Compact

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* The action property, and the reason this entry exists.  `[][P]_vars` is  *)
(* what an ExTLA `action_property` is: a predicate over a STEP, which TLC   *)
(* checks as a PROPERTY rather than as an INVARIANT.  Unlike a temporal     *)
(* property, its counterexample is finite -- a prefix ending at the         *)
(* offending step -- so its length is a fixture the two checkers can be     *)
(* held to.                                                                 *)
(***************************************************************************)
LogOnlyGrows == [][Len(log') >= Len(log)]_vars
=============================================================================
