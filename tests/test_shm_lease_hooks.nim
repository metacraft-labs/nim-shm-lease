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

    setScheduleHook(nil)
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
