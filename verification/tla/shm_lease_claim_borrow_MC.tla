------------------------- MODULE shm_lease_claim_borrow_MC -------------------------
(***************************************************************************)
(* THE PER-FIELD FIT TEST IS LOAD-BEARING, NOT DEFENSIVE -- checked.        *)
(*                                                                         *)
(* `RunQuota-Shared-Memory-Structures.md` SS"The claim algorithm": "A packed  *)
(* subtraction is field-wise only while every field difference is           *)
(* non-negative. One underflowing field BORROWS FROM THE FIELD ABOVE IT,    *)
(* silently corrupting a DIFFERENT dimension -- a memory over-claim can      *)
(* present as CPU-slot corruption."                                        *)
(*                                                                         *)
(* This instance is the smallest workload that exhibits exactly that, on    *)
(* ONE budget word with TWO processes:                                     *)
(*                                                                         *)
(*   Capacity = (field0: 1, field1: 2)  packed 1 + 2*4 = 9                  *)
(*   Want     = (field0: 1, field1: 0)  packed 1                            *)
(*                                                                         *)
(* The first claim leaves (field0: 0, field1: 2), packed 8. The second      *)
(* claimant's PER-FIELD test refuses it -- field0 wants 1 and has 0 -- while *)
(* the whole-word test `1 <= 8` ACCEPTS it, and the subtraction 8 - 1 = 7   *)
(* is (field0: 3, field1: 1): field0 went from 0 to THREE and field1 lost a *)
(* unit nobody asked for.                                                  *)
(*                                                                         *)
(* TWO CONFIGURATIONS, and the pair is the evidence that the fit test is    *)
(* what did it rather than the workload:                                    *)
(*                                                                         *)
(*   `shm_lease_claim_borrow_MC.cfg`     PerFieldFit = FALSE (MUTATION)      *)
(*        -> `NoBorrow` VIOLATED, and so are `NoOvercommit` and             *)
(*           `ConservationExact`: two processes hold a dimension that only   *)
(*           admits one, which is the overcommit the library exists to      *)
(*           prevent, reached through a dimension the claimant did not name. *)
(*                                                                         *)
(*   `shm_lease_claim_borrow_fit_MC.cfg` PerFieldFit = TRUE  (SHIPPED)       *)
(*        -> everything HOLDS on the identical workload.                    *)
(***************************************************************************)
EXTENDS shm_lease_claim, TLC

CONSTANTS p1, p2

ProcsDef == {p1, p2}
CapDef == [w \in {0} |-> 9]
WantDef == [p \in ProcsDef |-> 1]
ListDef == [p \in ProcsDef |-> <<0>>]
================================================================================
