## Deterministic interleaving + publish-before-write suite for `nim-shm-lease`.
## Built with `-d:shmLeaseScheduleHooks --threads:on`.
##
## MOCKS: none. The schedule hooks are not mocks — they do not replace any
## behaviour, they only PAUSE the real code at a real CAS or publish site so a
## specific interleaving can be driven on purpose. Every assertion below is over the
## real segment, the real atomics, and the real `rename`.
##
## Why this file exists at all: the design spec makes "deterministic interleaving
## tests at every CAS, publish, and role-transfer site" a condition of adopting
## shared-memory admission, and the campaign's M5/M7 gates need the seams to already
## be there. Landing them in M2, with tests that use them, is what keeps them from
## becoming a retrofit onto a structure whose operations are not individually
## recoverable.
##
## Coverage:
##   * the schedule hook fires at EVERY declared point during a create / claim /
##     release / rolled-back-claim cycle (a seam nothing ever reaches is not a seam);
##   * PUBLISH-BEFORE-WRITE: creation paused at `slpBeforeSegmentRename` — the final
##     name does not exist and cannot be attached, and becomes both the instant the
##     rename completes;
##   * the claim CAS retry loop, driven deterministically: two claimants paused at
##     `slpBeforeBudgetCas` having both read the SAME budget value. A blind store
##     would lose one claim; the CAS loop must land both.
##   * the same, for release;
##   * a rollback racing a concurrent claimant: the machine word ends up EXACTLY
##     restored.

import std/[atomics, os, posix, strutils, times, unittest]
import shm_lease

static: doAssert scheduleHooksEnabled, "expected -d:shmLeaseScheduleHooks"

var tmpCounter = 0
proc freshPath(tag: string): string =
  inc tmpCounter
  getTempDir() / ("shmlease-h-" & tag & "-" & $getpid() & "-" & $tmpCounter & ".seg")

proc cleanup(path: string) =
  try: removeFile(path)
  except CatchableError: discard

# --- hook-point coverage ----------------------------------------------------

var gSeen: set[SchedulePoint]

proc recordHook(p: SchedulePoint) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    gSeen.incl p

suite "schedule-hook coverage at every CAS and publish site":
  test "a create / claim / release / rollback cycle reaches every declared point":
    let path = freshPath("coverage")
    defer: cleanup(path)
    gSeen = {}
    setScheduleHook(recordHook)

    # Create: anchor publish, magic publish, rename (before + after).
    var l = createLeaseSegment(path, [vec(8, 8, 8, 8), vec(1, 1, 1, 1)])
    check l.available

    # A granted claim: budget CAS (before + after).
    var r: Reservation
    check l.claim(vec(2, 2, 2, 2), r) == csGranted
    # A release: release CAS (before + after).
    check l.release(r)
    # A two-word claim refused on the pool word: rollback CAS on the machine word.
    check l.claim(vec(2, 2, 2, 2), r, poolIndex = 0) == csRefused

    # --- M3: the wait/wake seams -------------------------------------------
    # The design spec asks for deterministic interleaving tests at every CAS,
    # publish AND wait/wake site, so the blocking wrapper's seams are exercised in
    # the same cycle: a slow-path wait (register, re-check, park, return), a
    # publish, and a forced wake syscall.
    let wpath = freshPath("coverage-wait")
    defer: cleanup(wpath)
    var ws = createWaitSegment(wpath, 4)
    check ws.available
    let woff = ws.slotOffset(0)
    prefaultWaitWord(ws.base, woff)
    # Value MATCHES, so this takes the slow path: register, re-check, park. The
    # short timeout is what makes it return without a second thread.
    check waitOn(ws.base, woff, ws.slotValue(0), timeoutNs = 5_000_000'i64) ==
      wrTimedOut
    check ws.publishGrant(0, 1'u64) == wkNoWaiters   # publish; wake fast-paths
    discard wakeRaw(ws.base, woff)                   # forced: the wake syscall seam
    ws.detach()

    # --- M4: the observation ring's seams ----------------------------------
    # The append, the signal decision, the consumer's publication of its idle token
    # and its decision to sleep. The ring's own ticket CAS and release-store publish
    # live in `nim-shm-queue` and carry that library's seams; these are the four
    # this milestone added on top, and each is where a lost wakeup would live.
    let opath = freshPath("coverage-obs")
    defer: cleanup(opath)
    var obs = createObsRing(opath, 8, 32)
    check obs.available
    var orec: array[32, byte]
    check obs.publish(orec) == oprPublished            # publish seams
    check obs.publishForcedSignal(orec) == oprPublished # the signal seam
    var obuf: array[32, byte]
    var on = 0
    while obs.drainOne(obuf, on) == odrGot: discard
    # An EMPTY ring, a short timeout: the consumer publishes its idle token and
    # parks, reaching both consumer seams and returning without a second thread.
    check obs.awaitRecord(timeoutNs = 5_000_000'i64) == owrTimedOut
    obs.detach()

    # --- M5: the arbiter's CAS, publish AND ROLE-TRANSFER seams -------------
    # The role transfer is the site the design spec names that the earlier
    # milestones had nothing to intercept. One full round reaches all of them: the
    # acquisition CAS (before + after), the ledger CASes of the raise and scan
    # passes, the commit CAS inside the role word, the sequence advance, the budget
    # recompute, the grant publication and the role release.
    let apath = freshPath("coverage-arb")
    defer: cleanup(apath)
    var al = createLeaseSegment(apath, [vec(8, 8, 8, 8)], requestSlots = 4)
    check al.available
    var ac = al.arbiterClient(0)
    check ac.registerSlot(0)
    check ac.publishRequest(vec(1, 1, 1, 1)) == psPublished
    var around: CombineRound
    check ac.tryCombine(around) == cbCommitted
    check ac.collectAnswer() == ansGranted
    check ac.releaseGrant()              # the ledger CAS of a release
    al.detach()

    setScheduleHook(nil)
    # A seam nothing ever reaches is not a seam.
    for p in SchedulePoint:
      check p in gSeen
    l.detach()

# --- publish-before-write ---------------------------------------------------

var gArrived: Atomic[int]
var gRelease: Atomic[int]
var gHookPoint: SchedulePoint
var gPath: string
var gCreateOk: Atomic[int]
var tPaused {.threadvar.}: bool

proc pauseHook(p: SchedulePoint) {.gcsafe, raises: [].} =
  ## Pause the FIRST time this thread reaches the chosen point: announce arrival,
  ## then spin until the driver releases. Once released the thread never pauses
  ## again, so a retry loop runs to completion.
  if p == gHookPoint and not tPaused:
    tPaused = true
    discard gArrived.fetchAdd(1)
    while gRelease.load(moAcquire) == 0:
      discard sched_yield()

proc resetBarrier() =
  gArrived.store(0)
  gRelease.store(0)

proc waitArrived(target: int; sec: float): bool =
  let deadline = epochTime() + sec
  while gArrived.load(moAcquire) < target:
    if epochTime() > deadline: return false
    discard sched_yield()
  true

proc creatorThread(unused: int) {.thread.} =
  {.cast(gcsafe).}:
    setScheduleHook(pauseHook)
    var l = createLeaseSegment(gPath, [vec(4, 4, 4, 4)])
    setScheduleHook(nil)
    if l.available:
      gCreateOk.store(1)
      l.detach()

suite "publish-before-write":
  test "the final name does not exist until the segment is fully initialised":
    let path = freshPath("prewrite")
    defer:
      cleanup(path)
      for _, p in walkDir(parentDir(path)):
        if extractFilename(p).startsWith(extractFilename(path) & ".tmp."):
          try: removeFile(p)
          except CatchableError: discard
    gPath = path
    gHookPoint = slpBeforeSegmentRename
    gCreateOk.store(0)
    resetBarrier()

    var t: Thread[int]
    createThread(t, creatorThread, 0)
    check waitArrived(1, 10.0)          # the segment is complete but NOT renamed

    # The temp file exists — so the work really is done — but the FINAL name does
    # not, and therefore cannot be discovered or attached. This is the property that
    # makes a half-initialised segment unobservable rather than merely unlikely.
    var temps = 0
    for _, p in walkDir(parentDir(path)):
      if extractFilename(p).startsWith(extractFilename(path) & ".tmp."): inc temps
    check temps == 1
    check not fileExists(path)
    var early = attachLeaseSegment(path)
    check not early.available

    gRelease.store(1)
    joinThread(t)
    check gCreateOk.load() == 1
    check fileExists(path)

    # And the instant the final name exists, everything behind it is already valid.
    var view = attachLeaseSegment(path)
    check view.available
    check view.capacityVec(0) == vec(4, 4, 4, 4)
    check view.remainingVec(0) == vec(4, 4, 4, 4)
    check view.ownerStartTime() != 0'u64
    view.detach()

# --- deterministic CAS races -------------------------------------------------

var gClaimStatus: array[2, ClaimStatus]
var gReleaseOk: array[2, bool]
var gClaimVec: ResourceVec
var gPool: int

proc claimThread(id: int) {.thread.} =
  {.cast(gcsafe).}:
    var l = attachLeaseSegment(gPath)
    doAssert l.available
    setScheduleHook(pauseHook)
    var r: Reservation
    gClaimStatus[id] = l.claim(gClaimVec, r, poolIndex = gPool)
    setScheduleHook(nil)
    l.detach()

proc releaseThread(id: int) {.thread.} =
  {.cast(gcsafe).}:
    var l = attachLeaseSegment(gPath)
    doAssert l.available
    setScheduleHook(pauseHook)
    gReleaseOk[id] = l.releaseVec(gClaimVec, poolIndex = gPool)
    setScheduleHook(nil)
    l.detach()

suite "deterministic CAS races":
  test "two claimants that read the SAME budget value both land (no lost update)":
    let path = freshPath("clashclaim")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [vec(4, 4, 4, 4)])
    check l.available
    gPath = path
    gPool = -1
    gClaimVec = vec(1, 1, 1, 1)
    gHookPoint = slpBeforeBudgetCas
    resetBarrier()

    var t: array[2, Thread[int]]
    createThread(t[0], claimThread, 0)
    createThread(t[1], claimThread, 1)
    # Both threads have loaded `remaining` (4,4,4,4) and computed their decremented
    # value; NEITHER has executed the CAS. This is the exact window in which a blind
    # store would lose a claim.
    check waitArrived(2, 10.0)
    check l.remainingVec(0) == vec(4, 4, 4, 4)
    gRelease.store(1)
    joinThread(t[0]); joinThread(t[1])

    check gClaimStatus[0] == csGranted
    check gClaimStatus[1] == csGranted
    # Both claims are accounted for: 4 - 1 - 1 == 2 in every dimension. A lost
    # update would leave 3.
    check l.remainingVec(0) == vec(2, 2, 2, 2)
    check l.claimCount(0) == 2
    check l.retryCount(0) >= 1'u64        # the loser really did retry
    check l.noOvercommit(0)
    l.detach()

  test "two releasers that read the SAME budget value both land":
    let path = freshPath("clashrelease")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [vec(4, 4, 4, 4)])
    check l.available
    gPath = path
    gPool = -1
    gClaimVec = vec(1, 1, 1, 1)
    # Take two reservations up front so there is something to give back.
    var a, b: Reservation
    check l.claim(gClaimVec, a) == csGranted
    check l.claim(gClaimVec, b) == csGranted
    check l.remainingVec(0) == vec(2, 2, 2, 2)

    gHookPoint = slpBeforeReleaseCas
    resetBarrier()
    var t: array[2, Thread[int]]
    createThread(t[0], releaseThread, 0)
    createThread(t[1], releaseThread, 1)
    check waitArrived(2, 10.0)
    check l.remainingVec(0) == vec(2, 2, 2, 2)
    gRelease.store(1)
    joinThread(t[0]); joinThread(t[1])

    check gReleaseOk[0]
    check gReleaseOk[1]
    check l.remainingVec(0) == vec(4, 4, 4, 4)
    check l.packedRemaining(0) == l.packedCapacity(0)
    check l.releaseCount(0) == 2
    check l.noOvercommit(0)
    l.detach()

  test "a rollback racing a concurrent claimant restores the machine word exactly":
    let path = freshPath("clashrollback")
    defer: cleanup(path)
    # Machine word is roomy; the pool word cannot satisfy the claim, so thread 0's
    # two-word claim is refused and must give the machine word back. Thread 1 claims
    # against the machine word only, concurrently.
    var l = createLeaseSegment(path, [vec(8, 8, 8, 8), vec(1, 1, 1, 1)])
    check l.available
    gPath = path
    gClaimVec = vec(2, 2, 2, 2)
    gHookPoint = slpBeforeRollbackCas
    resetBarrier()

    var t: array[2, Thread[int]]
    gPool = 0
    createThread(t[0], claimThread, 0)         # will be refused, then roll back
    check waitArrived(1, 10.0)
    # Mid-rollback: the machine word is transiently DOWN by the claim, which is
    # safe (remaining never exceeds capacity) but visibly not yet restored.
    check l.remainingVec(MachineBudgetIndex) == vec(6, 6, 6, 6)
    check l.noOvercommitAnywhere()

    gPool = -1
    createThread(t[1], claimThread, 1)         # concurrent machine-only claimant
    # Give the rollback the go-ahead; thread 1 may CAS before or after it.
    gRelease.store(1)
    joinThread(t[0]); joinThread(t[1])

    check gClaimStatus[0] == csRefused
    check gClaimStatus[1] == csGranted
    # Exactly one claim of (2,2,2,2) is outstanding: the rolled-back one left no
    # trace, and the concurrent one was not clobbered by it.
    check l.remainingVec(MachineBudgetIndex) == vec(6, 6, 6, 6)
    check l.remainingVec(poolBudgetIndex(0)) == vec(1, 1, 1, 1)
    check l.claimCount(MachineBudgetIndex) == 1
    check l.rollbackCount(MachineBudgetIndex) == 1
    check l.noOvercommitAnywhere()
    check l.releaseVec(gClaimVec)              # give back the one real claim...
    check l.packedRemaining(MachineBudgetIndex) ==
      l.packedCapacity(MachineBudgetIndex)
    check not l.releaseVec(gClaimVec)          # ...and there is nothing else to give
    l.detach()


# --- M3: the compare-and-park window, driven deterministically ---------------
#
# `waitOn`'s slow path is: register as a waiter, RE-CHECK the value, then park.
# It is worth being exact about which step buys what, because the two are easy to
# conflate and only one of them is a correctness argument:
#
#   * The KERNEL's compare-and-park is the correctness mechanism. A publish that
#     lands after the waiter decided to sleep but before it is actually inside the
#     kernel cannot strand it, because the kernel compares the word atomically with
#     the block and returns immediately when it no longer matches. The first test
#     below drives precisely that interleaving through `slpBeforeWaitPark` and
#     issues NO WAKE SYSCALL AT ALL, so the only thing that can save the waiter is
#     the kernel's compare.
#   * The userspace re-check after registering is a SYSCALL-AVOIDANCE step. The
#     third test shows it: under the same publish, a waiter paused at
#     `slpAfterWaiterRegister` returns without ever entering the kernel.
#
# The second test is the control that gives the first one teeth — the identical
# schedule with nothing published must sit out its whole timeout.

var gWaitPath: string
var gWaitRc: WaitResult
var gWaitParks: uint64
var gWaitWallMs: int

proc waiterHookThread(unused: int) {.thread.} =
  {.cast(gcsafe).}:
    var ws = attachWaitSegment(gWaitPath)
    doAssert ws.available
    let off = ws.slotOffset(0)
    prefaultWaitWord(ws.base, off)
    let seen = ws.slotValue(0)
    resetWaitWordCounters()
    setScheduleHook(pauseHook)
    let t0 = epochTime()
    gWaitRc = waitOn(ws.base, off, seen, timeoutNs = 1_000_000_000'i64)
    gWaitWallMs = int((epochTime() - t0) * 1000)
    gWaitParks = wwParks
    setScheduleHook(nil)
    ws.detach()

suite "M3 deterministic interleavings: publish vs park":
  test "a publish landing just before the park is caught by the kernel's compare":
    let path = freshPath("cmppark")
    defer: cleanup(path)
    var ws = createWaitSegment(path, 4)
    check ws.available
    gWaitPath = path
    gHookPoint = slpBeforeWaitPark
    resetBarrier()

    var t: Thread[int]
    createThread(t, waiterHookThread, 0)
    # The waiter has registered, re-checked, and is about to enter the kernel. It
    # is NOT yet inside it.
    check waitArrived(1, 10.0)
    check ws.slotWaiters(0) == 1'u32

    # Publish with NO WAKE. A wake syscall issued now would find nobody parked
    # anyway (`wkNobodyParked`), so if the waiter comes back it can only be because
    # the kernel compared the word as it blocked.
    publishValue(ws.base, ws.slotOffset(0), ws.slotValue(0) + 1)
    gRelease.store(1)
    joinThread(t)

    check gWaitRc != wrTimedOut
    check gWaitWallMs < 500
    check gWaitParks == 1'u64          # it DID enter the kernel, and came straight back
    ws.detach()

  test "the same schedule with nothing published sits out the whole timeout":
    # The control. Without it, "the waiter came back quickly" could equally mean
    # the wait never blocked in the first place.
    let path = freshPath("cmppark-ctl")
    defer: cleanup(path)
    var ws = createWaitSegment(path, 4)
    check ws.available
    gWaitPath = path
    gHookPoint = slpBeforeWaitPark
    resetBarrier()

    var t: Thread[int]
    createThread(t, waiterHookThread, 0)
    check waitArrived(1, 10.0)
    gRelease.store(1)                 # released, but nothing was published
    joinThread(t)

    check gWaitRc == wrTimedOut
    check gWaitWallMs >= 900
    check gWaitParks == 1'u64
    ws.detach()

  test "a publish before the re-check costs no syscall at all":
    # The syscall-avoidance half: paused between registering and re-checking, a
    # waiter that finds the value already changed returns WITHOUT parking. This is
    # SM-2's fast path reached from the slow path's own window, and the park count
    # is what proves the kernel was never entered.
    let path = freshPath("recheck")
    defer: cleanup(path)
    var ws = createWaitSegment(path, 4)
    check ws.available
    gWaitPath = path
    gHookPoint = slpAfterWaiterRegister
    resetBarrier()

    var t: Thread[int]
    createThread(t, waiterHookThread, 0)
    check waitArrived(1, 10.0)
    check ws.slotWaiters(0) == 1'u32
    # A wake issued here reports `wkNobodyParked`: the syscall WAS made and found
    # nobody in the kernel. That is a different outcome from the syscall-free
    # `wkNoWaiters`, and keeping them distinct is what lets SM-2 be stated exactly.
    check ws.publishGrant(0, 0xFEED'u64) == wkNobodyParked
    gRelease.store(1)
    joinThread(t)

    check gWaitRc == wrNotEqual
    check gWaitParks == 0'u64          # <-- never entered the kernel
    check gWaitWallMs < 500
    ws.detach()

# ---------------------------------------------------------------------------
# M4: the observation ring's signalling window
# ---------------------------------------------------------------------------
#
# The two interleavings the empty-to-non-empty rule stands or falls on. Both are
# driven through real hooks in the real code — nothing here is a model of the
# protocol, it IS the protocol, paused.

var gObsPath: string
var gObsRc: int
var gObsParks: int
var gObsWallMs: int

proc obsConsumerHookThread(unused: int) {.thread.} =
  {.cast(gcsafe).}:
    var ring = attachObsRing(gObsPath)
    if not ring.available:
      gObsRc = -1
      return
    setScheduleHook(pauseHook)
    var parks = 0
    let t0 = epochTime()
    let rc = ring.awaitRecord(timeoutNs = 1_000_000_000'i64, parks = addr parks)
    gObsWallMs = int((epochTime() - t0) * 1000)
    setScheduleHook(nil)
    gObsParks = parks
    gObsRc = ord(rc)
    ring.detach()

suite "M4 deterministic interleavings: an append vs the consumer's park":

  test "an append landing between the empty check and the idle token is NOT slept through":
    # THE LOST WAKEUP A NAIVE PRODUCER WOULD HAVE. The consumer has already observed
    # the ring EMPTY and has not yet published its idle token, so a producer
    # appending in this window CANNOT signal — it looks at the token and correctly
    # finds nobody idle. The consumer must therefore catch the record itself, which
    # is what the re-check AFTER the token publication (and the seq-cst fence that
    # orders the two) exists for. A design that snapshots `tail - head` before
    # appending and signals on "was empty" loses exactly this record.
    let path = freshPath("obs-window")
    defer: cleanup(path)
    var ring = createObsRing(path, 16, 32)
    check ring.available
    gObsPath = path
    gObsRc = -2
    gHookPoint = slpBeforeObsIdlePublish
    resetBarrier()

    var t: Thread[int]
    createThread(t, obsConsumerHookThread, 0)
    check waitArrived(1, 10.0)
    check not ring.consumerIdle()        # the token is NOT published yet
    var rec: array[32, byte]
    rec[0] = 42
    check ring.publish(rec) == oprPublished
    check ring.signalCount() == 0'u64    # ...and no signal was possible
    gRelease.store(1)
    joinThread(t)

    check gObsRc == ord(owrReady)        # <-- it saw the record anyway
    check gObsParks == 0                 # <-- without ever entering the kernel
    check gObsWallMs < 500
    check ring.signalCount() == 0'u64
    ring.detach()

  test "an append landing just before the park is caught by the kernel's compare":
    # The other window: the consumer has published its token, re-checked the ring
    # AND the wait word, and is about to sleep. The producer's append claims the
    # token and bumps the value; the park is issued against the OLD value, so the
    # kernel's atomic compare-and-park returns immediately instead of sleeping.
    # That is the guard — not the userspace re-check, which is only syscall
    # avoidance.
    let path = freshPath("obs-prepark")
    defer: cleanup(path)
    var ring = createObsRing(path, 16, 32)
    check ring.available
    gObsPath = path
    gObsRc = -2
    gHookPoint = slpBeforeObsConsumerPark
    resetBarrier()

    var t: Thread[int]
    createThread(t, obsConsumerHookThread, 0)
    check waitArrived(1, 10.0)
    check ring.consumerIdle()            # the token IS published, and claimable
    var rec: array[32, byte]
    rec[0] = 43
    check ring.publish(rec) == oprPublished
    check ring.signalCount() == 1'u64    # the producer claimed the transition
    check not ring.consumerIdle()        # ...exclusively: the token is consumed
    gRelease.store(1)
    joinThread(t)

    check gObsRc == ord(owrReady)
    check gObsWallMs < 500               # it did NOT sit out the timeout
    ring.detach()

  test "the same schedule with nothing appended sits out the whole timeout":
    # The control for both tests above. Without it, "the consumer came back
    # quickly" could equally mean it never committed to sleeping at all.
    let path = freshPath("obs-ctl")
    defer: cleanup(path)
    var ring = createObsRing(path, 16, 32)
    check ring.available
    gObsPath = path
    gObsRc = -2
    gHookPoint = slpBeforeObsConsumerPark
    resetBarrier()

    var t: Thread[int]
    createThread(t, obsConsumerHookThread, 0)
    check waitArrived(1, 10.0)
    gRelease.store(1)                    # released, but nothing was appended
    joinThread(t)

    check gObsRc == ord(owrTimedOut)
    check gObsWallMs >= 900
    check gObsParks == 1                 # it really did sleep, exactly once
    check ring.signalCount() == 0'u64
    ring.detach()

# ===========================================================================
# M5 deterministic interleavings: the ROLE-TRANSFER site.
# ===========================================================================
#
# The design spec's condition of adoption names "every CAS, publish, AND
# ROLE-TRANSFER site", and the role transfer is the one the earlier milestones had
# nothing to intercept. What these tests drive is the interleaving MV2 says a
# kill-injection suite CANNOT reach — the FALSE-POSITIVE STEAL: a combiner
# descheduled at its commit point, stolen from while it is not running, and then
# RESUMED onto a round it no longer owns. Every step it then takes is a real step
# rather than an abort, which is exactly what makes it dangerous.
#
# The steal is performed from INSIDE the hook, on the combiner's own call stack.
# That is not a simplification of the two-process case, it is the same schedule:
# the hook suspends the combiner between the decision and the commit, another
# client's acquisition CAS lands, and the combiner then executes its commit
# against a word that has moved. A second thread would add scheduling noise to a
# schedule that is already exact.

var
  gArbView: ArbiterView
  gStealerSlot: int
  gStealFired: bool
  gStealEpoch: uint32
  gPubForged: bool
  gForgedSlot: int
  gForgedVal: uint32

proc stealAtCommitHook(p: SchedulePoint) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    if p == slpBeforeCommitCas and not gStealFired:
      gStealFired = true
      var cur = gArbView.roleSnapshot()
      gStealEpoch = roleEpoch(cur) + 1'u32
      discard gArbView.casRoleWord(cur,
        roleWord(uint16(gStealerSlot), gStealEpoch, false))

proc forgePublishHook(p: SchedulePoint) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    if p == slpBeforeGrantPublish and not gPubForged:
      gPubForged = true
      # Another publisher gets there first: it moves the value word to the same
      # epoch this combiner is about to write. Under the shipped rule the answer is
      # then already delivered, and this combiner's CAS must fail rather than
      # deliver it a second time.
      let vp = cast[ptr uint32](addr gArbView.base[
        gArbView.slotOffset(gForgedSlot) + RqOffValue])
      vp[] = gForgedVal

suite "M5 deterministic interleavings: the role-transfer site":
  test "a combiner stolen from AT ITS COMMIT cannot commit, and leaves no trace":
    # `verification/tla/shm_lease_combine_unfenced_MC.cfg` violates `NeverBoth` on
    # a 13-state trace when the commit lands in a word the steal did not touch.
    # Here the commit IS the role word, so this is the same schedule with the
    # shipped layout — and the round simply fails.
    let path = freshPath("m5steal")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [vec(8, 8, 8, 8)], requestSlots = 4)
    check l.available
    var a = l.arbiterClient(0)
    check a.registerSlot(0)
    var b = l.arbiterClient(1)
    check b.registerSlot(1)
    check a.publishRequest(vec(2, 2, 1, 2)) == psPublished
    check b.publishRequest(vec(2, 2, 1, 2)) == psPublished

    gArbView = a.view
    gStealerSlot = 1
    gStealFired = false
    setScheduleHook(stealAtCommitHook)
    var r: CombineRound
    let st = a.tryCombine(r)
    setScheduleHook(nil)

    check gStealFired
    check st == cbFenced                 # <-- THE COMMIT CAS FAILED
    check r.status == cbFenced
    # THE ROUND LEFT NO TRACE. Nothing was published, nobody was woken, the
    # sequence never advanced, and not one of its proposals is effective.
    check r.published == 0
    check r.wakes == 0
    check a.view.combineSeq() == 0'u32
    check a.view.valueAt(0) == 0'u32
    check a.view.valueAt(1) == 0'u32
    check a.view.heldSum() == ResourceVec()
    check a.collectAnswer() == ansNone
    # The stealer holds the role at the higher epoch, uncommitted.
    check roleOwner(a.view.roleSnapshot()) == 1'u16
    check roleEpoch(a.view.roleSnapshot()) == gStealEpoch
    check not roleCommitted(a.view.roleSnapshot())

    # ...AND ADMISSION RECOVERS. The stealer runs the round to completion, and
    # both requests — including the one the fenced combiner had decided — are
    # answered exactly once.
    var r2: CombineRound
    check b.tryCombine(r2) == cbCommitted
    check r2.grants == 2
    check a.collectAnswer() == ansGranted
    check b.collectAnswer() == ansGranted
    check a.view.heldSum() == vec(4, 4, 2, 4)
    # BudgetExact's shape at quiescence: the word equals what the ledger says.
    check a.view.budgetCache() == vec(8, 8, 8, 8) - vec(4, 4, 2, 4)
    check a.view.valueAt(0) == r2.epoch
    check a.view.valueAt(1) == r2.epoch
    l.detach()

  test "an answer published by somebody else is NOT delivered or woken twice":
    # The publication is `payload, then CAS the value, then wake`. The CAS is what
    # makes the wake belong to the publisher that actually MOVED the word — so a
    # resurrected combiner racing a stealer through the same publication cannot
    # manufacture a second wake for one grant. This drives that race exactly.
    let path = freshPath("m5pub")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [vec(8, 8, 8, 8)], requestSlots = 4)
    check l.available
    var a = l.arbiterClient(0)
    check a.registerSlot(0)
    check a.publishRequest(vec(1, 1, 1, 1)) == psPublished

    gArbView = a.view
    gPubForged = false
    gForgedSlot = 0
    gForgedVal = 1'u32                   # the epoch this round will publish
    setScheduleHook(forgePublishHook)
    var r: CombineRound
    check a.tryCombine(r) == cbCommitted
    setScheduleHook(nil)

    check gPubForged
    check r.epoch == 1'u32
    check r.grants == 1                  # the grant was DECIDED...
    check r.published == 0               # ...but this round did not deliver it...
    check r.wakes == 0                   # ...so it issued no wake for it either
    check a.view.valueAt(0) == 1'u32     # the word moved exactly once, to the epoch
    # The waiter still collects its answer exactly once: the value word is the
    # publication marker, and it does not matter which publisher moved it.
    check a.collectAnswer() == ansGranted
    l.detach()

# ===========================================================================
# M5 recovery: a combiner that dies BETWEEN THE COMMIT AND THE PUBLISH.
# ===========================================================================
#
# THIS IS A REGRESSION TEST FOR A DEADLOCK THE ADMISSION GATES INTRODUCED, and it
# is the one window the earlier M5 tests do not cover. `tryCombine` steps 5..8 are
# `commit CAS`, `repairSequence`, `refreshBudgetCache`, `publish loop`. A combiner
# that dies anywhere in that window leaves slot `j` with an EFFECTIVE `[e, ldGrant]`
# entry, `cseq == e`, state `rqPending`, and its value word NEVER MOVED. A later
# round's publish loop is the DESIGNED recovery — that is the whole reason
# constraint 3 puts the epoch in the published value ("a stealer republishing a
# dead combiner's answer writes the same word twice").
#
# Two gates added to bound empty rounds each blocked that recovery on its own:
#   * `decidableWork` counted slot `j`'s OWN grant into `held`, so the pending
#     request no longer fitted `capacity - held` and was not refusable either. The
#     predicate said "nothing to do" and the role was never taken; and
#   * step 4b (`stamped == 0` abandons the round) returned BEFORE step 8, so even a
#     round that did take the role handed it back without publishing.
# Measured against the pre-gate code: one round RECOVERED. Against the gated code:
# 199 rounds, `cbNoWork` every time, the answer never delivered.
#
# The `slpBeforeGrantPublish` seam makes the crash EXACT rather than stochastic —
# no kill-injection harness (M7) is needed, because the child dies at a named
# program point rather than at a sampled instant.

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}

var gDieAtGrantPublish = false

proc dieAtGrantPublishHook(p: SchedulePoint) {.gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    if p == slpBeforeGrantPublish and gDieAtGrantPublish:
      # The payload is already stored; the VALUE word has not moved. This is the
      # state the ledger cannot distinguish from "published" and the value word
      # can.
      cExit(0)

suite "M5 recovery: a committed-but-unpublished answer":
  test "a combiner killed between the commit and the publish is recovered from":
    let path = freshPath("m5strand")
    defer: cleanup(path)
    let cap = vec(8, 64, 8, 100)
    var l = createLeaseSegment(path, [cap], requestSlots = 2)
    check l.available

    # Slot 0 is the WAITER, and it asks for MORE THAN HALF the capacity on every
    # dimension. That is what makes the stranded state a deadlock rather than a
    # delay: once its own grant is effective, the free capacity can never fit the
    # same request again, so a predicate that reads the ledger says "nothing to do"
    # about the very slot that needs publishing.
    var a = l.arbiterClient(0)
    check a.registerSlot(0)
    check a.publishRequest(vec(5, 40, 5, 60)) == psPublished
    let v = a.view
    check v.workPending()
    check v.decidableWork()              # before the crash: plainly grantable

    # The COMBINER is a separate process, and it dies at the seam.
    let pid = fork()
    if pid == 0:
      var l2 = attachLeaseSegment(path)
      var b = l2.arbiterClient(1)
      doAssert b.registerSlot(1)
      setScheduleHook(dieAtGrantPublishHook)
      gDieAtGrantPublish = true
      var rc: CombineRound
      discard b.tryCombine(rc)
      cExit(9)                           # unreachable: the hook exits first
    check pid > 0
    var st: cint
    check waitpid(pid, st, 0) == pid
    check st == 0                        # it died AT THE HOOK, not on an assertion

    # THE STRANDED STATE, spelled out. The round COMMITTED — its entry is effective
    # and the sequence caught up — and the answer was never delivered.
    check ledgerDec(v.ledgerAt(0)) == ldGrant
    check ledgerEpoch(v.ledgerAt(0)) == 1'u32
    check v.combineSeq() == 1'u32        # committed: the entry IS effective
    check v.valueAt(0) == 0'u32          # ...and the value word never moved
    check not v.answerArrived(0)
    check v.heldSum() == vec(5, 40, 5, 60)

    # THE REGRESSION ASSERTION. `workPending` is true, and an admission gate that
    # reads the ledger must agree: an effective decision whose answer is still
    # unpublished is DECIDABLE WORK — it needs publishing, not deciding. This is
    # the assertion that fails against the gated code.
    check v.workPending()
    check v.decidableWork()

    # ...AND A SURVIVOR ACTUALLY RECOVERS. The waiter drives rounds itself, which is
    # the friendliest possible case and is exactly what `combineUntilAnswered` does.
    a.stealAfterNs = 1_000_000
    a.anchorProbeAfterNs = 1_000_000
    var r: CombineRound
    var rounds = 0
    for i in 0 ..< 100:
      inc rounds
      discard a.tryCombine(r)
      if v.answerArrived(0): break
      sleep(2)
    check v.answerArrived(0)
    check rounds < 100
    check v.valueAt(0) == 1'u32          # the ENTRY'S epoch, not `value + 1`
    check r.published == 1               # republication delivered exactly one answer
    check r.wakes == 1
    check a.collectAnswer() == ansGranted
    check v.heldSum() == vec(5, 40, 5, 60)

    # AND THE LIVELOCK FIX SURVIVES IT. The recovering round stamped nothing, so it
    # must NOT have committed and must NOT have advanced the sequence: it published
    # and handed the role back uncommitted. `cseq` is still the dead combiner's
    # epoch, and `roundsCommitted` is zero.
    check a.stats.roundsCommitted == 0'u64
    check v.combineSeq() == 1'u32

    # IDEMPOTENT: a further round republishes nothing and burns no epoch.
    let epochAfter = roleEpoch(v.roleSnapshot())
    var r2: CombineRound
    check a.tryCombine(r2) == cbNoWork
    check r2.published == 0
    check r2.wakes == 0
    check roleEpoch(v.roleSnapshot()) == epochAfter
    check v.combineSeq() == 1'u32
    l.detach()
