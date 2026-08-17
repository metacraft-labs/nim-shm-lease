------------------------------- MODULE shm_lease_wait -------------------------------
(***************************************************************************)
(* THE WAIT PROTOCOL of `nim-shm-lease` (`src/shm_lease/waitword.nim`:      *)
(* `publishGrant`, `waitOn`, `awaitValueChange`/`awaitGrant`, `wakeAll`,    *)
(* `parkRaw`, `wakeRaw`).                                                  *)
(*                                                                         *)
(* The contract being modelled is                                          *)
(* `reprobuild-specs/RunQuota-Shared-Memory-Structures.md` SS"Grant-then-wake *)
(* ordering", SS"Wait and wake outcomes" and SS"The lost-wakeup guard is the   *)
(* kernel's, not the re-check".                                            *)
(*                                                                         *)
(* WHAT IS MODELLED FAITHFULLY:                                            *)
(*                                                                         *)
(*  1. THE KERNEL'S ATOMIC COMPARE-AND-PARK is a distinct step from the     *)
(*     waiter's userspace re-check (`WPark`), and it re-reads the word. The  *)
(*     spec insists the lost-wakeup guard is the kernel's compare and NOT   *)
(*     the userspace re-check; both are present here as separate steps, so   *)
(*     which one does the work is a checkable question rather than a claim. *)
(*                                                                         *)
(*  2. THE WAKE SYSCALL ONLY WAKES A WAITER THAT IS ACTUALLY PARKED. A wake *)
(*     that arrives while the waiter has registered but not yet parked is   *)
(*     LOST (the `wkNobodyParked` outcome), exactly as the kernel behaves.  *)
(*     Modelling it as "sets a flag the waiter will notice" would have      *)
(*     erased the pre-park window this whole protocol is about.             *)
(*                                                                         *)
(*  3. SPURIOUS WAKEUPS ARE MANUFACTURED, and they are NOT fair -- nothing  *)
(*     in this model may rely on one arriving, because no platform          *)
(*     guarantees one. The waiter must re-validate and re-park.             *)
(*                                                                         *)
(*  4. THE GRANT-THEN-WAKE PUBLISH ORDER IS A CONSTANT (`PayloadFirst`), so *)
(*     the shipped order and its inversion are both runnable. Under the     *)
(*     inversion a waiter can observe the new value and read the PREVIOUS   *)
(*     grant's payload -- reachable under plain interleaving, no weak memory *)
(*     required.                                                           *)
(*                                                                         *)
(*  5. AN OPTIONAL, EXPLICIT, ONE-PAIR STORE BUFFER (`AllowStoreLoadReorder`) *)
(*     models x86-TSO store-load reordering FOR THE PUBLISHER'S PAIR ONLY:  *)
(*     the release store of `value` followed by the seq-cst load of         *)
(*     `waiters` in `wakeAll`. This is the pair `:first_target:` suspects.   *)
(*     READ THE CAVEAT: this is a HAND-BUILT approximation of one memory    *)
(*     model for one pair, not a validated memory model. It can show a      *)
(*     window is REACHABLE; only herd7/litmus can pronounce on whether the  *)
(*     shipped annotations forbid it on a given architecture. Nothing in    *)
(*     this module is a substitute for the litmus tier.                     *)
(*                                                                         *)
(*  6. `FenceAfterBump` models the remedy: a seq-cst fence (or a seq-cst    *)
(*     store) between the value bump and the load of `waiters`, which is    *)
(*     the Dekker pairing `shm_lease/obsring.nim` ALREADY uses for the       *)
(*     structurally identical token/`tail - head` pair. With it the buffer  *)
(*     must drain before the load, and the window closes.                   *)
(*                                                                         *)
(* WHAT IS ABSTRACTED:                                                     *)
(*                                                                         *)
(*  - EXCEPT for the one pair above, TLC EXPLORES SEQUENTIALLY-CONSISTENT   *)
(*    INTERLEAVINGS. In particular the payload/value RELEASE-ACQUIRE        *)
(*    pairing is ASSUMED to work: a waiter that observes the new value is   *)
(*    assumed to see the payload stored before it. Whether the shipped      *)
(*    `ATOMIC_RELEASE` / `ATOMIC_ACQUIRE` annotations deliver that on ARMv8  *)
(*    is the litmus tier's question (`litmus/grant-payload-publish.litmus`). *)
(*    What this model checks is the PROTOCOL ORDER -- that the payload is    *)
(*    written before the bump at all -- which is a different property and    *)
(*    is checkable here.                                                    *)
(*                                                                         *)
(*  - The waiter's two consecutive plain loads of the value                 *)
(*    (`awaitValueChange`'s loop test and `waitOn`'s fast-path test) are     *)
(*    ONE step here. Neither load has a side effect and both evaluate the   *)
(*    same predicate, so any interleaving between them is equivalent to one *)
(*    before or after -- collapsing them removes states, not behaviours.     *)
(*                                                                         *)
(*  - ONE GRANTOR. M5's migrating combiner role, where several processes    *)
(*    may publish grants, is MV2 and is deliberately not modelled here.      *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
  Waiters,               \* the waiting processes; each owns its own slot
  GrantWork,             \* Seq(Waiters): the grants the grantor publishes, in order
  MaxSpurious,           \* how many spurious wakeups the environment may inject
  PayloadFirst,          \* TRUE = shipped grant-then-wake; FALSE = MUTATION
  AllowStoreLoadReorder, \* TRUE = model an x86-TSO store buffer for ONE pair
  FenceAfterBump,        \* TRUE = seq-cst fence between the bump and the waiters load
  OneOutstandingPerSlot  \* TRUE = the caller's precondition; FALSE = it is dropped

NoPend == -1

TotalGrants(w) == Cardinality({i \in 1 .. Len(GrantWork) : GrantWork[i] = w})

NumGrants == Len(GrantWork)

VARIABLES
  value,       \* [Waiters -> Nat] the compared word, GLOBALLY VISIBLE
  pend,        \* [Waiters -> Int] a value store issued but not yet visible
  wcount,      \* [Waiters -> Nat] the `waiters` field that gates the wake syscall
  payload,     \* [Waiters -> Nat] the grant, published beside the wait word
  parked,      \* [Waiters -> BOOLEAN] inside the kernel, asleep
  woken,       \* [Waiters -> BOOLEAN] a wake syscall found this waiter parked
  pcW,         \* [Waiters -> STRING] waiter program counter
  lastSeen,    \* [Waiters -> Nat] the value this waiter waits to move off
  seen,        \* [Waiters -> Nat] the value it observed when it did move
  mismatch,    \* [Waiters -> BOOLEAN] it read a payload that was not its grant's
  pcG,         \* STRING grantor program counter
  j,           \* Nat cursor into GrantWork
  wakes,       \* Nat wake SYSCALLS issued
  grants,      \* Nat grants published
  spuriousLeft,
  wprobe

vars == <<value, pend, wcount, payload, parked, woken, pcW, lastSeen, seen,
          mismatch, pcG, j, wakes, grants, spuriousLeft, wprobe>>

Init ==
  /\ value = [w \in Waiters |-> 0]
  /\ pend = [w \in Waiters |-> NoPend]
  /\ wcount = [w \in Waiters |-> 0]
  /\ payload = [w \in Waiters |-> 0]
  /\ parked = [w \in Waiters |-> FALSE]
  /\ woken = [w \in Waiters |-> FALSE]
  /\ pcW = [w \in Waiters |-> "loop"]
  /\ lastSeen = [w \in Waiters |-> 0]
  /\ seen = [w \in Waiters |-> 0]
  /\ mismatch = [w \in Waiters |-> FALSE]
  /\ pcG = "g0"
  /\ j = 1
  /\ wakes = 0
  /\ grants = 0
  /\ spuriousLeft = MaxSpurious
  /\ wprobe = [fastWait |-> FALSE, realPark |-> FALSE, fastWake |-> FALSE,
               realWake |-> FALSE, nobodyParked |-> FALSE, kernelSave |-> FALSE,
               recheckSave |-> FALSE, spurious |-> FALSE, coalesced |-> FALSE]

(***************************************************************************)
(* THE WAITER: `awaitValueChange` -> `waitOn` -> the kernel's park.          *)
(***************************************************************************)

WDone(w) ==
  /\ pcW[w] = "loop"
  /\ lastSeen[w] = TotalGrants(w)
  /\ pcW' = [pcW EXCEPT ![w] = "wDone"]
  /\ UNCHANGED <<value, pend, wcount, payload, parked, woken, lastSeen, seen,
                 mismatch, pcG, j, wakes, grants, spuriousLeft, wprobe>>

WFastPath(w) ==
  \* The word already differs: ONE atomic load, `wrNotEqual`, NO syscall (SM-2).
  /\ pcW[w] = "loop"
  /\ lastSeen[w] # TotalGrants(w)
  /\ value[w] # lastSeen[w]
  /\ seen' = [seen EXCEPT ![w] = value[w]]
  /\ pcW' = [pcW EXCEPT ![w] = "gotGrant"]
  /\ wprobe' = [wprobe EXCEPT !.fastWait = TRUE,
                              !.coalesced = @ \/ (value[w] - lastSeen[w] > 1)]
  /\ UNCHANGED <<value, pend, wcount, payload, parked, woken, lastSeen,
                 mismatch, pcG, j, wakes, grants, spuriousLeft>>

WRegister(w) ==
  \* The slow path: register as a waiter (seq-cst RMW on `waiters`).
  /\ pcW[w] = "loop"
  /\ lastSeen[w] # TotalGrants(w)
  /\ value[w] = lastSeen[w]
  /\ wcount' = [wcount EXCEPT ![w] = wcount[w] + 1]
  /\ pcW' = [pcW EXCEPT ![w] = "wRecheck"]
  /\ UNCHANGED <<value, pend, payload, parked, woken, lastSeen, seen, mismatch,
                 pcG, j, wakes, grants, spuriousLeft, wprobe>>

WRecheckDiffers(w) ==
  \* The re-check caught a publisher that landed after the fast-path load. This
  \* is SYSCALL AVOIDANCE, not the lost-wakeup guard -- see `WPark`.
  /\ pcW[w] = "wRecheck"
  /\ value[w] # lastSeen[w]
  /\ wcount' = [wcount EXCEPT ![w] = wcount[w] - 1]
  /\ seen' = [seen EXCEPT ![w] = value[w]]
  /\ pcW' = [pcW EXCEPT ![w] = "gotGrant"]
  /\ wprobe' = [wprobe EXCEPT !.recheckSave = TRUE,
                              !.coalesced = @ \/ (value[w] - lastSeen[w] > 1)]
  /\ UNCHANGED <<value, pend, payload, parked, woken, lastSeen, mismatch,
                 pcG, j, wakes, grants, spuriousLeft>>

WRecheckSame(w) ==
  /\ pcW[w] = "wRecheck"
  /\ value[w] = lastSeen[w]
  /\ pcW' = [pcW EXCEPT ![w] = "wPark"]
  /\ UNCHANGED <<value, pend, wcount, payload, parked, woken, lastSeen, seen,
                 mismatch, pcG, j, wakes, grants, spuriousLeft, wprobe>>

WParkKernelSaves(w) ==
  \* THE LOST-WAKEUP GUARD: the kernel re-compares the word INSIDE the syscall,
  \* so a publisher that landed between the userspace re-check and the park makes
  \* the park return immediately instead of sleeping.
  /\ pcW[w] = "wPark"
  /\ value[w] # lastSeen[w]
  /\ wcount' = [wcount EXCEPT ![w] = wcount[w] - 1]
  /\ pcW' = [pcW EXCEPT ![w] = "loop"]
  /\ wprobe' = [wprobe EXCEPT !.kernelSave = TRUE]
  /\ UNCHANGED <<value, pend, payload, parked, woken, lastSeen, seen, mismatch,
                 pcG, j, wakes, grants, spuriousLeft>>

WParkSleeps(w) ==
  /\ pcW[w] = "wPark"
  /\ value[w] = lastSeen[w]
  /\ parked' = [parked EXCEPT ![w] = TRUE]
  /\ pcW' = [pcW EXCEPT ![w] = "wParked"]
  /\ wprobe' = [wprobe EXCEPT !.realPark = TRUE]
  /\ UNCHANGED <<value, pend, wcount, payload, woken, lastSeen, seen, mismatch,
                 pcG, j, wakes, grants, spuriousLeft>>

WWake(w) ==
  \* Returned from the kernel. `wrWoken` means "look again", NEVER "your grant is
  \* ready" -- the loop re-validates, which is what makes a spurious wake harmless.
  /\ pcW[w] = "wParked"
  /\ woken[w]
  /\ parked' = [parked EXCEPT ![w] = FALSE]
  /\ woken' = [woken EXCEPT ![w] = FALSE]
  /\ wcount' = [wcount EXCEPT ![w] = wcount[w] - 1]
  /\ pcW' = [pcW EXCEPT ![w] = "loop"]
  /\ UNCHANGED <<value, pend, payload, lastSeen, seen, mismatch, pcG, j,
                 wakes, grants, spuriousLeft, wprobe>>

SpuriousWake(w) ==
  \* Permitted by every one of the three platform primitives. DELIBERATELY NOT
  \* FAIR: no property in this model may depend on one arriving.
  /\ pcW[w] = "wParked"
  /\ ~woken[w]
  /\ spuriousLeft > 0
  /\ spuriousLeft' = spuriousLeft - 1
  /\ parked' = [parked EXCEPT ![w] = FALSE]
  /\ wcount' = [wcount EXCEPT ![w] = wcount[w] - 1]
  /\ pcW' = [pcW EXCEPT ![w] = "loop"]
  /\ wprobe' = [wprobe EXCEPT !.spurious = TRUE]
  /\ UNCHANGED <<value, pend, payload, woken, lastSeen, seen, mismatch, pcG, j,
                 wakes, grants>>

WConsume(w) ==
  \* Read the payload AFTER observing the value change, and re-arm on the value
  \* actually seen. `mismatch` records reading a payload that does not belong to
  \* the observed grant -- the failure the publish order exists to prevent.
  /\ pcW[w] = "gotGrant"
  /\ mismatch' = [mismatch EXCEPT ![w] = @ \/ (payload[w] # seen[w])]
  /\ lastSeen' = [lastSeen EXCEPT ![w] = seen[w]]
  /\ pcW' = [pcW EXCEPT ![w] = "loop"]
  /\ UNCHANGED <<value, pend, wcount, payload, parked, woken, seen, pcG, j,
                 wakes, grants, spuriousLeft, wprobe>>

StepW(w) ==
  \/ WDone(w) \/ WFastPath(w) \/ WRegister(w)
  \/ WRecheckDiffers(w) \/ WRecheckSame(w)
  \/ WParkKernelSaves(w) \/ WParkSleeps(w) \/ WWake(w) \/ WConsume(w)

(***************************************************************************)
(* THE GRANTOR: `publishGrant` -- payload, then a RELEASE bump of the value,  *)
(* then a wake ONLY IF `waiters` is non-zero.                               *)
(***************************************************************************)

Target == GrantWork[j]

SlotQuiet(w) ==
  (*************************************************************************)
  (* THE UNSTATED PRECONDITION OF `publishGrant`, made explicit: the slot's  *)
  (* previous grant has been collected by its waiter (`lastSeen` has caught  *)
  (* up with the published value) and no bump is still in flight. See        *)
  (* `shm_lease_wait_overwrite_MC.cfg` and verification/README.md for what   *)
  (* happens when it is dropped -- it is a REAL DEFECT in the contract, not   *)
  (* an artefact of the model.                                              *)
  (*************************************************************************)
  /\ lastSeen[w] = value[w]
  /\ pend[w] = NoPend

G0 ==
  /\ pcG = "g0"
  /\ (j <= NumGrants /\ OneOutstandingPerSlot => SlotQuiet(Target))
  /\ IF j > NumGrants
     THEN pcG' = "gDone"
     ELSE pcG' = (IF PayloadFirst THEN "gPayload" ELSE "gValue")
  /\ UNCHANGED <<value, pend, wcount, payload, parked, woken, pcW, lastSeen,
                 seen, mismatch, j, wakes, grants, spuriousLeft, wprobe>>

GPayload ==
  \* Step 1 of the publish order: write the payload. Its identity is the value
  \* the bump is about to publish, so "the waiter read the payload that went
  \* with the value it saw" is a checkable equality.
  /\ pcG = "gPayload"
  /\ payload' = [payload EXCEPT ![Target] = value[Target] + 1]
  /\ pcG' = (IF PayloadFirst THEN "gValue" ELSE "gLoad")
  /\ UNCHANGED <<value, pend, wcount, parked, woken, pcW, lastSeen, seen,
                 mismatch, j, wakes, grants, spuriousLeft, wprobe>>

GValueSC ==
  \* Step 2: the release bump, immediately globally visible (the sequentially
  \* consistent reading of the shipped code).
  /\ pcG = "gValue"
  /\ ~AllowStoreLoadReorder
  /\ value' = [value EXCEPT ![Target] = value[Target] + 1]
  /\ grants' = grants + 1
  /\ pcG' = (IF PayloadFirst THEN "gLoad" ELSE "gPayload")
  /\ UNCHANGED <<pend, wcount, payload, parked, woken, pcW, lastSeen, seen,
                 mismatch, j, wakes, spuriousLeft, wprobe>>

GValueBuffered ==
  \* Step 2 under the one-pair store-buffer abstraction: the bump is ISSUED but
  \* not yet globally visible. No other process can observe it until `GDrain`.
  /\ pcG = "gValue"
  /\ AllowStoreLoadReorder
  /\ pend[Target] = NoPend
  /\ pend' = [pend EXCEPT ![Target] = value[Target] + 1]
  /\ grants' = grants + 1
  /\ pcG' = (IF PayloadFirst THEN "gLoad" ELSE "gPayload")
  /\ UNCHANGED <<value, wcount, payload, parked, woken, pcW, lastSeen, seen,
                 mismatch, j, wakes, spuriousLeft, wprobe>>

GDrain ==
  \* The store buffer draining. Fair: a store always becomes visible eventually.
  /\ \E w \in Waiters : pend[w] # NoPend
  /\ LET w == CHOOSE x \in Waiters : pend[x] # NoPend IN
     /\ value' = [value EXCEPT ![w] = pend[w]]
     /\ pend' = [pend EXCEPT ![w] = NoPend]
  /\ UNCHANGED <<wcount, payload, parked, woken, pcW, lastSeen, seen, mismatch,
                 pcG, j, wakes, grants, spuriousLeft, wprobe>>

Drained == \A w \in Waiters : pend[w] = NoPend

GLoadFast ==
  \* Step 3, the WAKER'S FAST PATH (SM-2): `waiters` is zero, so NO SYSCALL.
  \* This is the load `:first_target:` is about: reached with the value bump
  \* possibly still in the store buffer unless `FenceAfterBump`.
  /\ pcG = "gLoad"
  /\ (Drained \/ ~FenceAfterBump)
  /\ wcount[Target] = 0
  /\ pcG' = "gNext"
  /\ wprobe' = [wprobe EXCEPT !.fastWake = TRUE]
  /\ UNCHANGED <<value, pend, wcount, payload, parked, woken, pcW, lastSeen,
                 seen, mismatch, j, wakes, grants, spuriousLeft>>

GLoadWake ==
  /\ pcG = "gLoad"
  /\ (Drained \/ ~FenceAfterBump)
  /\ wcount[Target] # 0
  /\ pcG' = "gWake"
  /\ UNCHANGED <<value, pend, wcount, payload, parked, woken, pcW, lastSeen,
                 seen, mismatch, j, wakes, grants, spuriousLeft, wprobe>>

GWake ==
  \* The wake syscall. It wakes a waiter that is PARKED; a waiter that has
  \* registered but not yet parked is not woken and the syscall reports
  \* `wkNobodyParked` -- the wake is genuinely lost, and the protocol must not
  \* need it (the kernel's compare-and-park is what covers that window).
  /\ pcG = "gWake"
  /\ wakes' = wakes + 1
  /\ woken' = [woken EXCEPT ![Target] = parked[Target]]
  /\ wprobe' = [wprobe EXCEPT !.realWake = @ \/ parked[Target],
                              !.nobodyParked = @ \/ ~parked[Target]]
  /\ pcG' = "gNext"
  /\ UNCHANGED <<value, pend, wcount, payload, parked, pcW, lastSeen, seen,
                 mismatch, j, grants, spuriousLeft>>

GNext ==
  /\ pcG = "gNext"
  /\ Drained            \* a buffered store never outlives the operation
  /\ j' = j + 1
  /\ pcG' = "g0"
  /\ UNCHANGED <<value, pend, wcount, payload, parked, woken, pcW, lastSeen,
                 seen, mismatch, wakes, grants, spuriousLeft, wprobe>>

StepG ==
  \/ G0 \/ GPayload \/ GValueSC \/ GValueBuffered \/ GLoadFast \/ GLoadWake
  \/ GWake \/ GNext

AllDone == pcG = "gDone" /\ \A w \in Waiters : pcW[w] = "wDone"

Terminating == AllDone /\ UNCHANGED vars

Next ==
  \/ StepG
  \/ GDrain
  \/ \E w \in Waiters : StepW(w) \/ SpuriousWake(w)
  \/ Terminating

Spec == Init /\ [][Next]_vars
        /\ WF_vars(StepG) /\ WF_vars(GDrain)
        /\ \A w \in Waiters : WF_vars(StepW(w))
        \* NOTE: no fairness on SpuriousWake -- nothing may depend on one.

(***************************************************************************)
(* INVARIANTS                                                              *)
(***************************************************************************)

TypeOK ==
  /\ value \in [Waiters -> 0 .. NumGrants]
  /\ pend \in [Waiters -> (0 - 1) .. NumGrants]
  /\ wcount \in [Waiters -> 0 .. Cardinality(Waiters)]
  /\ pcG \in {"g0", "gPayload", "gValue", "gLoad", "gWake", "gNext", "gDone"}
  /\ pcW \in [Waiters -> {"loop", "wRecheck", "wPark", "wParked", "gotGrant",
                          "wDone"}]
  /\ j \in 1 .. (NumGrants + 1)
  /\ spuriousLeft \in 0 .. MaxSpurious

Wedged(w) ==
  (*************************************************************************)
  (* A LOST WAKEUP, stated so that it cannot produce a false positive: the  *)
  (* waiter is asleep in the kernel, no wake is pending for it, the grantor *)
  (* has FINISHED so no further wake will ever be issued, every buffered    *)
  (* store has drained, and the word it is parked on HAS ALREADY MOVED.     *)
  (* Only a spurious wakeup could rescue it, and no platform guarantees one. *)
  (*************************************************************************)
  /\ parked[w]
  /\ ~woken[w]
  /\ pcG = "gDone"
  /\ Drained
  /\ value[w] # lastSeen[w]

NoLostWakeup == \A w \in Waiters : ~Wedged(w)

WakesLEGrants == wakes <= grants
  \* SM-3, no wake amplification: each grant wakes at most once.

WakeImpliesGrant == \A w \in Waiters :
                      pcW[w] = "gotGrant" => seen[w] > lastSeen[w]
  (*************************************************************************)
  (* A waiter only ever LEAVES the wait because its own word moved forward, *)
  (* i.e. because a grant was published to it -- never merely because it was *)
  (* woken. Wake-then-retry, which the spec calls a defect rather than an   *)
  (* alternative, would violate this.                                      *)
  (*************************************************************************)

GrantPayloadCoherent == \A w \in Waiters : ~mismatch[w]
  (*************************************************************************)
  (* THE GRANT-THEN-WAKE PUBLISH ORDER. A waiter that observes value v      *)
  (* reads the payload published FOR v, never the previous grant's. Violated *)
  (* by `PayloadFirst = FALSE`, and violated under PLAIN INTERLEAVING -- no  *)
  (* weak memory is needed to lose a payload if it is written after the bump. *)
  (*************************************************************************)

WaiterCountSane == \A w \in Waiters :
                     /\ wcount[w] >= 0
                     /\ (parked[w] => wcount[w] >= 1)
  \* A parked waiter is always counted, which is what makes the waker's
  \* fast path (`wkNoWaiters` without a syscall) sound.

NoWakeWhileUnregistered == \A w \in Waiters : parked[w] => wcount[w] > 0

AllServed == <>(\A w \in Waiters : pcW[w] = "wDone")
  \* The liveness form of no-lost-wakeup: every published grant is eventually
  \* collected by its waiter, WITHOUT relying on a spurious wakeup.

(***************************************************************************)
(* NON-VACUITY. Checked as a negation in `*_probe.cfg`; TLC MUST violate it. *)
(* The counterexample is one behaviour in which the waiter took its         *)
(* zero-syscall fast path AND genuinely slept AND was saved by the          *)
(* userspace re-check AND was saved by the KERNEL's compare-and-park AND was *)
(* woken by a real wake syscall AND survived a spurious wakeup, while the    *)
(* waker took both its zero-syscall fast path and its syscall path and hit   *)
(* the pre-park window where its wake found nobody inside the kernel.        *)
(***************************************************************************)

ProbeAllReached ==
  ~(/\ wprobe.fastWait
    /\ wprobe.realPark
    /\ wprobe.fastWake
    /\ wprobe.realWake
    /\ wprobe.nobodyParked
    /\ wprobe.kernelSave
    /\ wprobe.recheckSave
    /\ wprobe.spurious)

ProbeKernelSaveReached == ~wprobe.kernelSave
  \* The single most important window on its own: the publisher landing between
  \* the waiter's userspace re-check and its park, with the kernel's atomic
  \* compare being the only thing that stops the waiter sleeping through it.

ProbeNobodyParkedReached == ~wprobe.nobodyParked
  \* The mirror window: a wake syscall issued while the waiter had registered
  \* but not yet parked, so the wake was LOST and the protocol had to survive it.

================================================================================
