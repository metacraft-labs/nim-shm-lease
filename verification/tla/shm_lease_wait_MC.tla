---------------------------- MODULE shm_lease_wait_MC ----------------------------
(***************************************************************************)
(* THE SHIPPED WAIT PROTOCOL: finite instance for TLC.                     *)
(*                                                                         *)
(* TWO waiters, each with ITS OWN SLOT (the spec's rule: "a shared wait     *)
(* word reintroduces the thundering herd by construction"), and one grantor *)
(* publishing THREE grants: w1, w2, then w1 again. The repeat matters --     *)
(* it makes the waiter go round its `awaitValueChange` loop a second time    *)
(* with a NEW `lastSeen`, which is where an off-by-one re-arm would show.    *)
(*                                                                         *)
(* `MaxSpurious = 1`: the environment may manufacture one spurious wakeup,  *)
(* which every one of the three platform primitives is permitted to do.     *)
(***************************************************************************)
EXTENDS shm_lease_wait, TLC

CONSTANTS w1, w2

WaitersDef == {w1, w2}
GrantWorkDef == <<w1, w2, w1>>
================================================================================
