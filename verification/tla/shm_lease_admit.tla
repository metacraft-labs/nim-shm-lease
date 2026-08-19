------------------------------ MODULE shm_lease_admit ------------------------------
(***************************************************************************)
(* M6 — THE ADMISSION POLICY, AND WHETHER A LARGE CLAIM EVER GETS IN.      *)
(*                                                                         *)
(* SCOPE, STATED FIRST BECAUSE IT IS THE WHOLE REASON THIS IS A SEPARATE   *)
(* MODULE FROM `shm_lease_combine`. MV2 models the flat-combining PROTOCOL: *)
(* the role word, the epoch fence, the commit CAS, publication, the steal   *)
(* path and death at every program counter. It says nothing about WHICH     *)
(* pending request a round decides in favour of, because M5's policy was    *)
(* first fit and there was nothing to say. M6 adds a POLICY, and the        *)
(* property it has to establish is a LIVENESS one — a large claim is        *)
(* eventually admitted under a storm of small ones — which is orthogonal to *)
(* everything MV2 checks and which would multiply MV2's already 1.3-million *)
(* state graph by a fairness-checked temporal property and a requeue        *)
(* action.                                                                  *)
(*                                                                         *)
(* So this module abstracts the combine round to ONE ATOMIC ACTION, which   *)
(* is exactly what MV2 proves the commit CAS linearises it to, and models   *)
(* what MV2 deliberately does not: requests that stay PENDING across rounds,*)
(* capacity that is RELEASED, arrival order, and a reservation.             *)
(*                                                                         *)
(* WHAT IT THEREFORE DOES NOT COVER, so nobody reads more into a green run: *)
(* no role, no epoch, no steal, no death, no publication — those are        *)
(* `shm_lease_combine.tla`, and M6 changes none of them. Conversely MV2     *)
(* still has no release action and no requeue, and that debt is recorded    *)
(* rather than discharged here: a model with BOTH would be the right thing  *)
(* to build before M7 puts reclamation on the ledger entry.                 *)
(*                                                                         *)
(* ===================================================================== *)
(* THE WORKLOAD, AND WHY IT IS SHAPED LIKE THIS                           *)
(* ===================================================================== *)
(*                                                                         *)
(* A small claimer may hold up to `MaxHold` grants at once and may publish  *)
(* its next request while still holding — that is the OVERLAP the M6 gate's *)
(* harness uses, and it is what makes memory pressure persistent instead of *)
(* sawtoothed. It gives capacity back through two separate actions, and the *)
(* difference between them is the entire liveness argument:                 *)
(*                                                                         *)
(*   `ReleaseReplaced` — it holds MaxHold grants, so its replacement has    *)
(*     arrived and it drops the old one. Enabled only when the round HAS    *)
(*     granted the next request.                                            *)
(*   `ReleaseTimeout`  — it holds one grant and its next request is still   *)
(*     pending. This is the harness's BOUNDED OVERLAP expiring, and weak    *)
(*     fairness on it is exactly the statement "a claimer will not hold its *)
(*     current reservation forever waiting for a replacement that is not    *)
(*     coming".                                                             *)
(*                                                                         *)
(* Under a policy that holds nothing idle, the round grants the replacement *)
(* promptly, `ReleaseTimeout` is never CONTINUOUSLY enabled, weak fairness  *)
(* on it is discharged without it ever firing, and a fair behaviour exists  *)
(* in which occupancy never falls far enough for the large claim — which is *)
(* the counterexample TLC finds. Under the reservation the replacement is   *)
(* REFUSED, so `ReleaseTimeout` stays enabled, fairness forces it, occupancy*)
(* drains and the large claim is admitted. The same asymmetry the harness   *)
(* exhibits with a 20 ms timeout, checked here over every interleaving.     *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Smalls,        \* the set of small claimers
    Large,         \* the one large claimant
    SmallWant,     \* what a small claim asks for
    LargeWant,     \* ...and the large one
    Capacity,      \* the machine budget
    MaxHold,       \* how many grants a small claimer may hold at once
    SlotSeq,       \* every process in SLOT order, which is the order M5 scanned
    Reserve,       \* M6 rule 2: the first request a round cannot grant holds its
                   \* capacity idle for the rest of that round
    ArrivalOrder   \* M6 rule 1: the scan runs oldest-first rather than by slot

Procs == Smalls \union {Large}
Want(p) == IF p = Large THEN LargeWant ELSE SmallWant
MaxHoldOf(p) == IF p = Large THEN 1 ELSE MaxHold

VARIABLES
    held,          \* held[p]: how many grants p is holding
    pend,          \* the set of processes with a published, undecided request
    queue,         \* those processes in ARRIVAL order
    lPublished,    \* the large claim is published at most once
    blocked        \* GHOST: a round has refused a request that WOULD have fitted
                   \* the capacity genuinely free, purely because of the
                   \* reservation. This is the IDLE HOLD, and a probe
                   \* configuration requires it to become true — a reservation
                   \* that never costs anything was never tested.

vars == <<held, pend, queue, lPublished, blocked>>

RECURSIVE SumHeld(_)
SumHeld(S) ==
    IF S = {} THEN 0
    ELSE LET p == CHOOSE q \in S : TRUE
         IN held[p] * Want(p) + SumHeld(S \ {p})

HeldTotal == SumHeld(Procs)

RECURSIVE FilterSeq(_, _)
FilterSeq(sq, S) ==
    IF Len(sq) = 0 THEN << >>
    ELSE IF Head(sq) \in S
         THEN <<Head(sq)>> \o FilterSeq(Tail(sq), S)
         ELSE FilterSeq(Tail(sq), S)

(***************************************************************************)
(* THE SCAN — one round's decisions, as a fold over the scan order.        *)
(*                                                                         *)
(* Returns <<granted set, did the reservation cost anybody>>.               *)
(*                                                                         *)
(* `free` is `capacity - held` decremented by this round's own proposals,   *)
(* which is MV2's `CountOwnProposals` carried forward — a round whose fit   *)
(* test ignores its own grants overcommits, and that is already a           *)
(* required-to-fail configuration over there rather than a second one here. *)
(*                                                                         *)
(* `reserved` is ZERO until the first request the scan cannot grant, and is *)
(* that request's `want` from then on. AT MOST ONE HEAD PER ROUND: reserving*)
(* for every blocked request would let the reservations sum past the        *)
(* capacity and stop admission dead, which is the cure becoming a worse     *)
(* disease.                                                                 *)
(***************************************************************************)
RECURSIVE ScanRec(_, _, _, _)
ScanRec(sq, i, free, reserved) ==
    IF i > Len(sq) THEN <<{}, FALSE>>
    ELSE LET p     == sq[i]
             avail == IF reserved >= free THEN 0 ELSE free - reserved
         IN IF Want(p) <= avail /\ held[p] < MaxHoldOf(p)
            THEN LET rest == ScanRec(sq, i + 1, free - Want(p), reserved)
                 IN <<{p} \union rest[1], rest[2]>>
            ELSE IF Reserve /\ reserved = 0
                 THEN ScanRec(sq, i + 1, free, Want(p))   \* p becomes the head
                 ELSE LET rest == ScanRec(sq, i + 1, free, reserved)
                          cost == reserved > 0 /\ Want(p) <= free
                      IN <<rest[1], rest[2] \/ cost>>

ScanSeq == IF ArrivalOrder THEN queue ELSE FilterSeq(SlotSeq, pend)
RoundOutcome == ScanRec(ScanSeq, 1, Capacity - HeldTotal, 0)
Grants == RoundOutcome[1]
CostsSomebody == RoundOutcome[2]

(***************************************************************************)
(* ACTIONS                                                                 *)
(***************************************************************************)

Publish(p) ==
    /\ p \notin pend
    /\ held[p] < MaxHoldOf(p)
    /\ IF p = Large THEN ~lPublished /\ lPublished' = TRUE
                    ELSE lPublished' = lPublished
    /\ pend' = pend \union {p}
    /\ queue' = Append(queue, p)
    /\ UNCHANGED <<held, blocked>>

\* ONE COMBINE ROUND, atomically. A round that would decide nothing does not
\* run at all — the role gate `RunQuota-Shared-Memory-Structures.md` requires,
\* and the reason the arbiter burns no epoch while it holds capacity idle.
Round ==
    /\ Grants # {}
    /\ held' = [p \in Procs |-> IF p \in Grants THEN held[p] + 1 ELSE held[p]]
    /\ pend' = pend \ Grants
    /\ queue' = FilterSeq(queue, pend \ Grants)
    /\ blocked' = (blocked \/ CostsSomebody)
    /\ UNCHANGED lPublished

\* THE FAST PATH: the replacement arrived, so the old reservation goes back.
ReleaseReplaced(p) ==
    /\ p \in Smalls
    /\ held[p] = MaxHoldOf(p)
    /\ held' = [held EXCEPT ![p] = held[p] - 1]
    /\ UNCHANGED <<pend, queue, lPublished, blocked>>

\* THE BOUNDED OVERLAP EXPIRING: still holding, replacement still pending. Weak
\* fairness on THIS action is the whole liveness argument — see the header.
ReleaseTimeout(p) ==
    /\ p \in Smalls
    /\ held[p] = 1
    /\ p \in pend
    /\ held' = [held EXCEPT ![p] = 0]
    /\ UNCHANGED <<pend, queue, lPublished, blocked>>

Init ==
    /\ held = [p \in Procs |-> 0]
    /\ pend = {}
    /\ queue = << >>
    /\ lPublished = FALSE
    /\ blocked = FALSE

Next ==
    \/ Round
    \/ \E p \in Procs : Publish(p)
    \/ \E p \in Smalls : ReleaseReplaced(p)
    \/ \E p \in Smalls : ReleaseTimeout(p)

Fairness ==
    /\ WF_vars(Round)
    /\ \A p \in Procs  : WF_vars(Publish(p))
    /\ \A p \in Smalls : WF_vars(ReleaseReplaced(p))
    /\ \A p \in Smalls : WF_vars(ReleaseTimeout(p))

Spec == Init /\ [][Next]_vars /\ Fairness

(***************************************************************************)
(* SAFETY — checked in EVERY configuration, green and mutated alike. A      *)
(* policy control that starved the large claim by overcommitting would be    *)
(* worthless, so the mutations are held to the same safety bar as the       *)
(* shipping policy.                                                         *)
(***************************************************************************)
TypeOK ==
    /\ held \in [Procs -> 0..MaxHold]
    /\ pend \subseteq Procs
    /\ lPublished \in BOOLEAN
    /\ blocked \in BOOLEAN
    /\ \A p \in Procs : held[p] <= MaxHoldOf(p)

NoOvercommit == HeldTotal <= Capacity

\* The queue really is the pending set, in order: the scan cannot silently drop
\* or duplicate a request.
QueueIsPending ==
    /\ \A i \in 1..Len(queue) : queue[i] \in pend
    /\ \A p \in pend : \E i \in 1..Len(queue) : queue[i] = p
    /\ Len(queue) = Cardinality(pend)

(***************************************************************************)
(* LIVENESS — the property M6 exists to establish, and the one every        *)
(* mutation is required to break.                                           *)
(***************************************************************************)

\* SM-4: the large claim is eventually admitted. Green under the shipping
\* policy; VIOLATED under each of the three policy mutations.
LargeAdmitted == <>(held[Large] > 0)

\* ...AND THE CURE IS NOT PERMANENT UNDERUTILIZATION. A policy that reserved
\* forever would satisfy nothing here: small claims must keep being served,
\* infinitely often, for the whole behaviour.
SmallsKeepGoing == []<>(\E p \in Smalls : held[p] > 0)

\* NON-VACUITY, for the probe configuration: the reservation really did cost
\* somebody something. `[]~blocked` is REQUIRED TO FAIL, which is how "capacity
\* was held idle" is established rather than assumed.
NeverBlocked == blocked = FALSE
================================================================================
