## THE M3 GATE — cross-process blocking at DELIBERATELY DIFFERING virtual bases.
##
## `RunQuota-Observation-Store.milestones.org` ** M3 :gate:
##   "Cross-process wake test at DIFFERING virtual bases on Linux and macOS: a
##    waiter blocks, a second process wakes it, the waiter observes the grant.
##    Asserts (a) zero syscalls on the uncontended fast path via strace/dtrace
##    counting, (b) a blocked waiter consumes no measurable CPU over a multi-second
##    block, (c) spurious wakeups are tolerated (waiter re-validates). Portable
##    no-op arm compiles and reports unavailable elsewhere."
##   :proves: SM-1, SM-2
##
## MOCKS: none, and none are possible. The property under test is that a process
## blocked in the kernel is woken by a DIFFERENT process addressing the same shared
## word through a DIFFERENT virtual address. Threads would not test it (one address
## space is exactly the thing that must not be relied on), and a fake clock or a
## fake syscall counter would test the fake. So: real `fork`, real file-backed
## `mmap(MAP_SHARED)`, real `MAP_FIXED` at real distinct addresses, the kernel's own
## syscall counter, and the kernel's own `getrusage` CPU accounting.
##
## HOW EACH GATE CLAUSE IS PROVEN, AND WHAT MAKES EACH ASSERTION ABLE TO FAIL:
##
## PHASE A — CROSS-PROCESS WAKE AT DIFFERING BASES, WITH SPURIOUS WAKES INJECTED.
##   A child maps the segment with `MAP_FIXED` at a base the parent chose before
##   forking, blocks on its own wait word, and is woken by the parent writing and
##   waking through the parent's OWN, different, mapping. The bases are asserted to
##   differ, so this is simultaneously the SM-7 statement for the wait word and the
##   direct assertion of the keying rule the design depends on — Linux shared
##   futexes key on inode + offset rather than the virtual address, and macOS's
##   `OS_SYNC_*_SHARED` exists precisely to allow a wake from another process. The
##   parent first injects spurious wakes (a forced wake with the value UNCHANGED),
##   and the child must re-validate and go back to sleep rather than report a grant
##   that does not exist; the child's own park count, published through shared
##   memory, is what shows it did.
##
## PHASE B — SM-1, WITH A SPINNING NEGATIVE CONTROL. Two children block for the
##   same multi-second window at two different bases: one parks on the wait word,
##   the other BUSY-WAITS on it, which is the implementation the design spec
##   prohibits. Both report their own `getrusage` CPU. The parked waiter must be
##   under the CPU limit; the spinner must be OVER it. That second assertion is
##   what gives the first one teeth — a threshold nothing can fail is not a
##   measurement, and "spin-then-park implementations pass a latency benchmark and
##   fail this one" is the spec's own stated reason for gating SM-1 separately.
##
## PHASE C — SM-2 AT A DIFFERING BASE. The child measures the KERNEL's count of the
##   syscalls it made (`shm_lease/syscount`) across 200000 uncontended fast-path
##   waits and 200000 no-waiter wakes, and separately across a batch of forced
##   wakes. Zero, zero, and non-zero. Doing it in the child rather than only in the
##   unit test matters: it shows the fast path is still syscall-free at a
##   `MAP_FIXED` base, which is where a design that had accidentally become
##   address-dependent would break.
##
## PHASE D — THE SHARED SCOPE IS LOAD-BEARING. Two children park on two slots under
##   an identical schedule; one uses the cross-process scope and one the
##   process-local scope (`FUTEX_*_PRIVATE` / `OS_SYNC_WAIT_ON_ADDRESS_NONE`). The
##   parent publishes and wakes both with the cross-process scope. The shared waiter
##   must be woken promptly; the process-local waiter must NOT be — it must sit
##   until its own timeout. This is the campaign's "assert this rather than assuming
##   it": if the two behaved the same, the keying claim would be unfounded.
##
## PHASE E — position independence of the segment itself, in-process: remap at yet
##   another base, re-read every value, and audit for stored pointers.
##
## HARNESS SHAPE IS M2's, DELIBERATELY REUSED rather than re-derived (the
## milestone's :next_steps: says so). One `PROT_NONE` region reserved BEFORE the
## fork, so child `i` maps at `region + i * pageAlignedStride` and the bases are
## pairwise distinct BY CONSTRUCTION — two forked children both calling
## `mmap(nil, ...)` would very likely land at the SAME address and prove nothing
## about either differing-base blocking or the inode+offset keying rule. The stride
## is `sysconf(_SC_PAGESIZE)`-derived: `MAP_FIXED` needs a page-aligned address and
## the page size is a HOST property (16 KiB on Apple Silicon, 4 KiB elsewhere),
## which is the hazard M2 hit and M3's :notes: carried forward. A start barrier over
## a pipe releases every child with one `close`, and the report pipe is DRAINED
## BEFORE the children are reaped — reaping first is the pipe deadlock M2 found.

import std/[os, posix, strutils, unittest]
import shm_lease/[waitword, syscount]

# ---------------------------------------------------------------------------
# geometry and thresholds
# ---------------------------------------------------------------------------

const
  SlotCount = 8
    ## Per-waiter slots. The design spec requires each waiter to have its OWN wait
    ## word — a shared one reintroduces the thundering herd by construction — so
    ## the segment is an array from the start even though M3 parks at most two
    ## waiters at a time.
  ProgressSlot = SlotCount - 1
    ## A slot used as a one-way progress channel from child to parent: the child
    ## publishes its park count into it, and the parent reads it. Shared memory
    ## rather than a pipe, because the parent must read it WHILE the child is
    ## blocked, and a pipe read would be the parent blocking on the child it is
    ## trying to observe.

  SpuriousWakes = 3
  GrantPayloadA = 0xC0FFEE_0BAD_F00D'u64
  GrantPayloadD = 0x0D0D_0D0D_0D0D_0D0D'u64

  DefaultBlockSeconds = 3
  BlockedCpuLimitNs = 20_000_000'u64
    ## 20 ms of CPU over a multi-second block — i.e. under 1% of a single core.
    ##
    ## Chosen to be far above the measured cost of a park/unpark pair (hundreds of
    ## microseconds on this host, dominated by process start-up before the block
    ## even begins) and far below anything a spinning implementation could achieve.
    ## PHASE B asserts a spinner EXCEEDS this same limit, so the number is
    ## calibrated by both sides rather than picked to make one side pass.

  FastPathIterations = 200_000
  ForcedWakeControl = 200

  ProcLocalTimeoutNs = 1_500_000_000'i64
  ProcLocalPublishDelayMs = 300

type
  ChildRole = enum
    crBlockWaiter       ## parks on its wait word until granted
    crSpinWaiter        ## BUSY-WAITS on the same word — the prohibited design
    crScopeShared       ## parks with the cross-process scope
    crScopeProcessLocal ## parks with the process-local scope (negative control)
    crFastPath          ## measures the kernel's syscall count over the fast paths

  ChildReport = object
    ## Reported over a pipe, never through the segment: a mapped base is an
    ## ADDRESS, and writing an address into shared memory is precisely the position
    ## -independence violation this gate exists to rule out.
    ok: uint64
    childId: uint64
    role: uint32
    base: uint64
    slot: uint64
    waitRc: uint32
    parks: uint64
    spins: uint64
    payload: uint64
    wallNs: uint64
    cpuNs: uint64
    volCsw: uint64
    fastWaitSyscalls: uint64
    fastWakeSyscalls: uint64
    forcedWakeSyscalls: uint64
    lastErrno: int32

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
proc quitChild(code: cint) {.noreturn.} = cExit(code)

var tmpCounter = 0
proc freshPath(tag: string): string =
  inc tmpCounter
  getTempDir() / ("shmlease-m3-" & tag & "-" & $getpid() & "-" & $tmpCounter & ".seg")

proc cleanup(path: string) =
  try: removeFile(path)
  except CatchableError: discard

proc nowNs(): uint64 =
  var ts: Timespec
  discard clock_gettime(CLOCK_MONOTONIC, ts)
  uint64(ts.tv_sec) * 1_000_000_000'u64 + uint64(ts.tv_nsec)

proc selfCpuNs(): uint64 =
  ## This process's own CPU consumption, user + system, as the KERNEL accounts it.
  ## Self-reported by the child rather than derived from `RUSAGE_CHILDREN`, because
  ## the phases run several children at once and the aggregate would not say which
  ## one burned the core.
  var ru: Rusage
  if getrusage(RUSAGE_SELF, addr ru) != 0: return 0
  uint64(ru.ru_utime.tv_sec) * 1_000_000_000'u64 +
    uint64(ru.ru_utime.tv_usec) * 1_000'u64 +
    uint64(ru.ru_stime.tv_sec) * 1_000_000_000'u64 +
    uint64(ru.ru_stime.tv_usec) * 1_000'u64

proc selfVolCsw(): uint64 =
  var ru: Rusage
  if getrusage(RUSAGE_SELF, addr ru) != 0: return 0
  uint64(ru.ru_nvcsw)

proc blockSeconds(): int =
  var s = DefaultBlockSeconds
  try:
    let raw = getEnv("SHM_LEASE_BLOCK_SECONDS")
    if raw.len > 0: s = max(1, parseInt(raw.strip()))
  except CatchableError: discard
  s

proc writeFull(fd: cint; p: pointer; n: int): bool =
  var done = 0
  while done < n:
    let w = write(fd, cast[pointer](cast[uint](p) + uint(done)), n - done)
    if w <= 0: return false
    done += int(w)
  true

proc readFull(fd: cint; p: pointer; n: int): bool =
  var done = 0
  while done < n:
    let r = read(fd, cast[pointer](cast[uint](p) + uint(done)), n - done)
    if r <= 0: return false
    done += int(r)
  true

# ---------------------------------------------------------------------------
# the child
# ---------------------------------------------------------------------------

proc childMain(childId: int; role: ChildRole; slot: int; path: string;
    wantBase: pointer; readyW, goR, pipeW: cint; windowNs: int64) {.noreturn.} =
  var rep = ChildReport(childId: uint64(childId), role: uint32(ord(role)),
    base: cast[uint64](wantBase), slot: uint64(slot),
    waitRc: uint32(ord(wrUnavailable)))

  # Attach at the base the PARENT chose for this child, over the region it
  # reserved before forking. Every participant therefore observes the same segment
  # through a different virtual address.
  var seg = attachWaitSegment(path, wantBase)
  if not seg.available:
    discard writeFull(pipeW, addr rep, sizeof(rep)); quitChild(11)
  if cast[uint](seg.mappedBase()) != cast[uint](wantBase):
    discard writeFull(pipeW, addr rep, sizeof(rep)); quitChild(12)

  let off = seg.slotOffset(slot)
  # Fault the page in BEFORE announcing readiness. On macOS a park on a page this
  # process has not touched fails instantly with EFAULT, and a forked child with a
  # fresh MAP_FIXED mapping is exactly in that state — see `waitword`'s prefault
  # note. Doing it before the barrier also keeps the fault out of the measured
  # window.
  prefaultWaitWord(seg.base, off)
  let lastSeen = seg.slotValue(slot)

  # START BARRIER (M2's shape): announce "attached", then block until the parent
  # has every child's announcement and releases them all with one `close`.
  var one: byte = 1
  if not writeFull(readyW, addr one, 1):
    discard writeFull(pipeW, addr rep, sizeof(rep)); quitChild(13)
  discard close(readyW)
  var goByte: byte
  discard read(goR, addr goByte, 1)      # 0 at EOF: the broadcast release
  discard close(goR)

  let cpu0 = selfCpuNs()
  let csw0 = selfVolCsw()
  let t0 = nowNs()

  case role
  of crBlockWaiter:
    # The canonical waiter loop, written out rather than delegated to
    # `awaitGrant`, so the child can publish its park count into shared memory
    # after every kernel return — which is how the parent knows a spurious wake
    # was actually delivered instead of guessing with a sleep.
    var parks = 0
    var rc = wrNotEqual
    while true:
      if seg.slotValue(slot) != lastSeen: break
      rc = waitOn(seg.base, off, lastSeen, windowNs)
      if rc != wrNotEqual:
        inc parks
        discard seg.publishGrant(ProgressSlot, uint64(parks))
      if rc == wrTimedOut or rc == wrError or rc == wrUnavailable: break
    rep.parks = uint64(parks)
    rep.waitRc = uint32(ord(if seg.slotValue(slot) != lastSeen: wrNotEqual else: rc))
    rep.payload = seg.slotPayload(slot)

  of crSpinWaiter:
    # THE NEGATIVE CONTROL for SM-1: the prohibited implementation. It re-reads the
    # word in a tight loop instead of parking, which is what "a spinning waiter on
    # a CPU-saturated build host steals a core from the actions it waits for" means
    # concretely. The cap bounds the damage if the parent dies.
    var spins = 0'u64
    # The cap is on WALL TIME, not on iteration count. An iteration cap is a bug
    # waiting for a faster machine or a shorter window: at
    # SHM_LEASE_BLOCK_SECONDS=1 an earlier iteration-capped version bailed out
    # after 276 ms of a 1003 ms window and failed its own coverage assertion, while
    # passing at the 3 s default purely because the count happened to be large
    # enough. `clock_gettime(CLOCK_MONOTONIC)` is a commpage/vDSO read rather than
    # a syscall, and it is consulted once every 65536 spins, so it does not turn
    # the spinner into something other than a spinner.
    let capNs = uint64(windowNs)
    while seg.slotValue(slot) == lastSeen:
      inc spins
      if (spins and 0xFFFF'u64) == 0 and nowNs() - t0 > capNs: break
    rep.spins = spins
    rep.waitRc = uint32(ord(wrNotEqual))
    rep.payload = seg.slotPayload(slot)

  of crScopeShared, crScopeProcessLocal:
    let scope = if role == crScopeShared: wsShared else: wsProcessLocal
    var parks = 0
    let rc = seg.awaitGrant(slot, lastSeen, timeoutNs = windowNs, scope = scope,
      parks = addr parks)
    rep.parks = uint64(parks)
    rep.waitRc = uint32(ord(rc))
    rep.payload = seg.slotPayload(slot)
    rep.lastErrno = int32(waitWordLastErrno)

  of crFastPath:
    # SM-2, measured at a MAP_FIXED base in a real second process.
    resetWaitWordCounters()
    let cur = seg.slotValue(slot)
    let w0 = unixSyscallCount()
    for _ in 0 ..< FastPathIterations:
      discard waitOn(seg.base, off, cur + 1)          # already differs: fast path
    let w1 = unixSyscallCount()
    for _ in 0 ..< FastPathIterations:
      discard wakeAll(seg.base, off)                  # nobody parked: fast path
    let w2 = unixSyscallCount()
    for _ in 0 ..< ForcedWakeControl:
      discard wakeRaw(seg.base, off)                  # the control: always a syscall
    let w3 = unixSyscallCount()
    rep.fastWaitSyscalls = w1 - w0
    rep.fastWakeSyscalls = w2 - w1
    rep.forcedWakeSyscalls = w3 - w2
    rep.parks = wwParks
    rep.waitRc = uint32(ord(wrNotEqual))

  rep.wallNs = nowNs() - t0
  rep.cpuNs = selfCpuNs() - cpu0
  rep.volCsw = selfVolCsw() - csw0
  rep.ok = 1
  if not writeFull(pipeW, addr rep, sizeof(rep)): quitChild(4)
  quitChild(0)

# ---------------------------------------------------------------------------
# the harness
# ---------------------------------------------------------------------------

type Phase = object
  region: pointer
  regionSize: int
  pids: seq[Pid]
  reportR: cint
  nChildren: int

proc startPhase(seg: var WaitSegment; path: string; roles: openArray[ChildRole];
    slots: openArray[int]; windowNs: int64): Phase =
  ## Reserve one `PROT_NONE` region BEFORE forking, give child `i` the base
  ## `region + i * stride`, fork, and release every child with a single `close`
  ## once all of them have announced that they attached.
  doAssert roles.len == slots.len
  let n = roles.len
  # MAP_FIXED needs a PAGE-ALIGNED address and the page size is a HOST property —
  # 16 KiB on Apple Silicon, 4 KiB elsewhere. M2 strode by the segment size and got
  # a silent EINVAL for most children; ask, do not assume.
  let ps = pageSize()
  doAssert ps > 0
  let stride = ((seg.size + ps - 1) div ps) * ps
  result.regionSize = stride * (n + 1)
  result.region = mmap(nil, result.regionSize, PROT_NONE,
    MAP_PRIVATE or MAP_ANONYMOUS, cint(-1), 0)
  doAssert result.region != MAP_FAILED, "could not reserve the MAP_FIXED probe region"
  # The parent must be a genuine (n+1)-th distinct base, not an alias of a child's.
  doAssert cast[uint](seg.mappedBase()) < cast[uint](result.region) or
    cast[uint](seg.mappedBase()) >= cast[uint](result.region) + uint(result.regionSize),
    "the parent's mapping unexpectedly landed inside the probe region"
  result.nChildren = n

  var fds: array[0..1, cint]        # child reports -> parent
  var readyFds: array[0..1, cint]   # child "attached" -> parent
  var goFds: array[0..1, cint]      # parent broadcast release -> children
  doAssert pipe(fds) == 0
  doAssert pipe(readyFds) == 0
  doAssert pipe(goFds) == 0

  for i in 0 ..< n:
    let childBase = cast[pointer](cast[uint](result.region) + uint(i * stride))
    let pid = fork()
    if pid == 0:
      discard close(fds[0])
      discard close(readyFds[0])
      discard close(goFds[1])      # the child must not hold the gate's write end,
                                   # or it would never observe EOF on the release
      childMain(i, roles[i], slots[i], path, childBase, readyFds[1], goFds[0],
        fds[1], windowNs)
    doAssert pid > 0
    result.pids.add pid
  discard close(fds[1])
  discard close(readyFds[1])
  discard close(goFds[0])

  for i in 0 ..< n:
    var b: byte
    doAssert readFull(readyFds[0], addr b, 1),
      "child " & $i & " never reached the start barrier"
  discard close(readyFds[0])
  discard close(goFds[1])          # BROADCAST: every child starts now
  result.reportR = fds[0]

proc finishPhase(p: var Phase): seq[ChildReport] =
  ## DRAIN THE REPORT PIPE BEFORE REAPING. Reaping first is the classic pipe
  ## deadlock, and M2's harness hit it for real — the parent sat in `waitpid` while
  ## a child sat in `write`. Draining first removes the dependency on pipe capacity
  ## rather than staying just under whatever it happens to be.
  for i in 0 ..< p.nChildren:
    var rep: ChildReport
    doAssert readFull(p.reportR, addr rep, sizeof(rep)),
      "short read of child report " & $i
    result.add rep
  discard close(p.reportR)
  for k in 0 ..< p.pids.len:
    var st: cint
    doAssert waitpid(p.pids[k], st, 0) == p.pids[k]
    doAssert WIFEXITED(st) and WEXITSTATUS(st) == 0,
      "child " & $k & " did not exit cleanly (exited=" & $WIFEXITED(st) &
      " status=" & $WEXITSTATUS(st) & ")"
  discard munmap(p.region, p.regionSize)

proc awaitParked(seg: var WaitSegment; slot: int; want: uint32 = 1;
    budgetMs = 10_000): bool =
  ## Poll the wait word's waiter count from the PARENT's mapping until the child
  ## has registered. Cross-process visibility of that count is itself part of what
  ## makes the waker's fast path sound, so observing it here is not incidental.
  for _ in 0 ..< budgetMs:
    if seg.slotWaiters(slot) == want: return true
    sleep(1)
  false

proc awaitProgress(seg: var WaitSegment; atLeast: uint64; budgetMs = 5_000): bool =
  for _ in 0 ..< budgetMs:
    if seg.slotPayload(ProgressSlot) >= atLeast: return true
    sleep(1)
  false

# ===========================================================================

when not waitWordSupported:
  suite "M3 gate: portable no-op arm":
    test "the blocking primitive reports unavailable rather than failing to build":
      # Windows lands here by design: `WaitOnAddress` is within-process only, so
      # the cross-process wake path needs named kernel objects and is out of scope
      # for this campaign. The gap is recorded in the capability record.
      check not waitWordAvailable()
      check createWaitSegment("unused", 4).available == false

else:
 suite "M3 gate: cross-process blocking at differing virtual bases":

  test "A. a waiter blocks, another process wakes it, spurious wakes tolerated":
    let path = freshPath("wake")
    defer: cleanup(path)
    var seg = createWaitSegment(path, SlotCount)
    check seg.available
    check waitWordAvailable()
    const Slot = 0

    var ph = startPhase(seg, path, [crBlockWaiter], [Slot],
      windowNs = 20_000_000_000'i64)

    # The child is parked once the wait word records it. That the PARENT can see
    # this through its own mapping is the first cross-process fact of the test.
    let parked = awaitParked(seg, Slot)
    let waitersSeen = seg.slotWaiters(Slot)

    # INJECT SPURIOUS WAKEUPS: a wake issued with the value UNCHANGED. Every
    # primitive under this wrapper is permitted to manufacture exactly this event,
    # so the waiter must re-validate and go back to sleep. Delivery is CONFIRMED
    # rather than assumed — `waiters` becomes non-zero a few instructions before
    # the child is actually inside the kernel, so a wake issued in that window is
    # legitimately lost, and the loop re-issues instead of sleeping and hoping.
    var delivered = 0
    var attempts = 0
    while delivered < SpuriousWakes and attempts < 500:
      inc attempts
      check seg.slotPayload(Slot) == 0'u64          # no grant exists yet
      discard wakeRaw(seg.base, seg.slotOffset(Slot))
      if awaitProgress(seg, uint64(delivered + 1), budgetMs = 500):
        inc delivered
        check seg.slotPayload(Slot) == 0'u64        # ...and it invented none
        check awaitParked(seg, Slot)                # it re-validated and re-parked
        sleep(2)
    check delivered == SpuriousWakes

    sleep(150)
    # THE REAL GRANT, published and woken through the PARENT's mapping — a
    # different virtual address from the child's.
    check seg.publishGrant(Slot, GrantPayloadA) == wkWoke

    let reps = finishPhase(ph)
    check reps.len == 1
    let r = reps[0]

    check r.ok == 1
    check parked                                    # it really entered the kernel
    check waitersSeen == 1'u32
    # DIFFERING VIRTUAL BASES. This is the whole point: the wake was issued at the
    # parent's address and received at the child's, so the primitive cannot be
    # keyed on the virtual address. On Linux that is the inode+offset rule stated
    # in the design spec; on macOS it is what OS_SYNC_*_SHARED exists for.
    check r.base != cast[uint64](seg.mappedBase())
    check r.waitRc == uint32(ord(wrNotEqual))       # it observed the CHANGE
    check r.payload == GrantPayloadA                # ...and the right payload
    # Spurious wakes were survived: one park per delivered spurious wake, plus the
    # park the real grant ended.
    check r.parks >= uint64(SpuriousWakes) + 1
    check r.wallNs > 100_000_000'u64                # it genuinely waited
    check seg.slotWaiters(Slot) == 0'u32            # and deregistered

    echo "  [A] child base=0x", toHex(r.base), " parent base=0x",
      toHex(cast[uint64](seg.mappedBase())),
      " spurious delivered=", delivered, "/", attempts, " attempts",
      " parks=", r.parks, " wall=", r.wallNs div 1_000_000, "ms",
      " payload=0x", toHex(r.payload)
    seg.detach()

  test "B. SM-1: a blocked waiter burns no CPU; a spinning one fails the same limit":
    let path = freshPath("cpu")
    defer: cleanup(path)
    var seg = createWaitSegment(path, SlotCount)
    check seg.available
    const BlockSlot = 0
    const SpinSlot = 1
    let secs = blockSeconds()
    let windowNs = int64(secs) * 1_000_000_000'i64

    var ph = startPhase(seg, path, [crBlockWaiter, crSpinWaiter],
      [BlockSlot, SpinSlot], windowNs = windowNs * 4)

    check awaitParked(seg, BlockSlot)
    let t0 = nowNs()
    sleep(secs * 1000)
    let heldNs = nowNs() - t0
    check seg.publishGrant(BlockSlot, GrantPayloadA) == wkWoke
    # The spinner is not parked, so the wake fast-paths — which is itself the
    # honest picture: a spinning waiter needs no wake syscall because it never
    # stopped consuming the core.
    check seg.publishGrant(SpinSlot, GrantPayloadA) == wkNoWaiters

    let reps = finishPhase(ph)
    check reps.len == 2
    var blocked, spun: ChildReport
    for r in reps:
      if r.role == uint32(ord(crBlockWaiter)): blocked = r else: spun = r

    check blocked.ok == 1
    check spun.ok == 1
    check blocked.base != spun.base                       # differing bases again
    check blocked.base != cast[uint64](seg.mappedBase())
    check spun.base != cast[uint64](seg.mappedBase())

    # Both really did cover the window.
    check blocked.wallNs >= uint64(heldNs) * 9 div 10
    check spun.wallNs >= uint64(heldNs) * 9 div 10

    # --- SM-1 -------------------------------------------------------------
    check blocked.cpuNs < BlockedCpuLimitNs
    # --- and the control that gives the limit teeth ------------------------
    # The IDENTICAL assertion applied to the prohibited implementation must FAIL,
    # which is asserted here by requiring the spinner to exceed the limit. Without
    # this, `blocked.cpuNs < limit` could be passing because the limit is
    # unfalsifiable rather than because parking is cheap.
    check spun.cpuNs > BlockedCpuLimitNs
    check spun.cpuNs > blocked.cpuNs * 10
    check spun.cpuNs > spun.wallNs div 2       # it really did burn a core
    check spun.spins > 0'u64

    # The parked waiter entered the kernel exactly to sleep, and came back holding
    # its grant — no re-check loop, no herd.
    check blocked.parks >= 1'u64
    # Relative form of the same invariant, independent of the absolute limit: a
    # blocked waiter must consume under 1% of the wall time it was blocked for.
    check blocked.cpuNs * 100 < uint64(heldNs)
    # NOTE on `volCsw`: reported, NOT asserted. macOS leaves `ru_nvcsw` at zero on
    # this host (measured 0 for a waiter that demonstrably slept for three
    # seconds), so voluntary context switches are not a usable second signal here.
    # It is printed anyway because on Linux it is, and a future run there should
    # show a blocked waiter switching and a spinner not.

    echo "  [B] window=", heldNs div 1_000_000, "ms  BLOCKED cpu=",
      blocked.cpuNs div 1000, "us (", blocked.volCsw, " vol csw, ",
      blocked.parks, " parks)  SPINNING cpu=", spun.cpuNs div 1_000_000,
      "ms over ", spun.spins, " spins  ratio=",
      (if blocked.cpuNs == 0: "inf" else: $(spun.cpuNs div max(blocked.cpuNs, 1'u64))),
      "x  limit=", BlockedCpuLimitNs div 1_000_000, "ms"
    seg.detach()

  test "C. SM-2: the fast path costs zero syscalls in a second process too":
    let path = freshPath("sm2")
    defer: cleanup(path)
    var seg = createWaitSegment(path, SlotCount)
    check seg.available
    var ph = startPhase(seg, path, [crFastPath], [2], windowNs = 0)
    var reps = finishPhase(ph)
    check reps.len == 1
    let r = reps[0]
    check r.ok == 1
    check r.base != cast[uint64](seg.mappedBase())
    check r.parks == 0'u64

    if syscallCountAvailable():
      check r.fastWaitSyscalls == 0'u64                     # <-- SM-2, waiter side
      check r.fastWakeSyscalls == 0'u64                     # <-- SM-2, waker side
      check r.forcedWakeSyscalls >= uint64(ForcedWakeControl)  # <-- the control
      echo "  [C] at base 0x", toHex(r.base), ": ", FastPathIterations,
        " fast-path waits -> ", r.fastWaitSyscalls, " syscalls; ",
        FastPathIterations, " no-waiter wakes -> ", r.fastWakeSyscalls,
        " syscalls; control ", ForcedWakeControl, " forced wakes -> ",
        r.forcedWakeSyscalls, " syscalls"
    else:
      # Linux: there is no cheap in-process kernel syscall counter, so SM-2 is
      # measured from OUTSIDE with `just test-syscalls` (strace -c). Say so loudly
      # rather than let the phase pass while asserting nothing.
      echo "  [C] SKIPPED: no in-process kernel syscall counter on this platform. " &
        "SM-2 must be measured externally here — run `just test-syscalls`."
      check true
    seg.detach()

  test "D. the cross-process scope is load-bearing, not decorative":
    # `RunQuota-Observation-Store.milestones.org` ** M3: shared futexes key on
    # inode + offset rather than the virtual address — "assert this rather than
    # assuming it". The assertion is that the PROCESS-LOCAL variant, on the same
    # word in the same shared mapping under the same schedule, is NOT woken.
    let path = freshPath("scope")
    defer: cleanup(path)
    var seg = createWaitSegment(path, SlotCount)
    check seg.available
    const SharedSlot = 0
    const LocalSlot = 1

    var ph = startPhase(seg, path, [crScopeShared, crScopeProcessLocal],
      [SharedSlot, LocalSlot], windowNs = ProcLocalTimeoutNs)

    check awaitParked(seg, SharedSlot)
    check awaitParked(seg, LocalSlot)
    sleep(ProcLocalPublishDelayMs)
    # Both published and woken identically, with the CROSS-PROCESS scope.
    check seg.publishGrant(SharedSlot, GrantPayloadD) == wkWoke
    discard seg.publishGrant(LocalSlot, GrantPayloadD)

    let reps = finishPhase(ph)
    check reps.len == 2
    var sh, lo: ChildReport
    for r in reps:
      if r.role == uint32(ord(crScopeShared)): sh = r else: lo = r
    check sh.ok == 1
    check lo.ok == 1
    check sh.base != lo.base

    # The shared waiter was woken by the cross-process wake, promptly.
    check sh.waitRc == uint32(ord(wrNotEqual))
    check sh.payload == GrantPayloadD
    check sh.wallNs < uint64(ProcLocalTimeoutNs) * 8 div 10

    # The process-local waiter was NOT: it slept until its own timeout. If this
    # child came back early, the two scopes are not distinguishable and the keying
    # claim in the design spec would be unfounded.
    check lo.waitRc == uint32(ord(wrTimedOut))
    check lo.wallNs >= uint64(ProcLocalTimeoutNs) * 9 div 10

    echo "  [D] SHARED woken after ", sh.wallNs div 1_000_000, "ms (rc=",
      WaitResult(sh.waitRc), "); PROCESS-LOCAL not woken, timed out after ",
      lo.wallNs div 1_000_000, "ms (rc=", WaitResult(lo.waitRc), ")"
    seg.detach()

  test "E. position independence: the segment re-reads correctly at a third base":
    let path = freshPath("pos")
    defer: cleanup(path)
    var seg = createWaitSegment(path, SlotCount)
    check seg.available
    check seg.storedPointerCheck()
    check seg.publishGrant(4, 0x1234_5678'u64) == wkNoWaiters
    let v4 = seg.slotValue(4)

    let far = mmap(nil, seg.size, PROT_NONE,
      MAP_PRIVATE or MAP_ANONYMOUS, cint(-1), 0)
    check far != MAP_FAILED
    var view = attachWaitSegment(path, far)
    check view.available
    check cast[uint](view.mappedBase()) == cast[uint](far)
    check cast[uint](view.mappedBase()) != cast[uint](seg.mappedBase())
    check view.slotCount == seg.slotCount
    check view.slotValue(4) == v4
    check view.slotPayload(4) == 0x1234_5678'u64
    check view.storedPointerCheck()
    # A grant published through the far mapping is visible through the near one.
    check view.publishGrant(5, 0x9999'u64) == wkNoWaiters
    check seg.slotPayload(5) == 0x9999'u64
    view.detach()
    seg.detach()
