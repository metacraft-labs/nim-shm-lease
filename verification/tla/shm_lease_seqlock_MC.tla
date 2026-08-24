--------------------------- MODULE shm_lease_seqlock_MC ---------------------------
(***************************************************************************)
(* THE PUBLISHED AGGREGATE TABLE'S SEQLOCK: finite instance for TLC.       *)
(*                                                                         *)
(* TWO readers and TWO payload words, and both twos are the minimum that    *)
(* make something checkable rather than round numbers:                     *)
(*                                                                         *)
(*  - TWO PAYLOAD WORDS is the smallest entry that can TEAR. With one word  *)
(*    `NoTornRead` is unfalsifiable and every negative control below would  *)
(*    pass, which is the failure mode this whole tier exists to avoid.      *)
(*                                                                         *)
(*  - TWO READERS, because the spec's reason for a per-entry seqlock is     *)
(*    that concurrent readers do not serialise. One reader would leave      *)
(*    `ReaderAlwaysEnabled` and `ReaderTerminates` unable to distinguish    *)
(*    "never blocks" from "is the only one".                               *)
(*                                                                         *)
(*  - THREE ROUNDS. Two would let a reader's retry succeed against a        *)
(*    counter that has stopped moving; three means a retry can be           *)
(*    interrupted AGAIN, which is where a reader that re-arms on the wrong  *)
(*    counter shows up.                                                     *)
(*                                                                         *)
(* NOTHING HERE IS A BOUND ON BEHAVIOUR, so unlike MV2's `MaxEpochs` there  *)
(* is nothing for an `EpochBoundNotBinding`-style check to be about: the    *)
(* writer publishes finitely many rounds by construction and the reader     *)
(* retries as often as it needs to, uncounted.                              *)
(***************************************************************************)
EXTENDS shm_lease_seqlock, TLC

CONSTANTS c1, c2

ReadersDef == {c1, c2}

================================================================================
