---------------------------- MODULE shm_lease_claim_MC ----------------------------
(***************************************************************************)
(* THE SHIPPED CLAIM PROTOCOL: finite instance for TLC.                    *)
(*                                                                         *)
(* Three processes over TWO budget words -- word 0 is the per-machine       *)
(* budget (`MachineBudgetIndex`) and word 1 is pool 0                      *)
(* (`poolBudgetIndex(0)`), exactly the two-word shape `claim` builds when   *)
(* `poolIndex >= 0`.                                                       *)
(*                                                                         *)
(* THE WORKLOAD IS CHOSEN TO MAKE EVERY BRANCH REACHABLE (and the           *)
(* `*_probe.cfg` companion PROVES it is, rather than asserting it):         *)
(*                                                                         *)
(*   Capacity per word = (field0: 2, field1: 2)  packed 2 + 2*4 = 10        *)
(*   Want per process  = (field0: 1, field1: 1)  packed 1 + 1*4 = 5         *)
(*                                                                         *)
(* so each word admits exactly TWO concurrent claims and refuses the third. *)
(*                                                                         *)
(*   p1 : <<0, 1>>   two-word claim, ascending                             *)
(*   p2 : <<0, 1>>   two-word claim, ascending -- contends with p1 on BOTH  *)
(*   p3 : <<1>>      single-word claim on the POOL word only               *)
(*                                                                         *)
(* p3 is what makes ROLLBACK reachable: p1 and p2 take word 0, p3 and one   *)
(* of them take word 1, and the loser is refused on word 1 while ALREADY    *)
(* HOLDING word 0 -- the partial-claim rollback path. Without a process     *)
(* that claims the second word alone, every two-word claim would succeed or *)
(* fail on the first word and the rollback code would never run.            *)
(***************************************************************************)
EXTENDS shm_lease_claim, TLC

CONSTANTS p1, p2, p3

ProcsDef == {p1, p2, p3}
CapDef == [w \in {0, 1} |-> 10]
WantDef == [p \in ProcsDef |-> 5]
ListDef == (p1 :> <<0, 1>>) @@ (p2 :> <<0, 1>>) @@ (p3 :> <<1>>)
================================================================================
