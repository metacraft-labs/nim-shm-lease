## `nim-shm-lease` **M5** — the FLAT-COMBINING ARBITER, with grant-then-wake.
##
## Design authority: `reprobuild-specs/RunQuota-Shared-Memory-Transport.md`
## §"3. Flat combining puts the policy in shared memory" and §"4. Structural crash
## safety is where the real design work is"; layout in
## `reprobuild-specs/RunQuota-Shared-Memory-Structures.md`; campaign milestone
## `reprobuild-specs/RunQuota-Observation-Store.milestones.org` ** M5, whose gate
## lives in `tests/test_shm_lease_arbiter_multiprocess.nim`.
##
## **THIS PROTOCOL WAS MODELLED BEFORE IT WAS WRITTEN.** `verification/tla/
## shm_lease_combine.tla` (MV2) is a TLA+ model of exactly this arbiter — role
## acquisition, the round, publication, release, the STEAL path, and death at
## every program counter — and it is the specification this module implements, not
## background reading. Every structural decision below cites the configuration that
## fails without it. Where a reading of this code and the model disagree, the model
## is right and this comment is the bug.
##
## ===========================================================================
## THE FOUR CONSTRAINTS MV2 DERIVED, AND WHERE EACH ONE LIVES HERE
## ===========================================================================
##
## 1. **Commit and role transfer resolve in a SINGLE CAS on a SINGLE word.**
##    The role word (`LhOffReserved2`) is `[owner, epoch, committed]`; `commitRound`
##    below is one `CAS(role, [me, e, false] -> [me, e, true])`. A combiner that
##    was stolen from CANNOT execute it, because the stealer already replaced the
##    word. The alternative — the role word as a lock and the commit as a monotone
##    store on the sequence word — is `shm_lease_combine_unfenced_MC.cfg`, which
##    violates `NeverBoth` on a 13-state trace: a descheduled combiner is stolen
##    from, resumed, and commits a round the stealer had already discarded.
##    MV2 states the necessary condition as a LAYOUT constraint: either reserved
##    word may carry it, but the commit must not land in a word the steal did not
##    touch. This module puts the flag in the role word (bit 48).
##
## 2. **The budget word is a CACHE derived from the stamped ledger, never
##    incrementally decremented.** `refreshBudgetCache` recomputes
##    `capacity - sum of effective grants` and stores it; nothing subtracts from it
##    per grant, and no decision is ever made by reading it. The mutation is
##    `shm_lease_combine_budget_MC.cfg`, which violates `BudgetExact` on a 26-state
##    trace: a decrement and its epoch stamp are two words, no CAS spans them, and
##    a round discarded between them destroys capacity for the lifetime of the
##    segment. `amIncrementalBudget` below reproduces that in code, deliberately.
##
## 3. **BOTH per-slot serialisation AND an epoch carried in the published value.**
##    Serialisation ("may I grant into this slot?") is `raiseNeeded`, which refuses
##    to restamp an entry that is effective and not yet superseded
##    (`shm_lease_combine_noserial_MC.cfg`, `NoDoubleGrant` at 32 states). The
##    published value is the COMBINE EPOCH ("did the corpse already publish
##    this?"), not `value + 1`, so a stealer republishing a dead combiner's answer
##    writes the same word twice and the waiter's word does not move
##    (`shm_lease_combine_counter_MC.cfg`, `NoDoubleGrant` at 30 states). Neither
##    substitutes for the other; each has its own failing configuration, and
##    `amNoSerialise` / `amCounterPublish` reproduce them here.
##
## 4. **The steal detector needs the anchor check AND a bounded timeout.**
##    `stealVerdict` fires immediately when the role owner's boot+pid+start-time
##    anchor says it is gone, and otherwise only after the role word has been
##    observed UNCHANGED for `stealAfterNs`. MV2 proved the division of labour:
##    with an arbitrarily wrong detector (`StealFromLive = TRUE`) every safety
##    invariant still holds over 1,325,806 states — the epoch stamps buy safety —
##    while `shm_lease_combine_livelock_MC.cfg` violates `EpochBoundNotBinding`,
##    i.e. an unsound detector costs LIVENESS through unbounded role churn. So an
##    early fire is a wasted round, never a corruption, and the anchor check is
##    what stops the churn.
##
## Plus the design rule MV2 found while debugging its own drafts, and it is not
## obvious: **the recovery predicate and the waiter's wake predicate must be the
## SAME predicate — the VALUE word.** `workPending` (does this round have anything
## to do?) and `answerArrived` (may this waiter stop waiting?) are both
## `value != baseVal` on the same u32. Testing the ledger instead deadlocks the
## model in 157 states (a combiner that decided everything and committed nothing
## leaves no survivor able to see work); testing the payload deadlocks it in 711
## (a combiner that died between the payload store and the value bump leaves a slot
## whose waiter was told nothing).
##
## ===========================================================================
## THE PROTOCOL
## ===========================================================================
##
## ROLE WORD (`LhOffReserved2`, one u64, CAS-mutated):
##   `[epoch:0..31][ownerSlot:32..47][committed:48]`. The epoch increases on EVERY
##   acquisition, clean or stolen, because it is the fence: after it, the previous
##   owner's ledger CASes — which all carry its own epoch as the expected value —
##   can no longer match. The owner is a SLOT INDEX rather than a pid, and the
##   slot carries the owner's boot+pid+start-time anchor, so the identity the steal
##   detector consults is the full three-part anchor while the role word stays one
##   word.
##
## COMBINE SEQUENCE (`LhOffReserved3`, one u64, MONOTONE): the highest COMMITTED
##   epoch. A ledger entry is EFFECTIVE iff its stamp is `<= cseq`, so this single
##   word is both the durable record of "was this round applied" that the transport
##   spec asks for and the switch that makes a whole round take effect at once.
##
## PER-SLOT LEDGER ENTRY (`RqOffLedger`, one u64): `[epoch:0..31][decision:32..39]`.
##   EVERY mutation of it is a CAS whose expected value carries an epoch, which is
##   what makes a stale combiner's write FAIL rather than corrupt. The GRANTED
##   AMOUNT is not stored here: it is the slot's `want`, which its owner writes
##   before the request is published and does not touch again until the outcome has
##   been collected (`publishRequest` refuses while a grant is outstanding). So the
##   decision is one atomic word and the amount is an immutable word — not two
##   mutable words, which is the shape constraint 2 forbids.
##
## A ROUND, in order — every step one atomic word write:
##   1. `repairSequence`  — public and idempotent; MUST precede an acquisition, or
##      a steal would erase the only record that the previous round committed.
##   2. `tryAcquire` / steal — CAS the role word to `[me, epoch+1, false]`.
##   3. raise pass  — CAS every NON-EFFECTIVE entry with an older stamp up to my
##      epoch, decision cleared. This is BOTH the discard of a half-applied round
##      AND the fence that invalidates the previous owner's proposals.
##   4. scan        — per pending slot, in ASCENDING SLOT ORDER, decide against the
##      effective ledger PLUS this round's own proposals.
##   5. commit      — one CAS on the role word. THE LINEARISATION POINT.
##   6. sequence    — advance `cseq` to my epoch (the same public repair).
##   7. refresh     — recompute the budget cache from the effective ledger.
##   8. publish     — per effective entry: payload, then the value, then the wake.
##      This is ALSO the exit taken by a round that decided nothing (step 4b): the
##      entries a dead combiner committed and never published are effective, and
##      republishing them is the recovery constraint 3's epoch-in-the-value exists
##      for. A round that skips it because it stamped nothing is lossy.
##   9. release     — CAS the role word back to unowned.
##
## ===========================================================================
## WHAT THIS MODULE IS NOT, AND THE TWO PLACES IT LEAVES THE MODEL
## ===========================================================================
##
## **ANTI-STARVATION (M6) IS IMPLEMENTED, AND IT IS TWO RULES.** The scan used to
## be ascending slot order, first fit, which starves a large request behind a
## stream of small ones — `RunQuota-Shared-Memory-Transport.md` §2, and the reason
## that spec calls this a correctness gate rather than a fairness preference.
## What replaces it:
##
##   * **ORDER — the scan runs in ARRIVAL ORDER**, ascending ticket
##     (`RqOffTicket`, a monotonic-clock stamp written by `publishRequest`), slot
##     index breaking a tie. Slot index is a placement accident; arrival is the
##     thing a starving requester actually accumulates.
##   * **RESERVATION — the FIRST request the scan cannot grant HOLDS ITS CAPACITY
##     IDLE.** It becomes the round's single reservation head: every later request
##     is decided against `capacity - held - proposed - reserved`, so a small claim
##     arriving behind a blocked large one CANNOT take the capacity the large one
##     is waiting for. This is the "hold capacity idle for a large pending claim
##     instead of spending it on a small one" the transport spec §2 asks for.
##
## **AT MOST ONE HEAD PER ROUND, AND THAT BOUND IS THE WHOLE ANTI-DEADLOCK
## ARGUMENT.** Reserving for every blocked request would let the reservations sum
## past the capacity and stop admission dead — the cure becoming a worse disease.
## One head means the reserved amount is at most one request's `want`, and the
## capacity beyond it stays available to everybody: measured in the M6 gate as
## small claims continuing to be granted while the head waits.
##
## WHY THIS BOUNDS THE WAIT, stated as the argument it is rather than as a claim.
## Let R be the head at time t0. From t0 on, every grant satisfies
## `want <= capacity - held - reserved`, so no grant made after t0 pushes `held`
## above `capacity - want(R)`. `held` otherwise only DECREASES (a release). So
## `held` is monotonically driven to `<= capacity - want(R)`, at which point R
## fits and is granted — R is scanned before every request that arrived after it,
## so no younger request can take that capacity first. The wait is therefore
## bounded by the time the grants outstanding at t0 take to be released, plus one
## round, plus the bounded set of requests OLDER than R. Admission is ONLINE —
## future arrivals are unknown — so optimal packing is unattainable in principle;
## bounded waiting and no overcommit are the achievable goals and are all that is
## claimed here.
##
## THE IDLE HOLD IS BOUNDED BY CONSTRUCTION, WHICH IS THE OTHER HALF OF THE GATE.
## A reservation exists only while its head does not fit `capacity - held`, i.e.
## only while another slot's LIVE grant covers the capacity it needs. It ends when
## the head is granted. A policy that reserved permanently would be its own
## failure mode, so the gate asserts the head is admitted within a bounded, stated
## time and that small-claim throughput RECOVERS afterwards.
##
## THREE NEGATIVE CONTROLS, one per mechanism plus the pair (see
## `ArbiterMutation`): `amFirstFit` is M5's policy exactly, `amSlotOrder` keeps the
## reservation but hands it to the wrong request, and `amNoReserve` keeps arrival
## order but holds nothing idle. All three STARVE the large claim in the M6 gate,
## structurally rather than probabilistically.
##
## **NO RECLAMATION (M7).** A client that dies holding a grant leaves the grant in
## the ledger and its capacity taken. MV2 excludes reclamation for the same reason.
##
## **DEPARTURE 1 — a request that does not fit stays PENDING; the model REFUSES
## it.** MV2's `CDecide` decides every pending request in the round, grant or
## refuse, and `CScanDone` cannot fire until it has. This module refuses only a
## request that can NEVER fit (`want` exceeds capacity outright) and otherwise
## leaves a non-fitting request pending for a later round. That is what makes a
## "waiter" exist at all — the gate's clause (a) is about a release freeing
## capacity for several WAITERS — and it moves the request from the model's
## `AllSettled` liveness into M6's bounded-waiting property, which is not checked
## anywhere yet. No safety invariant MV2 states mentions refusals
## (`NoDoubleGrant`, `GrantCoherent`, `NoOvercommit`, `BudgetExact`, `NeverBoth`,
## `GrantedEqualsTaken`, `NoDiscardOfCollected` are all about grants and stamps),
## so the departure is a liveness-scope change and is recorded as one. M6 has to
## extend the model here anyway, because it must model a requeued request.
##
##   **AND IT HAS AN EPOCH CONSEQUENCE, WHICH IS NOT THE SAME THING AS A WAITING
##   ONE.** A pending request keeps `workPending` true, and `workPending` is the
##   only thing standing between a caller's `tryCombine` loop and an unbounded
##   sequence of rounds that decide nothing. Measured before this was fixed: a
##   board carrying one permanently-unfittable request committed ONE FULL ROUND
##   PER CALL forever — ten calls, ten committed rounds, `grants == 0` in each,
##   the role-word epoch 1 -> 11. MV2 carries `EpochBoundNotBinding` as an
##   invariant of EVERY green configuration and treats unbounded epoch churn as
##   Finding 5's liveness defect, so this was the implementation reproducing, in
##   code, exactly the defect the model rules out — and it was the direct cause of
##   the gate's single-combiner arm filling its 1024-round log with empty rounds
##   and then stranding its peers. `decidableWork` below closes it: a round is not
##   even attempted unless some pending request can be granted, permanently
##   refused, or PUBLISHED right now, and a round whose scan decided nothing
##   publishes whatever is outstanding and then abandons the role without
##   committing. That bounds the do-nothing rounds; it does NOT bound how long a
##   request waits, which remains M6's property.
##
##   **THE "OR PUBLISHED" IS NOT DECORATION — WITHOUT IT THIS GATE DEADLOCKS, AND
##   IT DID.** The gate reads the effective ledger, and the argument that it
##   therefore cannot hide work holds only for an UNCOMMITTED round. A combiner
##   that commits and then dies before step 8 leaves an entry that IS effective and
##   IS counted as held, so the slot's own grant stops the slot's own request from
##   fitting and the gate reports "nothing to do" about exactly the work that needs
##   doing. Both new gates blocked the republication that is this protocol's
##   designed recovery — measured: 199 rounds of `cbNoWork` where the pre-gate code
##   recovered in one. See `decidableWork` and step 4b for the two fixes and the
##   correct statement of what the predicate guarantees.
##
## **DEPARTURE 2 — `releaseGrant` has no counterpart in the model at all, and it
## is a WRITER THE MODEL CANNOT SEE.** MV2 never gives capacity back; a grant,
## once effective, stays effective forever. A release here is one CAS on the
## owner's own ledger entry, `[e, grant]` -> `[e, released]`.
##
##   This is not "orthogonal to" MV2's atomisation argument — it is OUTSIDE it, and
##   it is the one place in this module where that is true. MV2's defence is that
##   every `res[q]` mutation is a CAS whose expected value carries an EPOCH, and
##   that every acquisition increments that epoch, so a stale writer's CAS cannot
##   match. **The release CAS carries the OLD epoch as its expected value and
##   therefore succeeds regardless of who holds the role**, at whatever epoch:
##   measured succeeding while another client held the role uncommitted at a
##   strictly higher epoch. It is not fenced, and no model checks it.
##
##   THE SAFETY ARGUMENT, WRITTEN OUT — AND IT IS UNCHECKED. No overcommit and no
##   double grant can follow from it, for three reasons that must all hold:
##     1. A release only ever moves an entry from `ldGrant` to `ldReleased`, and
##        `isEffectiveGrant` is false for `ldReleased` at every stamp. So the
##        effective sum can only DECREASE; a release can never manufacture
##        capacity, whatever epoch it lands at.
##     2. A released entry can never be raised back into a live grant. The raise
##        pass writes `ldNone`, decisions are stamped with a STRICTLY INCREASING
##        epoch, and `publishRequest` refuses a slot whose entry is still
##        `ldGrant` — so the ledger cannot ABA back to the grant that was
##        released, and `heldVec`'s re-validation (below) sees a released entry as
##        a CHANGED entry and skips it.
##     3. The amount is `want`, and `publishRequest` rewrites `want` only AFTER it
##        has cleared the ledger decision — so the window in which a stale reader
##        could pair an old decision with a new amount is closed by `heldVec`'s
##        re-read of the entry, not by the epoch fence.
##   **None of that is model-checked.** M7 wants a model with a release action
##   before it builds reclamation on this entry, and M6 must extend the model for
##   Departure 1 anyway. Note that the ONE real defect M5's gate found — the
##   two-load `heldVec` read — was in exactly this seam.
##
##   What the departure also means is that a round's arithmetic is not a function
##   of the epoch alone, which is why `CombineRound` records the held-set it
##   actually scanned: the gate's reference implementation replays THAT, and would
##   catch a grant appearing in a round's held-set that no round ever made.
##
## ALLOCATION-FREE AND SYSCALL-FREE, as the milestone requires. A round touches
## `slotCount <= MaxRequestSlots` fixed-size records through stack locals; there is
## no `seq`, no `string`, and no allocation on the path. The ONLY syscall a round
## can make is the wake of a waiter it has just answered, and M3's waker fast path
## skips even that when the waiter is not parked. The anchor check, which does cost
## a `kill(pid, 0)`, is deliberately OUTSIDE the round: it runs only when the role
## is busy AND the bounded timeout has already expired.

# `hooks` and `waitword` are imported INSIDE the supported arm rather than here,
# exactly as `waitword` imports `hooks`: the portable arm does not use them, and
# `just lint`'s `nim check --os:windows` pass exists precisely to keep that arm
# free of imports it does not need.
import ./packed
import ./anchor

type ShmBase = ptr UncheckedArray[byte]
  ## The mapped base in THIS process. Deliberately NOT exported, for the reason
  ## `waitword` gives for the same decision: `shm_lease` already exports a
  ## structurally identical `ShmBase`, and a second exported one would make the
  ## name ambiguous for any module importing both. They are the same type — an
  ## alias, not a distinct — so callers pass `shm_lease`'s without a cast.

const
  arbiterSupported* = defined(linux) or defined(macosx)
    ## False wherever `mmap(MAP_SHARED)` and the wait primitive are absent; every
    ## operation then reports unavailable, exactly as M2/M3/M4 do.

  MaxRequestSlots* = 64
    ## Upper bound on request slots in one lease segment. A BOUND EXISTS so a
    ## combine round can snapshot the ledger into stack locals — "bounded and
    ## allocation-free" is a milestone requirement, not a preference — and so a
    ## corrupt header can never make an attacher compute a nonsense mapping.
    ## It is exactly 64 so a round's held-set is ONE `uint64` bitmask; raising it
    ## means giving `CombineRound.heldMask` a different representation, which is
    ## why the two numbers are stated together rather than left to drift apart.

  # --- one request slot: exactly 64 bytes, offsets only ---------------------
  #
  # The first eight bytes are LAID OUT AS A WAIT WORD ON PURPOSE: `value` at +0
  # and `waiters` at +4 are exactly `WwOffValue` / `WwOffWaiters`, so M3's
  # `waitOn` / `wakeOne` / `prefaultWaitWord` operate on `(base, slotOffset)`
  # verbatim. Each waiter therefore has its OWN wait word, which is the rule M3
  # established ("a shared wait word reintroduces the herd by construction").
  RqOffValue* = 0        ## u32 — the wait word. Its value IS THE COMBINE EPOCH of
                         ## the published answer. Never `value + 1` (constraint 3).
  RqOffWaiters* = 4      ## u32 — M3's waiter count; what gates the wake syscall
  RqOffState* = 8        ## u64 — `[baseVal:0..31][gen:32..55][state:56..63]`
  RqOffWant* = 16        ## u64 — packed `ResourceVec`, written BEFORE the state is
                         ## published and immutable until the outcome is collected
  RqOffLedger* = 24      ## u64 — `[epoch:0..31][decision:32..39]`, CAS-only
  RqOffOutcome* = 32     ## u64 — the PUBLISHED payload: the same encoding, so the
                         ## epoch inside it is the tag that must equal the value
                         ## the waiter observed
  RqOffOwnerPid* = 40    ## u64 — anchor: the client that registered this slot
  RqOffOwnerStart* = 48  ## u64 — anchor: its start time (defeats pid reuse)
  RqOffTicket* = 56      ## u64 — **M6**: the ARRIVAL TICKET, a monotonic-clock
                         ## stamp written by `publishRequest` BEFORE the state is
                         ## released. It is what makes the scan order arrival
                         ## order rather than slot order, and therefore what makes
                         ## the reservation head the OLDEST blocked request.
                         ##
                         ## This word was `RqOffReserved`, annotated "M7:
                         ## reservation deadline". M6 takes it, and M7 is not left
                         ## short: a deadline is `ticket + policy timeout`, so the
                         ## arrival stamp is the better half of what that note
                         ## wanted. No offset moved and no field changed size, so
                         ## a segment created without request slots is still
                         ## byte-for-byte M2's and the format version does not
                         ## move.
                         ##
                         ## CLOCK, NOT COUNTER, and that is a choice with a reason:
                         ## a global ticket counter needs a header word (the
                         ## 128-byte header has none free) and adds a contended
                         ## fetch-add to every publish. `CLOCK_MONOTONIC` is
                         ## system-wide on both supported platforms, so stamps
                         ## from different processes are comparable, and the tie
                         ## break on slot index makes an exact collision
                         ## deterministic rather than merely unlikely.
  RqOffReserved* = RqOffTicket
                         ## DEPRECATED alias for the word above, kept so a reader
                         ## coming from M5's layout notes lands on the rename.
  RequestSlotSize* = 64

  RoleNoOwner* = 0xFFFF'u16
    ## The role word's "unowned" owner field.

  DefaultStealAfterNs* = 250_000_000'i64
    ## The bounded timeout half of constraint 4. A wrongly early fire costs a
    ## wasted round and never a corruption (MV2's 1.3M-state run with a maximally
    ## wrong detector), so this number is a tuning parameter and M7 owns choosing
    ## it by measurement. It is deliberately LONG relative to a round, so the
    ## common path is a clean acquisition rather than a steal.

  DefaultAnchorProbeAfterNs* = 30_000_000'i64
    ## How long the role word must have been unchanged before the ANCHOR half of
    ## the detector spends a `kill(pid, 0)` on it. Shorter than the steal timeout,
    ## because a holder that is demonstrably gone should be recovered from sooner
    ## than one that is merely slow — and longer than a round, so the common path
    ## never pays for it.

type
  LedgerDecision* = enum
    ## The per-slot outcome. `ldReleased` is the one MV2 does not have — see
    ## DEPARTURE 2 in the module docstring.
    ldNone = 0      ## no decision stamped at this epoch
    ldGrant = 1     ## granted; EFFECTIVE once `epoch <= cseq`, and that is what
                    ## "this slot holds capacity" means
    ldRefuse = 2    ## refused permanently (the request cannot fit in the capacity
                    ## even when the machine is idle)
    ldReleased = 3  ## the owner gave a granted reservation back

  RequestState* = enum
    rqFree = 0      ## no client owns this slot
    rqIdle = 1      ## registered, nothing outstanding
    rqPending = 2   ## a request is published and awaiting an answer
    rqHolding = 3   ## a grant has been collected and the capacity is HELD

  ArbiterMutation* = enum
    ## **TEST-ONLY NEGATIVE CONTROLS, and they exist for the same reason
    ## `waitword`'s `wsProcessLocal` does: a rule that has never been seen to fail
    ## has not been shown to be load-bearing.** Each one turns off exactly one of
    ## the mechanisms MV2 proved necessary, at exactly one site, and each has a
    ## required-to-fail TLC configuration whose failure it reproduces in code.
    ## The shipping path passes `{}` and every one of these is off.
    amBlindFit          ## the fit test ignores THIS round's own proposals.
                        ## `CountOwnProposals = FALSE`,
                        ## `shm_lease_combine_fit_MC.cfg` -> OVERCOMMIT.
    amIncrementalBudget ## decrement the budget word per grant instead of
                        ## recomputing it. `BudgetIsCache = FALSE`,
                        ## `shm_lease_combine_budget_MC.cfg` -> `BudgetExact`.
    amCounterPublish    ## publish `value + 1` instead of the combine epoch, which
                        ## is what `publishGrant` does today.
                        ## `IdempotentPublish = FALSE`,
                        ## `shm_lease_combine_counter_MC.cfg` -> `NoDoubleGrant`.
    amNoSerialise       ## let the raise pass restamp EFFECTIVE entries too.
                        ## `SerialisePerSlot = FALSE`,
                        ## `shm_lease_combine_noserial_MC.cfg` -> `NoDoubleGrant`.
    amFirstFit          ## **M6 CONTROL — M5's POLICY, EXACTLY.** Ascending slot
                        ## order, first fit, no reservation. This is the "naive
                        ## first-come-if-it-fits" admission
                        ## `RunQuota-Shared-Memory-Transport.md` §2 says starves
                        ## large claims, and the M6 gate requires it to do so.
                        ## `Reserve = FALSE` + `ArrivalOrder = FALSE`,
                        ## `shm_lease_admit_firstfit_MC.cfg` -> `LargeAdmitted`.
    amSlotOrder         ## **M6 CONTROL — the RESERVATION, given to the WRONG
                        ## REQUEST.** The reservation stays on but the scan runs
                        ## in slot order, so the head is the lowest-indexed
                        ## blocked request rather than the oldest. It isolates the
                        ## ARRIVAL ORDER as load-bearing: a large claim at a high
                        ## slot index is starved even though capacity is being
                        ## held idle — for somebody else.
                        ## `ArrivalOrder = FALSE`,
                        ## `shm_lease_admit_slotorder_MC.cfg` -> `LargeAdmitted`.
    amNoReserve         ## **M6 CONTROL — ARRIVAL ORDER WITHOUT THE RESERVATION.**
                        ## The scan is oldest-first but nothing is held idle, so
                        ## capacity freed by a release is spent on whichever
                        ## request fits. It isolates the RESERVATION as
                        ## load-bearing, and it is the more interesting of the
                        ## three: FIFO ordering alone looks like an anti-starvation
                        ## policy and is not one.
                        ## `Reserve = FALSE`,
                        ## `shm_lease_admit_noreserve_MC.cfg` -> `LargeAdmitted`.

  ArbiterMutations* = set[ArbiterMutation]

  CombineStatus* = enum
    ## Why a combine attempt ended. NONE of these blocks: a client that does not
    ## get the role neither spins nor parks inside this call (SM-8).
    cbCommitted     ## a round ran and COMMITTED
    cbNoWork        ## nothing was pending, or nothing pending could be decided
                    ## against the capacity that is currently free; the epoch was
                    ## NOT burned and no round committed
    cbRoleBusy      ## someone else holds the role and is not (yet) stealable
    cbLostRace      ## the acquisition CAS was lost to another client
    cbFenced        ## this combiner was STOLEN FROM mid-round and abandoned it
    cbUnavailable   ## the view is not attached / the platform has no primitive

  DecisionKind* = enum
    dkGrant         ## granted in this round
    dkPending       ## did not fit; LEFT PENDING for a later round (DEPARTURE 1)
    dkRefuse        ## can never fit; refused permanently

  DecisionRec* = object
    ## One decision, in the order the round took it. The round records these so
    ## the gate's single-threaded REFERENCE IMPLEMENTATION can replay the same
    ## sequence and assert the decisions are identical.
    slot*: uint16
    gen*: uint32          ## which request in that slot's history this was
    want*: uint64         ## packed
    kind*: DecisionKind
    ticket*: uint64       ## **M6**: the arrival stamp this decision was ordered
                          ## by. Recorded so the gate's reference implementation
                          ## can check the ORDER as well as the outcomes — a scan
                          ## that silently reverted to slot order would still make
                          ## individually defensible decisions.
    reserved*: bool       ## **M6**: this decision left the request pending AND
                          ## made it the round's reservation head.

  CombineRound* = object
    ## The outcome record of one combine attempt. A plain object with fixed-size
    ## arrays: filling it allocates nothing.
    status*: CombineStatus
    epoch*: uint32
    owner*: uint16
    stolen*: bool
    heldMask*: uint64     ## which slots held an EFFECTIVE grant when the scan
                          ## read the ledger. The reference replay checks that no
                          ## slot appears here that it never granted.
    held*: ResourceVec    ## and what that summed to, by this round's arithmetic
    decisions*: array[MaxRequestSlots, DecisionRec]
    decisionCount*: int
    grants*: int          ## decisions of kind `dkGrant` in this round
    reserveSlot*: int     ## **M6**: the slot this round held capacity idle for,
                          ## or -1. THE IDLE HOLD, per round.
    reservedVec*: ResourceVec  ## ...and how much was held idle for it.
    reserveBlocked*: int  ## **M6**: decisions this round left pending that WOULD
                          ## HAVE FIT the capacity that was genuinely free, and
                          ## were refused solely because the head's reservation
                          ## covered it. This is the idle hold OBSERVED rather
                          ## than inferred: zero of these means the reservation
                          ## never cost anything, i.e. it was never tested.
    published*: int       ## answers whose value word this round actually moved
    wakes*: int           ## wake calls issued (a wake NEVER happens without a
                          ## publication immediately before it, in this same loop)
    wakeSyscalls*: int    ## of those, the ones that entered the kernel

  AnswerStatus* = enum
    ansNone         ## nothing published yet for the outstanding request
    ansGranted      ## the request was granted; the capacity is now HELD
    ansRefused      ## the request was refused permanently
    ansIncoherent   ## THE DETECTOR: the payload's tag is not the value that was
                    ## observed, i.e. a grant meant for another request was read.
                    ## This is `GrantCoherent` as a runtime check.
    ansUnavailable

  PublishStatus* = enum
    psPublished
    psHoldsGrant    ## THE PRECONDITION, ENFORCED: a slot may not carry a second
                    ## request while a grant is outstanding on it
    psNotIdle
    psInvalidVec
    psUnavailable

  ArbiterStats* = object
    ## Per-process observability. A CROSS-CHECK on the shared state, not the proof.
    roundsCommitted*: uint64
    roundsNoWork*: uint64
    roundsBusy*: uint64
    roundsLost*: uint64
    roundsFenced*: uint64
    steals*: uint64
    anchorProbes*: uint64      ## how often the anchor half of the detector ran
    anchorSteals*: uint64      ## steals the ANCHOR authorised (the holder was
                               ## demonstrably gone), as opposed to the timeout
    grantDecisions*: uint64   ## grants DECIDED by this process's COMMITTED
                               ## rounds. SM-3's denominator: a republication of
                               ## an older round's answer adds a wake WITHOUT
                               ## adding a grant here, which is precisely how
                               ## `amCounterPublish` shows up as `wakes > grants`.
    refuseDecisions*: uint64   ## permanent refusals decided, likewise
    reservations*: uint64      ## **M6**: rounds that named a reservation head,
                               ## i.e. rounds in which capacity was HELD IDLE for
                               ## a request that did not fit.
    reserveBlocks*: uint64     ## **M6**: the cost of those reservations, counted
                               ## — decisions left pending that would otherwise
                               ## have been granted. A policy that never pays this
                               ## never reserves anything.
    grantsPublished*: uint64   ## grants whose value word this process moved
    answersPublished*: uint64  ## answers (grant or refusal) it moved
    wakeCalls*: uint64         ## wake calls issued. SM-3 is `wakes <= grants`.
    wakeSyscalls*: uint64      ## of those, the ones that entered the kernel
    parks*: uint64             ## waits that entered the kernel
    parksWokenWithAnswer*: uint64 ## parks that returned from a wake WITH THE WAIT
                               ## WORD MOVED — i.e. woken by this protocol rather
                               ## than by the kernel's own discretion. The
                               ## denominator clause (b) is measured against.
    parksWokenIncomplete*: uint64 ## THE GATE'S CLAUSE (b), AS A CODE PROPERTY.
                               ## Of the parks above — the ones this protocol
                               ## really did wake — the ones that did NOT find a
                               ## complete, coherent answer waiting. Grant-then-
                               ## wake is the payload store, then the value CAS,
                               ## then the wake, so a woken waiter always finds
                               ## the payload its value word is tagged with, and
                               ## this MUST stay ZERO. Publishing the value before
                               ## its payload — or waking before either — makes it
                               ## fire. Nothing the KERNEL is permitted to do can.
    parksSpurious*: uint64     ## returned from `wrWoken` with the wait word
                               ## UNCHANGED. **This is a kernel-permitted spurious
                               ## wakeup, not a protocol defect**, and it is
                               ## REPORTED rather than asserted zero: `waitword`
                               ## documents the same tolerance, and a park loop
                               ## that re-validates after every wake is correct
                               ## precisely because it does not assume otherwise.
                               ## Asserting it zero would be asserting a property
                               ## of the kernel's wait primitive.
    parksTimedOut*: uint64
    fastAnswers*: uint64       ## the answer was already there; no park at all
    requests*: uint64
    grantsCollected*: uint64
    refusalsCollected*: uint64
    releases*: uint64

  ArbiterView* = object
    ## An attached view of the arbiter's state inside a lease segment. OFFSETS
    ## ONLY — nothing here is written into the segment, so every process may map
    ## the segment at its own base (SM-7).
    available*: bool
    base*: ShmBase
    roleOff*: int          ## `LhOffReserved2`
    seqOff*: int           ## `LhOffReserved3`
    reclaimOff*: int       ## **M7**: `LhOffReserved1`, the RECLAMATION EPOCH — a
                           ## monotone count of reclaimed slots. An OFFSET like
                           ## every other field here, and the word M2 reserved
                           ## with the note "M7: reclamation epoch"; zero means
                           ## the view was bound without one, which is how the
                           ## portable arm and a hand-built view degrade.
    remainingOff*: int     ## the managed budget word (a CACHE, constraint 2)
    slotsOff*: int
    slotCount*: int
    capacity*: ResourceVec ## immutable after publish; read once at bind time
    boot*: uint64

  ArbiterClient* = object
    ## One client's handle: its view, its slot, and the LOCAL state the steal
    ## detector needs. `lastRoleWord` / `lastRoleNs` are deliberately process-local
    ## — a timeout observed by one process says nothing to another, and putting it
    ## in shared memory would invite exactly that mistake.
    view*: ArbiterView
    slot*: int
    gen*: uint32
    baseVal*: uint32
    lastRoleWord*: uint64
    lastRoleNs*: int64
    lastAnchorNs*: int64
    stealAfterNs*: int64
    anchorProbeAfterNs*: int64
    mutations*: ArbiterMutations
    stats*: ArbiterStats

# ---------------------------------------------------------------------------
# WORD ENCODINGS — pure, portable, and testable on every platform.
# ---------------------------------------------------------------------------

func roleWord*(owner: uint16; epoch: uint32; committed: bool): uint64 {.inline.} =
  ## `[epoch:0..31][ownerSlot:32..47][committed:48]`. One word, so the acquisition
  ## CAS and the commit CAS contend for the same bytes — constraint 1.
  uint64(epoch) or (uint64(owner) shl 32) or (if committed: 1'u64 shl 48 else: 0'u64)

func roleEpoch*(w: uint64): uint32 {.inline.} = uint32(w and 0xFFFF_FFFF'u64)
func roleOwner*(w: uint64): uint16 {.inline.} = uint16((w shr 32) and 0xFFFF'u64)
func roleCommitted*(w: uint64): bool {.inline.} = ((w shr 48) and 1'u64) != 0'u64
func roleIsFree*(w: uint64): bool {.inline.} = roleOwner(w) == RoleNoOwner

func ledgerWord*(epoch: uint32; dec: LedgerDecision): uint64 {.inline.} =
  uint64(epoch) or (uint64(ord(dec)) shl 32)

func ledgerEpoch*(w: uint64): uint32 {.inline.} = uint32(w and 0xFFFF_FFFF'u64)

func ledgerDec*(w: uint64): LedgerDecision {.inline.} =
  ## Decoded defensively: an out-of-range byte reads as `ldNone` rather than
  ## being cast into the enum, because a corrupt word must not become undefined
  ## behaviour in a process that is about to decide admission on it.
  case uint8((w shr 32) and 0xFF'u64)
  of 1'u8: ldGrant
  of 2'u8: ldRefuse
  of 3'u8: ldReleased
  else: ldNone

func stateWord*(st: RequestState; gen: uint32; baseVal: uint32): uint64 {.inline.} =
  uint64(baseVal) or ((uint64(gen) and 0xFF_FFFF'u64) shl 32) or
    (uint64(ord(st)) shl 56)

func stateBaseVal*(w: uint64): uint32 {.inline.} = uint32(w and 0xFFFF_FFFF'u64)
func stateGen*(w: uint64): uint32 {.inline.} = uint32((w shr 32) and 0xFF_FFFF'u64)

func stateOf*(w: uint64): RequestState {.inline.} =
  case uint8((w shr 56) and 0xFF'u64)
  of 1'u8: rqIdle
  of 2'u8: rqPending
  of 3'u8: rqHolding
  else: rqFree

func arbiterAreaSize*(slotCount: int): int {.inline.} =
  ## Bytes the request-slot array occupies.
  slotCount * RequestSlotSize

when arbiterSupported:
  import ./hooks
  import ./waitword
  import std/[posix, monotimes]

  # --- offset-addressed atomics ---------------------------------------------

  template atField(base: ShmBase; offset: int; T: typedesc): ptr T =
    cast[ptr T](addr base[offset])

  proc loadU64Acquire(base: ShmBase; off: int): uint64 {.inline.} =
    atomicLoadN(atField(base, off, uint64), ATOMIC_ACQUIRE)
  proc loadU64Relaxed(base: ShmBase; off: int): uint64 {.inline.} =
    atomicLoadN(atField(base, off, uint64), ATOMIC_RELAXED)
  proc storeU64Relaxed(base: ShmBase; off: int; v: uint64) {.inline.} =
    atomicStoreN(atField(base, off, uint64), v, ATOMIC_RELAXED)
  proc storeU64Release(base: ShmBase; off: int; v: uint64) {.inline.} =
    atomicStoreN(atField(base, off, uint64), v, ATOMIC_RELEASE)
  proc casU64(base: ShmBase; off: int; expected: var uint64;
      desired: uint64): bool {.inline.} =
    atomicCompareExchangeN(atField(base, off, uint64), addr expected, desired,
      false, ATOMIC_ACQ_REL, ATOMIC_ACQUIRE)
  proc loadU32Acquire(base: ShmBase; off: int): uint32 {.inline.} =
    atomicLoadN(atField(base, off, uint32), ATOMIC_ACQUIRE)
  proc casU32Release(base: ShmBase; off: int; expected: var uint32;
      desired: uint32): bool {.inline.} =
    atomicCompareExchangeN(atField(base, off, uint32), addr expected, desired,
      false, ATOMIC_ACQ_REL, ATOMIC_ACQUIRE)

  proc nowNs(): int64 {.inline.} = getMonoTime().ticks

  # --- geometry --------------------------------------------------------------

  proc slotOffset*(v: ArbiterView; slot: int): int {.inline.} =
    ## Byte OFFSET of a slot — never an address, which is what lets every process
    ## address the same slot from its own mapping base (SM-7).
    v.slotsOff + slot * RequestSlotSize

  proc initArbiterArea*(base: ShmBase; slotsOff: int; slotCount: int) =
    ## Owner-side initialisation, called while the segment is still under its temp
    ## name and before the magic is published. Plain stores: nothing else can see
    ## these bytes yet.
    for i in 0 ..< slotCount:
      let off = slotsOff + i * RequestSlotSize
      storeU64Relaxed(base, off + RqOffValue, 0)          # value + waiters
      storeU64Relaxed(base, off + RqOffState, stateWord(rqFree, 0, 0))
      storeU64Relaxed(base, off + RqOffWant, 0)
      storeU64Relaxed(base, off + RqOffLedger, ledgerWord(0, ldNone))
      storeU64Relaxed(base, off + RqOffOutcome, ledgerWord(0, ldNone))
      storeU64Relaxed(base, off + RqOffOwnerPid, 0)
      storeU64Relaxed(base, off + RqOffOwnerStart, 0)
      storeU64Relaxed(base, off + RqOffTicket, 0)

  # --- reading the shared words ----------------------------------------------

  proc roleSnapshot*(v: ArbiterView): uint64 {.inline.} =
    if not v.available: return roleWord(RoleNoOwner, 0, true)
    loadU64Acquire(v.base, v.roleOff)

  proc combineSeq*(v: ArbiterView): uint32 {.inline.} =
    if not v.available: return 0
    uint32(loadU64Acquire(v.base, v.seqOff) and 0xFFFF_FFFF'u64)

  proc casRoleWord*(v: ArbiterView; expected: var uint64;
      desired: uint64): bool {.inline.} =
    ## RAW CAS on the role word, exported for exactly the reason M2 exports
    ## `casPackedRemaining`: constraint 1 — that the commit and the role transfer
    ## are resolved by ONE CAS ON ONE WORD — is only DEMONSTRABLE by a test that
    ## performs a stale combiner's commit CAS after a steal and requires it to
    ## FAIL. Production callers want `tryCombine`, which is the only thing in this
    ## module that calls this.
    if not v.available: return false
    scheduleHook(slpBeforeRoleCas)
    result = casU64(v.base, v.roleOff, expected, desired)
    scheduleHook(slpAfterRoleCas)

  proc storeCombineSeq*(v: ArbiterView; e: uint32) =
    ## RAW monotone store on the combine-sequence word — the ALTERNATIVE DESIGN's
    ## commit, and the counterfactual half of constraint 1's evidence. It exists so
    ## a test can show that this write is NOT invalidated by a steal, which is
    ## precisely why a design that commits here while the role moves there fails
    ## `NeverBoth` (`shm_lease_combine_unfenced_MC.cfg`, 13-state trace). Nothing
    ## in the shipping path calls it; the round commits in the role word.
    if not v.available: return
    var cur = loadU64Acquire(v.base, v.seqOff)
    while uint32(cur and 0xFFFF_FFFF'u64) < e:
      if casU64(v.base, v.seqOff, cur, uint64(e)): return

  proc ledgerAt*(v: ArbiterView; slot: int): uint64 {.inline.} =
    loadU64Acquire(v.base, v.slotOffset(slot) + RqOffLedger)

  proc wantAt*(v: ArbiterView; slot: int): uint64 {.inline.} =
    loadU64Acquire(v.base, v.slotOffset(slot) + RqOffWant)

  proc ticketAt*(v: ArbiterView; slot: int): uint64 {.inline.} =
    ## **M6**: the arrival stamp of the request currently published in this slot.
    ## Written before the state's release-store, so a combiner that acquire-loads
    ## `rqPending` necessarily sees the ticket that goes with it — the same
    ## publish-before-write rule `want` follows.
    loadU64Acquire(v.base, v.slotOffset(slot) + RqOffTicket)

  proc stateAt*(v: ArbiterView; slot: int): uint64 {.inline.} =
    loadU64Acquire(v.base, v.slotOffset(slot) + RqOffState)

  proc valueAt*(v: ArbiterView; slot: int): uint32 {.inline.} =
    loadU32Acquire(v.base, v.slotOffset(slot) + RqOffValue)

  proc outcomeAt*(v: ArbiterView; slot: int): uint64 {.inline.} =
    loadU64Acquire(v.base, v.slotOffset(slot) + RqOffOutcome)

  proc waitersAt*(v: ArbiterView; slot: int): uint32 {.inline.} =
    waitWordWaiters(v.base, v.slotOffset(slot))

  func isEffectiveGrant(entry: uint64; cseq: uint32): bool {.inline.} =
    ## THE definition of "this slot holds capacity": a GRANT whose stamp has been
    ## swept up by the committed sequence. Everything the budget is derived from
    ## goes through this one predicate.
    ledgerDec(entry) == ldGrant and ledgerEpoch(entry) <= cseq

  proc heldVec*(v: ArbiterView; mask: var uint64): ResourceVec =
    ## The AUTHORITATIVE view of what is taken: the sum of the EFFECTIVE grants in
    ## the ledger. Constraint 2 in one procedure — no decision anywhere in this
    ## module reads the budget word, and this is what it reads instead.
    ##
    ## Summed per dimension in 32-bit lanes rather than by packed addition: a
    ## packed add would carry between dimensions if the sum ever exceeded a field,
    ## and "a memory over-claim presents as CPU-slot corruption" is precisely the
    ## borrow hazard `packed.nim` exists to keep out of the arithmetic.
    ##
    ## **THE DECISION AND THE AMOUNT ARE TWO WORDS, SO THE PAIR IS RE-VALIDATED.**
    ## The ledger entry carries the decision and its stamp; the amount is the
    ## slot's `want`, which is immutable *while the grant is outstanding* but is
    ## rewritten by the owner's next `publishRequest`. Reading the entry and then
    ## the want without a check therefore has a window: release, re-request with a
    ## different vector, and the sum attributes the NEW amount to the OLD grant.
    ## Re-reading the entry afterwards closes it — an unchanged entry means the
    ## want that was read belongs to it.
    ##
    ## THE SNAPSHOT IS NOT ATOMIC, AND THE ARGUMENT THAT IT DOES NOT NEED TO BE
    ## RESTS ON THREE PREMISES. They are stated in full because MV2's atomisation
    ## table only ENUMERATES this site; nothing checks the argument.
    ##
    ##   1. **`cseq` IS FROZEN FOR THE WHOLE ROUND, which is what makes the single
    ##      `let cseq = v.combineSeq()` below sound.** `cseq` advances only in
    ##      `repairSequence`, and `repairSequence` advances nothing unless the role
    ##      word says `committed`. The caller's acquisition CAS wrote that flag
    ##      FALSE, so while this round is live no process — not the combiner, not a
    ##      repairer, not a stealer, which must acquire before it commits — can
    ##      move `cseq`. Re-reading it per slot would therefore read the same word;
    ##      reading it once is not an approximation.
    ##   2. **NO GRANT CAN BE ADDED WHILE THIS SCAN RUNS.** A grant is stamped only
    ##      by the round holding the role, and it becomes EFFECTIVE only when a
    ##      commit advances `cseq`, which premise 1 rules out. So the set of
    ##      effective grants can only SHRINK during the scan.
    ##   3. **THE SKIP ON A CHANGED ENTRY IS EXACT, NOT CONSERVATIVE — and the
    ##      stronger fact is the one the argument needs.** The only writers of a
    ##      ledger entry other than the round itself are the SLOT'S OWN
    ##      `releaseGrant` (`ldGrant` -> `ldReleased`) and the `publishRequest`
    ##      clear that can only follow it. Both mean the entry stopped being an
    ##      outstanding grant, i.e. THE CAPACITY REALLY IS FREE at the moment the
    ##      re-read observes it. Skipping the slot is not an under-count the
    ##      arithmetic tolerates: it is the correct answer for the state the scan
    ##      linearises at. That matters because the gate's clause (c) validates the
    ##      round's held AMOUNT against the reference — an under-count would be a
    ##      `heldMismatch`, not something absorbed.
    ##
    ## This was not caught by inspection: the M5 gate's reference implementation
    ## caught it, and only after many runs — see the sensitivity figure recorded in
    ## the milestone. Clause (c) is what noticed it at all; it is not a detector
    ## anyone should rely on to notice it again quickly.
    mask = 0
    var total = ResourceVec()
    if not v.available: return total
    let cseq = v.combineSeq()
    for i in 0 ..< v.slotCount:
      let e = ledgerAt(v, i)
      if isEffectiveGrant(e, cseq):
        let w = wantAt(v, i)
        if ledgerAt(v, i) != e: continue   # released mid-scan: not held now
        mask = mask or (1'u64 shl i)
        total = total + unpackVec(w)
    total

  proc heldSum*(v: ArbiterView): ResourceVec =
    var mask: uint64
    v.heldVec(mask)

  proc budgetCache*(v: ArbiterView): ResourceVec {.inline.} =
    ## The CACHE, for a caller that wants a cheap "is there any point in asking".
    ## It is never authoritative and no decision in this module reads it.
    ##
    ## It IS, however, the same word M2's `packedRemaining` / `remainingVec` /
    ## `noOvercommit` read, so a stale value here is a stale answer handed to a
    ## caller of the M2 API. Every operation that changes the effective sum —
    ## a committed round, AND `releaseGrant` — recomputes it, so at QUIESCENCE
    ## this word equals `capacity - heldSum()` exactly. That is `BudgetExact`, and
    ## quiescence is where MV2 states it.
    if not v.available: return ResourceVec()
    unpackVec(loadU64Acquire(v.base, v.remainingOff))

  proc refreshBudgetCache*(v: ArbiterView): ResourceVec {.discardable.} =
    ## CONSTRAINT 2, the whole of it: recompute `capacity - held` from the stamped
    ## ledger and store it. Idempotent and self-healing — a process that dies here
    ## leaves a stale cache and the next combiner recomputes it, which is why
    ## dying inside this call costs nothing.
    ##
    ## Defined here rather than beside the round because `releaseGrant` calls it
    ## too: the recompute is what keeps the cache from lagging the ledger between
    ## rounds. Recomputing is NOT the incremental decrement constraint 2 forbids —
    ## the value stored is derived from the stamped ledger every time, so a
    ## discarded round leaves nothing behind and a repeated call is a no-op.
    let held = v.heldSum()
    let avail = v.capacity - held
    scheduleHook(slpBeforeBudgetRefresh)
    storeU64Release(v.base, v.remainingOff, packVec(avail))
    avail

  proc availableVec*(cap, held, proposed: ResourceVec): ResourceVec {.inline.} =
    ## `capacity - held - proposed`, saturating per dimension (`-` on `ResourceVec`
    ## saturates at zero, so a momentarily impossible state reads as "nothing
    ## available" rather than wrapping into a huge one).
    (cap - held) - proposed

  func vecFits*(want, avail: ResourceVec): bool {.inline.} =
    want.cpuSlots <= avail.cpuSlots and want.memUnits <= avail.memUnits and
      want.procs <= avail.procs and want.ioWeight <= avail.ioWeight

  # --- the combine sequence: a PUBLIC, IDEMPOTENT repair ---------------------

  proc repairSequence*(v: ArbiterView): bool =
    ## If the role word says a round committed and `cseq` has not caught up,
    ## advance `cseq`. PUBLIC and IDEMPOTENT, and it MUST run before an
    ## acquisition: a steal overwrites the role word, and with it the only
    ## evidence that the previous round committed.
    ##
    ## A max-store implemented as a CAS loop, so two processes racing to repair
    ## the same epoch write the same value and `cseq` never moves backwards.
    if not v.available: return false
    let r = v.roleSnapshot()
    if not roleCommitted(r): return false
    let e = roleEpoch(r)
    if e == 0: return false
    var cur = loadU64Acquire(v.base, v.seqOff)
    result = false
    while uint32(cur and 0xFFFF_FFFF'u64) < e:
      scheduleHook(slpBeforeSeqAdvance)
      if casU64(v.base, v.seqOff, cur, uint64(e)):
        return true

  proc sequenceNeedsRepair*(v: ArbiterView): bool {.inline.} =
    let r = v.roleSnapshot()
    roleCommitted(r) and roleEpoch(r) > v.combineSeq() and roleEpoch(r) > 0'u32

  # --- the requester side ----------------------------------------------------

  proc registerSlot*(c: var ArbiterClient; slot: int): bool =
    ## Claim a request slot for this process and write its ANCHOR — boot id, pid,
    ## and process START TIME. The anchor is what the steal detector consults when
    ## this client holds the role and stops running, and start time is the field
    ## that defeats pid reuse (`shm_lease/anchor`).
    if not c.view.available: return false
    if slot < 0 or slot >= c.view.slotCount: return false
    let off = c.view.slotOffset(slot)
    var cur = loadU64Acquire(c.view.base, off + RqOffState)
    if stateOf(cur) != rqFree: return false
    let want = stateWord(rqIdle, 0, valueAt(c.view, slot))
    if not casU64(c.view.base, off + RqOffState, cur, want): return false
    let pid = getpid()
    storeU64Relaxed(c.view.base, off + RqOffOwnerPid, uint64(pid))
    storeU64Release(c.view.base, off + RqOffOwnerStart, processStartTime(int(pid)))
    c.slot = slot
    c.gen = 0
    c.baseVal = valueAt(c.view, slot)
    true

  proc publishRequest*(c: var ArbiterClient; want: ResourceVec): PublishStatus =
    ## Publish a request into this client's own slot. NON-BLOCKING (SM-8): it
    ## never waits for the role and never enters the kernel.
    ##
    ## **THIS IS WHERE `publishGrant`'s INHERITED PRECONDITION BECOMES STRUCTURAL.**
    ## M3 documented "at most one outstanding grant per slot" as a contract that
    ## "is not enforced here", and MV2 settled that M5 must satisfy it by
    ## construction. A slot whose ledger entry is an outstanding GRANT is refused
    ## here with `psHoldsGrant` — so a second grant can never be published into a
    ## slot whose first has not been collected and released, because a second
    ## REQUEST cannot exist.
    ##
    ## ORDER: clear the ledger decision (one CAS, keeping the old stamp so the
    ## next round's raise pass restamps it), then write `want`, then RELEASE-store
    ## the state. A combiner that acquire-loads `rqPending` therefore necessarily
    ## sees the `want` that goes with it — publish-before-write, the same rule the
    ## segment's magic follows.
    if not c.view.available: return psUnavailable
    if not validVec(want): return psInvalidVec
    let off = c.view.slotOffset(c.slot)
    var st = loadU64Acquire(c.view.base, off + RqOffState)
    if stateOf(st) == rqHolding: return psHoldsGrant
    if stateOf(st) != rqIdle: return psNotIdle
    var entry = loadU64Acquire(c.view.base, off + RqOffLedger)
    # THE STRUCTURAL GUARD, and it is the one that matters: the state word above is
    # written by this client and a confused client could get it wrong, whereas the
    # LEDGER is the shared record every combiner decides from. An outstanding grant
    # there refuses the request whatever the state word says.
    if ledgerDec(entry) == ldGrant: return psHoldsGrant
    if ledgerDec(entry) != ldNone:
      # Clear a collected refusal or a released grant, keeping the stamp: an entry
      # with `dec = none` is NON-EFFECTIVE at any stamp, which is exactly what the
      # raise pass is looking for.
      let cleared = ledgerWord(ledgerEpoch(entry), ldNone)
      scheduleHook(slpBeforeLedgerCas)
      if not casU64(c.view.base, off + RqOffLedger, entry, cleared):
        return psNotIdle
    inc c.gen
    c.baseVal = valueAt(c.view, c.slot)
    storeU64Relaxed(c.view.base, off + RqOffWant, packVec(want))
    # **M6 — THE ARRIVAL TICKET.** Written here, with `want`, under the same
    # publish-before-write discipline: both are plain relaxed stores that PRECEDE
    # the release-store of the state, so a combiner that acquire-loads `rqPending`
    # sees the pair that belongs to it. A FRESH stamp per request is the fairness
    # rule, not an implementation detail — a client that is granted, releases and
    # asks again goes to the BACK of the arrival order, which is what stops one
    # busy client from holding a permanent claim on the head position.
    #
    # It costs a clock read and NOT a kernel entry: `CLOCK_MONOTONIC` is served
    # from the commpage on macOS and the vDSO on Linux, and the unit suite asserts
    # that with the kernel's own syscall counter rather than asserting it here.
    storeU64Relaxed(c.view.base, off + RqOffTicket, uint64(nowNs()))
    storeU64Release(c.view.base, off + RqOffState,
      stateWord(rqPending, c.gen, c.baseVal))
    inc c.stats.requests
    psPublished

  proc answerArrived*(v: ArbiterView; slot: int): bool {.inline.} =
    ## THE WAITER'S WAKE PREDICATE — and, deliberately, the same expression
    ## `workPending` uses for recovery. The VALUE word, not the ledger and not the
    ## payload. See the module docstring for the two deadlocks that rule the other
    ## two out.
    let st = stateAt(v, slot)
    stateOf(st) == rqPending and valueAt(v, slot) != stateBaseVal(st)

  proc collectAnswer*(c: var ArbiterClient): AnswerStatus =
    ## Read the published outcome after the value word has moved, and check the
    ## payload's tag against the value that was observed. A mismatch is
    ## `GrantCoherent` failing — a grant meant for another request — and it is
    ## REPORTED rather than acted on.
    if not c.view.available: return ansUnavailable
    let off = c.view.slotOffset(c.slot)
    let observed = valueAt(c.view, c.slot)
    let st = loadU64Acquire(c.view.base, off + RqOffState)
    if stateOf(st) != rqPending: return ansNone
    if observed == stateBaseVal(st): return ansNone
    let payload = loadU64Acquire(c.view.base, off + RqOffOutcome)
    if ledgerEpoch(payload) != observed: return ansIncoherent
    c.baseVal = observed
    case ledgerDec(payload)
    of ldGrant:
      storeU64Release(c.view.base, off + RqOffState,
        stateWord(rqHolding, c.gen, observed))
      inc c.stats.grantsCollected
      ansGranted
    of ldRefuse:
      storeU64Release(c.view.base, off + RqOffState,
        stateWord(rqIdle, c.gen, observed))
      inc c.stats.refusalsCollected
      ansRefused
    else:
      ansIncoherent

  proc releaseGrant*(c: var ArbiterClient): bool =
    ## Give a granted reservation back: ONE CAS on this client's own ledger entry,
    ## `[e, grant]` -> `[e, released]`. See DEPARTURE 2 — the model has no release,
    ## it is a WRITER OUTSIDE MV2's EPOCH FENCE, and the safety argument for that
    ## is written out there and is UNCHECKED.
    ##
    ## **IT RECOMPUTES THE BUDGET CACHE AFTERWARDS, AND THAT IS NOT A DECREMENT.**
    ## An earlier version left the word alone on the grounds that the next round
    ## would recompute it — but rounds are not obliged to happen, and until one
    ## does the word is a stale answer handed to every caller of `budgetCache`,
    ## `packedRemaining` and `noOvercommit`, which are public M2 API. Measured: a
    ## grant-then-release with no intervening round left the word at
    ## `(4, 60, 7, 90)` while the ledger said `(8, 64, 8, 100)` was free.
    ## `refreshBudgetCache` DERIVES `capacity - Σ effective grants` from the
    ## stamped ledger; it does not subtract this release's amount from whatever the
    ## word happened to hold, which is the accumulator constraint 2 forbids and
    ## `amIncrementalBudget` reproduces.
    ##
    ## ORDER: the ledger CAS first, the recompute second. A process that dies
    ## between them leaves the word conservative (it understates availability) and
    ## the next round or the next release repairs it — the same self-healing
    ## property that makes dying inside `refreshBudgetCache` cost nothing.
    if not c.view.available: return false
    let off = c.view.slotOffset(c.slot)
    var st = loadU64Acquire(c.view.base, off + RqOffState)
    if stateOf(st) != rqHolding: return false
    var entry = loadU64Acquire(c.view.base, off + RqOffLedger)
    if ledgerDec(entry) != ldGrant: return false
    scheduleHook(slpBeforeLedgerCas)
    if not casU64(c.view.base, off + RqOffLedger,
        entry, ledgerWord(ledgerEpoch(entry), ldReleased)):
      return false
    storeU64Release(c.view.base, off + RqOffState,
      stateWord(rqIdle, c.gen, c.baseVal))
    # THE MUTATION REACHES HERE TOO, and it has to: `amIncrementalBudget` means
    # "the budget word is an accumulator, not a cache", and an accumulator is not
    # recomputed at ANY site. Skipping the recompute here is what lets the negative
    # control show the damage — three grant/release cycles leaving 6 of 8 CPU slots
    # permanently gone — instead of having it repaired by the release it is
    # supposed to survive.
    if amIncrementalBudget notin c.mutations:
      discard c.view.refreshBudgetCache()
    inc c.stats.releases
    true

  # --- waiting ---------------------------------------------------------------

  proc awaitAnswer*(c: var ArbiterClient; timeoutNs: int64 = 0): AnswerStatus =
    ## Park until this client's own answer is published, re-validating after every
    ## wake. Returns `ansNone` on timeout so the caller can drive a round itself —
    ## which is what makes the protocol live when the role holder is stalled.
    ##
    ## THE PREFAULT RULE: on macOS a park through an address whose page this
    ## process has not yet touched fails instantly with `EFAULT`, and a forked
    ## child that `MAP_FIXED`ed the segment is in exactly that state. `waitOn` does
    ## not prefault; `awaitValueChange` does, and this loop is a hand-written
    ## `awaitValueChange`, so it prefaults too. Removing this line reproduces M3's
    ## measured hazard.
    if not c.view.available: return ansUnavailable
    let off = c.view.slotOffset(c.slot)
    prefaultWaitWord(c.view.base, off)
    if c.view.answerArrived(c.slot):
      inc c.stats.fastAnswers
      return c.collectAnswer()
    let r = waitOn(c.view.base, off, c.baseVal, timeoutNs)
    case r
    of wrNotEqual:
      inc c.stats.fastAnswers
    of wrWoken:
      inc c.stats.parks
      if not c.view.answerArrived(c.slot):
        # THE WAIT WORD DID NOT MOVE, so nothing in this protocol woke this
        # waiter: the kernel's wait primitive is permitted to return early and
        # this loop re-validates precisely because it does not assume otherwise.
        # **This is COUNTED, NOT ASSERTED ZERO.** An earlier version asserted it
        # zero in the name of clause (b), which made a property of the KERNEL into
        # a gate on the code; `waitword` documents the same tolerance for spurious
        # wakeups a few modules over, and a single one would have failed the gate.
        # Clause (b) is asserted instead on what the code guarantees: see
        # `parksWokenIncomplete` below and `wakeCalls <= answersPublished` in
        # `publishOne`.
        inc c.stats.parksSpurious
        return ansNone
      # WOKEN BY THIS PROTOCOL — the wait word moved. THE GATE'S CLAUSE (b) LIVES
      # HERE: grant-then-wake writes the payload, then CASes the value, then
      # wakes, so a waiter that finds its value moved must find the payload the
      # value is TAGGED WITH. Anything else is the wake-then-retry pattern
      # `RunQuota-Shared-Memory-Transport.md` §4 calls a defect rather than a
      # strategy, and `parksWokenIncomplete` is where it shows up.
      inc c.stats.parksWokenWithAnswer
      let woken = c.collectAnswer()
      if woken != ansGranted and woken != ansRefused:
        inc c.stats.parksWokenIncomplete
      return woken
    of wrTimedOut:
      inc c.stats.parks
      inc c.stats.parksTimedOut
      if not c.view.answerArrived(c.slot): return ansNone
    else:
      return ansUnavailable
    if not c.view.answerArrived(c.slot): return ansNone
    c.collectAnswer()

  # --- the steal detector (constraint 4) --------------------------------------

  proc ownerAnchorVerdict*(v: ArbiterView; slot: int): AnchorVerdict =
    ## Judge the role holder from the anchor in its OWN slot. This is the half of
    ## the detector that buys progress when the holder is gone rather than merely
    ## slow, and it is the half MV2 says must not be dropped on the grounds that
    ## the protocol tolerates false positives — it tolerates them for SAFETY, and
    ## pays for them in LIVENESS.
    if slot < 0 or slot >= v.slotCount: return avNoOwner
    let off = v.slotOffset(slot)
    anchorVerdict(v.boot, loadU64Relaxed(v.base, off + RqOffOwnerPid),
      loadU64Relaxed(v.base, off + RqOffOwnerStart))

  proc mayStealRole*(c: var ArbiterClient; observed: uint64): bool =
    ## CONSTRAINT 4, both halves, and MV2 is explicit that neither is optional.
    ##
    ##   * **THE ANCHOR CHECK** — boot id + pid + start time, read from the owner's
    ##     own slot. A holder that is demonstrably GONE is stolen from IMMEDIATELY,
    ##     without waiting the timeout out. This is the half that buys PROGRESS,
    ##     and MV2 warns specifically against dropping it on the grounds that the
    ##     protocol tolerates false positives: it tolerates them for safety and
    ##     pays for them in liveness (`shm_lease_combine_livelock_MC.cfg`).
    ##   * **THE BOUNDED TIMEOUT** — for a holder that is alive but not running,
    ##     which is the residual risk the transport spec names: a large CPU-hungry
    ##     build client holding the role is exactly what the scheduler deschedules.
    ##     It fires on a RUNNING holder too, deliberately; MV2 ran the protocol
    ##     with a maximally wrong detector over 1,325,806 states and every safety
    ##     invariant held, so an early fire costs a wasted round and nothing else.
    ##
    ## The anchor check costs a `kill(pid, 0)`, so it is RATE-LIMITED by its own
    ## bounded interval rather than run on every attempt — and it is never reached
    ## from inside a round, which must stay syscall-free. `anchorProbeAfterNs` is
    ## shorter than `stealAfterNs` because a dead holder should be recovered from
    ## sooner than a slow one. A negative `stealAfterNs` disables the timeout half,
    ## which is how a test asks for "anchor only".
    let now = nowNs()
    if observed != c.lastRoleWord:
      c.lastRoleWord = observed
      c.lastRoleNs = now
      c.lastAnchorNs = now
      return false           # first sighting: neither half can have elapsed yet
    let idle = now - c.lastRoleNs
    if idle >= c.anchorProbeAfterNs and now - c.lastAnchorNs >= c.anchorProbeAfterNs:
      c.lastAnchorNs = now
      let verdict = c.view.ownerAnchorVerdict(int(roleOwner(observed)))
      inc c.stats.anchorProbes
      if verdict != avLive:
        inc c.stats.anchorSteals
        return true
    if c.stealAfterNs < 0: return false
    idle >= c.stealAfterNs

  proc workPending*(v: ArbiterView): bool =
    ## "IS THERE ANYTHING TO COMBINE." The test is on the VALUE word — the same
    ## predicate the waiter waits on. Testing the ledger instead deadlocks MV2's
    ## model in 157 states and testing the payload in 711; see the module
    ## docstring. It is also what keeps the epoch from being burned on empty
    ## rounds.
    ##
    ## UNCHANGED, AND DELIBERATELY SO: MV2's design rule is that the RECOVERY
    ## predicate and the waiter's WAKE predicate are the same predicate, and this
    ## is that predicate. `decidableWork` below is an ADDITIONAL gate, not a
    ## replacement.
    for i in 0 ..< v.slotCount:
      let st = stateAt(v, i)
      if stateOf(st) == rqPending and valueAt(v, i) == stateBaseVal(st):
        return true
    false

  # --- M6: the admission POLICY, in the two places that must agree -----------

  func usesArrivalOrder*(m: ArbiterMutations): bool {.inline.} =
    ## **M6 rule 1.** Off under the two controls that revert the ordering.
    amFirstFit notin m and amSlotOrder notin m

  func usesReservation*(m: ArbiterMutations): bool {.inline.} =
    ## **M6 rule 2.** Off under the two controls that hold nothing idle.
    amFirstFit notin m and amNoReserve notin m

  proc buildScanOrder(v: ArbiterView; order: var array[MaxRequestSlots, uint16];
      keys: var array[MaxRequestSlots, uint64]; arrivalOrder: bool): int =
    ## Collect the slots a round would consider and put them in SCAN ORDER.
    ##
    ## Allocation-free and bounded, which the milestone requires of everything a
    ## round does: two fixed arrays of `MaxRequestSlots`, and an insertion sort
    ## over at most 64 entries. An insertion sort rather than anything cleverer
    ## because 64 is the bound and "no allocation, no recursion" is the property
    ## that matters here, not the asymptotics.
    ##
    ## The sort is STABLE (the shift condition is a strict `>`) and slots are
    ## offered to it in ascending index order, so equal keys keep ascending slot
    ## order. That is what makes an exact ticket collision — two processes
    ## stamping the same nanosecond — DETERMINISTIC rather than merely unlikely,
    ## which matters because the gate's reference implementation has to predict
    ## the same order.
    ##
    ## `arrivalOrder = false` gives every slot the key 0, so the stable sort
    ## leaves them in ascending slot index: M5's order, reproduced by the
    ## `amFirstFit` / `amSlotOrder` controls through THIS code path rather than
    ## through a second copy of the loop that could drift from it.
    var n = 0
    for i in 0 ..< v.slotCount:
      let st = stateAt(v, i)
      if stateOf(st) != rqPending: continue
      if valueAt(v, i) != stateBaseVal(st): continue   # already answered
      let key = if arrivalOrder: ticketAt(v, i) else: 0'u64
      var j = n
      while j > 0 and keys[j - 1] > key:
        order[j] = order[j - 1]
        keys[j] = keys[j - 1]
        dec j
      order[j] = uint16(i)
      keys[j] = key
      inc n
    n

  proc decidableWork*(v: ArbiterView; mutations: ArbiterMutations = {}): bool =
    ## "IS THERE ANYTHING A ROUND COULD ACTUALLY GET DONE RIGHT NOW" — decide OR
    ## publish. Not the same question as `workPending`, and DEPARTURE 1 is why: a
    ## request that does not
    ## fit is left pending, so `workPending` stays true for as long as it is
    ## unfittable — forever, if nothing is ever released. Without this gate a
    ## caller's `tryCombine` loop commits one do-nothing round per call and burns
    ## an epoch each time, which is the unbounded epoch churn MV2 rules out with
    ## `EpochBoundNotBinding` (see DEPARTURE 1 in the module docstring for the
    ## measurement, and for the gate failure it caused).
    ##
    ## **IT IS EXACT, NOT A HEURISTIC, and that matters — an over-eager answer
    ## would put the empty rounds back and a shy one would drop real work.** It is
    ## exact because it RUNS THE SAME POLICY the scan runs, over the same slots in
    ## the same order, and stops at the first decision the scan would stamp:
    ##   * the scan order is `buildScanOrder`, the identical procedure;
    ##   * the fit test is `capacity - held - proposed - reserved`, and since this
    ##     simulation returns at the FIRST grantable request, `proposed` is still
    ##     zero there — so the two agree without this loop having to model the
    ##     accumulation;
    ##   * the reservation head is chosen by the identical rule, which is what
    ##     makes the answer exact UNDER M6's POLICY: a request that fits
    ##     `capacity - held` but sits behind the head is NOT decidable work, and a
    ##     predicate that said otherwise would take the role, stamp nothing, and
    ##     reintroduce the churn `EpochBoundNotBinding` rules out — this time
    ##     without even the empty commit to show for it, since step 4b abandons
    ##     the round at the same epoch;
    ##   * a request that cannot fit `capacity` at all is refused unconditionally,
    ##     ahead of any reservation, so a permanently unfittable request is never
    ##     hidden behind a head.
    ## The PUBLICATION clause is exact in its own sense: it tests the identical
    ## condition `publishOne` tests before it moves a word. Taken together: true
    ## exactly when the round would stamp a ledger entry or move a value word.
    ##
    ## `tests/test_shm_lease_arbiter.nim` asserts that equivalence EXECUTABLY,
    ## over a sweep of boards, rather than leaving it to this paragraph — the two
    ## drifting apart is the exact shape of the defect M5's verification found
    ## twice.
    ##
    ## **DECIDABLE INCLUDES "ALREADY DECIDED BUT NOT YET PUBLISHED", AND LEAVING
    ## THAT OUT WAS A DEADLOCK.** An earlier version of this predicate asked only
    ## whether a round could stamp a new decision, and claimed it could not deadlock
    ## on the grounds that "it reads only the EFFECTIVE ledger, so no round's
    ## in-flight state can make it say nothing: a half-applied round's entries are
    ## non-effective". That argument covers an UNCOMMITTED round and nothing else.
    ## A round that committed and then died before its publish loop leaves entries
    ## that ARE effective, ARE counted into `held`, and therefore HIDE the very work
    ## that needs doing: slot `j`'s own grant makes slot `j`'s request stop fitting
    ## `capacity - held`, the request is not permanently refusable either, and the
    ## role is never taken. Measured: 199 rounds of `cbNoWork`, the answer never
    ## delivered, while the pre-gate code recovered in ONE round. The third clause
    ## below is the fix — an effective decision whose answer has not reached the
    ## value word is work, and it is PUBLICATION work, not decision work.
    ##
    ## SO THE CORRECT NO-DEADLOCK STATEMENT IS THIS. A `false` here means, for every
    ## pending slot: its answer is already on the value word, or its request needs
    ## capacity that some OTHER slot's effective grant currently holds. Neither is a
    ## state a survivor can improve, and both are exited by an event outside this
    ## round — a release (which frees capacity) or a publication (which this
    ## predicate now demands and step 4b now performs). What it does NOT do is bound
    ## how long a request waits; that is M6's property and it is not implemented
    ## here.
    ##
    ## THE PUBLICATION CLAUSE AND THE PUBLISH LOOP TEST THE SAME THING, WHICH IS
    ## WHAT MAKES IT TERMINATE: `publishOne` writes `ledgerEpoch(entry)` and returns
    ## without doing anything once the value word already holds it, so this clause
    ## goes false exactly when the publication it asks for has happened — by this
    ## process or by any other.
    if not v.available: return false
    var mask: uint64
    let held = v.heldVec(mask)
    let free = v.capacity - held
    let cseq = v.combineSeq()

    # THE PUBLICATION CLAUSE, first and independent of the policy: an effective
    # decision whose answer has not reached its value word is work whatever the
    # ordering rule says, and it is the clause whose absence deadlocked M5.
    for i in 0 ..< v.slotCount:
      let st = stateAt(v, i)
      if stateOf(st) != rqPending: continue
      if valueAt(v, i) != stateBaseVal(st): continue   # already answered
      let entry = ledgerAt(v, i)
      let dec = ledgerDec(entry)
      if (dec == ldGrant or dec == ldRefuse) and ledgerEpoch(entry) <= cseq and
          valueAt(v, i) != ledgerEpoch(entry):
        return true                                    # DECIDED, UNPUBLISHED

    # THE DECISION CLAUSES, under M6's policy: the same order, the same fit test,
    # the same single reservation head.
    var order: array[MaxRequestSlots, uint16]
    var keys: array[MaxRequestSlots, uint64]
    let n = buildScanOrder(v, order, keys, usesArrivalOrder(mutations))
    let reserve = usesReservation(mutations)
    var reserved = ResourceVec()
    var reserving = false
    for k in 0 ..< n:
      let i = int(order[k])
      let want = unpackVec(wantAt(v, i))
      if not vecFits(want, v.capacity): return true    # refusable, permanently
      if vecFits(want, free - reserved): return true   # grantable now
      if reserve and not reserving:
        reserving = true
        reserved = want                                # THE IDLE HOLD begins here
    false

  # --- THE ROUND -------------------------------------------------------------

  proc publishOne(c: var ArbiterClient; r: var CombineRound; slot: int;
      entry: uint64) =
    ## GRANT-THEN-WAKE for one slot: payload first, then the value, then the wake.
    ##
    ## The value written is the ENTRY'S EPOCH (constraint 3), so a stealer
    ## republishing a dead combiner's answer writes the same word twice and the
    ## waiter sees ONE transition. It is written with a CAS rather than a store:
    ## the post-state is identical either way (the model's `CPubValue` is a plain
    ## store of the same value), but a CAS means the wake below is issued only by
    ## the publisher that actually MOVED the word — so a resurrected combiner
    ## racing a stealer cannot manufacture a second wake for one answer. That is a
    ## strengthening of the modelled step, and it is stated rather than assumed.
    let off = c.view.slotOffset(slot)
    var observed = valueAt(c.view, slot)
    let newVal =
      if amCounterPublish in c.mutations: observed + 1'u32   # THE MUTATION
      else: ledgerEpoch(entry)
    if observed == newVal: return
    storeU64Release(c.view.base, off + RqOffOutcome,
      ledgerWord(newVal, ledgerDec(entry)))
    scheduleHook(slpBeforeGrantPublish)
    if not casU32Release(c.view.base, off + RqOffValue, observed, newVal):
      return                       # somebody else published this answer already
    inc r.published
    inc c.stats.answersPublished
    if ledgerDec(entry) == ldGrant:
      inc c.stats.grantsPublished
    # THE WAKE COMES AFTER THE PUBLISH, NEVER BEFORE, and only for a slot this
    # call has just answered — which is what makes `wakes <= grants` (SM-3) a
    # property of the code's shape rather than of a measurement. It is also the
    # PUBLISHER-SIDE half of the gate's clause (b): every increment of `wakeCalls`
    # is preceded, in this same straight-line block, by the increment of
    # `answersPublished` that a successful value CAS earned, so
    # `wakeCalls <= answersPublished` holds by construction and no wake can be
    # delivered ahead of the answer it announces.
    inc r.wakes
    inc c.stats.wakeCalls
    let wk = wakeOne(c.view.base, off)
    if wk != wkNoWaiters:
      inc r.wakeSyscalls
      inc c.stats.wakeSyscalls

  proc publishEffective(c: var ArbiterClient; r: var CombineRound) =
    ## Publish every EFFECTIVE decision whose answer has not reached the value word
    ## yet — this round's own, and any a dead combiner left behind.
    ##
    ## **THIS IS THE RECOVERY PATH, NOT AN OPTIMISATION.** Constraint 3 puts the
    ## COMBINE EPOCH in the published value precisely so that "a stealer
    ## republishing a dead combiner's answer writes the same word twice"; this loop
    ## is the code that does the republishing, and it is why a combiner may die
    ## anywhere between the commit CAS and the last publication without stranding
    ## the waiter. It is idempotent by construction: `publishOne` returns
    ## immediately when the value word already holds the entry's epoch, so running
    ## it on a fully published board costs a read per slot and changes nothing.
    ##
    ## Called from BOTH exits of a round that holds the role — step 8 after a
    ## commit, and step 4b when the round decided nothing. The 4b call is the one
    ## the deadlock turned on: abandoning the role without running this is what made
    ## the "stamped nothing" path LOSSY, because for a board whose only outstanding
    ## work is a dead combiner's unpublished answer, "stamped nothing" is the
    ## NORMAL outcome and publishing is the entire job.
    let cseqNow = c.view.combineSeq()
    for i in 0 ..< c.view.slotCount:
      let entry = ledgerAt(c.view, i)
      if ledgerDec(entry) != ldGrant and ledgerDec(entry) != ldRefuse: continue
      if ledgerEpoch(entry) > cseqNow: continue
      c.publishOne(r, i, entry)

  proc tryCombine*(c: var ArbiterClient; r: var CombineRound): CombineStatus =
    ## Try to become the combiner and run one round. NEVER BLOCKS: a client that
    ## does not get the role returns `cbRoleBusy` and the caller runs other work
    ## (SM-8). Allocation-free and, apart from the wake of a waiter it has just
    ## answered, syscall-free.
    # `reserveSlot` is -1 = "this round held nothing idle"; the default zero
    # value would name slot 0, which is a real slot.
    r = CombineRound(status: cbUnavailable, reserveSlot: -1)
    if not c.view.available: return cbUnavailable
    let v = c.view

    # 1. SEQUENCE REPAIR, BEFORE ACQUISITION. A steal overwrites the role word and
    #    with it the only evidence that the previous round committed, so this must
    #    run first — and it is the same public, idempotent operation the round
    #    itself uses at step 6.
    discard v.repairSequence()

    # 2. ACQUIRE or STEAL. One CAS on the role word; the epoch increases on EVERY
    #    acquisition because it is the fence.
    var observed = v.roleSnapshot()
    var stolen = false
    if not roleIsFree(observed):
      if int(roleOwner(observed)) == c.slot:
        # Re-entrancy: this process already holds the role from an abandoned round.
        # Take it again the normal way rather than resuming, so the epoch bumps.
        stolen = true
      elif c.mayStealRole(observed):
        stolen = true
        inc c.stats.steals
      else:
        inc c.stats.roundsBusy
        r.status = cbRoleBusy
        return cbRoleBusy
    if v.sequenceNeedsRepair():
      # Another process committed between the repair above and now. MV2's
      # `TakeRole` is guarded by `~SeqNeedsRepair` for a reason: acquiring here
      # would overwrite the role word, and with it the only evidence that that
      # round committed. Come back after somebody has repaired it.
      inc c.stats.roundsLost
      r.status = cbLostRace
      return cbLostRace
    if not v.workPending():
      inc c.stats.roundsNoWork
      r.status = cbNoWork
      return cbNoWork
    if not v.decidableWork(c.mutations):
      # NOTHING THIS ROUND COULD DECIDE. Requests are pending, but every one of
      # them needs capacity that is currently held and none of them is refusable,
      # so a round would raise the ledger, decide nothing, commit and advance the
      # epoch for no effect. That is DEPARTURE 1's epoch consequence, and it is
      # stopped HERE — before the acquisition CAS — so no epoch is burned at all.
      inc c.stats.roundsNoWork
      r.status = cbNoWork
      return cbNoWork
    let epoch = roleEpoch(observed) + 1'u32
    scheduleHook(slpBeforeRoleCas)
    let won = casU64(v.base, v.roleOff, observed,
      roleWord(uint16(c.slot), epoch, false))
    scheduleHook(slpAfterRoleCas)
    if not won:
      inc c.stats.roundsLost
      r.status = cbLostRace
      return cbLostRace
    r.epoch = epoch
    r.owner = uint16(c.slot)
    r.stolen = stolen

    # 3. THE RAISE PASS. Restamp every NON-EFFECTIVE entry with an older stamp up
    #    to my epoch, decision cleared. This is BOTH the discard of a half-applied
    #    round AND the fence that invalidates the previous owner's proposals: its
    #    decide CAS expects its own epoch and can no longer match.
    #
    #    The guard is re-evaluated PER STEP against the CURRENT ledger and `cseq`,
    #    not against a snapshot taken when the pass began — MV2's damage analysis
    #    turns on exactly that, because an entry that becomes effective mid-pass
    #    must stop being raised from that step onward.
    for i in 0 ..< v.slotCount:
      var entry = ledgerAt(v, i)
      let cseq = v.combineSeq()
      if ledgerEpoch(entry) >= epoch: continue
      let nonEffective = ledgerDec(entry) == ldNone or ledgerEpoch(entry) > cseq
      # SERIALISE PER SLOT (constraint 3, first half): an effective, uncollected
      # decision is NEVER restamped, so a live round cannot re-decide an answered
      # slot. Dropping this is `shm_lease_combine_noserial_MC.cfg`.
      if amNoSerialise notin c.mutations and not nonEffective: continue
      scheduleHook(slpBeforeLedgerCas)
      discard casU64(v.base, v.slotOffset(i) + RqOffLedger, entry,
        ledgerWord(epoch, ldNone))

    # 4. THE SCAN. Decide against the EFFECTIVE ledger plus this round's own
    #    proposals, in ARRIVAL ORDER — bulk admission, one round settles what it
    #    can.
    #
    #    **M6 LIVES IN THIS LOOP, AND IT IS TWO RULES** (module docstring for the
    #    bounded-wait argument): the order is the arrival ticket rather than the
    #    slot index, and the FIRST request the scan cannot grant becomes the
    #    round's single RESERVATION HEAD, whose `want` is withheld from every
    #    request decided after it. That is capacity HELD IDLE for a pending large
    #    claim instead of spent on a small one that arrived later, which is what
    #    `RunQuota-Shared-Memory-Transport.md` §2 requires and what M5's
    #    slot-ordered first fit could not do.
    var mask: uint64
    let held = v.heldVec(mask)
    r.heldMask = mask
    r.held = held
    var order: array[MaxRequestSlots, uint16]
    var keys: array[MaxRequestSlots, uint64]
    let arrivalOrder = usesArrivalOrder(c.mutations)
    let scanCount = buildScanOrder(v, order, keys, arrivalOrder)
    let reserve = usesReservation(c.mutations)
    var reserved = ResourceVec()
    var reserving = false
    var proposed = ResourceVec()
    var stamped = 0        ## ledger entries this round actually decided —
                           ## grants plus permanent refusals. A round that stamps
                           ## none of them has done nothing; see step 4b.
    # The mutation reads the budget WORD and treats it as authoritative, which is
    # what `BudgetIsCache = FALSE` means and what `claimWords` does today on the
    # packed budget — so it is the design an M5 author would inherit rather than
    # invent. The shipping path never reads this variable.
    var incremental =
      if amIncrementalBudget in c.mutations: v.budgetCache()
      else: v.capacity - held
    for k in 0 ..< scanCount:
      let i = int(order[k])
      let st = stateAt(v, i)
      if stateOf(st) != rqPending: continue
      var entry = ledgerAt(v, i)
      if ledgerEpoch(entry) != epoch or ledgerDec(entry) != ldNone: continue
      if valueAt(v, i) != stateBaseVal(st): continue  # already answered
      let want = unpackVec(wantAt(v, i))
      # THE FIT TEST. `amBlindFit` is the mutation: deciding every request in the
      # round against the view the round STARTED with is the single most plausible
      # bug in a bulk-admission round, because each decision is individually
      # correct against a real state and their SUM overcommits
      # (`shm_lease_combine_fit_MC.cfg`).
      let availFree =
        if amIncrementalBudget in c.mutations: incremental
        elif amBlindFit in c.mutations: v.capacity - held
        else: availableVec(v.capacity, held, proposed)
      # ...and THEN the reservation is taken off it. Two variables rather than one
      # because the difference between them is exactly the IDLE HOLD, and it is
      # counted below rather than inferred: `availFree` is what is genuinely free,
      # `avail` is what this request is allowed to have.
      let avail = if reserve: availFree - reserved else: availFree
      var kind: DecisionKind
      if vecFits(want, avail):
        kind = dkGrant
      elif not vecFits(want, v.capacity):
        kind = dkRefuse          # can NEVER fit: a permanent refusal is an answer
      else:
        kind = dkPending         # DEPARTURE 1: left pending for a later round
      var becameHead = false
      if kind == dkPending and reserve:
        if not reserving:
          # **THE RESERVATION HEAD.** The first request this round could not
          # grant holds its capacity idle for the rest of the scan. ONE head, not
          # one per blocked request: reservations that summed past the capacity
          # would stop admission dead, which is the cure becoming the disease.
          reserving = true
          becameHead = true
          reserved = want
          r.reserveSlot = i
          r.reservedVec = want
          inc c.stats.reservations
        elif vecFits(want, availFree):
          # THE COST OF THE RESERVATION, COUNTED. This request fitted the capacity
          # that was genuinely free and was refused anyway, because the head is
          # waiting for it.
          #
          # **REPORTED RATHER THAN ASSERTED, AND THE REASON IS AN INTERACTION
          # WORTH KNOWING.** On a board whose only pending work is a reserved head
          # and the requests it is blocking, `decidableWork` declines the role
          # BEFORE a round runs — so the arbiter does not even burn an acquisition
          # while it holds capacity idle, and this counter stays near zero by
          # design rather than by absence of the behaviour. The M6 gate therefore
          # observes the idle hold from OUTSIDE, by sampling the board for states
          # in which the head is waiting, a small claim is waiting, and capacity is
          # free and not being given out. The deterministic assertion on this
          # counter lives in a unit test that gives the round other work to do.
          inc r.reserveBlocked
          inc c.stats.reserveBlocks
      if kind != dkPending:
        scheduleHook(slpBeforeLedgerCas)
        let decided = ledgerWord(epoch,
          if kind == dkGrant: ldGrant else: ldRefuse)
        if not casU64(v.base, v.slotOffset(i) + RqOffLedger, entry, decided):
          # FENCED: a stealer restamped this entry, so this round no longer owns
          # the board. Abandon it — every mutation it made is already invalidated.
          inc c.stats.roundsFenced
          r.status = cbFenced
          return cbFenced
        inc stamped
        if kind == dkGrant:
          proposed = proposed + want
          incremental = incremental - want
          inc r.grants
      if r.decisionCount < MaxRequestSlots:
        r.decisions[r.decisionCount] =
          DecisionRec(slot: uint16(i), gen: stateGen(st),
                      want: packVec(want), kind: kind,
                      # The key the scan actually ordered by when that key IS the
                      # ticket, so the reference can check the ORDER and not only
                      # the outcomes. Under the two order-reverting controls the
                      # key is 0 by construction, and recording the slot's real
                      # ticket there is what lets the same reference SEE that the
                      # order was wrong.
                      ticket: (if arrivalOrder: keys[k] else: ticketAt(v, i)),
                      reserved: becameHead)
        inc r.decisionCount

    # 4b. AN EMPTY ROUND DOES NOT COMMIT. `decidableWork` above makes this the
    #     residual case rather than the common one — the common one is a board of
    #     unfittable requests, and that never gets this far — but the scan can
    #     still stamp nothing if a raise-pass CAS was lost to a concurrent release
    #     or `publishRequest` clear and the slot fell out of the scan's guard.
    #     Committing here would advance `cseq` and the epoch for no effect, which
    #     is the churn `EpochBoundNotBinding` rules out. Abandon instead: hand the
    #     role back UNCOMMITTED at the same epoch, so `repairSequence` correctly
    #     declines to move `cseq` and the next acquisition mints `epoch + 1`.
    #
    #     NOTHING IS LEFT BEHIND. The only mutation this round made is the raise
    #     pass, which rewrote NON-EFFECTIVE entries to `[epoch, ldNone]` — still
    #     non-effective at any stamp, and re-raised by the next round because
    #     their stamp is below its epoch. This is the same discard the fence
    #     performs, taken voluntarily.
    #
    #     **BUT IT PUBLISHES FIRST, AND SKIPPING THAT WAS A DEADLOCK.** "Decided
    #     nothing" is not "did nothing": the board may carry an EFFECTIVE decision a
    #     dead combiner committed and never published, and for such a board stamping
    #     nothing is the NORMAL outcome — the entry already carries its decision, so
    #     the scan above skips it, and publishing it is the whole of the work. An
    #     earlier version returned here without running the publish loop, which made
    #     this path lossy and left the waiter unwakeable forever. The role is still
    #     held at this point, so this is the same exclusive window step 8 publishes
    #     in, and the loop is idempotent either way.
    if stamped == 0:
      c.publishEffective(r)
      var expectE = roleWord(uint16(c.slot), epoch, false)
      scheduleHook(slpBeforeRoleRelease)
      discard casU64(v.base, v.roleOff, expectE, roleWord(RoleNoOwner, epoch, false))
      inc c.stats.roundsNoWork
      r.status = cbNoWork
      return cbNoWork

    # 5. COMMIT — ONE CAS ON ONE WORD, and the linearisation point of the whole
    #    round (constraint 1). A combiner that was stolen from CANNOT execute it,
    #    because the stealer already replaced the word: that is the entire content
    #    of Finding 4, and it is this line.
    var expect = roleWord(uint16(c.slot), epoch, false)
    scheduleHook(slpBeforeCommitCas)
    if not casU64(v.base, v.roleOff, expect, roleWord(uint16(c.slot), epoch, true)):
      inc c.stats.roundsFenced
      r.status = cbFenced
      return cbFenced

    # 6. Advance the sequence: the round's decisions become effective, all at once.
    discard v.repairSequence()

    # 7. Recompute the budget cache (constraint 2), unless the mutation is on.
    if amIncrementalBudget notin c.mutations:
      discard v.refreshBudgetCache()
    else:
      # THE MUTATION: an incrementally maintained budget word. The decrements
      # above already happened in `incremental`; storing it here is the
      # accumulator Finding 6 forbids, and a discarded round's decrement is not
      # undone by anything.
      storeU64Release(v.base, v.remainingOff, packVec(incremental))

    # 8. PUBLISH: payload, value, wake — per effective entry. Republication is a
    #    no-op because the value written is the entry's epoch. The SAME loop step 4b
    #    runs, deliberately: a committing round must also clear whatever a dead
    #    combiner left unpublished, and one procedure is what keeps the two exits
    #    from drifting apart.
    c.publishEffective(r)

    # 9. RELEASE THE ROLE.
    var expect2 = roleWord(uint16(c.slot), epoch, true)
    scheduleHook(slpBeforeRoleRelease)
    discard casU64(v.base, v.roleOff, expect2, roleWord(RoleNoOwner, epoch, true))
    inc c.stats.roundsCommitted
    c.stats.grantDecisions += uint64(r.grants)
    for i in 0 ..< r.decisionCount:
      if r.decisions[i].kind == dkRefuse: inc c.stats.refuseDecisions
    r.status = cbCommitted
    cbCommitted

  proc combineUntilAnswered*(c: var ArbiterClient; r: var CombineRound;
      parkNs: int64): AnswerStatus =
    ## The client driver: try to run a round; if the answer is still not there and
    ## the role was busy, PARK with a bounded timeout rather than spinning (SM-1).
    ## The bounded timeout is what makes the protocol live when the role holder is
    ## descheduled: the caller comes back, the steal detector eventually fires, and
    ## admission recovers without anyone spinning.
    if not c.view.available: return ansUnavailable
    discard c.tryCombine(r)
    if c.view.answerArrived(c.slot):
      return c.collectAnswer()
    c.awaitAnswer(parkNs)

else:
  # --- portable no-op arm ----------------------------------------------------
  #
  # Compiles everywhere, reports unavailable everywhere. Windows lands here for
  # the same reason M3 does: the wake path needs named kernel objects, and the gap
  # is RECORDED in the capability record rather than silently omitted.
  proc slotOffset*(v: ArbiterView; slot: int): int = v.slotsOff + slot * RequestSlotSize
  proc initArbiterArea*(base: ShmBase; slotsOff: int; slotCount: int) = discard
  proc roleSnapshot*(v: ArbiterView): uint64 = roleWord(RoleNoOwner, 0, true)
  proc combineSeq*(v: ArbiterView): uint32 = 0
  proc casRoleWord*(v: ArbiterView; expected: var uint64;
    desired: uint64): bool = false
  proc storeCombineSeq*(v: ArbiterView; e: uint32) = discard
  proc ledgerAt*(v: ArbiterView; slot: int): uint64 = 0
  proc wantAt*(v: ArbiterView; slot: int): uint64 = 0
  proc ticketAt*(v: ArbiterView; slot: int): uint64 = 0
  proc stateAt*(v: ArbiterView; slot: int): uint64 = 0
  proc valueAt*(v: ArbiterView; slot: int): uint32 = 0
  proc outcomeAt*(v: ArbiterView; slot: int): uint64 = 0
  proc waitersAt*(v: ArbiterView; slot: int): uint32 = 0
  proc heldVec*(v: ArbiterView; mask: var uint64): ResourceVec =
    mask = 0; ResourceVec()
  proc heldSum*(v: ArbiterView): ResourceVec = ResourceVec()
  proc budgetCache*(v: ArbiterView): ResourceVec = ResourceVec()
  proc availableVec*(cap, held, proposed: ResourceVec): ResourceVec =
    (cap - held) - proposed
  func vecFits*(want, avail: ResourceVec): bool =
    want.cpuSlots <= avail.cpuSlots and want.memUnits <= avail.memUnits and
      want.procs <= avail.procs and want.ioWeight <= avail.ioWeight
  proc repairSequence*(v: ArbiterView): bool = false
  proc sequenceNeedsRepair*(v: ArbiterView): bool = false
  proc registerSlot*(c: var ArbiterClient; slot: int): bool = false
  proc publishRequest*(c: var ArbiterClient; want: ResourceVec): PublishStatus =
    psUnavailable
  proc answerArrived*(v: ArbiterView; slot: int): bool = false
  proc collectAnswer*(c: var ArbiterClient): AnswerStatus = ansUnavailable
  proc releaseGrant*(c: var ArbiterClient): bool = false
  proc awaitAnswer*(c: var ArbiterClient; timeoutNs: int64 = 0): AnswerStatus =
    ansUnavailable
  proc ownerAnchorVerdict*(v: ArbiterView; slot: int): AnchorVerdict = avNoOwner
  proc mayStealRole*(c: var ArbiterClient; observed: uint64): bool = false
  proc workPending*(v: ArbiterView): bool = false
  proc decidableWork*(v: ArbiterView; mutations: ArbiterMutations = {}): bool =
    false
  func usesArrivalOrder*(m: ArbiterMutations): bool =
    amFirstFit notin m and amSlotOrder notin m
  func usesReservation*(m: ArbiterMutations): bool =
    amFirstFit notin m and amNoReserve notin m
  proc refreshBudgetCache*(v: ArbiterView): ResourceVec {.discardable.} =
    ResourceVec()
  proc tryCombine*(c: var ArbiterClient; r: var CombineRound): CombineStatus =
    r = CombineRound(status: cbUnavailable, reserveSlot: -1); cbUnavailable
  proc combineUntilAnswered*(c: var ArbiterClient; r: var CombineRound;
      parkNs: int64): AnswerStatus = ansUnavailable
