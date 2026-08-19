## `nim-shm-lease` **M7** — RECLAMATION: giving back the capacity a dead client
## is still holding.
##
## Design authority: `reprobuild-specs/RunQuota-Shared-Memory-Transport.md`
## §"5. Reservation reclamation is the residual cost, independent of algorithm";
## anchoring rules in `reprobuild-specs/RunQuota-Shared-Memory-Structures.md`
## §"Conventions Every Segment Obeys"; campaign milestone
## `reprobuild-specs/RunQuota-Observation-Store.milestones.org` ** M7, whose gate
## lives in `tests/test_shm_lease_kill_injection.nim` and
## `tests/test_shm_lease_reclaim.nim`.
##
## ===========================================================================
## WHY THIS IS A SEPARATE INVARIANT FROM CRASH RECOVERY (SM-5 vs SM-6)
## ===========================================================================
##
## SM-5 says a death never deadlocks admission and never corrupts the structure.
## The arbiter already satisfies it: the epoch fence discards a half-applied
## round, the steal detector recovers the role, and `publishEffective` republishes
## a committed-but-unpublished answer. **None of that gives the capacity back.**
##
## A dead client's grant is still an EFFECTIVE ledger entry, so `heldVec` still
## counts it, so `capacity - held` is permanently smaller for every subsequent
## action. That is SM-6, and the transport spec is explicit about why it is graver
## than a lost observation: "a leaked memory reservation is not a lost statistic —
## it withholds capacity from every subsequent action until reclaimed". Admission
## stays CORRECT (nothing is overcommitted) and becomes progressively USELESS.
##
## ===========================================================================
## THE PER-RESERVATION OWNER ANCHOR ALREADY EXISTS — BY CONSTRUCTION
## ===========================================================================
##
## The obvious reading of "every reservation carries owner identity" is that a
## reservation needs a NEW shared record with a pid in it. It does not, and the
## reason is a property M5 already established for a different purpose:
##
##   * a grant lives in ONE slot's ledger entry, and its amount is that slot's
##     `want`;
##   * `publishRequest` REFUSES a slot whose ledger entry is still an outstanding
##     grant (`psHoldsGrant`), so **at most one outstanding grant exists per slot**
##     — structurally, not by discipline;
##   * the slot already carries `RqOffOwnerPid` + `RqOffOwnerStart`, written by
##     `registerSlot`, and the segment carries the boot id.
##
## So the slot's anchor IS the reservation's anchor, exactly and unambiguously.
## What M7 adds is the READER: a pass that consults it and acts. The fields landed
## in M2 precisely so this would not be a retrofit ("it MUST be designed in from
## the start; it cannot be retrofitted onto a structure whose operations are not
## individually recoverable").
##
## **WHAT IS NOT COVERED, AND IT IS A REAL GAP.** M2's `claimWords` path takes
## capacity by CASing the packed budget word down and hands the caller a
## PROCESS-LOCAL `Reservation` handle. There is no shared record of who holds it,
## so a client killed there leaks capacity irrecoverably. That is not fixed here
## and cannot be without a budget-record format change. It is also not the
## admission path: `arbiterView`'s docstring already forbids driving one budget
## word from `claimWords` and the arbiter at once, and RunQuota's admission is the
## arbiter. Stated rather than left to be discovered.
##
## ===========================================================================
## THE RULE, AND BOTH DIRECTIONS OF GETTING IT WRONG
## ===========================================================================
##
## > A slot is reclaimed when its owner's anchor is NOT `avLive` **and** the slot's
## > words have been unchanged for a bounded grace period.
##
## **THE ANCHOR IS THE SAFETY HALF.** A false positive here is worse than a slow
## reclaim: it hands out capacity that is genuinely in use, which is the overcommit
## this component exists to prevent. `avPidReused` is the verdict only START TIME
## can produce, and it is the one that matters — a pid that exists again after its
## owner died is a DIFFERENT process, and a reclaimer that judges on boot+pid alone
## reads a dead owner as live and leaks the reservation forever.
##
## **THE GRACE IS THE TRANSIENT-WINDOW HALF, and it is not the anchor's backup.**
## `registerSlot` CASes the state and THEN writes pid and start time; `releaseGrant`
## CASes the ledger and THEN stores the state. A slot observed inside either window
## is momentarily indistinguishable from an abandoned one, and the grace is what
## stops a reclaimer from judging a slot in the middle of a two-step write. It is
## the same division of labour constraint 4 states for the steal detector — with
## the roles of the two halves reversed, and the reversal is worth being exact
## about: for the STEAL, the epoch fence buys safety and the anchor buys progress,
## so an early fire costs a wasted round; for RECLAMATION there is no fence, the
## anchor IS the safety, and an early fire costs an overcommit. That is why
## `rmTimeoutOnly` below exists as a required-to-fail control rather than as a
## tuning option.
##
## Both directions are asserted, and each has a mutation that breaks it:
##
##   | direction                            | mutation           | damage            |
##   |--------------------------------------|--------------------|-------------------|
##   | a dead holder's capacity comes back  | `rmIgnoreStartTime`| leak under pid reuse |
##   | a LIVE holder is never reclaimed     | `rmTimeoutOnly`    | reclaims a live grant |
##   | a two-step write is not judged early | `rmNoGrace`        | reclaims mid-registration |
##
## ===========================================================================
## WHAT A PASS DOES, AND WHY DYING INSIDE ONE COSTS NOTHING
## ===========================================================================
##
## Per reclaimed slot, in this order — every step one word, and every prefix a
## consistent state:
##
##   1. CAS the ledger entry `[e, ldGrant] -> [e, ldReleased]`. This is the SAME
##      CAS `releaseGrant` performs, so it inherits DEPARTURE 2's safety argument
##      verbatim: a release only ever makes the effective sum SMALLER, a released
##      entry can never be raised back into a live grant, and the amount is the
##      immutable `want`. **The capacity is back the instant this CAS lands** —
##      everything after it is tidying.
##   2. Bump the RECLAMATION EPOCH (`LhOffReserved1`, the word M2 reserved for
##      exactly this) — a monotone change counter, so "has anything been reclaimed
##      since I last looked" is decidable by a reader that never saw the pass. It
##      is bumped BEFORE the slot is cleared, so a reclaimer that dies mid-slot
##      makes the next pass count that slot twice rather than not at all; for a
##      change counter over-counting costs a re-read and under-counting costs a
##      stale view.
##   3. Clear the slot's payload words (want, ticket, outcome, anchor, wait word).
##   4. RELEASE-store the state to `rqFree`, which is what makes the slot
##      re-registerable. It is last, so a slot is never observed free with a stale
##      PAYLOAD behind it. The one word step 3 does NOT clear is the LEDGER entry:
##      a reclaimed slot reaches `rqFree` still carrying `[old epoch, ldReleased]`.
##      That is deliberate and benign — a released entry is non-effective at any
##      stamp, so it holds nothing, `heldSum` does not count it, and it is exactly
##      the shape `publishRequest`'s raise pass expects — but the guarantee is
##      about the payload rather than about every word, and saying otherwise would
##      be stronger than the code.
##
## A reclaimer that dies at any point leaves a state the next pass finishes: a
## ledger entry already released is skipped, a slot already cleared is `rqFree`,
## and the budget cache is recomputed by the next round, the next release or the
## next pass. **The pass is idempotent and its own crash-recovery**, which is the
## same self-healing shape `refreshBudgetCache` has.
##
## ===========================================================================
## WHAT RECLAMATION DELIBERATELY DOES NOT TOUCH: THE ROLE WORD
## ===========================================================================
##
## A dead client that held the COMBINER ROLE is recovered by the steal detector,
## which is modelled (MV2), fenced by the epoch, and already proven by M5. This
## module does not write the role word at all, and that is a decision rather than
## an omission: a second writer of the role word that is not part of the
## acquire/commit CAS discipline is precisely the shape MV2's Finding 4 rules out
## ("what must not exist is a design in which the role moves in one word and the
## commit lands in another"). Reclaiming the dead holder's SLOT is safe and is what
## this module does; the role it may still nominally own is then owned by a slot
## with no anchor, which `ownerAnchorVerdict` reads as `avNoOwner` and the detector
## treats as stealable — strictly more recoverable than before, through the
## existing path.

import ./packed
import ./anchor
import ./arbiter

type
  ReclaimMutation* = enum
    ## **TEST-ONLY NEGATIVE CONTROLS**, in the same spirit as `ArbiterMutation`:
    ## a rule that has never been seen to fail has not been shown to be
    ## load-bearing. Each turns off exactly one half of the rule above, at exactly
    ## one site. The shipping path passes `{}`.
    rmIgnoreStartTime  ## judge the anchor on boot + pid ONLY. Under pid reuse a
                       ## dead owner then reads as `avLive` and its reservation is
                       ## NEVER reclaimed — SM-6 fails as a LEAK.
    rmTimeoutOnly      ## drop the anchor check; reclaim on the grace alone. A live
                       ## client holding a grant does not touch its words while it
                       ## works, so this reclaims a LIVE holder — the mirror-image
                       ## failure, and the one that overcommits.
    rmNoGrace          ## drop the bounded grace; act on the first observation. A
                       ## slot caught between `registerSlot`'s state CAS and its
                       ## anchor stores is then reclaimed out from under a live
                       ## registrant.

  ReclaimMutations* = set[ReclaimMutation]

  SlotAction* = enum
    ## What a pass did about one slot, per slot, so a caller can log WHY rather
    ## than only HOW MANY.
    saNothing       ## free, and holding nothing: there is nothing to reclaim
    saLive          ## the owner is LIVE — deliberately untouched
    saGrace         ## judged gone, but the bounded grace has not elapsed yet
    saUncommitted   ## a grant proposed by a round that has not committed. Not
                    ## effective, so it holds nothing; a later pass sees it as a
                    ## real grant or not at all
    saReclaimed
    saRaceLost      ## the ledger CAS lost — the entry changed under the pass, so
                    ## somebody else acted. Retried by the next pass.

  ReclaimStats* = object
    passes*: uint64
    slotsReclaimed*: uint64
    grantsReclaimed*: uint64   ## of those, the ones that were holding capacity
    liveSkipped*: uint64       ## THE SAFETY COUNTER: slots a pass looked at and
                               ## deliberately left alone because the owner was
                               ## live. A reclaimer that never increments this has
                               ## never been asked the question that matters.
    graceSkipped*: uint64
    raceLost*: uint64
    anchorProbes*: uint64      ## `kill(pid, 0)` + start-time reads spent

  ReclaimReport* = object
    ## The outcome of ONE pass. Fixed-size arrays: a pass allocates nothing, for
    ## the same reason a combine round does not — a reaper that allocates under
    ## memory pressure is a reaper that fails when it is needed.
    scanned*: int              ## occupied slots examined
    reclaimed*: int
    live*: int
    grace*: int
    raceLost*: int
    freed*: ResourceVec        ## capacity handed back by this pass
    epoch*: uint64             ## the reclamation epoch AFTER this pass
    verdict*: array[MaxRequestSlots, AnchorVerdict]
    action*: array[MaxRequestSlots, SlotAction]

  Reclaimer* = object
    ## The reaper's handle. The per-slot observation timers are PROCESS-LOCAL, for
    ## the reason `ArbiterClient.lastRoleNs` is: a timeout observed by one process
    ## says nothing to another, and putting it in shared memory would invite
    ## exactly that mistake.
    view*: ArbiterView
    graceNs*: int64
    mutations*: ReclaimMutations
    seen*: array[MaxRequestSlots, bool]
    lastState*: array[MaxRequestSlots, uint64]
    lastLedger*: array[MaxRequestSlots, uint64]
    lastNs*: array[MaxRequestSlots, int64]
    stats*: ReclaimStats

const
  DefaultReclaimGraceNs* = 50_000_000'i64
    ## How long a slot's words must have been UNCHANGED before a pass will act on
    ## an anchor that says "gone". It covers the two-step writes named above —
    ## `registerSlot`'s state-then-anchor and `releaseGrant`'s ledger-then-state —
    ## which are a handful of instructions apart, so this is orders of magnitude
    ## more than it needs to be and deliberately so: the grace costs a delayed
    ## reclaim and never a wrong one, while the anchor costs an overcommit if it is
    ## wrong. Longer than `DefaultAnchorProbeAfterNs` (30 ms) because the role is
    ## recovered by the steal path and should not wait for the reaper.

when arbiterSupported:
  import ./hooks
  import std/[monotimes]

  type ShmBase = ptr UncheckedArray[byte]

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

  proc nowNs(): int64 {.inline.} = getMonoTime().ticks

  proc reclaimEpoch*(v: ArbiterView): uint64 {.inline.} =
    ## The monotone count of slots this segment has had reclaimed, in
    ## `LhOffReserved1` — the header word M2 reserved with the note "M7:
    ## reclamation epoch". A reader that never observed a pass can still decide
    ## "has anything been reclaimed since I last looked" by comparing this.
    if not v.available or v.reclaimOff <= 0: return 0
    loadU64Acquire(v.base, v.reclaimOff)

  proc slotOwnerPid*(v: ArbiterView; slot: int): uint64 {.inline.} =
    if not v.available or slot < 0 or slot >= v.slotCount: return 0
    loadU64Relaxed(v.base, v.slotOffset(slot) + RqOffOwnerPid)

  proc slotOwnerStart*(v: ArbiterView; slot: int): uint64 {.inline.} =
    if not v.available or slot < 0 or slot >= v.slotCount: return 0
    loadU64Relaxed(v.base, v.slotOffset(slot) + RqOffOwnerStart)

  proc writeSlotAnchor*(v: ArbiterView; slot: int; pid, start: uint64) =
    ## **TEST SUPPORT**, and it exists for the same reason `writeProbeWord` does:
    ## the pid-reuse property is only provable if a test can put the segment into
    ## the state a pid reuse produces. A natural reuse is not reachable in a test —
    ## macOS hands out pids sequentially and wraps at ~99k, so provoking one would
    ## mean forking the entire pid space — while the state it produces is exactly
    ## "this slot records pid P with a start time that is not P's current start
    ## time". Both values a test writes here are REAL start times of REAL
    ## processes; nothing is fabricated, and the reclaimer cannot tell this apart
    ## from a natural reuse because there is nothing to tell apart.
    if not v.available or slot < 0 or slot >= v.slotCount: return
    let off = v.slotOffset(slot)
    storeU64Relaxed(v.base, off + RqOffOwnerPid, pid)
    storeU64Release(v.base, off + RqOffOwnerStart, start)

  proc newReclaimer*(v: ArbiterView;
      graceNs: int64 = DefaultReclaimGraceNs;
      mutations: ReclaimMutations = {}): Reclaimer =
    Reclaimer(view: v, graceNs: graceNs, mutations: mutations)

  proc slotVerdict*(rc: var Reclaimer; slot: int): AnchorVerdict =
    ## The anchor judgement for one slot, with `rmIgnoreStartTime` applied. The
    ## mutation passes a ZERO recorded start time, which `anchorVerdict` treats as
    ## UNKNOWN and falls back on the weaker boot+pid judgement for — so the
    ## mutation is "the field was never recorded", which is precisely the state a
    ## reclaimer that ignores start time is in, rather than a second code path
    ## that could drift from the real one.
    let pid = rc.view.slotOwnerPid(slot)
    let start =
      if rmIgnoreStartTime in rc.mutations: 0'u64
      else: rc.view.slotOwnerStart(slot)
    inc rc.stats.anchorProbes
    anchorVerdict(rc.view.boot, pid, start)

  proc reclaimPass*(rc: var Reclaimer): ReclaimReport =
    ## ONE reclamation pass over every request slot. Allocation-free and bounded;
    ## it costs about THREE syscalls per OCCUPIED slot — `anchorVerdict` recomputes
    ## the boot id first, which on macOS is itself a `sysctl`, and then spends a
    ## `kill(pid, 0)` and a start-time read — so it is a reaper's operation and
    ## MUST NOT be called from inside a combine round, the same rule constraint 4
    ## states for the anchor half of the steal detector.
    ##
    ## Returns what it did and, per slot, WHY — `anchorVerdict` reports which
    ## check fired rather than collapsing to a boolean precisely so this can be
    ## logged.
    result = ReclaimReport()
    if not rc.view.available: return
    inc rc.stats.passes
    let v = rc.view
    let now = nowNs()
    let cseq = v.combineSeq()
    var freedAny = false

    for i in 0 ..< v.slotCount:
      let off = v.slotOffset(i)
      let st = stateAt(v, i)
      var entry = ledgerAt(v, i)
      let holdsGrant = ledgerDec(entry) == ldGrant
      let occupied = stateOf(st) != rqFree or holdsGrant
      if not occupied:
        result.action[i] = saNothing
        rc.seen[i] = false
        continue
      inc result.scanned

      # THE ANCHOR — the safety half. `rmTimeoutOnly` is what skipping it looks
      # like, and it is required to reclaim a live holder.
      let verdict = rc.slotVerdict(i)
      result.verdict[i] = verdict
      if verdict == avLive and rmTimeoutOnly notin rc.mutations:
        result.action[i] = saLive
        inc result.live
        inc rc.stats.liveSkipped
        rc.seen[i] = false          # a live slot's timer starts fresh if it dies
        continue

      # THE GRACE — the transient-window half. The fingerprint is the two words a
      # two-step write moves: the state and the ledger entry. Any change restarts
      # the clock, which makes the grace conservative in the only direction that
      # matters.
      if rmNoGrace notin rc.mutations:
        if (not rc.seen[i]) or rc.lastState[i] != st or rc.lastLedger[i] != entry:
          rc.seen[i] = true
          rc.lastState[i] = st
          rc.lastLedger[i] = entry
          rc.lastNs[i] = now
          result.action[i] = saGrace
          inc result.grace
          inc rc.stats.graceSkipped
          continue
        if now - rc.lastNs[i] < rc.graceNs:
          result.action[i] = saGrace
          inc result.grace
          inc rc.stats.graceSkipped
          continue

      # A grant a round PROPOSED but has not committed is not effective, holds
      # nothing, and is about to be discarded by the epoch fence or made effective
      # by a commit. Touching it would put this pass inside another round's board,
      # which is the one place the ledger has a fenced writer. Leave it; the next
      # pass sees whichever it became.
      if holdsGrant and ledgerEpoch(entry) > cseq:
        result.action[i] = saUncommitted
        continue

      # 1. GIVE THE CAPACITY BACK. Same CAS as `releaseGrant`, same argument.
      if holdsGrant:
        let want = wantAt(v, i)
        scheduleHook(slpBeforeReclaimCas)
        if not casU64(v.base, off + RqOffLedger, entry,
            ledgerWord(ledgerEpoch(entry), ldReleased)):
          result.action[i] = saRaceLost
          inc result.raceLost
          inc rc.stats.raceLost
          rc.seen[i] = false
          continue
        result.freed = result.freed + unpackVec(want)
        inc rc.stats.grantsReclaimed
        freedAny = true

      # 2. RECORD IT, in the header word M2 reserved for exactly this, BEFORE the
      # slot is cleared rather than after. The order matters for a reclaimer that
      # dies mid-slot: bumping first can make the next pass count the same slot
      # twice, bumping last can make a reclamation go unrecorded. This word is a
      # monotone "has anything been reclaimed since I looked" change counter, not
      # an exact tally, so over-counting is the safe direction — a spurious "yes"
      # costs a re-read and a missed one costs a stale view.
      if v.reclaimOff > 0:
        scheduleHook(slpBeforeReclaimEpoch)
        discard atomicAddFetch(atField(v.base, v.reclaimOff, uint64), 1'u64,
          ATOMIC_ACQ_REL)

      # 3. Clear the payload words, THEN 4. release the slot. The wait word goes
      # to zero with them: nobody is parked on a dead owner's slot, and leaving a
      # stale waiter count would make every future wake on this slot pay for a
      # syscall that can find nobody.
      storeU64Relaxed(v.base, off + RqOffWant, 0)
      storeU64Relaxed(v.base, off + RqOffTicket, 0)
      storeU64Relaxed(v.base, off + RqOffOutcome, ledgerWord(0, ldNone))
      storeU64Relaxed(v.base, off + RqOffOwnerPid, 0)
      storeU64Relaxed(v.base, off + RqOffOwnerStart, 0)
      storeU64Relaxed(v.base, off + RqOffValue, 0)
      storeU64Release(v.base, off + RqOffState, stateWord(rqFree, 0, 0))

      result.action[i] = saReclaimed
      inc result.reclaimed
      inc rc.stats.slotsReclaimed
      rc.seen[i] = false

    # The budget word is a CACHE derived from the stamped ledger (constraint 2), so
    # it is RECOMPUTED — never decremented by what this pass freed. A pass that
    # died before this line leaves the word conservative and the next round, the
    # next release or the next pass repairs it.
    #
    # **THE CONDITION IS "RECLAIMED ANYTHING", NOT "FREED A GRANT", AND THE
    # DIFFERENCE IS A REAL CASE THIS GATE FOUND.** A reaper killed between its
    # ledger CAS and the rest of the slot leaves an entry already `ldReleased` and
    # a slot still occupied. The next pass finishes that slot WITHOUT performing a
    # CAS — there is no grant left to release — so a condition that keyed on
    # `freedAny` would leave the cache understating availability with nothing
    # obliged to repair it. That is the same defect `releaseGrant` was fixed for:
    # rounds are not obliged to happen, and until one does the word is a stale
    # answer handed to every caller of `packedRemaining` / `remainingVec` /
    # `noOvercommit`.
    if result.reclaimed > 0 or freedAny:
      discard v.refreshBudgetCache()
    result.epoch = v.reclaimEpoch()

  proc reclaimUntilQuiet*(rc: var Reclaimer; maxPasses: int = 8): ReclaimReport =
    ## Run passes until one reclaims nothing, bounded. `saRaceLost` and
    ## `saUncommitted` are the two outcomes a single pass can leave behind, and
    ## both are resolved by looking again — this is the loop that does it, with a
    ## bound so a caller can never spin on a board that keeps changing.
    result = ReclaimReport()
    for _ in 0 ..< maxPasses:
      let r = rc.reclaimPass()
      result.scanned = r.scanned
      result.live = r.live
      result.grace = r.grace
      result.raceLost = r.raceLost
      result.reclaimed = result.reclaimed + r.reclaimed
      result.freed = result.freed + r.freed
      result.epoch = r.epoch
      for i in 0 ..< rc.view.slotCount:
        # A slot this pass had nothing to say about keeps whatever the previous
        # pass concluded. Copying unconditionally would overwrite the reason a slot
        # was reclaimed with `avLive` — the enum's zero value — the moment the slot
        # went free, which is exactly the state the pass AFTER a reclamation sees.
        if r.action[i] != saNothing:
          result.action[i] = r.action[i]
          result.verdict[i] = r.verdict[i]
      if r.reclaimed == 0 and r.raceLost == 0: break

else:
  # --- portable no-op arm ----------------------------------------------------
  proc reclaimEpoch*(v: ArbiterView): uint64 = 0
  proc slotOwnerPid*(v: ArbiterView; slot: int): uint64 = 0
  proc slotOwnerStart*(v: ArbiterView; slot: int): uint64 = 0
  proc writeSlotAnchor*(v: ArbiterView; slot: int; pid, start: uint64) = discard
  proc newReclaimer*(v: ArbiterView;
      graceNs: int64 = DefaultReclaimGraceNs;
      mutations: ReclaimMutations = {}): Reclaimer =
    Reclaimer(view: v, graceNs: graceNs, mutations: mutations)
  proc slotVerdict*(rc: var Reclaimer; slot: int): AnchorVerdict = avNoOwner
  proc reclaimPass*(rc: var Reclaimer): ReclaimReport = ReclaimReport()
  proc reclaimUntilQuiet*(rc: var Reclaimer; maxPasses: int = 8): ReclaimReport =
    ReclaimReport()
