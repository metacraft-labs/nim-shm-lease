------------------------ MODULE shm_lease_reclaim_MC ------------------------
(***************************************************************************)
(* M7's RESERVATION + COMBINE + DEATH + RECLAMATION model: finite instance  *)
(* for TLC.                                                                *)
(*                                                                         *)
(* THE SAME ARITHMETIC AS `shm_lease_admit_MC`, deliberately, so the two    *)
(* models are comparable and a difference in outcome is a difference in the *)
(* PROTOCOL rather than in the numbers:                                     *)
(*                                                                         *)
(*   Capacity  = 4                                                         *)
(*   SmallWant = 1, and a small claimer may hold TWO at once (the overlap)  *)
(*   LargeWant = 3                                                         *)
(*                                                                         *)
(* so the storm's floor when it never lets go is 2, the large claim needs   *)
(* `held <= 1`, and `4 - 2 = 2 < 3`.                                       *)
(*                                                                         *)
(* `MaxDeaths = 1` is what keeps the graph finite AND is the interesting    *)
(* case: one death is enough to hold the role forever, to leak a grant      *)
(* forever, and to park a corpse at the head of the arrival order. A second *)
(* death adds a second instance of the same three shapes.                   *)
(***************************************************************************)
EXTENDS shm_lease_reclaim, TLC

CONSTANTS s1, s2, big

SmallsDef == {s1, s2}
SlotSeqDef == <<s1, s2, big>>
================================================================================
