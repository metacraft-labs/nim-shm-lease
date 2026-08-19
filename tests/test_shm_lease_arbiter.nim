## M5 UNIT TESTS — the flat-combining arbiter, against the four constraints MV2
## derived BEFORE this code existed.
##
## `verification/tla/shm_lease_combine.tla` is the specification these tests hold
## the implementation to, and the structure of this file follows it: one suite per
## constraint, each with a POSITIVE assertion and — where the mechanism can be
## turned off — a NEGATIVE CONTROL that switches exactly that mechanism off and
## requires the damage to appear. The negative controls are the point. This
## campaign's recurring defect is a check that cannot fail (five instances so far),
## and a constraint whose absence has never been observed to hurt has not been
## shown to be load-bearing.
##
## MOCKS: none. Every test drives a real file-backed `mmap(MAP_SHARED)` segment
## through the shipping API. Several tests run two arbiter CLIENTS inside one
## process — that is not a mock of two processes, it is two clients: the protocol
## is entirely offsets and atomics on shared memory, the clients share no
## process-local state, and the cross-process facts (differing virtual bases, real
## parking, the role migrating between address spaces) are the multi-process gate's
## job, in `tests/test_shm_lease_arbiter_multiprocess.nim`.

import std/[os, posix, unittest]
import shm_lease

var tmpCounter = 0
proc freshPath(tag: string): string =
  inc tmpCounter
  getTempDir() / ("shmlease-arb-" & tag & "-" & $getpid() & "-" & $tmpCounter & ".seg")

proc cleanup(path: string) =
  try: removeFile(path)
  except CatchableError: discard

const
  Cap = vec(8, 64, 8, 100)
  Slots = 8

proc newSeg(tag: string; capacity = Cap; slots = Slots): (string, ShmLease) =
  let path = freshPath(tag)
  var l = createLeaseSegment(path, [capacity], requestSlots = slots)
  (path, l)

proc mkClient(l: ShmLease; slot: int): ArbiterClient =
  result = l.arbiterClient(slot)
  doAssert result.registerSlot(slot)

# ===========================================================================
# The words themselves.
# ===========================================================================

suite "M5 arbiter: the two words MV2 pinned":
  test "the role word carries owner, epoch AND the commit flag":
    # CONSTRAINT 1 at the encoding level: the commit flag is a BIT INSIDE the role
    # word, so a CAS that changes the owner necessarily invalidates a CAS that
    # would set the flag. A layout that put the flag in another word would make
    # these two values differ in a word the acquisition never touches.
    let w = roleWord(3'u16, 7'u32, false)
    check roleOwner(w) == 3'u16
    check roleEpoch(w) == 7'u32
    check not roleCommitted(w)
    check not roleIsFree(w)
    let c = roleWord(3'u16, 7'u32, true)
    check roleCommitted(c)
    check roleOwner(c) == 3'u16 and roleEpoch(c) == 7'u32
    check w != c                      # ...and they are ONE word apart
    check roleIsFree(roleWord(RoleNoOwner, 12'u32, true))
    # The epoch occupies a full u32 and the owner does not bleed into it.
    let big = roleWord(RoleNoOwner, 0xFFFF_FFFF'u32, true)
    check roleEpoch(big) == 0xFFFF_FFFF'u32
    check roleOwner(big) == RoleNoOwner

  test "ledger and state words round-trip, and a corrupt decision reads as none":
    let e = ledgerWord(9'u32, ldGrant)
    check ledgerEpoch(e) == 9'u32
    check ledgerDec(e) == ldGrant
    check ledgerDec(ledgerWord(0'u32, ldNone)) == ldNone
    check ledgerDec(ledgerWord(1'u32, ldRefuse)) == ldRefuse
    check ledgerDec(ledgerWord(1'u32, ldReleased)) == ldReleased
    # A byte that is not a decision must decode as `ldNone` rather than be cast
    # into the enum: a corrupt word must not become undefined behaviour in a
    # process that is about to decide admission on it.
    check ledgerDec(uint64(0x7B'u8) shl 32) == ldNone
    let s = stateWord(rqPending, 0x123456'u32, 0xDEADBEEF'u32)
    check stateOf(s) == rqPending
    check stateGen(s) == 0x123456'u32
    check stateBaseVal(s) == 0xDEADBEEF'u32

# ===========================================================================
# The segment binding.
# ===========================================================================

suite "M5 arbiter: binding to a lease segment":
  test "a segment with request slots exposes an arbiter; an M2-era one does not":
    let (path, l) = newSeg("bind")
    defer: cleanup(path)
    check l.available
    check l.requestSlots == Slots
    let v = l.arbiterView()
    check v.available
    check v.slotCount == Slots
    check v.capacity == Cap
    check v.combineSeq() == 0'u32
    check roleIsFree(v.roleSnapshot())

    # M2 IS BYTE-FOR-BYTE UNTOUCHED: no request slots means the M2 size exactly,
    # and the format version does not move. This is what lets M5 extend the shared
    # structure in place, as `RunQuota-Shared-Memory-Structures.md` requires,
    # without invalidating a segment M2 wrote.
    check leaseSegmentSize(1) == leaseSegmentSize(1, 0)
    let path2 = freshPath("m2era")
    defer: cleanup(path2)
    var l2 = createLeaseSegment(path2, [Cap])
    check l2.available
    check l2.requestSlots == 0
    check not l2.arbiterView().available
    check l2.segmentSize() == leaseSegmentSize(1)
    l2.detach()

    # ...and the segment stays position-independent with the new area in it. The
    # audit's live window was extended to cover the request slots, so this is a
    # real check of the new bytes rather than of the old ones.
    check l.storedPointerCheck()
    var lv = l
    lv.detach()

  test "a request slot is claimed once, and its ANCHOR is written":
    let (path, l) = newSeg("register")
    defer: cleanup(path)
    var a = l.arbiterClient(0)
    check a.registerSlot(0)
    check stateOf(a.view.stateAt(0)) == rqIdle
    # The anchor the steal detector will consult is this process, alive.
    check a.view.ownerAnchorVerdict(0) == avLive
    # A second client cannot take the same slot: the CAS from `rqFree` fails.
    var b = l.arbiterClient(0)
    check not b.registerSlot(0)
    var lv = l
    lv.detach()

# ===========================================================================
# One round, end to end.
# ===========================================================================

suite "M5 arbiter: a combine round":
  test "bulk admission: what fits is granted, what does not stays pending":
    let (path, l) = newSeg("round")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    var b = mkClient(l, 1)
    var d = mkClient(l, 2)
    # 8 CPU slots of capacity against 3 + 3 + 4: the first two fit, the third does
    # not. `dkPending` rather than `dkRefuse` is DEPARTURE 1 from the model — see
    # `arbiter.nim` — and it is what makes a WAITER exist for the gate's clause (a).
    check a.publishRequest(vec(3, 4, 1, 10)) == psPublished
    check b.publishRequest(vec(3, 4, 1, 10)) == psPublished
    check d.publishRequest(vec(4, 4, 1, 10)) == psPublished

    var r: CombineRound
    check a.tryCombine(r) == cbCommitted
    check r.epoch == 1'u32
    check r.owner == 0'u16
    check r.grants == 2
    check r.decisionCount == 3
    check r.decisions[0].kind == dkGrant
    check r.decisions[1].kind == dkGrant
    check r.decisions[2].kind == dkPending      # did not fit; NOT refused
    check r.decisions[2].slot == 2'u16

    # The round is EFFECTIVE: the sequence caught up with the epoch, every
    # decision carries that stamp, and the budget CACHE equals what the ledger
    # says is left. Constraint 2 is this equality, and nothing decremented.
    let v = a.view
    check v.combineSeq() == 1'u32
    check ledgerEpoch(v.ledgerAt(0)) == 1'u32
    check ledgerDec(v.ledgerAt(0)) == ldGrant
    check ledgerDec(v.ledgerAt(2)) == ldNone     # still undecided, still pending
    check v.heldSum() == vec(6, 8, 2, 20)
    check v.budgetCache() == Cap - vec(6, 8, 2, 20)

    # GRANT-THEN-WAKE: the value word carries the COMBINE EPOCH (constraint 3) and
    # the payload is tagged with the same epoch, which is what makes "the waiter
    # read the payload published for the value it saw" checkable.
    check v.valueAt(0) == 1'u32
    check v.valueAt(1) == 1'u32
    check v.valueAt(2) == 0'u32                  # unanswered: never moved
    check ledgerEpoch(v.outcomeAt(0)) == v.valueAt(0)

    check a.collectAnswer() == ansGranted
    check b.collectAnswer() == ansGranted
    check d.collectAnswer() == ansNone
    check stateOf(v.stateAt(0)) == rqHolding
    check stateOf(v.stateAt(2)) == rqPending

    # A second round has nothing to publish and nothing new to decide. The pending
    # request is still visible to `workPending` — DEPARTURE 1 leaves it there — but
    # it STILL DOES NOT FIT, so there is nothing a round could decide and no round
    # is run at all. It used to commit here, grant nothing, and advance the epoch;
    # see `decidableWork` and DEPARTURE 1 in `arbiter.nim` for what that cost.
    check v.workPending()                        # the request is still on the board
    check not v.decidableWork()                  # ...and nothing can be done about it
    var r2: CombineRound
    check b.tryCombine(r2) == cbNoWork
    check r2.grants == 0
    # NOTE: this line used to also assert `r2.published == 0` under the heading
    # "REPUBLICATION IS A NO-OP". It was VACUOUS and has been dropped rather than
    # left in: no round runs here at all, so nothing is republished and the counter
    # could not have been anything else. The real property — that republishing an
    # answered slot writes the same word twice and delivers once — is carried by
    # "republishing an answered slot is a NO-OP, because the value IS the epoch"
    # below, by `forgePublishHook`'s interleaving in
    # `tests/test_shm_lease_hooks.nim`, and by the same file's recovery test, where
    # a republication that DOES happen is asserted to deliver exactly one answer.
    check r2.wakes == 0
    check v.combineSeq() == 1'u32                # ...and NO EPOCH WAS BURNED
    check roleEpoch(v.roleSnapshot()) == 1'u32
    check v.valueAt(0) == 1'u32                  # the collected slot did not move

    # Release, then combine: the freed capacity is redistributed and the waiter is
    # answered. This is the shape of the gate's clause (a).
    check a.releaseGrant()
    check v.heldSum() == vec(3, 4, 1, 10)
    var r3: CombineRound
    check d.tryCombine(r3) == cbCommitted
    check r3.grants == 1
    check d.collectAnswer() == ansGranted
    check v.heldSum() == vec(7, 8, 2, 20)
    check v.budgetCache() == Cap - vec(7, 8, 2, 20)
    var lv = l
    lv.detach()

  test "a request that can NEVER fit is refused, and the refusal is delivered":
    let (path, l) = newSeg("refuse")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    check a.publishRequest(vec(9, 1, 1, 1)) == psPublished   # capacity is 8 slots
    var r: CombineRound
    check a.tryCombine(r) == cbCommitted
    check r.decisionCount == 1
    check r.decisions[0].kind == dkRefuse
    check a.collectAnswer() == ansRefused
    check a.view.heldSum() == ResourceVec()
    # ...and the slot is reusable afterwards, with the stamp cleared for the next
    # round's raise pass.
    check a.publishRequest(vec(1, 1, 1, 1)) == psPublished
    var r2: CombineRound
    check a.tryCombine(r2) == cbCommitted
    check a.collectAnswer() == ansGranted
    var lv = l
    lv.detach()

  test "an empty board does NOT burn an epoch":
    # `workPending` is the guard, and MV2 needs it: without it the epoch counter
    # runs away on empty rounds and `EpochBoundNotBinding` stops being provable.
    let (path, l) = newSeg("nowork")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    var r: CombineRound
    check a.tryCombine(r) == cbNoWork
    check roleEpoch(a.view.roleSnapshot()) == 0'u32
    check a.publishRequest(vec(1, 1, 1, 1)) == psPublished
    check a.tryCombine(r) == cbCommitted
    check roleEpoch(a.view.roleSnapshot()) == 1'u32
    check a.tryCombine(r) == cbNoWork
    check roleEpoch(a.view.roleSnapshot()) == 1'u32
    var lv = l
    lv.detach()

  test "a board of UNDECIDABLE requests does not burn an epoch either":
    # DEPARTURE 1's EPOCH CONSEQUENCE, which `workPending` alone does not cover. A
    # request that does not fit is left PENDING, so `workPending` stays true for as
    # long as it is unfittable — and before `decidableWork` existed, every call
    # here committed a full round that granted nothing and advanced the epoch.
    # MEASURED THEN: ten calls, ten committed rounds, `grants == 0` in each, the
    # role epoch 1 -> 11. That is the unbounded churn MV2 rules out with
    # `EpochBoundNotBinding`, and it is what filled the gate's single-combiner arm
    # with 1024 empty rounds until the lone combiner stopped and stranded its
    # peers. The assertion is the whole loop: EXACTLY ONE round runs.
    let (path, l) = newSeg("undecidable")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    var b = mkClient(l, 1)
    let v = a.view
    check a.publishRequest(vec(7, 8, 2, 20)) == psPublished
    var r: CombineRound
    check a.tryCombine(r) == cbCommitted
    check r.grants == 1
    check a.collectAnswer() == ansGranted
    # B now asks for something that fits an IDLE machine — so it is not refusable —
    # and does not fit THIS one. It stays pending, and stays pending.
    check b.publishRequest(vec(4, 4, 1, 10)) == psPublished
    check v.workPending()
    check not v.decidableWork()
    let epochAfterGrant = roleEpoch(v.roleSnapshot())
    let seqAfterGrant = v.combineSeq()
    for i in 0 ..< 10:
      var rn: CombineRound
      check b.tryCombine(rn) == cbNoWork
      check rn.grants == 0
    check roleEpoch(v.roleSnapshot()) == epochAfterGrant
    check v.combineSeq() == seqAfterGrant
    check b.stats.roundsCommitted == 0'u64
    check b.stats.roundsNoWork == 10'u64
    # ...and the moment the capacity is genuinely free, the SAME loop decides it.
    check a.releaseGrant()
    check v.decidableWork()
    var r2: CombineRound
    check b.tryCombine(r2) == cbCommitted
    check r2.grants == 1
    check roleEpoch(v.roleSnapshot()) == epochAfterGrant + 1
    check b.collectAnswer() == ansGranted
    var lv = l
    lv.detach()

  test "the arbiter works through a SECOND mapping at a different base (SM-7)":
    let (path, l) = newSeg("bases")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    let far = mmap(nil, l.segmentSize(), PROT_NONE,
      MAP_PRIVATE or MAP_ANONYMOUS, cint(-1), 0)
    check far != MAP_FAILED
    var view = attachLeaseSegment(path, far)
    check view.available
    check cast[uint](view.mappedBase()) != cast[uint](l.mappedBase())
    var b = view.arbiterClient(1)
    check b.registerSlot(1)
    check a.publishRequest(vec(2, 2, 1, 5)) == psPublished
    check b.publishRequest(vec(2, 2, 1, 5)) == psPublished
    # The round is run from the FAR mapping and answers a request published
    # through the near one; every word in play is addressed by offset.
    var r: CombineRound
    check b.tryCombine(r) == cbCommitted
    check r.grants == 2
    check a.collectAnswer() == ansGranted
    check b.collectAnswer() == ansGranted
    check l.arbiterView().heldSum() == view.arbiterView().heldSum()
    view.detach()
    var lv = l
    lv.detach()

# ===========================================================================
# CONSTRAINT 1 — commit and role transfer resolve in ONE CAS on ONE word.
# ===========================================================================

suite "M5 constraint 1: the commit CAS is the CAS the steal invalidates":
  test "a stolen-from combiner's commit FAILS; the same commit in the OTHER word would not":
    # `shm_lease_combine_unfenced_MC.cfg` violates `NeverBoth` on a 13-state trace:
    # a combiner stalls at its commit, is stolen from, resumes, and commits a round
    # the stealer already discarded. MV2's necessary condition is that the commit
    # and the role transfer be resolved by a single CAS on a single word. This test
    # is that condition, executed.
    let (path, l) = newSeg("fence")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    var b = mkClient(l, 1)
    let v = a.view

    # A holds the role at epoch 1, uncommitted — the state a combiner is in for
    # the whole of its round.
    var free = v.roleSnapshot()
    check v.casRoleWord(free, roleWord(0'u16, 1'u32, false))

    # B steals it. EVERY acquisition bumps the epoch, because the epoch is the
    # fence.
    var observed = v.roleSnapshot()
    check v.casRoleWord(observed, roleWord(1'u16, 2'u32, false))

    # A resumes and executes its commit. It MUST fail: the word it is CASing is
    # the word the steal replaced.
    var stale = roleWord(0'u16, 1'u32, false)
    check not v.casRoleWord(stale, roleWord(0'u16, 1'u32, true))
    check roleOwner(v.roleSnapshot()) == 1'u16
    check roleEpoch(v.roleSnapshot()) == 2'u32
    check not roleCommitted(v.roleSnapshot())

    # THE COUNTERFACTUAL, and it is what makes the assertion above evidence rather
    # than a tautology: the ALTERNATIVE design commits by a monotone store on the
    # SEPARATE sequence word, and nothing the steal touched invalidates that. A's
    # stale commit would have succeeded — which is exactly the half-applied,
    # half-discarded round the model finds.
    check v.combineSeq() == 0'u32
    v.storeCombineSeq(1'u32)
    check v.combineSeq() == 1'u32     # the stale commit LANDS in the other word
    var lv = l
    lv.detach()

  test "a round abandoned mid-flight leaves the ledger and the budget intact":
    # The damage clause: a discarded round must leave NO trace. Here the round is
    # abandoned by the fence rather than by a crash (crash injection is M7), and
    # the check is `BudgetExact`'s shape — at quiescence the budget word equals
    # exactly what the committed ledger says is left.
    let (path, l) = newSeg("discard")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    var b = mkClient(l, 1)
    let v = a.view
    check a.publishRequest(vec(2, 2, 1, 5)) == psPublished
    check b.publishRequest(vec(2, 2, 1, 5)) == psPublished
    var r: CombineRound
    check a.tryCombine(r) == cbCommitted
    check a.collectAnswer() == ansGranted
    check b.collectAnswer() == ansGranted
    let heldBefore = v.heldSum()
    let budgetBefore = v.budgetCache()

    # Now leave the role word looking like a round that decided nothing and died:
    # owner A, next epoch, uncommitted. The next combiner must discard it.
    var cur = v.roleSnapshot()
    check v.casRoleWord(cur, roleWord(0'u16, roleEpoch(cur) + 1, false))
    check a.releaseGrant()
    check b.publishRequest(vec(1, 1, 1, 1)) == psHoldsGrant  # still holding
    check b.releaseGrant()
    check b.publishRequest(vec(1, 1, 1, 1)) == psPublished
    var r2: CombineRound
    # B's steal timeout is what recovers the abandoned round.
    b.stealAfterNs = 0
    discard b.tryCombine(r2)          # first sighting arms the detector
    check b.tryCombine(r2) == cbCommitted
    check r2.stolen
    check b.collectAnswer() == ansGranted
    check v.heldSum() == vec(1, 1, 1, 1)
    check v.budgetCache() == Cap - vec(1, 1, 1, 1)
    check heldBefore == vec(4, 4, 2, 10)
    check budgetBefore == Cap - vec(4, 4, 2, 10)
    var lv = l
    lv.detach()

# ===========================================================================
# CONSTRAINT 2 — the budget word is a CACHE, never an accumulator.
# ===========================================================================

suite "M5 constraint 2: the budget word is derived, not decremented":
  test "grant, release and recompute leave the word EXACTLY right":
    let (path, l) = newSeg("cache")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    let v = a.view
    for i in 0 ..< 5:
      check a.publishRequest(vec(2, 2, 1, 5)) == psPublished
      var r: CombineRound
      check a.tryCombine(r) == cbCommitted
      check a.collectAnswer() == ansGranted
      check v.budgetCache() == Cap - v.heldSum()
      check a.releaseGrant()
      # ...AND ACROSS THE RELEASE, WITH NO ROUND IN BETWEEN. This is the
      # assertion the test used to avoid: it checked the word BEFORE the release
      # and only the ledger after, which is exactly the shape of a suite written
      # around a gap. `releaseGrant` recomputes the word from the stamped ledger
      # (it does not decrement it), so `BudgetExact` — the budget word equals
      # `capacity - Σ effective grants` at quiescence — holds at EVERY quiescent
      # point of this loop and not merely at the ones a round happens to touch.
      # Measured before the fix: (4, 60, 7, 90) in the word against (8, 64, 8,
      # 100) in the ledger, handed to any caller of the public `budgetCache`,
      # `packedRemaining` or `noOvercommit`.
      check v.heldSum() == ResourceVec()
      check v.budgetCache() == Cap
      check v.budgetCache() == Cap - v.heldSum()
    check a.publishRequest(vec(1, 1, 1, 1)) == psPublished
    var rr: CombineRound
    check a.tryCombine(rr) == cbCommitted
    check v.budgetCache() == Cap - vec(1, 1, 1, 1)
    # And the same identity survives the last release of the segment's life, when
    # by construction no round follows it to repair the word.
    check a.collectAnswer() == ansGranted
    check a.releaseGrant()
    check v.heldSum() == ResourceVec()
    check v.budgetCache() == Cap - v.heldSum()
    var lv = l
    lv.detach()

  test "NEGATIVE CONTROL: an incrementally decremented word DESTROYS capacity":
    # `shm_lease_combine_budget_MC.cfg` violates `BudgetExact` on a 26-state trace,
    # and the mutation is the obvious implementation — the one `claimWords` already
    # uses. `amIncrementalBudget` is that implementation, and this test is the
    # damage in code: the decrement and the stamp are two words, so a release that
    # clears the stamp does not restore the word, and the capacity is withheld from
    # every subsequent action for the lifetime of the segment.
    let (path, l) = newSeg("budgetmut")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    a.mutations = {amIncrementalBudget}
    let v = a.view
    for i in 0 ..< 3:
      check a.publishRequest(vec(2, 2, 1, 5)) == psPublished
      var r: CombineRound
      check a.tryCombine(r) == cbCommitted
      check a.collectAnswer() == ansGranted
      check a.releaseGrant()
    # The ledger says nothing is held...
    check v.heldSum() == ResourceVec()
    # ...and the word says 6 CPU slots of the 8 are gone, permanently.
    check v.budgetCache() != Cap - v.heldSum()
    check v.budgetCache().cpuSlots == 2'u32
    # The shipping path repairs it in one recompute, which is the whole argument
    # for deriving rather than accumulating.
    a.mutations = {}
    discard v.refreshBudgetCache()
    check v.budgetCache() == Cap - v.heldSum()
    var lv = l
    lv.detach()

  test "NEGATIVE CONTROL: a fit test blind to its own proposals OVERCOMMITS":
    # `shm_lease_combine_fit_MC.cfg`. Deciding every request in a bulk round
    # against the view the round STARTED with is the single most plausible bug
    # here: each decision is individually correct against a real state of the
    # budget, and their SUM overcommits.
    let (path, l) = newSeg("fitmut")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    var b = mkClient(l, 1)
    var d = mkClient(l, 2)
    a.mutations = {amBlindFit}
    check a.publishRequest(vec(3, 4, 1, 10)) == psPublished
    check b.publishRequest(vec(3, 4, 1, 10)) == psPublished
    check d.publishRequest(vec(3, 4, 1, 10)) == psPublished
    var r: CombineRound
    check a.tryCombine(r) == cbCommitted
    check r.grants == 3                          # 9 CPU slots out of 8
    let held = a.view.heldSum()
    check held.cpuSlots > Cap.cpuSlots           # OVERCOMMIT, observed
    # And the same workload on the shipping path grants exactly two.
    let (path2, l2) = newSeg("fitok")
    defer: cleanup(path2)
    var a2 = mkClient(l2, 0)
    var b2 = mkClient(l2, 1)
    var d2 = mkClient(l2, 2)
    check a2.publishRequest(vec(3, 4, 1, 10)) == psPublished
    check b2.publishRequest(vec(3, 4, 1, 10)) == psPublished
    check d2.publishRequest(vec(3, 4, 1, 10)) == psPublished
    var r2: CombineRound
    check a2.tryCombine(r2) == cbCommitted
    check r2.grants == 2
    check a2.view.heldSum().cpuSlots <= Cap.cpuSlots
    var lv = l
    lv.detach()
    var lv2 = l2
    lv2.detach()

# ===========================================================================
# CONSTRAINT 3 — serialise per slot AND carry the epoch in the published value.
# ===========================================================================

suite "M5 constraint 3: serialisation AND the epoch in the value":
  test "republishing an answered slot is a NO-OP, because the value IS the epoch":
    let (path, l) = newSeg("idem")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    var b = mkClient(l, 1)
    let v = a.view
    check a.publishRequest(vec(1, 1, 1, 1)) == psPublished
    var r: CombineRound
    check a.tryCombine(r) == cbCommitted
    check r.published == 1
    check r.wakes == 1
    let val = v.valueAt(0)
    check val == r.epoch
    # A second combiner sweeps the same effective entry. Under the shipped rule it
    # writes the same value, so the CAS is skipped, the waiter's word does not
    # move, and there is no second wake. `shm_lease_combine_counter_MC.cfg` is the
    # configuration in which that is not true.
    check b.publishRequest(vec(1, 1, 1, 1)) == psPublished
    var r2: CombineRound
    check b.tryCombine(r2) == cbCommitted
    check v.valueAt(0) == val                    # slot 0 did NOT move again
    check r2.published == 1                      # only slot 1's answer
    check r2.wakes == 1
    var lv = l
    lv.detach()

  test "NEGATIVE CONTROL: a counter bump republishes, and wakes EXCEED grants":
    # `IdempotentPublish = FALSE` — which is what `publishGrant` does today
    # (`value + 1`), and the reason MV1's precondition existed at all. A stealer
    # completing a committed round cannot tell whether the dead combiner already
    # published; with a counter it republishes and the waiter's word moves twice
    # for one grant. SM-3 is `wakes <= grants`, and here it fails.
    let (path, l) = newSeg("countermut")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    var b = mkClient(l, 1)
    b.mutations = {amCounterPublish}
    let v = a.view
    check a.publishRequest(vec(1, 1, 1, 1)) == psPublished
    var r: CombineRound
    check a.tryCombine(r) == cbCommitted
    let val = v.valueAt(0)
    check b.publishRequest(vec(1, 1, 1, 1)) == psPublished
    var r2: CombineRound
    check b.tryCombine(r2) == cbCommitted
    check v.valueAt(0) != val                    # ...it moved AGAIN, for one grant
    check r2.published == 2                      # two publications, one new grant
    check r2.grants == 1
    check r2.wakes > r2.grants                   # SM-3 VIOLATED, observed
    var lv = l
    lv.detach()

  test "an EFFECTIVE grant is never restamped, however many rounds run":
    let (path, l) = newSeg("serial")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    var b = mkClient(l, 1)
    let v = a.view
    check a.publishRequest(vec(2, 2, 1, 5)) == psPublished
    var r: CombineRound
    check a.tryCombine(r) == cbCommitted
    check a.collectAnswer() == ansGranted
    let stamp = v.ledgerAt(0)
    for i in 0 ..< 4:
      check b.publishRequest(vec(1, 1, 1, 1)) == psPublished
      var rr: CombineRound
      check b.tryCombine(rr) == cbCommitted
      check b.collectAnswer() == ansGranted
      check b.releaseGrant()
      check v.ledgerAt(0) == stamp     # A's held grant is untouched by all of it
    check a.stats.grantsCollected == 1'u64
    var lv = l
    lv.detach()

  test "NEGATIVE CONTROL: without serialisation an answered slot is granted AGAIN":
    # `shm_lease_combine_noserial_MC.cfg`, `NoDoubleGrant` at a 32-state trace: a
    # request that has ALREADY BEEN COLLECTED is re-decided and granted a second
    # time. Serialisation is the mechanism that stops it, and the epoch in the
    # published value cannot cover for it — the slot is stamped correctly
    # throughout; the question serialisation answers is "may I grant into this
    # slot at all?".
    let (path, l) = newSeg("noserial")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    var b = mkClient(l, 1)
    b.mutations = {amNoSerialise}
    let v = a.view
    check a.publishRequest(vec(2, 2, 1, 5)) == psPublished
    var r: CombineRound
    check a.tryCombine(r) == cbCommitted
    check a.collectAnswer() == ansGranted        # collected, and HOLDING
    let held1 = v.heldSum()
    check held1 == vec(2, 2, 1, 5)

    # B's round clears the board rather than respecting the answered slot. A's
    # entry is restamped to B's epoch with its decision erased...
    check b.publishRequest(vec(1, 1, 1, 1)) == psPublished
    var r2: CombineRound
    check b.tryCombine(r2) == cbCommitted
    # ...so the ledger has FORGOTTEN what A holds: the capacity A is using is
    # counted as free, which is the erasure-behind-a-collected-outcome that
    # `NoDiscardOfCollected` and `GrantedEqualsTaken` witness in the model.
    check v.heldSum() != held1
    check v.heldSum().cpuSlots < held1.cpuSlots
    check ledgerDec(v.ledgerAt(0)) == ldNone     # A's grant, erased
    check stateOf(v.stateAt(0)) == rqHolding     # while A still holds it
    var lv = l
    lv.detach()

# ===========================================================================
# CONSTRAINT 4 — the steal detector: the anchor check AND a bounded timeout.
# ===========================================================================

suite "M5 constraint 4: the steal detector needs both halves":
  test "with the timeout disabled and a LIVE holder, nobody steals":
    let (path, l) = newSeg("nosteal")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    var b = mkClient(l, 1)
    let v = a.view
    check b.publishRequest(vec(1, 1, 1, 1)) == psPublished
    var cur = v.roleSnapshot()
    check v.casRoleWord(cur, roleWord(0'u16, 1'u32, false))   # A holds it
    b.stealAfterNs = -1                # timeout half OFF
    b.anchorProbeAfterNs = 0           # anchor half ON, and A is alive
    var r: CombineRound
    check b.tryCombine(r) == cbRoleBusy
    check b.tryCombine(r) == cbRoleBusy
    check b.stats.anchorProbes > 0'u64  # the anchor really was consulted...
    check b.stats.anchorSteals == 0'u64 # ...and it correctly refused to fire
    var lv = l
    lv.detach()

  test "the ANCHOR alone recovers a role held by a process that is GONE":
    # This is the half that buys PROGRESS. With the timeout set beyond the life of
    # the test, the only thing that can recover admission is the boot+pid+start
    # anchor — and it does. Deleting the anchor check leaves this test hanging on
    # the timeout, which is exactly the liveness cost MV2's Finding 5 describes.
    let (path, l) = newSeg("anchor")
    defer: cleanup(path)
    var b = mkClient(l, 1)
    let v = b.view
    # Slot 0's anchor names a pid that does not exist, so it reads as gone. (A
    # forged anchor is how M2 proves start time is consulted; same technique.)
    let off = v.slotOffset(0)
    let deadPid = cast[ptr uint64](addr v.base[off + RqOffOwnerPid])
    let deadStart = cast[ptr uint64](addr v.base[off + RqOffOwnerStart])
    deadPid[] = 0x7FFF_FFF0'u64
    deadStart[] = 1'u64
    check v.ownerAnchorVerdict(0) == avOwnerGone
    check b.publishRequest(vec(1, 1, 1, 1)) == psPublished
    var cur = v.roleSnapshot()
    check v.casRoleWord(cur, roleWord(0'u16, 1'u32, false))
    b.stealAfterNs = 3600_000_000_000'i64        # an hour: the timeout cannot fire
    b.anchorProbeAfterNs = 0
    var r: CombineRound
    check b.tryCombine(r) == cbRoleBusy           # first sighting arms the detector
    check b.tryCombine(r) == cbCommitted          # the ANCHOR recovered it
    check r.stolen
    check b.stats.anchorSteals == 1'u64
    check b.collectAnswer() == ansGranted
    var lv = l
    lv.detach()

  test "the bounded TIMEOUT recovers a role held by a process that is merely stuck":
    # The other half. The holder here is this very process — alive, anchor green,
    # and not making progress. Only the timeout can recover it, and MV2 says an
    # early fire costs a wasted round rather than correctness.
    let (path, l) = newSeg("timeout")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    var b = mkClient(l, 1)
    let v = a.view
    check b.publishRequest(vec(1, 1, 1, 1)) == psPublished
    var cur = v.roleSnapshot()
    check v.casRoleWord(cur, roleWord(0'u16, 1'u32, false))
    check v.ownerAnchorVerdict(0) == avLive      # the anchor CANNOT help here
    b.stealAfterNs = 0
    b.anchorProbeAfterNs = 3600_000_000_000'i64  # anchor half effectively off
    var r: CombineRound
    check b.tryCombine(r) == cbRoleBusy
    check b.tryCombine(r) == cbCommitted
    check r.stolen
    check b.stats.steals == 1'u64
    check b.stats.anchorSteals == 0'u64
    var lv = l
    lv.detach()

# ===========================================================================
# The inherited precondition, and the coherence detector.
# ===========================================================================

suite "M5: publishGrant's precondition is now satisfied BY CONSTRUCTION":
  test "a slot with an outstanding grant REFUSES a second request":
    # M3 documented "at most one outstanding grant per slot" as a contract that
    # "is not enforced here" and left M5 owing a decision. This is the decision:
    # a second grant cannot be published into a slot because a second REQUEST
    # cannot exist there.
    let (path, l) = newSeg("precond")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    check a.publishRequest(vec(1, 1, 1, 1)) == psPublished
    check a.publishRequest(vec(1, 1, 1, 1)) == psNotIdle     # already pending
    var r: CombineRound
    check a.tryCombine(r) == cbCommitted
    check a.collectAnswer() == ansGranted
    check a.publishRequest(vec(1, 1, 1, 1)) == psHoldsGrant  # <-- THE PRECONDITION
    check a.releaseGrant()
    check a.publishRequest(vec(1, 1, 1, 1)) == psPublished
    var lv = l
    lv.detach()

  test "the coherence detector FIRES when a payload is tagged for another round":
    # `GrantCoherent` as a runtime check. Forged rather than raced, because the
    # protocol makes the race unreachable — and a detector that has never been
    # seen to fire has not been shown to detect anything.
    let (path, l) = newSeg("coherent")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    let v = a.view
    check a.publishRequest(vec(1, 1, 1, 1)) == psPublished
    var r: CombineRound
    check a.tryCombine(r) == cbCommitted
    let payload = cast[ptr uint64](addr v.base[v.slotOffset(0) + RqOffOutcome])
    payload[] = ledgerWord(ledgerEpoch(payload[]) + 7'u32, ldGrant)
    check a.collectAnswer() == ansIncoherent
    var lv = l
    lv.detach()

suite "M5: a combine round is syscall-free":
  test "a round that answers nobody parked enters the kernel ZERO times":
    # The milestone requires combine rounds to be "bounded, allocation-free, and
    # syscall-free". The only syscall a round can make is the wake of a waiter it
    # has just answered, and M3's waker fast path skips even that when nobody is
    # parked — so a round over unparked waiters must cost exactly nothing, and the
    # kernel's own counter is what says so.
    if not syscallCountAvailable():
      echo "  [skip] no in-process kernel syscall counter on this platform " &
        "(Linux: `just test-syscalls` counts from outside)"
      skip()
    else:
      let (path, l) = newSeg("syscalls")
      defer: cleanup(path)
      var a = mkClient(l, 0)
      var b = mkClient(l, 1)
      # Calibrate the counter in-suite before trusting it, as M3 and M4 both do.
      let c0 = unixSyscallCount()
      for i in 0 ..< 200: discard getppid()
      let calib = unixSyscallCount() - c0
      check calib >= 200'u64

      check a.publishRequest(vec(1, 1, 1, 1)) == psPublished
      check b.publishRequest(vec(1, 1, 1, 1)) == psPublished
      var r: CombineRound
      let before = unixSyscallCount()
      check a.tryCombine(r) == cbCommitted
      let delta = unixSyscallCount() - before
      check r.grants == 2
      check r.published == 2
      check r.wakes == 2                  # two wakes ISSUED...
      check r.wakeSyscalls == 0           # ...and neither entered the kernel
      check delta == 0'u64
      # The control: a wake that does not consult the waiter count DOES enter the
      # kernel, so the zero above is a measurement rather than a broken counter.
      let b2 = unixSyscallCount()
      discard wakeRaw(a.view.base, a.view.slotOffset(0))
      check unixSyscallCount() - b2 > 0'u64
      echo "  [m5] round syscalls=", delta, " (calibration ", calib,
        " for 200 getppid), wakes=", r.wakes, " wakeSyscalls=", r.wakeSyscalls
      var lv = l
      lv.detach()

# ===========================================================================
# M6 — THE ANTI-STARVATION POLICY: arrival order, and ONE reservation head.
# ===========================================================================
#
# `RunQuota-Observation-Store.milestones.org` ** M6, and
# `RunQuota-Shared-Memory-Transport.md` §"2. Policy is the actual obstacle".
#
# The multi-process gate (`tests/test_shm_lease_starvation.nim`) proves the
# END-TO-END property — an 8 GiB claim admitted within a bounded wait under a
# continuous 512 MiB storm, with four other admission policies failing the same
# test. THESE tests prove the MECHANISM, deterministically and in one process:
# which request is scanned first, which one holds capacity idle, how much, and
# when it stops. Each has a control that switches exactly the mechanism under test
# off, in the same board, and requires the behaviour to change.

suite "M6 rule 1: the scan runs in ARRIVAL order, not slot order":
  test "requests published in REVERSE slot order are decided oldest first":
    # THE FALSIFIABLE PAIR. Three clients publish in reverse slot order, so
    # arrival order and slot order are exact opposites and no run can satisfy both
    # readings. Everything fits, so the ORDER is the only thing under test.
    let (path, l) = newSeg("arrival")
    defer: cleanup(path)
    var c2 = mkClient(l, 2)
    var c1 = mkClient(l, 1)
    var c0 = mkClient(l, 0)
    check c2.publishRequest(vec(1, 1, 1, 1)) == psPublished
    check c1.publishRequest(vec(1, 1, 1, 1)) == psPublished
    check c0.publishRequest(vec(1, 1, 1, 1)) == psPublished
    # The tickets really are in publication order, which is what the scan sorts by.
    let v = c0.view
    check v.ticketAt(2) < v.ticketAt(1)
    check v.ticketAt(1) < v.ticketAt(0)

    var r: CombineRound
    check c0.tryCombine(r) == cbCommitted
    check r.decisionCount == 3
    check r.grants == 3
    # OLDEST FIRST: slots 2, 1, 0 — the exact reverse of the slot order M5 used.
    check r.decisions[0].slot == 2'u16
    check r.decisions[1].slot == 1'u16
    check r.decisions[2].slot == 0'u16
    for i in 1 ..< r.decisionCount:
      check r.decisions[i].ticket > r.decisions[i - 1].ticket

  test "...and the CONTROL that turns the ordering off decides slot order":
    # `amSlotOrder` on the identical board. If the assertions above were reading
    # a coincidence rather than the policy, this one would agree with them.
    let (path, l) = newSeg("arrivalctl")
    defer: cleanup(path)
    var c2 = mkClient(l, 2)
    var c1 = mkClient(l, 1)
    var c0 = mkClient(l, 0)
    c0.mutations = {amSlotOrder}
    check c2.publishRequest(vec(1, 1, 1, 1)) == psPublished
    check c1.publishRequest(vec(1, 1, 1, 1)) == psPublished
    check c0.publishRequest(vec(1, 1, 1, 1)) == psPublished
    var r: CombineRound
    check c0.tryCombine(r) == cbCommitted
    check r.decisionCount == 3
    check r.decisions[0].slot == 0'u16
    check r.decisions[1].slot == 1'u16
    check r.decisions[2].slot == 2'u16
    # ...and the tickets DESCEND, which is the inversion the M5 gate's replay
    # counts and requires to be zero on the shipping path.
    var inversions = 0
    for i in 1 ..< r.decisionCount:
      if r.decisions[i].ticket < r.decisions[i - 1].ticket: inc inversions
    check inversions == 2

  test "a re-request goes to the BACK of the arrival order":
    # The fairness rule that keeps one busy client from owning the head position:
    # `publishRequest` stamps a FRESH ticket, so a client that is granted,
    # releases and asks again is younger than everything already waiting.
    let (path, l) = newSeg("reticket")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    var b = mkClient(l, 1)
    check a.publishRequest(vec(1, 1, 1, 1)) == psPublished
    let firstTicket = a.view.ticketAt(0)
    var r: CombineRound
    check a.tryCombine(r) == cbCommitted
    check a.collectAnswer() == ansGranted
    check b.publishRequest(vec(1, 1, 1, 1)) == psPublished
    check a.releaseGrant()
    check a.publishRequest(vec(1, 1, 1, 1)) == psPublished
    check a.view.ticketAt(0) > firstTicket          # a fresh stamp...
    check a.view.ticketAt(0) > a.view.ticketAt(1)   # ...and it is now the younger
    check b.tryCombine(r) == cbCommitted
    check r.decisions[0].slot == 1'u16              # B, which waited, goes first

  test "publishing a request costs ZERO kernel syscalls":
    # M6 put a monotonic-clock read on the publish path, and `publishRequest`'s
    # docstring says it never enters the kernel. `CLOCK_MONOTONIC` is served from
    # the commpage on macOS and the vDSO on Linux, so that is TRUE — but a claim
    # about syscalls is exactly the kind this campaign measures rather than
    # asserts, so the kernel's own counter says it.
    if not syscallCountAvailable():
      echo "  [skip] no in-process kernel syscall counter on this platform"
      skip()
    else:
      let (path, l) = newSeg("pubsyscalls")
      defer: cleanup(path)
      var a = mkClient(l, 0)
      let c0 = unixSyscallCount()
      for i in 0 ..< 200: discard getppid()
      let calib = unixSyscallCount() - c0
      check calib >= 200'u64
      var r: CombineRound
      var published = 0
      let before = unixSyscallCount()
      for i in 0 ..< 500:
        if a.publishRequest(vec(1, 1, 1, 1)) == psPublished: inc published
        # Settle the request without leaving the process: one round, collect,
        # release. The round wakes nobody parked, so it is syscall-free too (the
        # M5 suite measures that separately).
        discard a.tryCombine(r)
        discard a.collectAnswer()
        discard a.releaseGrant()
      let delta = unixSyscallCount() - before
      check published == 500
      check delta == 0'u64
      echo "  [m6] 500 publish/round/collect/release cycles cost ", delta,
        " syscalls (calibration ", calib, " for 200 getppid)"
      var lv = l
      lv.detach()

suite "M6 rule 2: the OLDEST blocked request holds capacity idle":
  test "a small claim that FITS is refused because an older large one is waiting":
    # THE WHOLE OF M6 IN ONE BOARD. `A` holds 6 of 8 CPU slots. `B` then asks for
    # 4 — which does not fit — and `C`, later, asks for 2, which does. First fit
    # grants C and B waits for as long as the C-shaped requests keep coming; the
    # reservation refuses C and keeps the 2 free slots for B.
    let (path, l) = newSeg("reserve")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    var b = mkClient(l, 1)
    var c = mkClient(l, 2)
    var r: CombineRound
    check a.publishRequest(vec(6, 6, 1, 6)) == psPublished
    check a.tryCombine(r) == cbCommitted
    check a.collectAnswer() == ansGranted
    let v = a.view
    check v.heldSum().cpuSlots == 6'u32

    check b.publishRequest(vec(4, 4, 1, 4)) == psPublished   # older, does NOT fit
    check c.publishRequest(vec(2, 2, 1, 2)) == psPublished   # younger, DOES fit

    # THE CAPACITY IS FREE AND IS NOT GIVEN OUT — and the arbiter does not even
    # take the role to say so, which is the interaction between M6's reservation
    # and M5's `decidableWork` gate: nothing can be granted or permanently
    # refused, so no round runs and no epoch is burned while the hold lasts.
    check vecFits(vec(2, 2, 1, 2), v.capacity - v.heldSum())  # C would fit...
    check not v.decidableWork()                               # ...and is refused
    let epoch0 = roleEpoch(v.roleSnapshot())
    check c.tryCombine(r) == cbNoWork
    check roleEpoch(v.roleSnapshot()) == epoch0
    check v.combineSeq() == 1'u32

    # THE CONTROL: the identical board with the reservation switched off. C is
    # grantable, a round runs, and the 2 free slots go to the request that arrived
    # SECOND — which is the starvation this milestone exists to remove.
    var c2 = l.arbiterClient(2)
    c2.slot = 2
    c2.mutations = {amNoReserve}
    check c2.view.decidableWork({amNoReserve})
    check c2.tryCombine(r) == cbCommitted
    check r.grants == 1
    check r.decisions[0].slot == 1'u16          # B considered first (older)...
    check r.decisions[0].kind == dkPending      # ...and still left waiting
    check r.decisions[1].slot == 2'u16
    check r.decisions[1].kind == dkGrant        # C took the capacity B needed

  test "the idle hold ENDS when the head is served, and it served the head first":
    # The other half of "bounded": a reservation exists only while its head does
    # not fit, and the instant capacity is released the head — not the younger
    # request that has been waiting behind it — is the one that gets it.
    let (path, l) = newSeg("release")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    var b = mkClient(l, 1)
    var c = mkClient(l, 2)
    var r: CombineRound
    check a.publishRequest(vec(6, 6, 1, 6)) == psPublished
    check a.tryCombine(r) == cbCommitted
    check a.collectAnswer() == ansGranted
    check b.publishRequest(vec(4, 4, 1, 4)) == psPublished
    check c.publishRequest(vec(2, 2, 1, 2)) == psPublished
    check not a.view.decidableWork()

    check a.releaseGrant()                       # <-- the event that ends the hold
    check a.view.decidableWork()
    check b.tryCombine(r) == cbCommitted
    check r.grants == 2
    check r.decisions[0].slot == 1'u16
    check r.decisions[0].kind == dkGrant         # the head, served first
    check r.decisions[1].slot == 2'u16
    check r.decisions[1].kind == dkGrant         # and then the one behind it
    check r.reserveSlot == -1                    # nothing is held idle any more
    check b.collectAnswer() == ansGranted
    check c.collectAnswer() == ansGranted
    check vecFits(a.view.heldSum(), Cap)

  test "AT MOST ONE head per round, and the counters name it":
    # Reserving for EVERY blocked request would let the reservations sum past the
    # capacity and stop admission dead — the cure becoming a worse disease. One
    # head, and the round records which slot and how much.
    #
    # The board also gives the round something it CAN do (a request that could
    # never fit an idle machine, which is refused unconditionally and ahead of any
    # reservation), so a round really runs and `reserveBlocked` — the in-round
    # count of requests the hold cost — is exercised rather than gated out.
    let (path, l) = newSeg("onehead")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    var b = mkClient(l, 1)
    var c = mkClient(l, 2)
    var d = mkClient(l, 3)
    var e = mkClient(l, 4)
    var r: CombineRound
    check a.publishRequest(vec(6, 6, 1, 6)) == psPublished
    check a.tryCombine(r) == cbCommitted
    check a.collectAnswer() == ansGranted
    check b.publishRequest(vec(4, 4, 1, 4)) == psPublished   # blocked -> the HEAD
    check c.publishRequest(vec(3, 3, 1, 3)) == psPublished   # blocked, no reserve
    check d.publishRequest(vec(2, 2, 1, 2)) == psPublished   # fits, but refused
    check e.publishRequest(vec(9, 9, 1, 9)) == psPublished   # can NEVER fit

    check a.view.decidableWork()                # ...because of E
    check b.tryCombine(r) == cbCommitted
    check r.grants == 0
    check r.reserveSlot == 1                    # exactly ONE head, and it is B
    check r.reservedVec == vec(4, 4, 1, 4)      # ...reserving ONLY B's want
    check r.reserveBlocked == 1                 # D fitted what was free; C did not
    check r.decisionCount == 4
    check r.decisions[0].slot == 1'u16 and r.decisions[0].kind == dkPending
    check r.decisions[0].reserved                       # the head, flagged
    check r.decisions[1].slot == 2'u16 and r.decisions[1].kind == dkPending
    check not r.decisions[1].reserved                   # blocked, but not a head
    check r.decisions[2].slot == 3'u16 and r.decisions[2].kind == dkPending
    check r.decisions[3].slot == 4'u16 and r.decisions[3].kind == dkRefuse
    check e.collectAnswer() == ansRefused       # the permanent refusal is an ANSWER

  test "held capacity never RISES while a head is reserved":
    # The invariant the bounded-wait argument rests on: from the moment a request
    # becomes the head, every grant satisfies `want <= capacity - held - reserved`,
    # so no grant pushes `held` above `capacity - want(head)` and `held` is driven
    # monotonically down to where the head fits. Asserted over a sequence of rounds
    # with fresh small requests arriving between them, which is the storm in
    # miniature.
    let (path, l) = newSeg("monotone")
    defer: cleanup(path)
    var a = mkClient(l, 0)
    var head = mkClient(l, 1)
    var s: array[3, ArbiterClient]
    for i in 0 ..< 3: s[i] = mkClient(l, 2 + i)
    var r: CombineRound
    check a.publishRequest(vec(5, 5, 1, 5)) == psPublished
    check a.tryCombine(r) == cbCommitted
    check a.collectAnswer() == ansGranted
    check head.publishRequest(vec(6, 6, 1, 6)) == psPublished   # 6 > 8 - 5
    var prev = a.view.heldSum().cpuSlots
    check prev == 5'u32
    for round in 0 ..< 4:
      for i in 0 ..< 3:
        if stateOf(s[i].view.stateAt(2 + i)) == rqIdle:
          check s[i].publishRequest(vec(1, 1, 1, 1)) == psPublished
      discard s[0].tryCombine(r)
      let h = a.view.heldSum().cpuSlots
      # THE INVARIANT, STATED CORRECTLY: `held` is 5 when the head arrives and the
      # head wants 6 of 8, so it is ALREADY above `capacity - want(head)`. What the
      # reservation guarantees is not that `held` is immediately below that line —
      # nothing could give that — but that it never RISES: no grant is made that
      # would push it up, so the only direction is down, and the head is served
      # when it gets there. Three small requests arrive in every round and not one
      # of them may be granted.
      check h <= prev
      prev = h
    check prev == 5'u32
    check a.releaseGrant()
    check head.tryCombine(r) == cbCommitted
    check head.collectAnswer() == ansGranted     # ...and the head is served

suite "M6: decidableWork stayed EXACT under the new policy":
  test "over a sweep of boards, the gate and the round agree":
    # M5's verification failed TWICE on this predicate drifting from the loop it
    # gates, so M6 asserts the equivalence executably rather than in a comment.
    # The property, in both directions:
    #   * `decidableWork` true  =>  the round COMMITS (it stamped at least one
    #     ledger entry, or published an outstanding one);
    #   * `decidableWork` false =>  `tryCombine` returns `cbNoWork` WITHOUT
    #     burning an epoch or moving the combine sequence.
    # An over-eager predicate reintroduces the empty rounds `EpochBoundNotBinding`
    # rules out; a shy one drops real work.
    let (path, l) = newSeg("exact", slots = 6)
    defer: cleanup(path)
    var cs: array[6, ArbiterClient]
    for i in 0 ..< 6: cs[i] = mkClient(l, i)
    let v = cs[0].view
    var r: CombineRound
    var trueCases = 0
    var falseCases = 0
    var seed = 0x9E3779B9'u32
    proc nextRand(): uint32 =
      seed = seed * 1664525'u32 + 1013904223'u32
      (seed shr 16) and 0xFFFF'u32
    for step in 0 ..< 400:
      # Perturb the board: publish, collect and release at random, with wants
      # spread across "fits easily", "fits only when idle" and "can never fit".
      let who = int(nextRand() mod 6'u32)
      case int(nextRand() mod 4'u32)
      of 0:
        if stateOf(v.stateAt(who)) == rqIdle:
          let n = 1'u32 + nextRand() mod 9'u32
          discard cs[who].publishRequest(vec(n, n, 1, n))
      of 1:
        if v.answerArrived(who): discard cs[who].collectAnswer()
      else:
        # Releases are drawn twice as often as publishes, deliberately: without
        # that the board saturates and the sweep never revisits the decidable
        # side, which would make half the equivalence untested.
        if v.answerArrived(who): discard cs[who].collectAnswer()
        if stateOf(v.stateAt(who)) == rqHolding: discard cs[who].releaseGrant()

      let dw = v.decidableWork()
      let wp = v.workPending()
      let epoch0 = roleEpoch(v.roleSnapshot())
      let seq0 = v.combineSeq()
      let st = cs[who].tryCombine(r)
      if wp and dw:
        inc trueCases
        check st == cbCommitted
        check v.combineSeq() > seq0
      elif wp and not dw:
        inc falseCases
        check st == cbNoWork
        check roleEpoch(v.roleSnapshot()) == epoch0
        check v.combineSeq() == seq0
    # ...and the sweep really did visit both sides. A run that only ever saw one
    # of them would prove half of the equivalence and read as a pass.
    check trueCases > 0
    check falseCases > 0
    echo "  [m6] decidableWork sweep: ", trueCases, " decidable / ", falseCases,
      " not, over 400 perturbations"
