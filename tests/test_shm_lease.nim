## Unit + negative-control suite for `nim-shm-lease` (campaign M2).
##
## MOCKS: none. Per the workspace policy every test here runs against the real
## filesystem, real `mmap(MAP_SHARED)` segments, and real processes; there is no
## mock object in this repo, so there is nothing to justify. The one piece of
## deliberate artificiality is the NEGATIVE CONTROLS, which construct broken
## behaviour on purpose so the assertions that are supposed to catch it can be seen
## to catch it. That is the opposite of a mock: it is a proof that the real
## assertions have teeth.
##
## Coverage:
##   * packed-budget arithmetic and the per-dimension fit test, including the
##     borrow-across-dimensions failure the fit test exists to prevent;
##   * segment creation, publish-before-write's observable consequence (the final
##     name only ever names a valid segment), and boot/format/unit guards on attach;
##   * claim / release / refuse / all-or-nothing rollback on multi-word budgets;
##   * the FIXED CLAIM ORDER, enforced rather than documented;
##   * anchoring by boot id + owner pid + owner process START TIME, with the
##     same-pid / different-start-time case that only start time can decide;
##   * over-release refusal (a double release must not fabricate capacity);
##   * position independence in one process (a second mapping at a chosen base) plus
##     the stored-pointer checker and its negative control.

import std/[os, posix, strutils, unittest]
import shm_lease

# --- helpers ---------------------------------------------------------------

var tmpCounter = 0
proc freshPath(tag: string): string =
  inc tmpCounter
  getTempDir() / ("shmlease-u-" & tag & "-" & $getpid() & "-" & $tmpCounter & ".seg")

proc cleanup(path: string) =
  try: removeFile(path)
  except CatchableError: discard

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}

proc reapedPid(): uint64 =
  ## A pid that is definitely NOT alive: fork, let the child exit immediately,
  ## reap it. Deterministic, unlike guessing a large number.
  let pid = fork()
  if pid == 0: cExit(0)
  doAssert pid > 0
  var st: cint
  doAssert waitpid(pid, st, 0) == pid
  uint64(pid)

# ---------------------------------------------------------------------------
suite "packed budget arithmetic":
  test "pack/unpack is exact at every field boundary":
    for v in [vec(0, 0, 0, 0),
              vec(1, 2, 3, 4),
              vec(DimMax, 0, 0, 0),
              vec(0, DimMax, 0, 0),
              vec(0, 0, DimMax, 0),
              vec(0, 0, 0, DimMax),
              vec(DimMax, DimMax, DimMax, DimMax)]:
      check validVec(v)
      check unpackVec(packVec(v)) == v

    # The four fields occupy exactly the four 16-bit lanes, in order.
    check packVec(vec(1, 0, 0, 0)) == 0x0000_0000_0000_0001'u64
    check packVec(vec(0, 1, 0, 0)) == 0x0000_0000_0001_0000'u64
    check packVec(vec(0, 0, 1, 0)) == 0x0000_0001_0000_0000'u64
    check packVec(vec(0, 0, 0, 1)) == 0x0001_0000_0000_0000'u64
    # 4 dimensions x 16 bits == one 64-bit word, with nothing left over. This is
    # why a 128-bit CAS (cmpxchg16b / CASP) is not needed.
    check LeaseDimCount * DimBits == 64

  test "a dimension above DimMax is rejected, never truncated":
    check not validVec(vec(DimMax + 1, 0, 0, 0))
    check not validVec(vec(0, DimMax + 1, 0, 0))
    check not validVec(vec(0, 0, DimMax + 1, 0))
    check not validVec(vec(0, 0, 0, DimMax + 1))

  test "the memory dimension's ceiling is ~4 TiB at 64 MiB granularity":
    check MemUnitBytes == 64 * 1024 * 1024
    # 65535 units x 64 MiB = 4095.94 GiB, i.e. ~4 TiB. Ample for any real build
    # host, which is the whole justification for 16 bits per dimension.
    check uint64(DimMax) * uint64(MemUnitBytes) == 4_397_979_402_240'u64
    check uint64(DimMax) * uint64(MemUnitBytes) div (1024'u64 * 1024 * 1024) == 4095'u64

  test "memUnitsForBytes rounds UP (rounding down would under-reserve)":
    check memUnitsForBytes(0) == 0
    check memUnitsForBytes(1) == 1
    check memUnitsForBytes(uint64(MemUnitBytes)) == 1
    check memUnitsForBytes(uint64(MemUnitBytes) + 1) == 2
    check memUnitsForBytes(8'u64 * 1024 * 1024 * 1024) == 128   # 8 GiB

  test "fitsPacked is per-dimension, not a whole-word comparison":
    let avail = packVec(vec(4, 10, 2, 50))
    check fitsPacked(avail, packVec(vec(4, 10, 2, 50)))
    check fitsPacked(avail, packVec(vec(0, 0, 0, 0)))
    check not fitsPacked(avail, packVec(vec(5, 0, 0, 0)))
    check not fitsPacked(avail, packVec(vec(0, 11, 0, 0)))
    check not fitsPacked(avail, packVec(vec(0, 0, 3, 0)))
    check not fitsPacked(avail, packVec(vec(0, 0, 0, 51)))
    # A whole-word `>=` would WRONGLY accept this: the packed want is numerically
    # smaller than the packed avail, yet it does not fit in the cpu dimension.
    let want = packVec(vec(5, 0, 0, 0))
    check want < avail
    check not fitsPacked(avail, want)

  test "NEGATIVE CONTROL: subtracting without the fit test borrows across dimensions":
    # This is the failure `fitsPacked` exists to prevent, made visible. avail has
    # ZERO cpu slots and 5 memory units; a claim of one cpu slot does not fit.
    let avail = packVec(vec(0, 5, 0, 0))
    let want = packVec(vec(1, 0, 0, 0))
    check not fitsPacked(avail, want)
    # Subtract anyway (what a fit-check-free implementation would do): the cpu field
    # underflows to 65535 AND steals a unit from the memory dimension above it.
    let broken = unpackVec(avail - want)
    check broken.cpuSlots == DimMax        # massive phantom capacity: overcommit
    check broken.memUnits == 4             # a DIFFERENT dimension silently corrupted
    # And that is exactly what `noOvercommit` samples for: remaining > capacity.
    check not fitsPacked(avail, avail - want)

# ---------------------------------------------------------------------------
suite "segment creation, publication and guards":
  test "a created segment is valid, full, and anchored":
    let path = freshPath("create")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [vec(8, 64, 8, 100), vec(4, 32, 4, 50)])
    check l.available
    check l.budgetCount == 2
    check l.segmentSize() == leaseSegmentSize(2)
    check l.capacityVec(MachineBudgetIndex) == vec(8, 64, 8, 100)
    check l.remainingVec(MachineBudgetIndex) == vec(8, 64, 8, 100)
    check l.capacityVec(poolBudgetIndex(0)) == vec(4, 32, 4, 50)
    check l.outstandingVec(MachineBudgetIndex) == vec(0, 0, 0, 0)
    check l.noOvercommitAnywhere()

    # Anchor: boot id + owner pid + owner process START TIME. Start time is the
    # field that will defeat pid reuse in M7; it is recorded from M2 so the
    # discipline is not a retrofit.
    check l.creatorBootId() == bootId()
    check l.ownerPid() == uint64(getpid())
    check l.ownerStartTime() != 0'u64
    check l.ownerStartTime() == processStartTime(getpid())
    check l.ownerVerdict() == avLive
    l.detach()

  test "the FINAL name only ever names a fully initialised segment":
    # The observable consequence of publish-before-write: whenever the final path
    # exists, attaching to it succeeds and every field is already correct. (The
    # window itself is driven deterministically in test_shm_lease_hooks.nim, which
    # pauses creation at `slpBeforeSegmentRename`.)
    let path = freshPath("publish")
    defer: cleanup(path)
    var owner = createLeaseSegment(path, [vec(2, 4, 2, 8)])
    check owner.available
    check fileExists(path)
    var view = attachLeaseSegment(path)
    check view.available
    check view.capacityVec(0) == vec(2, 4, 2, 8)
    check view.remainingVec(0) == vec(2, 4, 2, 8)
    check view.ownerPid() == uint64(getpid())
    view.detach(); owner.detach()
    # No temp file is left behind.
    var leftovers = 0
    for _, p in walkDir(parentDir(path)):
      if extractFilename(p).startsWith(extractFilename(path) & ".tmp."): inc leftovers
    check leftovers == 0

  test "attach refuses a missing file and a non-segment file":
    let missing = freshPath("missing")
    var a = attachLeaseSegment(missing)
    check not a.available

    let junk = freshPath("junk")
    defer: cleanup(junk)
    writeFile(junk, newString(leaseSegmentSize(1)))   # right size, wrong contents
    var b = attachLeaseSegment(junk)
    check not b.available

  test "an empty or oversized capacity list is refused":
    let path = freshPath("badcap")
    defer: cleanup(path)
    var none = createLeaseSegment(path, [])
    check not none.available
    var bad = createLeaseSegment(path, [vec(DimMax + 1, 0, 0, 0)])
    check not bad.available

# ---------------------------------------------------------------------------
suite "claim, release, refuse":
  test "a claim takes exactly the vector and a release gives exactly it back":
    let path = freshPath("claim")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [vec(8, 64, 8, 100)])
    check l.available
    var r: Reservation
    check l.claim(vec(2, 16, 1, 25), r) == csGranted
    check r.isGranted
    check l.remainingVec(0) == vec(6, 48, 7, 75)
    check l.outstandingVec(0) == vec(2, 16, 1, 25)
    check l.claimCount(0) == 1
    check l.noOvercommit(0)

    check l.release(r)
    check l.remainingVec(0) == vec(8, 64, 8, 100)
    check l.packedRemaining(0) == l.packedCapacity(0)  # bit-for-bit restored
    check l.releaseCount(0) == 1
    check not r.isGranted                              # handle cleared
    check not l.release(r)                             # second release is a no-op
    l.detach()

  test "a claim that does not fit is refused and changes nothing":
    let path = freshPath("refuse")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [vec(4, 8, 4, 10)])
    var r: Reservation
    let before = l.packedRemaining(0)
    check l.claim(vec(5, 1, 1, 1), r) == csRefused     # cpu does not fit
    check not r.isGranted
    check l.packedRemaining(0) == before
    check l.refusalCount(0) == 1
    check l.claim(vec(1, 9, 1, 1), r) == csRefused     # memory does not fit
    check l.packedRemaining(0) == before
    check l.claim(vec(1, 1, 1, 11), r) == csRefused    # io weight does not fit
    check l.packedRemaining(0) == before
    check l.claimCount(0) == 0
    check l.noOvercommit(0)
    l.detach()

  test "claiming the whole budget is granted; one more unit is refused":
    let path = freshPath("exact")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [vec(4, 8, 4, 10)])
    var a, b: Reservation
    check l.claim(vec(4, 8, 4, 10), a) == csGranted
    check l.remainingVec(0) == vec(0, 0, 0, 0)
    check l.claim(vec(0, 0, 0, 1), b) == csRefused
    check l.claim(vec(1, 0, 0, 0), b) == csRefused
    check l.claim(vec(0, 0, 0, 0), b) == csGranted      # the empty claim always fits
    check l.remainingVec(0) == vec(0, 0, 0, 0)
    check l.release(b)
    check l.release(a)
    check l.remainingVec(0) == vec(4, 8, 4, 10)
    l.detach()

  test "NEGATIVE CONTROL: the same overcommit, forced through the raw CAS":
    # Prove the invariant checker (`noOvercommit`) fails when the fit test is
    # skipped — the gate's central assertion is therefore evidence, not decoration.
    let path = freshPath("teeth")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [vec(1, 4, 1, 1)])
    check l.noOvercommit(0)
    var r: Reservation
    check l.claim(vec(1, 0, 0, 0), r) == csGranted      # takes the only cpu slot
    check l.remainingVec(0).cpuSlots == 0
    check l.claim(vec(1, 0, 0, 0), r) == csRefused      # the real API refuses
    check l.noOvercommit(0)

    # Now do what a fit-check-free claim would do: whole-word subtract, raw CAS.
    var expected = l.packedRemaining(0)
    check l.casPackedRemaining(0, expected, expected - packVec(vec(1, 0, 0, 0)))
    check l.remainingVec(0).cpuSlots == DimMax          # phantom capacity
    check not l.noOvercommit(0)                         # <-- the detector fires
    check not l.noOvercommitAnywhere()
    l.detach()

  test "over-release is REFUSED rather than fabricating capacity":
    let path = freshPath("overrelease")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [vec(4, 8, 4, 10)])
    var r: Reservation
    check l.claim(vec(2, 4, 2, 5), r) == csGranted
    check l.release(r)
    check l.remainingVec(0) == vec(4, 8, 4, 10)
    # A duplicate release (the same vector again, e.g. a buggy caller or a
    # double-reclaim) would push the word above capacity. Refuse it.
    check not l.releaseVec(vec(2, 4, 2, 5))
    check l.remainingVec(0) == vec(4, 8, 4, 10)
    check l.noOvercommit(0)
    l.detach()

# ---------------------------------------------------------------------------
suite "multi-word budgets and the FIXED CLAIM ORDER":
  test "machine + pool are both decremented, and both restored":
    let path = freshPath("twoword")
    defer: cleanup(path)
    var l = createLeaseSegment(path,
      [vec(8, 64, 8, 100), vec(4, 32, 4, 50), vec(4, 32, 4, 50)])
    check l.budgetCount == 3
    var r: Reservation
    check l.claim(vec(2, 8, 1, 10), r, poolIndex = 1) == csGranted
    check r.wordCount == 2
    check r.words[0] == int32(MachineBudgetIndex)
    check r.words[1] == int32(poolBudgetIndex(1))
    check l.remainingVec(MachineBudgetIndex) == vec(6, 56, 7, 90)
    check l.remainingVec(poolBudgetIndex(1)) == vec(2, 24, 3, 40)
    check l.remainingVec(poolBudgetIndex(0)) == vec(4, 32, 4, 50)   # untouched
    check l.release(r)
    check l.remainingVec(MachineBudgetIndex) == vec(8, 64, 8, 100)
    check l.remainingVec(poolBudgetIndex(1)) == vec(4, 32, 4, 50)
    l.detach()

  test "a claim refused on the POOL word rolls the MACHINE word back exactly":
    let path = freshPath("rollback")
    defer: cleanup(path)
    # The machine budget is generous; the pool budget is not. The claim therefore
    # succeeds on word 0 and is refused on word 1, which must leave word 0 exactly
    # as it was — no leaked capacity, and no trace in the claim accounting.
    var l = createLeaseSegment(path, [vec(8, 64, 8, 100), vec(1, 2, 1, 5)])
    let before = l.packedRemaining(MachineBudgetIndex)
    var r: Reservation
    check l.claim(vec(4, 16, 2, 20), r, poolIndex = 0) == csRefused
    check not r.isGranted
    check l.packedRemaining(MachineBudgetIndex) == before      # bit-for-bit
    check l.remainingVec(poolBudgetIndex(0)) == vec(1, 2, 1, 5)
    check l.rollbackCount(MachineBudgetIndex) == 1
    check l.claimCount(MachineBudgetIndex) == 0                # undone, not counted
    check l.claimedUnits(MachineBudgetIndex, ldCpuSlots) == 0
    check l.refusalCount(poolBudgetIndex(0)) == 1
    check l.noOvercommitAnywhere()
    l.detach()

  test "the fixed ascending order is ENFORCED, not merely documented":
    let path = freshPath("order")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [vec(8, 8, 8, 8), vec(8, 8, 8, 8), vec(8, 8, 8, 8)])
    var r: Reservation
    let v = vec(1, 1, 1, 1)
    # Ascending is the only accepted form: machine (0) first, then pools upward.
    check l.claimWords(v, [0, 1, 2], r) == csGranted
    check l.release(r)
    # Descending, repeated, and unsorted lists are refused. Reordering them
    # silently would let a caller construct an order this library cannot see.
    check l.claimWords(v, [1, 0], r) == csOutOfOrder
    check l.claimWords(v, [0, 0], r) == csOutOfOrder
    check l.claimWords(v, [2, 1, 0], r) == csOutOfOrder
    check l.claimWords(v, [0, 2, 1], r) == csOutOfOrder
    # And a refused claim took nothing.
    for i in 0 ..< 3:
      check l.remainingVec(i) == vec(8, 8, 8, 8)
    check l.claimWords(v, [], r) == csBadBudget
    check l.claimWords(v, [3], r) == csBadBudget
    check l.claimWords(v, [-1], r) == csBadBudget
    check l.claimWords(vec(DimMax + 1, 0, 0, 0), [0], r) == csInvalidVec
    l.detach()

# ---------------------------------------------------------------------------
suite "anchoring: boot id + owner pid + process START TIME":
  test "start time is what decides pid reuse, and it IS consulted":
    let myPid = uint64(getpid())
    let myStart = processStartTime(getpid())
    check myStart != 0'u64
    # Live, correct anchor.
    check anchorVerdict(bootId(), myPid, myStart) == avLive
    # SAME pid, SAME boot, process demonstrably alive — but a different start
    # time. Only start time can tell these apart, and the verdict proves it does.
    check anchorVerdict(bootId(), myPid, myStart + 1) == avPidReused
    check anchorVerdict(bootId(), myPid, myStart - 1) == avPidReused
    # An unknown (0) recorded start time falls back to boot+pid rather than
    # pretending to know.
    check anchorVerdict(bootId(), myPid, 0'u64) == avLive

  test "a previous boot and a dead owner are distinguished from pid reuse":
    let myStart = processStartTime(getpid())
    check anchorVerdict(bootId() + 1, uint64(getpid()), myStart) == avStaleBoot
    let dead = reapedPid()
    check not pidAlive(dead)
    check anchorVerdict(bootId(), dead, 12345'u64) == avOwnerGone
    check anchorVerdict(bootId(), 0'u64, 0'u64) == avNoOwner

  test "bootId is stable within a process and never zero":
    check bootId() != 0'u64
    check bootId() == bootId()

# ---------------------------------------------------------------------------
suite "position independence (SM-7) in one process":
  test "a second mapping at a DELIBERATELY chosen base sees the same budget":
    let path = freshPath("mapfixed")
    defer: cleanup(path)
    var owner = createLeaseSegment(path, [vec(8, 64, 8, 100), vec(4, 32, 4, 50)])
    check owner.available
    var r: Reservation
    check owner.claim(vec(3, 20, 2, 30), r, poolIndex = 0) == csGranted

    # Reserve a region of exactly the segment's size at an address the kernel hands
    # us, then force the second mapping THERE with MAP_FIXED — a base of our
    # choosing that differs from the owner's. Offsets-only ⇒ identical results; a
    # leaked absolute pointer would fault or mismatch here.
    let sz = owner.segmentSize()
    let want = mmap(nil, sz, PROT_NONE, MAP_PRIVATE or MAP_ANONYMOUS, cint(-1), 0)
    check want != MAP_FAILED
    var view = attachLeaseSegment(path, want)
    check view.available
    check cast[uint](view.mappedBase()) == cast[uint](want)
    check cast[uint](view.mappedBase()) != cast[uint](owner.mappedBase())

    check view.remainingVec(MachineBudgetIndex) == owner.remainingVec(MachineBudgetIndex)
    check view.capacityVec(poolBudgetIndex(0)) == owner.capacityVec(poolBudgetIndex(0))
    check view.ownerPid() == owner.ownerPid()

    # Mutate through the FAR mapping; observe through the NEAR one.
    var r2: Reservation
    check view.claim(vec(1, 4, 1, 5), r2, poolIndex = 0) == csGranted
    check owner.remainingVec(MachineBudgetIndex) == vec(4, 40, 5, 65)
    check owner.remainingVec(poolBudgetIndex(0)) == vec(0, 8, 1, 15)
    # ...and release through the NEAR mapping a reservation granted on the FAR one.
    check owner.releaseVec(vec(1, 4, 1, 5), poolIndex = 0)
    check view.remainingVec(MachineBudgetIndex) == vec(5, 44, 6, 70)

    check view.storedPointerCheck()
    check owner.storedPointerCheck()
    view.detach()
    check owner.release(r)
    check owner.remainingVec(MachineBudgetIndex) == vec(8, 64, 8, 100)
    owner.detach()

  test "NEGATIVE CONTROL: the stored-pointer checker catches a forged pointer":
    let path = freshPath("ptrprobe")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [vec(1, 1, 1, 1)])
    check l.storedPointerCheck()
    # Forge exactly the bug SM-7 forbids: an absolute pointer into this mapping,
    # stored inside the segment.
    l.writeProbeWord(cast[uint64](l.mappedBase()))
    check not l.storedPointerCheck()
    expect AssertionDefect:
      l.assertNoStoredPointers()
    # A plain small offset is fine.
    l.writeProbeWord(64'u64)
    check l.storedPointerCheck()
    l.assertNoStoredPointers()
    l.detach()

# ---------------------------------------------------------------------------
suite "platform arm":
  test "this host uses the real (Linux/macOS) arm":
    when defined(linux) or defined(macosx):
      check shmLeaseSupported
    else:
      # The portable no-op arm: everything reports unavailable so a caller
      # degrades instead of failing. Windows lands here — per the design spec the
      # Windows transport is deferred (`WaitOnAddress` is within-process only, so
      # M3's wake path needs named kernel objects). See the README capability record.
      check not shmLeaseSupported
      let path = freshPath("noop")
      var l = createLeaseSegment(path, [vec(1, 1, 1, 1)])
      check not l.available
      var r: Reservation
      check l.claim(vec(1, 0, 0, 0), r) == csUnavailable
