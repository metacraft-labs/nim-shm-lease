----------------------------- MODULE shm_lease_reclaim -----------------------------
(***************************************************************************)
(* M7 — THE RESERVATION AND THE COMBINE PROTOCOL, MODELLED TOGETHER, WITH  *)
(* DEATH AND RECLAMATION.                                                  *)
(*                                                                         *)
(* THIS MODULE EXISTS BECAUSE M6 SAID IT WAS OWED, AND SAID SO IN ITS OWN   *)
(* `:deferred:` (4): "THE RESERVATION AND THE COMBINE PROTOCOL ARE MODELLED *)
(* SEPARATELY AND NEVER TOGETHER. `shm_lease_admit.tla` has the requeue and *)
(* the release MV2's `:deferred:` asked for, but no role, no epoch, no      *)
(* steal and no death; `shm_lease_combine.tla` still has no release and no  *)
(* requeue. So a reservation interacting with a combiner that dies          *)
(* mid-round is checked by NEITHER model. A model with both is the right    *)
(* thing to build before M7 puts reclamation on the ledger entry."          *)
(*                                                                         *)
(* This is that model. It takes `shm_lease_admit`'s workload and policy —   *)
(* pending requests that survive rounds, capacity that is released, arrival *)
(* order, one reservation head — and adds the three things M7 turns on:     *)
(*                                                                         *)
(*   1. A ROLE that one process holds across a round, so a round is TWO     *)
(*      steps and a process can die BETWEEN them while a reservation stands.*)
(*   2. DEATH, at any point, of any process, holding anything.              *)
(*   3. RECLAMATION of a dead process's grant, and — as a required-to-fail  *)
(*      control — of a LIVE one's.                                          *)
(*                                                                         *)
(* ===================================================================== *)
(* WHAT IT DELIBERATELY DOES NOT RE-MODEL, AND WHY THAT IS NOT A GAP      *)
(* ===================================================================== *)
(*                                                                         *)
(* The EPOCH, the commit CAS, the raise pass, the per-slot serialisation and*)
(* the publication step are MV2's (`shm_lease_combine.tla`), which explores *)
(* them with death at every program counter over 1.3M states. Re-modelling  *)
(* them here would multiply that graph by this module's fairness-checked    *)
(* temporal properties for no new information. What MV2 PROVES is that a    *)
(* round linearises at its commit CAS and that a half-applied round is      *)
(* discarded intact by the next acquisition; this module takes that as its  *)
(* abstraction — `RoundStart` proposes, `RoundCommit` applies atomically,   *)
(* and `StealRole` discards a proposal wholesale — and asks the question    *)
(* MV2 cannot: what happens to the RESERVATION and to the CAPACITY while    *)
(* that is going on.                                                       *)
(*                                                                         *)
(* THE ONE THING THAT IS NEW IN KIND: `using` is a GHOST recording what each*)
(* process is REALLY consuming, as opposed to `held`, which is what the     *)
(* LEDGER says it holds. Live processes keep the two equal by construction; *)
(* death sets `using` to zero (the OS reclaims the memory) and leaves `held`*)
(* alone (the LEDGER does not know), which IS the leak; and a reclamation of*)
(* a LIVE process clears `held` while `using` stands, which IS the          *)
(* overcommit. One variable makes both failure directions checkable, and    *)
(* they are opposite directions of the same mistake.                       *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Smalls,        \* the set of small claimers
    Large,         \* the one large claimant
    SmallWant,     \* what a small claim asks for
    LargeWant,     \* ...and the large one
    Capacity,      \* the machine budget
    MaxHold,       \* how many grants a small claimer may hold at once
    SlotSeq,       \* every process in SLOT order
    Reserve,       \* M6 rule 2: one reservation head per round
    ArrivalOrder,  \* M6 rule 1: the scan runs oldest-first
    Steal,         \* M5 constraint 4: a dead role holder is stolen from
    Reclaim,       \* M7: a dead process's grant is given back
    ReclaimLive,   \* M7 MUTATION: reclamation fires on a LIVE holder too
    MaxDeaths,     \* bound on the number of deaths, so the graph is finite
    NoProc         \* a value outside `Procs`: "no owner" and "no reservation
                   \* head" are the same kind of thing -- the absence of a
                   \* process -- so they share one. A CONSTANT rather than a
                   \* `CHOOSE`, because an unbounded `CHOOSE` is not something
                   \* TLC can evaluate.

Procs == Smalls \union {Large}
Want(p) == IF p = Large THEN LargeWant ELSE SmallWant
MaxHoldOf(p) == IF p = Large THEN 1 ELSE MaxHold

VARIABLES
    held,          \* THE LEDGER: grants the arbiter believes each process holds
    using,         \* GHOST: what each process is REALLY consuming
    pend,          \* processes with a published, undecided request
    queue,         \* those processes in ARRIVAL order
    lPublished,    \* the large claim is published at most once
    blocked,       \* GHOST: a round refused a request the reservation covered
    alive,         \* processes that have not died
    deaths,        \* how many have
    role,          \* the process holding the combiner role, or NoProc
    prop,          \* the grants the round in progress has DECIDED, not applied
    roundHead,     \* GHOST: the reservation head of the round in progress
    reaped         \* GHOST: a reclamation has happened

vars == <<held, using, pend, queue, lPublished, blocked, alive, deaths,
          role, prop, roundHead, reaped>>

RECURSIVE SumOver(_, _)
SumOver(f, S) ==
    IF S = {} THEN 0
    ELSE LET p == CHOOSE q \in S : TRUE
         IN f[p] * Want(p) + SumOver(f, S \ {p})

HeldTotal == SumOver(held, Procs)
UsingTotal == SumOver(using, Procs)

RECURSIVE FilterSeq(_, _)
FilterSeq(sq, S) ==
    IF Len(sq) = 0 THEN << >>
    ELSE IF Head(sq) \in S
         THEN <<Head(sq)>> \o FilterSeq(Tail(sq), S)
         ELSE FilterSeq(Tail(sq), S)

(***************************************************************************)
(* THE SCAN — identical in content to `shm_lease_admit`'s, extended to      *)
(* report WHICH request became the reservation head. The head is what makes *)
(* the non-vacuity probe below able to say "a combiner died mid-round WHILE *)
(* A RESERVATION STOOD" rather than merely "a combiner died mid-round".     *)
(*                                                                         *)
(* Returns <<granted set, did the reservation cost anybody, the head>>.     *)
(*                                                                         *)
(* NOTE THAT THE SCAN DOES NOT CONSULT `alive`, AND THAT IS THE POINT. The  *)
(* arbiter cannot tell a corpse's pending request from a live one's — the   *)
(* anchor is consulted by the REAPER, out of band, never inside a round     *)
(* (the round must stay syscall-free). So a dead process's request can be   *)
(* granted, and can become the reservation head that holds capacity idle for*)
(* a process that will never collect. That is exactly the interaction this  *)
(* module was built to check.                                               *)
(***************************************************************************)
RECURSIVE ScanRec(_, _, _, _, _)
ScanRec(sq, i, free, reserved, head) ==
    IF i > Len(sq) THEN <<{}, FALSE, head>>
    ELSE LET p     == sq[i]
             avail == IF reserved >= free THEN 0 ELSE free - reserved
         IN IF Want(p) <= avail /\ held[p] < MaxHoldOf(p)
            THEN LET rest == ScanRec(sq, i + 1, free - Want(p), reserved, head)
                 IN <<{p} \union rest[1], rest[2], rest[3]>>
            ELSE IF Reserve /\ reserved = 0
                 THEN ScanRec(sq, i + 1, free, Want(p), p)   \* p becomes the head
                 ELSE LET rest == ScanRec(sq, i + 1, free, reserved, head)
                          cost == reserved > 0 /\ Want(p) <= free
                      IN <<rest[1], rest[2] \/ cost, rest[3]>>

ScanSeq == IF ArrivalOrder THEN queue ELSE FilterSeq(SlotSeq, pend)
RoundOutcome == ScanRec(ScanSeq, 1, Capacity - HeldTotal, 0, NoProc)
Grants == RoundOutcome[1]
CostsSomebody == RoundOutcome[2]
ScanHead == RoundOutcome[3]

(***************************************************************************)
(* ACTIONS                                                                 *)
(***************************************************************************)

\* Only a LIVE process publishes. A corpse's already-published request stays
\* pending, which is the state that matters.
Publish(p) ==
    /\ p \in alive
    /\ p \notin pend
    /\ held[p] < MaxHoldOf(p)
    /\ IF p = Large THEN ~lPublished /\ lPublished' = TRUE
                    ELSE lPublished' = lPublished
    /\ pend' = pend \union {p}
    /\ queue' = Append(queue, p)
    /\ UNCHANGED <<held, using, blocked, alive, deaths, role, prop, roundHead,
                   reaped>>

\* TAKE THE ROLE AND DECIDE. The round gate: a round that would decide nothing
\* is not taken at all, so no epoch is burned while capacity is held idle.
RoundStart(p) ==
    /\ p \in alive
    /\ role = NoProc
    /\ Grants # {}
    /\ role' = p
    /\ prop' = Grants
    /\ roundHead' = ScanHead
    /\ blocked' = (blocked \/ CostsSomebody)
    /\ UNCHANGED <<held, using, pend, queue, lPublished, alive, deaths, reaped>>

\* THE LINEARISATION POINT, which MV2 proves is one CAS on one word. Note the
\* grant lands in `held` for a DEAD process too — the arbiter does not know — and
\* `using` does not follow, because a corpse consumes nothing.
RoundCommit(p) ==
    /\ role = p
    /\ p \in alive
    /\ held' = [q \in Procs |-> IF q \in prop THEN held[q] + 1 ELSE held[q]]
    /\ using' = [q \in Procs |->
                    IF q \in prop /\ q \in alive THEN using[q] + 1 ELSE using[q]]
    /\ pend' = pend \ prop
    /\ queue' = FilterSeq(queue, pend \ prop)
    /\ role' = NoProc
    /\ prop' = {}
    /\ roundHead' = NoProc
    /\ UNCHANGED <<lPublished, blocked, alive, deaths, reaped>>

\* DEATH. Restricted to the SMALL claimers, and the restriction is about what can
\* be STATED rather than about what can happen: `LargeAdmitted` is a liveness
\* property about the large claimant, and a claimant that has died is not waiting
\* for anything, so allowing it to die would make the property unachievable for an
\* uninteresting reason. The deaths that matter here are the ones that hold
\* capacity and the role while somebody else is waiting, and a small claimer holds
\* both. The large claimant dying is MV2's case (any process may die there) and it
\* is checked over 1.3M states.
\*
\* The role, if held, STAYS HELD — that is the whole problem — and the
\* proposal stays proposed. `using` goes to zero because the OS really does take
\* the memory back; `held` does not, because the ledger has no way to know. The
\* gap between them IS the leaked capacity.
Die(p) ==
    /\ p \in Smalls
    /\ p \in alive
    /\ deaths < MaxDeaths
    /\ alive' = alive \ {p}
    /\ deaths' = deaths + 1
    /\ using' = [using EXCEPT ![p] = 0]
    /\ UNCHANGED <<held, pend, queue, lPublished, blocked, role, prop,
                   roundHead, reaped>>

\* M5 CONSTRAINT 4, abstracted: a role held by a process that is demonstrably
\* gone is taken back and its proposal DISCARDED. MV2 proves the discard is
\* sound (the epoch fence invalidates every CAS the corpse could still make);
\* here it is one step, and switching it off is a required-to-fail control.
StealRole ==
    /\ Steal
    /\ role # NoProc
    /\ role \notin alive
    /\ \E q \in alive : TRUE
    /\ role' = NoProc
    /\ prop' = {}
    /\ roundHead' = NoProc
    /\ UNCHANGED <<held, using, pend, queue, lPublished, blocked, alive,
                   deaths, reaped>>

\* M7: THE REAPER. The anchor says this process is gone, so its ledger entry is
\* handed back and its pending request withdrawn. Note both halves are needed:
\* the grant is the CAPACITY and the pending request is the admission ORDER — a
\* corpse at the head of the queue holds capacity idle for nobody.
ReclaimDead(p) ==
    /\ Reclaim
    /\ p \notin alive
    /\ (held[p] > 0 \/ p \in pend)
    /\ held' = [held EXCEPT ![p] = 0]
    /\ pend' = pend \ {p}
    /\ queue' = FilterSeq(queue, pend \ {p})
    /\ reaped' = TRUE
    /\ UNCHANGED <<using, lPublished, blocked, alive, deaths, role, prop,
                   roundHead>>

\* THE MIRROR IMAGE, AND IT IS A MUTATION RATHER THAN A FEATURE: reclamation
\* fired on a holder that is ALIVE. The ledger entry goes away, the process keeps
\* consuming, and the capacity is handed to somebody else — which is precisely the
\* overcommit this whole component exists to prevent. Required to violate
\* `NoLiveReclaim` and `NoOvercommitReal`.
ReclaimLiveAct(p) ==
    /\ ReclaimLive
    /\ p \in alive
    /\ held[p] > 0
    /\ held' = [held EXCEPT ![p] = 0]
    /\ UNCHANGED <<using, pend, queue, lPublished, blocked, alive, deaths,
                   role, prop, roundHead, reaped>>

\* THE FAST PATH: the replacement arrived, so the old reservation goes back.
ReleaseReplaced(p) ==
    /\ p \in Smalls
    /\ p \in alive
    /\ held[p] = MaxHoldOf(p)
    /\ held' = [held EXCEPT ![p] = held[p] - 1]
    /\ using' = [using EXCEPT ![p] = IF using[p] > 0 THEN using[p] - 1 ELSE 0]
    /\ UNCHANGED <<pend, queue, lPublished, blocked, alive, deaths, role, prop,
                   roundHead, reaped>>

\* THE BOUNDED OVERLAP EXPIRING: still holding, replacement still pending.
ReleaseTimeout(p) ==
    /\ p \in Smalls
    /\ p \in alive
    /\ held[p] = 1
    /\ p \in pend
    /\ held' = [held EXCEPT ![p] = 0]
    /\ using' = [using EXCEPT ![p] = 0]
    /\ UNCHANGED <<pend, queue, lPublished, blocked, alive, deaths, role, prop,
                   roundHead, reaped>>

Init ==
    /\ held = [p \in Procs |-> 0]
    /\ using = [p \in Procs |-> 0]
    /\ pend = {}
    /\ queue = << >>
    /\ lPublished = FALSE
    /\ blocked = FALSE
    /\ alive = Procs
    /\ deaths = 0
    /\ role = NoProc
    /\ prop = {}
    /\ roundHead = NoProc
    /\ reaped = FALSE

Next ==
    \/ \E p \in Procs : RoundStart(p)
    \/ \E p \in Procs : RoundCommit(p)
    \/ \E p \in Procs : Publish(p)
    \/ \E p \in Procs : Die(p)
    \/ StealRole
    \/ \E p \in Procs : ReclaimDead(p)
    \/ \E p \in Procs : ReclaimLiveAct(p)
    \/ \E p \in Smalls : ReleaseReplaced(p)
    \/ \E p \in Smalls : ReleaseTimeout(p)

\* `Die` is deliberately NOT fair: dying is something that MAY happen, never
\* something the system is obliged to do. Everything that RECOVERS from a death
\* is fair, because that is the claim under test — the steal and the reaper are
\* obligations, and a green run says the obligations are enough.
Fairness ==
    /\ \A p \in Procs  : WF_vars(RoundStart(p))
    /\ \A p \in Procs  : WF_vars(RoundCommit(p))
    /\ \A p \in Procs  : WF_vars(Publish(p))
    /\ WF_vars(StealRole)
    /\ \A p \in Procs  : WF_vars(ReclaimDead(p))
    /\ \A p \in Smalls : WF_vars(ReleaseReplaced(p))
    /\ \A p \in Smalls : WF_vars(ReleaseTimeout(p))

Spec == Init /\ [][Next]_vars /\ Fairness

(***************************************************************************)
(* SAFETY — checked in EVERY configuration, mutated ones included. A control*)
(* that starved the large claim by overcommitting would prove nothing.      *)
(***************************************************************************)
TypeOK ==
    /\ held \in [Procs -> 0..MaxHold]
    /\ using \in [Procs -> 0..MaxHold]
    /\ pend \subseteq Procs
    /\ alive \subseteq Procs
    /\ deaths \in 0..MaxDeaths
    /\ prop \subseteq Procs
    /\ lPublished \in BOOLEAN
    /\ blocked \in BOOLEAN
    /\ reaped \in BOOLEAN
    /\ \A p \in Procs : held[p] <= MaxHoldOf(p)

\* SM-6's precondition, on the LEDGER: whatever the arbiter believes is out never
\* exceeds the machine. This holds under every mutation here, including the ones
\* that leak and the one that reclaims a live holder — which is exactly why it is
\* not sufficient on its own and why `using` exists.
NoOvercommitLedger == HeldTotal <= Capacity

\* THE REAL ONE. What is actually being consumed never exceeds the machine.
\* VIOLATED by `ReclaimLive`: a live holder's entry is cleared, the capacity is
\* granted to somebody else, and both are using it.
NoOvercommitReal == UsingTotal <= Capacity

\* THE SAFETY RULE OF RECLAMATION, stated directly: no live process ever has its
\* ledger entry taken away behind its back. For a live process the ledger and
\* reality move together at every action, so any divergence is a false-positive
\* reclaim. VIOLATED by `ReclaimLive`, and by nothing else.
NoLiveReclaim == \A p \in alive : held[p] = using[p]

QueueIsPending ==
    /\ \A i \in 1..Len(queue) : queue[i] \in pend
    /\ \A p \in pend : \E i \in 1..Len(queue) : queue[i] = p
    /\ Len(queue) = Cardinality(pend)

\* The role is only ever held by one process, and a proposal only exists while a
\* round does. A steal that left a proposal behind would be a half-applied round
\* nobody owns.
RoleCoherent == (role = NoProc) => (prop = {} /\ roundHead = NoProc)

(***************************************************************************)
(* LIVENESS — the properties M7 exists to establish.                        *)
(***************************************************************************)

\* SM-4 STILL HOLDS WITH DEATHS IN THE PICTURE. Violated by `Steal = FALSE` (a
\* combiner that died mid-round while a reservation stood wedges admission for
\* everybody) and by `Reclaim = FALSE` (a dead claimer's capacity is withheld
\* forever, so the large claim never fits). Those are SM-5 and SM-6 respectively,
\* each observed through the property they destroy.
LargeAdmitted == <>(held[Large] > 0)

\* ...AND THE CURE IS NOT PERMANENT UNDERUTILIZATION.
SmallsKeepGoing == []<>(\E p \in Smalls : held[p] > 0)

\* NO PERMANENTLY LEAKED CAPACITY, as a temporal property rather than as a
\* snapshot: it is always the case that eventually the ledger agrees with reality.
\* This is SM-6 stated at its most direct, and `Reclaim = FALSE` violates it.
NoLeakedCapacity == []<>(HeldTotal = UsingTotal)

(***************************************************************************)
(* NON-VACUITY PROBES — required to FAIL, which is how the green run above  *)
(* is shown to have exercised the interaction rather than merely tolerated  *)
(* it.                                                                      *)
(***************************************************************************)

\* THE ONE M6 SAID NEITHER MODEL COULD SEE: a combiner dead in the middle of its
\* round, while that round's scan had named a RESERVATION HEAD. If this invariant
\* holds, the configuration never reached the state this module was built for.
NoDeadCombinerWithHead ==
    ~(role # NoProc /\ role \notin alive /\ roundHead # NoProc)

\* ...and that the reaper is ever exercised at all.
NeverReaped == ~reaped
================================================================================
