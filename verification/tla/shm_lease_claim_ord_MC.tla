-------------------------- MODULE shm_lease_claim_ord_MC --------------------------
(***************************************************************************)
(* THE DEADLOCK ARGUMENT, MADE MECHANICAL.                                 *)
(*                                                                         *)
(* `RunQuota-Shared-Memory-Structures.md` SS"Word indices and the claim      *)
(* order" states the whole deadlock argument as prose: "Because every       *)
(* claimant takes words ascending, the waits-for relation is a strict order *)
(* and no cycle is constructible." This instance CHECKS it, by building the *)
(* workload the argument excludes and running it BOTH WAYS:                 *)
(*                                                                         *)
(*   p1 : <<0, 1>>   ascending  -- a legal claim                            *)
(*   p2 : <<1, 0>>   DESCENDING -- the claim `csOutOfOrder` exists to refuse *)
(*                                                                         *)
(* Capacity per word = (field0: 1, field1: 1) packed 1 + 1*4 = 5, and each  *)
(* process wants exactly that, so ONE claimant fills a word completely and  *)
(* a second claimant on the same word must refuse. That is the tightest     *)
(* possible setting for constructing a cycle.                              *)
(*                                                                         *)
(* TWO CONFIGURATIONS, AND THE PAIR IS THE EVIDENCE:                        *)
(*                                                                         *)
(*   `shm_lease_claim_ord_MC.cfg`        EnforceOrder = TRUE  (SHIPPED)      *)
(*        -> `NoHoldCycle` and `AscendingHold` HOLD. p2's list is refused    *)
(*           with `csOutOfOrder` and p2 never holds anything, so the cycle   *)
(*           is not constructible. `ProbeOutOfOrderReached` is checked       *)
(*           separately and MUST be violated, proving the refusal really    *)
(*           fires rather than the workload never reaching it.               *)
(*                                                                         *)
(*   `shm_lease_claim_ord_nocheck_MC.cfg` EnforceOrder = FALSE (MUTATION)    *)
(*        -> `NoHoldCycle` IS VIOLATED. p1 holds word 0 and wants word 1,   *)
(*           p2 holds word 1 and wants word 0. The cycle the spec says is   *)
(*           "not constructible" is constructed the moment the ordering     *)
(*           rule is dropped -- so the rule is load-bearing, not stylistic.  *)
(***************************************************************************)
EXTENDS shm_lease_claim, TLC

CONSTANTS p1, p2

ProcsDef == {p1, p2}
CapDef == [w \in {0, 1} |-> 5]
WantDef == [p \in ProcsDef |-> 5]
ListDef == (p1 :> <<0, 1>>) @@ (p2 :> <<1, 0>>)
================================================================================
