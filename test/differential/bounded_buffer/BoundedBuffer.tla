--------------------------- MODULE BoundedBuffer ---------------------------
(***************************************************************************)
(* Producers and consumers over a bounded buffer: `spec/07-examples.md`     *)
(* Example 3, as TLC checks it.                                            *)
(*                                                                         *)
(* The fifth corpus entry, and the first with a SEQUENCE in state.  Order   *)
(* matters in a sequence and does not in a set, so a fingerprint that       *)
(* canonicalised a list the way it canonicalises a set would collapse       *)
(* states that differ only in what is at the head -- and the state count is *)
(* where that shows up.                                                    *)
(*                                                                         *)
(* It also ends on purpose: once MaxItems have been produced and drained,   *)
(* every consumer parks in `waiting` and every producer sits `ready` with   *)
(* nothing left to produce.  TLC calls that a deadlock; `terminal`          *)
(* (02-dsl-semantics.md 5.3) is how the ExTLA side says it was intended.    *)
(***************************************************************************)
EXTENDS Integers, Sequences

CONSTANTS
  Producers, Consumers, BufferSize, MaxItems,
  ready, waiting, producing, consuming

VARIABLES
  buffer,          \* the buffer, oldest item first
  producedCount,   \* how many items have been produced in total
  consumedCount,   \* how many have been taken off the buffer
  producerPc,      \* producerPc[p] is the control state of producer p
  consumerPc       \* consumerPc[c] is the control state of consumer c

vars == <<buffer, producedCount, consumedCount, producerPc, consumerPc>>

Item == [producer : Producers, seq : 0..(MaxItems - 1)]

\* Spelled out rather than `buffer \in Seq(Item)`: Seq(S) is infinite, and the
\* bound that makes this finite is BufferSize, which is stated here.
TypeOK ==
  /\ Len(buffer) \in 0..BufferSize
  /\ \A i \in 1..Len(buffer) : buffer[i] \in Item
  /\ producedCount \in 0..MaxItems
  /\ consumedCount \in 0..MaxItems
  /\ producerPc \in [Producers -> {ready, waiting, producing}]
  /\ consumerPc \in [Consumers -> {ready, waiting, consuming}]

Init ==
  /\ buffer = << >>
  /\ producedCount = 0
  /\ consumedCount = 0
  /\ producerPc = [p \in Producers |-> ready]
  /\ consumerPc = [c \in Consumers |-> ready]

Produce(p) ==
  /\ producerPc[p] = ready
  /\ Len(buffer) < BufferSize
  /\ producedCount < MaxItems
  /\ buffer' = Append(buffer, [producer |-> p, seq |-> producedCount])
  /\ producedCount' = producedCount + 1
  /\ producerPc' = [producerPc EXCEPT ![p] = producing]
  /\ UNCHANGED <<consumedCount, consumerPc>>

ProducerDone(p) ==
  /\ producerPc[p] = producing
  /\ producerPc' = [producerPc EXCEPT ![p] = ready]
  /\ UNCHANGED <<buffer, producedCount, consumedCount, consumerPc>>

ProducerWait(p) ==
  /\ producerPc[p] = ready
  /\ Len(buffer) >= BufferSize
  /\ producerPc' = [producerPc EXCEPT ![p] = waiting]
  /\ UNCHANGED <<buffer, producedCount, consumedCount, consumerPc>>

ProducerWake(p) ==
  /\ producerPc[p] = waiting
  /\ Len(buffer) < BufferSize
  /\ producerPc' = [producerPc EXCEPT ![p] = ready]
  /\ UNCHANGED <<buffer, producedCount, consumedCount, consumerPc>>

Consume(c) ==
  /\ consumerPc[c] = ready
  /\ Len(buffer) > 0
  /\ buffer' = Tail(buffer)
  /\ consumedCount' = consumedCount + 1
  /\ consumerPc' = [consumerPc EXCEPT ![c] = consuming]
  /\ UNCHANGED <<producedCount, producerPc>>

ConsumerDone(c) ==
  /\ consumerPc[c] = consuming
  /\ consumerPc' = [consumerPc EXCEPT ![c] = ready]
  /\ UNCHANGED <<buffer, producedCount, consumedCount, producerPc>>

ConsumerWait(c) ==
  /\ consumerPc[c] = ready
  /\ Len(buffer) = 0
  /\ consumerPc' = [consumerPc EXCEPT ![c] = waiting]
  /\ UNCHANGED <<buffer, producedCount, consumedCount, producerPc>>

ConsumerWake(c) ==
  /\ consumerPc[c] = waiting
  /\ Len(buffer) > 0
  /\ consumerPc' = [consumerPc EXCEPT ![c] = ready]
  /\ UNCHANGED <<buffer, producedCount, consumedCount, producerPc>>

Next ==
  \/ \E p \in Producers :
       Produce(p) \/ ProducerDone(p) \/ ProducerWait(p) \/ ProducerWake(p)
  \/ \E c \in Consumers :
       Consume(c) \/ ConsumerDone(c) \/ ConsumerWait(c) \/ ConsumerWake(c)

Spec == Init /\ [][Next]_vars

BufferBounded ==
  Len(buffer) >= 0 /\ Len(buffer) <= BufferSize

CountsConsistent ==
  /\ consumedCount <= producedCount
  /\ producedCount - consumedCount = Len(buffer)

NoOverConsumption ==
  consumedCount <= MaxItems
=============================================================================
