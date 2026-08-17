## M4 unit tests for the observation ring (`shm_lease/obsring`).
##
## `RunQuota-Observation-Store.milestones.org` * Introduction:
##   "An invariant is proven only by a test that FAILS when the invariant is
##    violated -- not by inspection."
## So every claim below is paired with a control that makes the assertion move.
##
## MOCKS: none, and the one place a mock would be tempting is the place it would
## destroy the test. The syscall counts come from the KERNEL (`task_info` /
## `TASK_EVENTS_INFO`, the same counter M3 calibrated); the ring lives in a real
## file-backed `mmap(MAP_SHARED)` segment; the drops are real ring-full drops
## against a real capacity; the parked consumer is a real thread really inside the
## kernel. A fake clock, a fake counter or a fake ring would each test the fake.
##
## The cross-PROCESS properties — saturation with real producers at differing
## `MAP_FIXED` bases, the idle-wakeup count, and the wake-syscall count under a
## sustained non-empty ring — are the M4 GATE and live in
## `tests/test_shm_lease_obs_multiprocess.nim`. This file is what can be established
## without forking.
##
## WHAT EACH SUITE PROVES:
##
## 1. CAPABILITY RECORD + GEOMETRY. Which backend was selected, and the layout
##    invariants the format contract states: the header size, the wait word on its
##    own cache line, and — load-bearing for the prefault hazard — the wait word
##    lying on the SAME page as the header that `attachObsRing` necessarily reads.
##
## 2. THE SEGMENT. Create/attach, geometry read back from the header, an
##    unrecognised format version REFUSED rather than interpreted, position
##    independence at a second base, and the stored-pointer audit with a negative
##    control that forges an absolute pointer and requires the checker to fail.
##
## 3. OS-1 — PUBLISHING NEVER BLOCKS, NEVER FAILS, AND NEEDS NO DAEMON. Includes
##    the "no daemon attached" requirement: with nobody draining, publishing keeps
##    working and keeps counting, and the client is never told an error.
##
## 4. OS-2 — DROPS ARE COUNTED AND SURFACED. The exact overflow arithmetic, the
##    `delivered + dropped == produced` identity, and `windowCompleteness` reporting
##    `ccTruncated` for a window that lost records — with the control that a window
##    which lost none reports `ccComplete`, so the verdict is not a constant.
##
## 5. THE SYSCALL COUNTER IS RE-CALIBRATED HERE. M3 calibrated it; this suite does
##    not inherit that. If the instrument is wrong, every syscall number in M4 is
##    worthless, so it is re-established before it is used.
##
## 6. SM-2 / THE SIGNALLING RULE. Appends into a ring with no idle consumer cost
##    ZERO wake syscalls, measured against a control arm (`publishForcedSignal`,
##    the naive "signal on every append") that costs one per append.
##
## 7. THE EMPTY-TO-NON-EMPTY TRANSITION. A real parked consumer is signalled
##    exactly ONCE while a long burst of appends keeps the ring non-empty.

import std/[os, posix, unittest]
import shm_lease/[obsring, waitword, syscount, anchor]

var tmpCounter = 0
proc freshPath(tag: string): string =
  inc tmpCounter
  getTempDir() / ("shmlease-obs-" & tag & "-" & $getpid() & "-" & $tmpCounter & ".seg")

proc cleanup(path: string) =
  try: removeFile(path)
  except CatchableError: discard

proc nowNs(): uint64 =
  var ts: Timespec
  discard clock_gettime(CLOCK_MONOTONIC, ts)
  uint64(ts.tv_sec) * 1_000_000_000'u64 + uint64(ts.tv_nsec)

const
  RecLen = 48
  Cap = 64

proc mkRec(producer, seqNo: uint32): array[RecLen, byte] =
  ## A self-describing record: producer id, sequence number, a fill pattern derived
  ## from both, and a checksum over everything before it. A torn record — one whose
  ## bytes came from two different writers — cannot satisfy the checksum, which is
  ## how "no torn records" becomes an assertion rather than a hope.
  result[0] = byte(producer and 0xFF)
  result[1] = byte((producer shr 8) and 0xFF)
  result[2] = byte(seqNo and 0xFF)
  result[3] = byte((seqNo shr 8) and 0xFF)
  result[4] = byte((seqNo shr 16) and 0xFF)
  result[5] = byte((seqNo shr 24) and 0xFF)
  for i in 6 ..< RecLen - 2:
    result[i] = byte((producer * 31 + seqNo * 17 + uint32(i)) and 0xFF)
  var sum: uint16 = 0
  for i in 0 ..< RecLen - 2: sum = sum + uint16(result[i])
  result[RecLen - 2] = byte(sum and 0xFF)
  result[RecLen - 1] = byte((sum shr 8) and 0xFF)

proc recOk(buf: openArray[byte]; n: int): bool =
  if n != RecLen: return false
  var sum: uint16 = 0
  for i in 0 ..< RecLen - 2: sum = sum + uint16(buf[i])
  buf[RecLen - 2] == byte(sum and 0xFF) and buf[RecLen - 1] == byte((sum shr 8) and 0xFF)

# ===========================================================================

when not obsRingSupported:
  suite "M4 portable no-op arm":
    test "the observation ring reports unavailable rather than failing to build":
      # Windows lands here by design, and `just lint` cross-checks it with
      # `nim check --os:windows` so the promise cannot bit-rot. See the structures
      # spec §Windows for the destination this deferral has.
      var r = createObsRing("unused", 8, 64)
      check not r.available
      var rec: array[8, byte]
      check r.publish(rec) == oprUnavailable
      check r.awaitRecord(1000) == owrUnavailable

else:
 # =========================================================================
 # 1 — capability record and geometry
 # =========================================================================

 suite "M4 capability record and the layout contract":
  test "the backend, the header geometry, and the cache-line separation":
    check obsRingSupported
    check ObsRingBackend == "shm_queue Layer 1 embedded ring + shm_lease wait word"
    check ObsHeaderSize == 128
    check ObsWaitOff == 128
    check ObsWaitBlockSize == 64
    check ObsRingOff == 192
    # The wait word and the ring's `tail` must not share a cache line: producers
    # CAS `tail` on every append and read `waiters` on every append, and putting
    # them together would make the signalling check contend with the reservation it
    # is supposed to be free of.
    check ObsRingOff - ObsWaitOff >= 64
    check ObsSegFormatVersion == 1'u32

  test "the segment is sized by the HOST page size, never by a constant 4096":
    # M2 hard-coded 4096 and paid for it; pages are 16 KiB on Apple Silicon. This
    # asserts the rounding follows `sysconf(_SC_PAGESIZE)` on whatever host runs it.
    let ps = pageSize()
    check ps > 0
    for cap in [1, 8, 1024]:
      let sz = obsSegmentSize(cap, 128)
      check sz mod ps == 0
      check sz >= ObsRingOff + cap * 128
    echo "  [geometry] page size ", ps, " B; a ", Cap, "x", RecLen,
      " ring is ", obsSegmentSize(Cap, RecLen), " B"

  test "the consumer's wait word shares the page `attach` already faulted in":
    # THE PREFAULT HAZARD, made structural. On macOS a park on a page this process
    # has not touched fails INSTANTLY with EFAULT. `awaitRecord` calls
    # `prefaultWaitWord` because it reaches for `parkRaw` directly — but the deeper
    # reason this consumer is safe is that the wait word lies on the SAME page as
    # the header magic, which `attachObsRing` must read to validate the segment at
    # all. This assertion FAILS if a future layout change moves the wait word onto
    # a page of its own without arranging for it to be faulted in, which is exactly
    # the change that would silently reintroduce the hazard.
    check ObsWaitOff + WaitWordSize <= pageSize()
    check ObsOffMagic div pageSize() == ObsWaitOff div pageSize()

  test "the extension tag round-trips, and the transport never reads it":
    var buf: array[ObsTagSize + 4, byte]
    check encodeObsTag(buf, ObsTag(extensionId: 0xDEAD_BEEF'u32,
      schemaVersion: 0x1234'u16, kind: 0x00AB'u16))
    var tag: ObsTag
    check decodeObsTag(buf, tag)
    check tag.extensionId == 0xDEAD_BEEF'u32
    check tag.schemaVersion == 0x1234'u16
    check tag.kind == 0x00AB'u16
    var tooSmall: array[4, byte]
    check not encodeObsTag(tooSmall, tag)
    check not decodeObsTag(tooSmall, tag)

 # =========================================================================
 # 2 — the segment
 # =========================================================================

 suite "the observation-ring segment":
  test "create, attach, and read the geometry back from the header":
    let path = freshPath("create")
    defer: cleanup(path)
    var r = createObsRing(path, Cap, RecLen)
    check r.available
    check r.isOwner
    check r.capacity == Cap
    check r.maxRecordLen == RecLen
    check r.waitOff == ObsWaitOff

    var a = attachObsRing(path)
    check a.available
    check not a.isOwner
    check a.capacity == Cap            # never agreed out of band
    check a.maxRecordLen == RecLen
    check a.size == r.size
    a.detach()
    r.detach()

  test "a bad geometry is refused rather than silently rounded":
    let p1 = freshPath("geom1")
    defer: cleanup(p1)
    # Capacity must be a power of two: the ticket-to-slot mapping is a mask, and a
    # non-power-of-two would alias tickets onto slots.
    check not createObsRing(p1, 100, RecLen).available
    check not createObsRing(p1, 0, RecLen).available
    check not createObsRing(p1, Cap, 0).available
    check not createObsRing(p1, Cap, MaxObsRecordLen + 1).available
    check not createObsRing(p1, MaxObsCapacity * 2, RecLen).available
    check not fileExists(p1)

  test "an unrecognised format version is REFUSED, not interpreted":
    let path = freshPath("fmt")
    defer: cleanup(path)
    var r = createObsRing(path, Cap, RecLen)
    check r.available
    # Bump the on-segment format version behind the library's back. A consumer that
    # does not recognise a version MUST refuse to attach rather than read unknown
    # bytes as if it understood them.
    let p = cast[ptr uint32](addr r.base[ObsOffFormatVersion])
    let saved = p[]
    p[] = saved + 1
    check not attachObsRing(path).available
    p[] = saved
    check attachObsRing(path).available          # ...and it is the version that did it
    r.detach()

  test "position independence: published here, drained through another base":
    let path = freshPath("pos")
    defer: cleanup(path)
    var r = createObsRing(path, Cap, RecLen)
    check r.available
    check r.storedPointerCheck()

    let far = mmap(nil, r.size, PROT_NONE, MAP_PRIVATE or MAP_ANONYMOUS, cint(-1), 0)
    check far != MAP_FAILED
    var view = attachObsRing(path, far)
    check view.available
    check cast[uint](view.mappedBase()) == cast[uint](far)
    check cast[uint](view.mappedBase()) != cast[uint](r.mappedBase())

    # Published through the NEAR mapping, drained through the FAR one.
    for s in 0'u32 ..< 5'u32:
      check r.publish(mkRec(7, s)) == oprPublished
    var buf: array[RecLen, byte]
    var n = 0
    for s in 0'u32 ..< 5'u32:
      check view.drainOne(buf, n) == odrGot
      check recOk(buf, n)
      check buf[0] == 7'u8
      check buf[2] == byte(s)
    check view.drainOne(buf, n) == odrEmpty
    check view.storedPointerCheck()
    check view.acceptedCount() == 5'u64   # the counters agree across the two bases
    check r.drainedCount() == 5'u64
    view.detach()
    r.detach()

  test "the stored-pointer audit FAILS when an absolute pointer is forged":
    # The negative control that gives the audit teeth: without it, a checker that
    # always returned true would pass every test above.
    let path = freshPath("ptr")
    defer: cleanup(path)
    var r = createObsRing(path, Cap, RecLen)
    check r.available
    check r.storedPointerCheck()
    let w = cast[ptr uint64](addr r.base[ObsOffReserved1])
    let saved = w[]
    w[] = cast[uint64](r.mappedBase())        # an absolute pointer, exactly what
    check not r.storedPointerCheck()          # position independence forbids
    w[] = saved
    check r.storedPointerCheck()
    r.detach()

 # =========================================================================
 # 3 — OS-1: publishing never blocks, never fails, needs no daemon
 # =========================================================================

 suite "OS-1: publishing never blocks, never fails, and needs no daemon":
  test "with NO daemon attached, publishing keeps working and keeps counting":
    let path = freshPath("nodaemon")
    defer: cleanup(path)
    var r = createObsRing(path, Cap, RecLen)
    check r.available
    # No consumer has registered. The requirement is not "it works anyway by luck":
    # a missing daemon MUST NOT be reported as an error and MUST NOT fail a run.
    check r.consumerVerdict() == avNoOwner
    check not r.consumerAttached()

    const Produced = Cap * 4
    var published, dropped, other = 0
    let t0 = nowNs()
    for s in 0'u32 ..< uint32(Produced):
      case r.publish(mkRec(1, s))
      of oprPublished: inc published
      of oprDropped: inc dropped
      else: inc other
    let elapsed = nowNs() - t0

    check other == 0                         # never `oprUnavailable`, never a failure
    check published + dropped == Produced
    check published == Cap                   # exactly the ring's worth fit
    check dropped == Produced - Cap
    check r.acceptedCount() == uint64(published)
    check r.droppedCount() == uint64(dropped)
    # NEVER BLOCKS: a block-on-full ring with no consumer would hang here forever.
    # The bound is deliberately loose (it is a liveness assertion, not a benchmark)
    # but it is what turns "does not block" into something a wedge would fail.
    check elapsed < 2_000_000_000'u64
    echo "  [no daemon] ", Produced, " appends -> ", published, " published, ",
      dropped, " dropped, in ", elapsed div 1000, "us (no consumer ever attached)"
    r.detach()

  test "the consumer anchor distinguishes attached, gone, and pid-reused":
    let path = freshPath("anchor")
    defer: cleanup(path)
    var r = createObsRing(path, Cap, RecLen)
    check r.available
    check r.consumerVerdict() == avNoOwner
    r.registerConsumer()
    check r.consumerVerdict() == avLive
    check r.consumerAttached()
    # Same pid, same boot, process demonstrably alive — and yet a DIFFERENT process,
    # because the recorded start time differs. That is the whole point of carrying
    # start time in the anchor, and the assertion proves the field is CONSULTED
    # rather than merely stored.
    let sp = cast[ptr uint64](addr r.base[ObsOffConsumerStart])
    let savedStart = sp[]
    sp[] = savedStart + 1
    check r.consumerVerdict() == avPidReused
    sp[] = savedStart
    check r.consumerVerdict() == avLive
    r.deregisterConsumer()
    check r.consumerVerdict() == avNoOwner
    check not r.consumerAttached()
    r.detach()

  test "an oversize record leaves the ring UNCHANGED and is not a drop":
    let path = freshPath("oversize")
    defer: cleanup(path)
    var r = createObsRing(path, Cap, RecLen)
    check r.available
    var big: array[RecLen + 1, byte]
    check r.publish(big) == oprOversize
    # NOT counted as a drop: a drop means capacity pressure, and conflating a caller
    # bug with pressure would make the completeness verdict lie in both directions.
    check r.droppedCount() == 0'u64
    check r.acceptedCount() == 0'u64
    check r.windowCompleteness(0) == ccComplete
    r.detach()

 # =========================================================================
 # 4 — OS-2: drops are counted and surfaced
 # =========================================================================

 suite "OS-2: every drop is counted, and a truncated window says so":
  test "the overflow arithmetic is exact, and completeness follows it":
    let path = freshPath("drops")
    defer: cleanup(path)
    var r = createObsRing(path, Cap, RecLen)
    check r.available

    # A window that loses nothing.
    let w0 = r.droppedCount()
    for s in 0'u32 ..< uint32(Cap):
      check r.publish(mkRec(2, s)) == oprPublished
    check r.droppedCount() == 0'u64
    check r.windowCompleteness(w0) == ccComplete       # <-- the control: not constant

    # One more record than the ring can hold.
    check r.publish(mkRec(2, 999)) == oprDropped
    check r.droppedCount() == 1'u64
    check r.windowCompleteness(w0) == ccTruncated      # <-- OS-2

    # ...and the loss is visible to a consumer that only sees the delivered rows:
    # `delivered + dropped == produced` EXACTLY, which is what makes a thinned
    # sample impossible to present as a complete one.
    var buf: array[RecLen, byte]
    var n = 0
    var delivered = 0
    while r.drainOne(buf, n) == odrGot:
      check recOk(buf, n)
      inc delivered
    check delivered == Cap
    check uint64(delivered) + r.droppedCount() == uint64(Cap + 1)
    # A window taken AFTER the loss, over which nothing was lost, is complete again:
    # completeness is a property of the window, not a latch.
    let w1 = r.droppedCount()
    check r.publish(mkRec(2, 1000)) == oprPublished
    check r.windowCompleteness(w1) == ccComplete
    r.detach()

  test "a drained slot is reusable, so drops are pressure and not exhaustion":
    let path = freshPath("reuse")
    defer: cleanup(path)
    var r = createObsRing(path, 8, RecLen)
    check r.available
    var buf: array[RecLen, byte]
    var n = 0
    # Ten times round an 8-slot ring, draining as we go: zero drops, because the
    # consumer keeps up. A ring that leaked slots would start dropping.
    for s in 0'u32 ..< 80'u32:
      check r.publish(mkRec(3, s)) == oprPublished
      check r.drainOne(buf, n) == odrGot
      check recOk(buf, n)
      check buf[2] == byte(s and 0xFF)
    check r.droppedCount() == 0'u64
    check r.pendingCount() == 0'u64
    check r.acceptedCount() == 80'u64
    check r.drainedCount() == 80'u64
    r.detach()

  test "a consumer buffer that is too small leaves the record in place":
    let path = freshPath("smallbuf")
    defer: cleanup(path)
    var r = createObsRing(path, 8, RecLen)
    check r.available
    check r.publish(mkRec(4, 1)) == oprPublished
    var tiny: array[RecLen - 1, byte]
    var n = 0
    check r.drainOne(tiny, n) == odrOverflowBuf
    check r.pendingCount() == 1'u64          # the ring is UNCHANGED: nothing lost
    var buf: array[RecLen, byte]
    check r.drainOne(buf, n) == odrGot
    check recOk(buf, n)
    r.detach()

 # =========================================================================
 # 5 — the instrument, re-calibrated before M4 uses it
 # =========================================================================

 suite "the syscall counter is re-calibrated before M4 relies on it":
  test "a known number of syscalls moves it by exactly that number":
    # M3 calibrated this counter. M4 does NOT inherit that: if the instrument is
    # wrong, every syscall number in this milestone is worthless, and a claim
    # inherited from a previous milestone is exactly the kind of claim that is never
    # re-checked.
    if not syscallCountAvailable():
      echo "  [skip] no in-process kernel syscall counter here; M4's SM-2 numbers " &
        "must be taken externally — see `just test-syscalls`"
      check true
    else:
      const N = 1000
      let a = unixSyscallCount()
      for _ in 0 ..< N: discard getppid()
      let delta = unixSyscallCount() - a
      check delta == uint64(N)
      echo "  [calibration] ", N, " getppid() -> counter moved by ", delta

  test "a purely userspace loop moves it by exactly zero":
    if not syscallCountAvailable():
      check true
    else:
      let a = unixSyscallCount()
      var acc = 0'u64
      for i in 0 ..< 1_000_000: acc = acc * 31 + uint64(i)
      let delta = unixSyscallCount() - a
      check delta == 0'u64
      check acc != 0'u64                      # not optimised away
      echo "  [calibration] 10^6 userspace iterations -> counter moved by ", delta

 # =========================================================================
 # 6 — SM-2: the signalling rule costs no syscalls when nobody is idle
 # =========================================================================

 suite "SM-2: appends cost ZERO wake syscalls when no consumer is idle":
  test "N appends -> 0 syscalls; the naive 'signal always' arm -> N syscalls":
    let pathA = freshPath("sig-real")
    let pathB = freshPath("sig-ctl")
    defer: cleanup(pathA)
    defer: cleanup(pathB)
    const Cap2 = 65536
    const N = 20_000
    var real = createObsRing(pathA, Cap2, RecLen)
    var ctl = createObsRing(pathB, Cap2, RecLen)
    check real.available
    check ctl.available

    if not syscallCountAvailable():
      echo "  [skip] no in-process kernel syscall counter here"
      check true
    else:
      let a0 = unixSyscallCount()
      for s in 0'u32 ..< uint32(N):
        check real.publish(mkRec(5, s)) == oprPublished
      let realDelta = unixSyscallCount() - a0

      let b0 = unixSyscallCount()
      for s in 0'u32 ..< uint32(N):
        check ctl.publishForcedSignal(mkRec(5, s)) == oprPublished
      let ctlDelta = unixSyscallCount() - b0

      # THE MEASUREMENT: no consumer is parked, so the empty-to-non-empty rule
      # signals nothing at all and the appends never enter the kernel.
      check realDelta == 0'u64
      check real.signalCount() == 0'u64
      # THE CONTROL that makes the zero a measurement rather than an artefact of a
      # counter that does not move: the naive implementation the transport spec
      # names — "signalling unconditionally would restore the syscall this design
      # removes" — pays one kernel entry per append.
      check ctlDelta >= uint64(N)
      check ctl.signalCount() == uint64(N)
      echo "  [SM-2] ", N, " appends -> ", realDelta, " syscalls (signals=",
        real.signalCount(), "); signal-always control -> ", ctlDelta,
        " syscalls (signals=", ctl.signalCount(), ")"
    ctl.detach()
    real.detach()

 # =========================================================================
 # 7 — the empty-to-non-empty transition, with a real parked consumer
 # =========================================================================

 var gRing: ObsRing
 var gConsumerRc {.threadvar.}: int
 var gConsumerParks: int
 var gConsumerResult: int
 var gConsumerDone: int

 proc consumerThread(unused: int) {.thread.} =
   {.cast(gcsafe).}:
     var parks = 0
     let rc = gRing.awaitRecord(timeoutNs = 20_000_000_000'i64, parks = addr parks)
     gConsumerParks = parks
     gConsumerResult = ord(rc)
     atomicStoreN(addr gConsumerDone, 1, ATOMIC_RELEASE)
     gConsumerRc = ord(rc)

 suite "the empty-to-non-empty transition is signalled exactly once":
  test "a parked consumer is woken by the FIRST append and by no later one":
    let path = freshPath("transition")
    defer: cleanup(path)
    const N = 5000
    gRing = createObsRing(path, 65536, RecLen)
    check gRing.available
    gConsumerParks = 0
    gConsumerResult = -1
    atomicStoreN(addr gConsumerDone, 0, ATOMIC_RELEASE)

    var th: Thread[int]
    createThread(th, consumerThread, 0)

    # Wait until the consumer is really parked. Its IDLE TOKEN is what a producer
    # claims, so observing it here is not incidental — it is the precondition the
    # signalling rule is defined against, established as a fact rather than by
    # sleeping and hoping.
    var parked = false
    for _ in 0 ..< 5000:
      if gRing.consumerIdle() and waitWordWaiters(gRing.base, gRing.waitOff) > 0'u32:
        parked = true
        break
      sleep(1)
    check parked

    # A long burst into a ring NOBODY drains: the ring is non-empty from the first
    # append onwards, so exactly ONE empty-to-non-empty transition exists in the
    # whole burst.
    for s in 0'u32 ..< uint32(N):
      discard gRing.publish(mkRec(6, s))

    joinThread(th)
    check gConsumerResult == ord(owrReady)
    check gConsumerParks >= 1                 # it really slept, and really returned
    check gRing.signalCount() == 1'u64        # <-- exactly one signal for N appends
    check gRing.acceptedCount() > 0'u64
    echo "  [transition] ", N, " appends into a ring nobody drains -> ",
      gRing.signalCount(), " signal(s); consumer parked ", gConsumerParks,
      " time(s) and returned ", ObsWaitResult(gConsumerResult)
    gRing.detach()

  test "a consumer that arrives AFTER the append never parks at all":
    # The other half of the rule: the fast path. A record already in the ring means
    # `awaitRecord` returns without registering, without a fence-and-recheck dance,
    # and above all without a syscall — which is the common case for a busy daemon
    # and the reason a backlog costs nothing to notice.
    let path = freshPath("nopark")
    defer: cleanup(path)
    var r = createObsRing(path, 64, RecLen)
    check r.available
    check r.publish(mkRec(8, 1)) == oprPublished
    var parks = 0
    if syscallCountAvailable():
      let a = unixSyscallCount()
      check r.awaitRecord(timeoutNs = 1_000_000_000'i64, parks = addr parks) == owrReady
      let delta = unixSyscallCount() - a
      check parks == 0
      check delta == 0'u64
      echo "  [fast path] a non-empty ring is noticed in ", delta, " syscalls"
    else:
      check r.awaitRecord(timeoutNs = 1_000_000_000'i64, parks = addr parks) == owrReady
      check parks == 0
    r.detach()
