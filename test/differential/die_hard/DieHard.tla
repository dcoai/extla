-------------------------------- MODULE DieHard --------------------------------
(***************************************************************************)
(* The jug problem from _Die Hard with a Vengeance_, as given in Lamport's *)
(* _Specifying Systems_.  Two jugs, one holding 3 gallons and one holding  *)
(* 5, and a fountain to fill from.  Measure out exactly 4 gallons.         *)
(*                                                                        *)
(* This is the first entry in the differential corpus because it is the    *)
(* smallest spec with all three of the properties the corpus compares: a   *)
(* small closed state space (16 distinct states), an invariant that holds  *)
(* (TypeOK), and an invariant that is violated at a known, checkable       *)
(* depth (NotSolved, at 7 states -- the 6-step solution).                  *)
(***************************************************************************)
EXTENDS Integers

VARIABLES small, big

TypeOK == /\ small \in 0..3
          /\ big   \in 0..5

Init == /\ small = 0
        /\ big   = 0

FillSmall  == /\ small' = 3
              /\ big'   = big

FillBig    == /\ big'   = 5
              /\ small' = small

EmptySmall == /\ small' = 0
              /\ big'   = big

EmptyBig   == /\ big'   = 0
              /\ small' = small

SmallToBig == LET poured == IF big + small > 5 THEN 5 - big ELSE small
              IN  /\ big'   = big + poured
                  /\ small' = small - poured

BigToSmall == LET poured == IF big + small > 3 THEN 3 - small ELSE big
              IN  /\ big'   = big - poured
                  /\ small' = small + poured

Next == \/ FillSmall
        \/ FillBig
        \/ EmptySmall
        \/ EmptyBig
        \/ SmallToBig
        \/ BigToSmall

Spec == Init /\ [][Next]_<<small, big>>

(***************************************************************************)
(* Refuted by design.  TLC's counterexample IS the solution to the puzzle,  *)
(* which is what makes the shortest-counterexample comparison meaningful    *)
(* here: any checker that reports a longer trace has not searched breadth-  *)
(* first, and any checker that reports no trace cannot find bugs at all.    *)
(***************************************************************************)
NotSolved == big /= 4
================================================================================
