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
