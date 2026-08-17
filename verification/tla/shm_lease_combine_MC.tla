-------------------------- MODULE shm_lease_combine_MC --------------------------
(***************************************************************************)
(* THE FLAT-COMBINING ARBITER: finite instance for TLC (MV2).              *)
(*                                                                         *)
(* TWO client processes, each owning its own request slot and each able to  *)
(* become the combiner -- which is the minimum that makes the role MIGRATE   *)
(* and therefore the minimum that makes a STEAL possible at all.            *)
(*                                                                         *)
(* THE WORKLOAD IS CHOSEN SO THAT BOTH DECISIONS ARE REACHABLE (and the     *)
(* `*_probe.cfg` companion PROVES they are, rather than asserting it):      *)
(*                                                                         *)
(*   Capacity = 2                                                          *)
(*   p1 wants 2   -- takes the whole budget                                 *)
(*   p2 wants 1   -- fits only if p1 has NOT been granted                   *)
(*                                                                         *)
(* so a round that grants p1 must REFUSE p2, and a round that reaches p2    *)
(* first grants it and then refuses p1. Both branches of the fit test run,  *)
(* and the order in which the combiner walks the slots decides which --      *)
(* which is the global-view policy decision flat combining exists to keep.  *)
(*                                                                         *)
(* `MaxFaults = 1`: the environment may kill OR descheduled exactly one      *)
(* process. One is enough to reach every recovery path with two processes:  *)
(* the survivor must both steal and finish. Two would only let the SECOND   *)
(* combiner die as well, which reaches no new protocol state and multiplies  *)
(* the graph -- see verification/README.md for what that bound excludes.     *)
(***************************************************************************)
EXTENDS shm_lease_combine, TLC

CONSTANTS p1, p2

ProcsDef == {p1, p2}
WantDef == (p1 :> 2) @@ (p2 :> 1)
================================================================================
