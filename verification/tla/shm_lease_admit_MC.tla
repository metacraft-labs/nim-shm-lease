------------------------- MODULE shm_lease_admit_MC -------------------------
(***************************************************************************)
(* M6's ADMISSION POLICY: finite instance for TLC.                         *)
(*                                                                         *)
(* TWO small claimers and one large claimant, and the arithmetic is chosen  *)
(* to be the M6 gate's arithmetic in miniature:                            *)
(*                                                                         *)
(*   Capacity  = 4                                                         *)
(*   SmallWant = 1, and a small claimer may hold TWO at once (the overlap)  *)
(*   LargeWant = 3                                                         *)
(*                                                                         *)
(* So the storm's floor when it never lets go is 2 units, the large claim   *)
(* needs `held <= 1`, and `4 - 2 = 2 < 3` — the same inequality the gate's  *)
(* `static: doAssert` enforces over 10 GiB, 512 MiB and 8 GiB. Two claimers *)
(* are the minimum that make the floor exceed the slack; a third adds no    *)
(* protocol state and multiplies the graph.                                 *)
(*                                                                         *)
(* `Capacity - LargeWant = 1 >= SmallWant`, deliberately: small claims must *)
(* still be servable while the large claim HOLDS, or `SmallsKeepGoing`      *)
(* would be vacuous rather than green.                                     *)
(*                                                                         *)
(* `SlotSeqDef` puts the large claimant LAST, which is the placement M5's   *)
(* slot-ordered scan is worst at and the one the `slotorder` mutation needs *)
(* in order to hand its reservation to the wrong request.                   *)
(***************************************************************************)
EXTENDS shm_lease_admit, TLC

CONSTANTS s1, s2, big

SmallsDef == {s1, s2}
SlotSeqDef == <<s1, s2, big>>
================================================================================
