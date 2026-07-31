## M3 unit tests for the futex-class blocking wrapper (`shm_lease/waitword`).
##
## `RunQuota-Observation-Store.milestones.org` * Introduction:
##   "An invariant is proven only by a test that FAILS when the invariant is
##    violated -- not by inspection."
## So every claim below is paired with a control that makes the assertion move.
##
## MOCKS: none. The syscall counts come from the kernel (`task_info` /
## `TASK_EVENTS_INFO`), the wait words live in a real file-backed
## `mmap(MAP_SHARED)` segment, and the blocking is real blocking. The one thing
## deliberately NOT tested here is cross-process behaviour — that needs real
## processes at real differing bases and lives in
## `tests/test_shm_lease_wait_multiprocess.nim`, which is the M3 gate.
##
## WHAT EACH SUITE PROVES:
##
## 1. CAPABILITY RECORD. The backend actually selected, the runtime availability
##    check (the macOS 14.4 gate), and the recorded Windows gap. A capability
##    record nobody asserts against drifts.
##
## 2. THE SYSCALL COUNTER IS CALIBRATED BEFORE IT IS TRUSTED. SM-2 says "verified
##    by syscall counting, not by reading code", which is only worth anything if
##    the counter is known to count. So the suite first shows 1000 `getppid()`
##    calls move it by exactly 1000 and 10^6 userspace iterations move it by
##    exactly 0. Everything after that is measured against a calibrated instrument.
##
## 3. SM-2, BOTH FAST PATHS. A waiter whose word already changed, and a waker with
##    no registered waiter, must each cost ZERO kernel entries over a large batch.
##    The controls in the same tests force the syscall and require the counter to
##    move, so "delta == 0" is a measurement and not an artefact.
##
## 4. SPURIOUS WAKEUPS ARE TOLERATED. Every primitive behind this wrapper is
##    permitted to wake a waiter for no reason, so the waiter re-validates. The
##    test INJECTS spurious wakes (a forced wake with the value unchanged) and
##    requires the waiter to re-park rather than to report a grant that does not
##    exist.
##
## 5. THE PREFAULT HAZARD IS REAL. `os_sync_wait_on_address` returns `EFAULT` on a
##    page this process has not yet touched. The test exhibits the failure on an
##    untouched page and shows the same address working after a prefault, so the
##    guard in `waitOn` is a demonstrated necessity rather than a cautious comment.

import std/[os, posix, strutils, times, unittest]
import shm_lease/[waitword, syscount, anchor]

var tmpCounter = 0
proc freshPath(tag: string): string =
  inc tmpCounter
  getTempDir() / ("shmlease-ww-" & tag & "-" & $getpid() & "-" & $tmpCounter & ".seg")

proc cleanup(path: string) =
  try: removeFile(path)
  except CatchableError: discard

# ===========================================================================
# 1 — the capability record
# ===========================================================================

suite "M3 capability record":
  test "the selected backend, its runtime gate, and the recorded Windows gap":
    echo "  [capability] supported=", waitWordSupported,
      " available=", waitWordAvailable(),
      " backend=", WaitWordBackend,
      " macOS min=", WaitWordMinMacOsVersion,
      " pageSize=", pageSize(),
      " syscallCounter=", syscallCountAvailable()
    when defined(macosx):
      check waitWordSupported
      # The symbols are weak-imported and NULL-checked, which is the whole point
      # of recording a minimum OS version: a binary built against a 14.4 SDK still
      # launches on an older host and reports unavailable there. On this host they
      # resolve, so availability must be true — if it is not, the weak import or
      # the shim is broken and everything below would silently degrade to
      # `wrUnavailable` and pass vacuously.
      check waitWordAvailable()
      check WaitWordMinMacOsVersion == "14.4"
      check WaitWordBackend.contains("os_sync_wait_on_address")
    elif defined(linux):
      check waitWordSupported
      check waitWordAvailable()
      # Non-private is not a detail: a PRIVATE futex keys on (mm, address), which
      # cannot wake a peer process at a different virtual base. The gate proves it.
      check WaitWordBackend.contains("without FUTEX_PRIVATE_FLAG")
    else:
      # Windows and anything else land here. `WaitOnAddress` is documented as
      # within-process only, so the cross-process WAKE path would need named
      # kernel objects; the campaign puts that out of scope and requires the gap to
      # be recorded rather than silently omitted.
      check not waitWordSupported
      check not waitWordAvailable()

    # The page size is asked, never assumed — 16 KiB on Apple Silicon, 4 KiB
    # elsewhere. M2 hard-coded 4096 and got a silent `EINVAL` for most MAP_FIXED
    # probe bases.
    check pageSize() > 0
    check (pageSize() and (pageSize() - 1)) == 0

  test "the wait word is 8 bytes of pure value — no address is representable":
    check WaitWordSize == 8
    check WwOffValue == 0
    check WwOffWaiters == 4
    check WaitSlotSize == 32
    check WaitSegHeaderSize == 64
    # Every slot offset is 8-aligned, which the atomics require in every mapping.
    check (WaitSegHeaderSize mod 8) == 0
    check (WaitSlotSize mod 8) == 0

when waitWordSupported:

  # ===========================================================================
  # 2 — calibrate the instrument BEFORE using it
  # ===========================================================================

  suite "the syscall counter is calibrated before SM-2 relies on it":
    test "a known number of syscalls moves it by exactly that number":
      if not syscallCountAvailable():
        echo "  [skip] no in-process kernel syscall counter on this platform; " &
          "SM-2 is measured externally here — see `just test-syscalls`"
        check true
      else:
        const N = 1000
        let a = unixSyscallCount()
        for _ in 0 ..< N: discard getppid()
        let b = unixSyscallCount()
        let delta = b - a
        # EXACTLY N. A counter that over- or under-counts would make the
        # zero-delta assertions below meaningless in one direction or the other.
        check delta == uint64(N)

    test "a purely userspace loop moves it by exactly zero":
      if not syscallCountAvailable():
        check true
      else:
        let a = unixSyscallCount()
        var acc = 0'u64
        for i in 0 ..< 1_000_000: acc += uint64(i)
        let b = unixSyscallCount()
        let delta = b - a
        check acc > 0'u64          # not optimised away
        check delta == 0'u64       # ...and reading the counter costs no UNIX syscall

  # ===========================================================================
  # 3 — SM-2: zero syscalls on the uncontended fast path
  # ===========================================================================

  suite "SM-2: the uncontended fast path never enters the kernel":
    test "200000 fast-path waits and 200000 no-waiter wakes cost zero syscalls":
      let path = freshPath("fast")
      defer: cleanup(path)
      var seg = createWaitSegment(path, 8)
      check seg.available
      let base = seg.base
      let off = seg.slotOffset(0)
      prefaultWaitWord(base, off)

      const N = 200_000
      const Ctl = 200

      resetWaitWordCounters()
      let cur = seg.slotValue(0)

      # --- waiter fast path: the word ALREADY differs from what we expect, so
      # `waitOn` must observe that with one atomic load and return.
      let w0 = unixSyscallCount()
      for _ in 0 ..< N:
        discard waitOn(base, off, cur + 1)      # expected != actual ⇒ fast path
      let w1 = unixSyscallCount()
      let waitDelta = w1 - w0
      let fastWaits = wwFastWaits
      let parks = wwParks

      # --- waker fast path: nobody is parked, so there is nothing to wake.
      let k0 = unixSyscallCount()
      for _ in 0 ..< N:
        discard wakeAll(base, off)
      let k1 = unixSyscallCount()
      let wakeDelta = k1 - k0
      let fastWakes = wwFastWakes

      # --- THE CONTROL. The identical measurement over a FORCED wake, which
      # always enters the kernel. Without this, "delta == 0" above could equally
      # mean the counter never moves.
      let c0 = unixSyscallCount()
      for _ in 0 ..< Ctl:
        discard wakeRaw(base, off)
      let c1 = unixSyscallCount()
      let ctlDelta = c1 - c0
      let wakeSyscalls = wwWakeSyscalls

      if syscallCountAvailable():
        check waitDelta == 0'u64          # <-- SM-2, waiter side
        check wakeDelta == 0'u64          # <-- SM-2, waker side
        check ctlDelta >= uint64(Ctl)     # <-- the control fires
      else:
        echo "  [skip] in-process syscall counting unavailable; the SM-2 " &
          "assertions above are not being made on this platform"

      # The library's own accounting must AGREE with the kernel's. Two independent
      # counts disagreeing means one of them is lying, and it matters which.
      check fastWaits == uint64(N)
      check parks == 0'u64
      check fastWakes == uint64(N)
      check wakeSyscalls == uint64(Ctl)

      echo "  [SM-2] ", N, " fast-path waits -> ", waitDelta, " syscalls; ",
        N, " no-waiter wakes -> ", wakeDelta, " syscalls; control ",
        Ctl, " forced wakes -> ", ctlDelta, " syscalls"
      seg.detach()

  # ===========================================================================
  # 4 — spurious wakeups are tolerated (in-process; cross-process is the gate)
  # ===========================================================================

  type WaiterCtx = object
    seg: ptr WaitSegment
    slot: int
    lastSeen: uint32
    parks: int
    rc: WaitResult
    payload: uint64

  var gCtx: WaiterCtx

  proc waiterThread(p: pointer) {.thread.} =
    gCtx.rc = gCtx.seg[].awaitGrant(gCtx.slot, gCtx.lastSeen,
      timeoutNs = 10_000_000_000'i64, parks = addr gCtx.parks)
    gCtx.payload = gCtx.seg[].slotPayload(gCtx.slot)

  proc awaitWaiterParked(seg: var WaitSegment; slot: int;
      want: uint32 = 1): bool =
    ## Poll until the wait word records `want` parked waiters, bounded so a wedged
    ## run fails loudly instead of hanging. This is what makes the spurious-wake
    ## injection DETERMINISTIC: the wake is issued only once the waiter is
    ## provably inside the kernel, so "it re-parked" is a fact rather than a race.
    for _ in 0 ..< 5_000:
      if seg.slotWaiters(slot) == want: return true
      sleep(1)
    false

  suite "spurious wakeups are tolerated: the waiter re-validates":
    test "three injected spurious wakes cause three re-parks and no false grant":
      let path = freshPath("spurious")
      defer: cleanup(path)
      var seg = createWaitSegment(path, 4)
      check seg.available
      const Slot = 1
      const Spurious = 3
      const Payload = 0x5EC0_1DED_CAFE_0001'u64

      gCtx = WaiterCtx(seg: addr seg, slot: Slot, lastSeen: seg.slotValue(Slot))
      var th: Thread[pointer]
      createThread(th, waiterThread, nil)

      check awaitWaiterParked(seg, Slot)

      # INJECT: a wake with the value UNCHANGED is exactly a spurious wakeup, and
      # is what every one of these primitives is permitted to manufacture on its
      # own. The waiter must go back to sleep rather than report a grant.
      #
      # RETRY, DO NOT SLEEP-AND-HOPE. `waiters` becomes non-zero a few
      # instructions BEFORE the waiter is actually inside the kernel, so a wake
      # issued in that window is legitimately lost — which is exactly why the
      # waiter re-checks after registering, and exactly why the first version of
      # this test measured one park instead of four. So the injection counts only
      # wakes the waiter DEMONSTRABLY returned from (its own park counter moved),
      # and re-issues the wake otherwise. The bound turns a wedge into a failure
      # rather than a hang.
      var effective = 0
      var attempts = 0
      while effective < Spurious and attempts < 500:
        inc attempts
        let before = gCtx.parks
        check seg.slotPayload(Slot) == 0'u64      # still no grant published
        discard wakeRaw(seg.base, seg.slotOffset(Slot))
        for _ in 0 ..< 500:
          if gCtx.parks > before: break
          sleep(1)
        if gCtx.parks > before:
          inc effective
          check seg.slotPayload(Slot) == 0'u64    # it did NOT invent a grant
          check awaitWaiterParked(seg, Slot)      # it re-validated and re-parked
          sleep(2)
      check effective == Spurious

      # Now the real grant. Payload first, then the value bump with a release
      # store, so a waiter that sees the new value necessarily sees the payload.
      check seg.publishGrant(Slot, Payload) == wkWoke
      joinThread(th)

      check gCtx.rc == wrNotEqual                 # it observed the CHANGE
      check gCtx.payload == Payload               # ...and the right payload
      # Every park after the first was caused by a spurious wake it survived.
      check gCtx.parks >= Spurious + 1
      check seg.slotWaiters(Slot) == 0'u32        # the waiter deregistered
      echo "  [spurious] delivered=", effective, " (", attempts, " attempts)",
        " parks=", gCtx.parks, " result=", gCtx.rc
      seg.detach()

    test "a waiter that arrives AFTER the grant never parks at all":
      # The other half of the same property: the fast path is what makes
      # grant-then-wake cheap, because a late waiter costs one atomic load.
      let path = freshPath("late")
      defer: cleanup(path)
      var seg = createWaitSegment(path, 2)
      check seg.available
      let before = seg.slotValue(0)
      check seg.publishGrant(0, 42'u64) == wkNoWaiters   # nobody parked: no syscall
      resetWaitWordCounters()
      var parks = 0
      check seg.awaitGrant(0, before, parks = addr parks) == wrNotEqual
      check parks == 0
      check wwParks == 0'u64
      check seg.slotPayload(0) == 42'u64
      seg.detach()

  # ===========================================================================
  # 5 — the prefault hazard, exhibited rather than asserted
  # ===========================================================================

  when defined(macosx):
    suite "the prefault guard is load-bearing (macOS)":
      test "an untouched page fails the park; the same address works prefaulted":
        # `os_sync_wait_on_address` returns EFAULT for an address whose page this
        # process has not yet touched — even though the mapping is valid and an
        # ordinary load from it succeeds. That is precisely the state a forked
        # child is in, which is where M3 lives, so the guard in `waitOn` needs a
        # test that FAILS without it rather than a comment.
        #
        # The header validation on attach touches page 0, so the probe slot is
        # deliberately placed on a LATER page, which nothing has touched yet.
        let slotsPerPage = pageSize() div WaitSlotSize
        let slots = slotsPerPage * 2
        let probeSlot = slotsPerPage + 4
        let path = freshPath("prefault")
        defer: cleanup(path)
        var owner = createWaitSegment(path, slots)
        check owner.available
        check owner.size > pageSize()

        # The expected value is read through the OWNER's mapping, so neither probe
        # mapping below is touched by reading it. That isolation is the whole
        # point: any load through a probe mapping would fault its page in and the
        # test would then be measuring "something touched it" rather than
        # `prefaultWaitWord`.
        let off = owner.slotOffset(probeSlot)
        check off > pageSize()          # genuinely on a later page
        let expected = owner.slotValue(probeSlot)

        # PROBE A — nothing at all touches the probe page in this mapping.
        var probeA = attachWaitSegment(path)
        check probeA.available
        let bad = parkRaw(probeA.base, off, expected, timeoutNs = 200_000_000'i64)
        let badErrno = waitWordLastErrno
        check bad == wrError
        check badErrno == EFAULT
        probeA.detach()

        # PROBE B — a SECOND fresh mapping in which the ONLY access to the probe
        # page is `prefaultWaitWord`. The identical park now blocks and times out
        # cleanly, so the prefault is what made the difference and nothing else did.
        var probeB = attachWaitSegment(path)
        check probeB.available
        prefaultWaitWord(probeB.base, off)
        let t0 = epochTime()
        let good = parkRaw(probeB.base, off, expected, timeoutNs = 200_000_000'i64)
        let elapsed = epochTime() - t0
        check good == wrTimedOut
        check elapsed > 0.15          # it really slept rather than erroring out
        echo "  [prefault] untouched -> ", bad, " (errno ", badErrno,
          "); prefaulted -> ", good, " after ", int(elapsed * 1000), "ms"
        probeB.detach()
        owner.detach()

  # ===========================================================================
  # 6 — segment hygiene: the M2 playbook, applied to the new segment
  # ===========================================================================

  suite "wait segment hygiene":
    test "page-sized, offsets only, anchored, and rejected when stale":
      let path = freshPath("hygiene")
      defer: cleanup(path)
      var seg = createWaitSegment(path, 16)
      check seg.available
      # Sized with `sysconf(_SC_PAGESIZE)` rather than a hard-coded 4096 — the
      # assumption class that produced M2's MAP_FIXED stride bug and its
      # `:deferred:` (9) segment-geometry note.
      check seg.size mod pageSize() == 0
      check seg.size >= WaitSegHeaderSize + 16 * WaitSlotSize
      check seg.storedPointerCheck()
      check seg.ownerPid() == uint64(getpid())
      check seg.ownerVerdict() == avLive

      # Position independence: a second mapping at a DIFFERENT base reads the same
      # values, and a grant published through one is visible through the other.
      var other = attachWaitSegment(path)
      check other.available
      check other.mappedBase() != seg.mappedBase()
      check other.slotCount == seg.slotCount
      check other.storedPointerCheck()
      check seg.publishGrant(3, 0xABCD'u64) == wkNoWaiters
      check other.slotValue(3) == seg.slotValue(3)
      check other.slotPayload(3) == 0xABCD'u64
      other.detach()

      check attachWaitSegment(path & ".does-not-exist").available == false
      seg.detach()

    test "out-of-range slots are refused rather than addressed":
      let path = freshPath("range")
      defer: cleanup(path)
      var seg = createWaitSegment(path, 2)
      check seg.available
      check seg.publishGrant(-1, 1'u64) == wkUnavailable
      check seg.publishGrant(2, 1'u64) == wkUnavailable
      check seg.awaitGrant(2, 0'u32) == wrUnavailable
      check createWaitSegment(freshPath("zero"), 0).available == false
      check createWaitSegment(freshPath("huge"), MaxWaitSlots + 1).available == false
      seg.detach()

else:
  suite "portable no-op arm":
    test "every operation reports unavailable instead of failing to build":
      check not waitWordSupported
      check not waitWordAvailable()
      var seg = createWaitSegment("unused", 4)
      check not seg.available
      check seg.publishGrant(0, 1'u64) == wkUnavailable
      check seg.awaitGrant(0, 0'u32) == wrUnavailable
