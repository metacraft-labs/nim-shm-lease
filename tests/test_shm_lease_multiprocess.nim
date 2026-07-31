## THE M2 GATE — multi-process packed-budget reservation.
##
## `RunQuota-Observation-Store.milestones.org` ** M2 :gate:
##   "Multi-process test: N processes concurrently claim and release
##    multi-dimensional reservations (CPU slots, memory in coarse units, process
##    count, IO weight) against a shared packed budget. Asserts no overcommit ever
##    observed, no lost update, and total released == total claimed.
##    Position-independence asserted by mapping the segment at deliberately
##    different virtual bases (MAP_FIXED probe) in each process."
##   :proves: SM-7; partial SM-5
##
## MOCKS: none, and none are possible — the property under test is cross-process
## shared memory, so the test uses `fork`ed processes, a real file-backed
## `mmap(MAP_SHARED)` segment, and real `mmap` at real distinct addresses. Threads
## would not test this (they share one address space, which is exactly the thing
## SM-7 says must not be relied on).
##
## HOW EACH GATE CLAUSE IS PROVEN, and why each assertion could actually fail:
##
## 1. NO OVERCOMMIT EVER OBSERVED. Every process — all N children plus the parent,
##    each at its own virtual base — samples every budget word repeatedly and
##    asserts `remaining[d] <= capacity[d]` in every dimension. That single
##    comparison catches both directions of overcommit: a claim whose fit test was
##    wrong underflows a field to a huge value, and an over-release drives a field
##    past capacity. `PART 2` below runs the SAME harness with a deliberately
##    fit-check-free claim and asserts the sampler DOES report violations, so a
##    zero-violation result in PART 1 is a measurement and not an artefact of an
##    assertion that cannot fail.
##    Two anti-vacuity assertions guard against "no overcommit because nothing was
##    ever tight": total refusals must be non-zero (the fit test really did have to
##    refuse claims) and the observed minimum remaining CPU must be at most 1 (the
##    budget really was driven to near-exhaustion).
##
## 2. NO LOST UPDATE. Each child counts its OWN successful claims and releases and
##    reports them; the parent asserts the shared-memory counters equal the sums,
##    per budget word. Then the stronger, counter-independent check: each child
##    deliberately keeps one reservation it never releases, and the parent asserts
##    the budget's deficit (`capacity - remaining`) equals the EXACT sum of the
##    reservations still held. A single lost claim or lost release moves that
##    equality.
##
## 3. TOTAL RELEASED == TOTAL CLAIMED. The parent releases the still-held
##    reservations on the dead children's behalf and asserts `remaining` is restored
##    to `capacity` BIT-FOR-BIT on every word, that claims == releases on every
##    word, that claimed units == released units in every dimension, and that one
##    further release is REFUSED rather than fabricating capacity.
##
## 4. POSITION INDEPENDENCE (SM-7). The parent reserves one PROT_NONE region before
##    forking, so every child inherits it at the same address; child `i` then maps
##    the segment with `MAP_FIXED` at `region + i * segmentSize`. The bases are
##    therefore distinct BY CONSTRUCTION, not by luck — which matters, because two
##    forked children that both call `mmap(nil, ...)` would very likely land at the
##    SAME address and prove nothing. Every child reports the base it actually
##    mapped at, and the parent asserts all N+1 bases are pairwise distinct AND that
##    every operation above came out correct across them. Finally the parent remaps
##    the whole segment at yet another base and re-reads every value.
##
## PARTIAL SM-5 (crash-recoverable structure) is what this milestone can honestly
## claim: every mutation here is a single CAS on a single word, so no process can be
## interrupted "half way through" a mutation and no structure can be left
## inconsistent. What is NOT proven here — and is M7's job — is that a process which
## dies while HOLDING a reservation has that reservation reclaimed. This test
## demonstrates the opposite, deliberately: the children exit while holding
## reservations, and that capacity stays held until someone gives it back. That is
## the leak SM-6 describes, and it is left visible rather than papered over.

import std/[os, posix, strutils, unittest]
import shm_lease

# --- geometry ---------------------------------------------------------------

const
  NChildren = 6
  DefaultRounds = 20_000

  # One machine budget (word 0) + two pool budgets (words 1, 2). Sized so N=6
  # children genuinely collide: 8 CPU slots against claims of 1..3 each.
  MachineCap = vec(8, 64, 8, 100)      # 8 slots, 64 x 64MiB = 4 GiB, 8 procs, 100 io
  PoolCap = vec(5, 40, 5, 60)
  NPools = 2

  # The reservation each child takes and DELIBERATELY never releases, so the parent
  # can check the budget deficit against an exactly known sum.
  HeldVec = vec(1, 1, 1, 1)

  # Small budget for the negative control, so a fit-check-free claim underflows
  # almost immediately.
  BrokenMachineCap = vec(2, 4, 2, 4)
  BrokenPoolCap = vec(2, 4, 2, 4)
  BrokenRounds = 400

  ParentSampleBudget = 100_000
    ## The parent samples the invariant a FIXED number of times, not "until the
    ## children exit".
    ##
    ## The earlier unbounded spin-sample loop made the reported invariant-sample
    ## count a function of MACHINE LOAD rather than of the test: the same
    ## `SHM_LEASE_ROUND_FACTOR=25` soak produced 7.2M samples on one host state and
    ## 19.3M on another, while claims/refusals/retries matched closely. A figure that
    ## moves 2.7x with ambient load cannot be quoted as a measured property, so the
    ## parent's contribution is now a constant and the children's is an exact
    ## function of their round and claim counts (asserted below). The total is
    ## therefore derivable rather than observed.

type
  ChildReport = object
    ## Reported over a pipe, not through shared memory. Deliberately: a mapped base
    ## is an ADDRESS, and writing an address into the segment is exactly the SM-7
    ## violation under test.
    ok: uint64
    childId: uint64
    base: uint64
    pool: uint64
    claims: uint64
    releases: uint64
    refusals: uint64
    errors: uint64
    samples: uint64
    violations: uint64
    heldCount: uint64
    heldCpu: uint64
    heldMem: uint64
    heldProcs: uint64
    heldIo: uint64
    minCpu: uint64
    minMem: uint64
    minProcs: uint64
    minIo: uint64
    startNs: uint64          ## CLOCK_MONOTONIC, taken AFTER the start barrier releases
    endNs: uint64             ## CLOCK_MONOTONIC, taken after the last round
    roundsDone: uint64        ## >= the requested round count; the child keeps going
                              ## until the parent lifts the stop gate

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
proc quitChild(code: cint) {.noreturn.} =
  ## Leave without running Nim/atexit teardown, which could touch shared state the
  ## parent is still asserting over.
  cExit(code)

var tmpCounter = 0
proc freshPath(tag: string): string =
  inc tmpCounter
  getTempDir() / ("shmlease-mp-" & tag & "-" & $getpid() & "-" & $tmpCounter & ".seg")

proc cleanup(path: string) =
  try: removeFile(path)
  except CatchableError: discard

proc nowNs(): uint64 =
  ## CLOCK_MONOTONIC is comparable ACROSS PROCESSES on one host, which is what lets
  ## the parent prove the children's hammering windows actually overlapped.
  var ts: Timespec
  discard clock_gettime(CLOCK_MONOTONIC, ts)
  uint64(ts.tv_sec) * 1_000_000_000'u64 + uint64(ts.tv_nsec)

proc nextRand(s: var uint64): uint64 =
  s = s xor (s shl 13)
  s = s xor (s shr 7)
  s = s xor (s shl 17)
  s

proc roundsForRun(): int =
  ## `SHM_LEASE_ROUND_FACTOR` multiplies the per-child round count, so `just soak`
  ## reuses this exact harness for a longer bounded run instead of a second one.
  var factor = 1
  try:
    let raw = getEnv("SHM_LEASE_ROUND_FACTOR")
    if raw.len > 0: factor = max(1, parseInt(raw.strip()))
  except CatchableError: discard
  DefaultRounds * factor

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

proc setNonBlocking(fd: cint) =
  discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) or O_NONBLOCK)

proc stopSignalled(fd: cint): bool =
  ## Has the parent lifted the stop gate? The gate is a pipe whose only write end
  ## the parent holds: while it is open and empty a non-blocking read returns -1 /
  ## EAGAIN, and the moment the parent closes it every reader sees EOF (0). One
  ## `close` is therefore a broadcast, and no child can mistake "not yet" for "go".
  var b: byte
  read(fd, addr b, 1) == 0

# --- invariant sampling -----------------------------------------------------

proc sampleAll(l: var ShmLease; violations: var uint64; samples: var uint64;
    minVec: var ResourceVec) =
  ## Sample EVERY budget word for the no-overcommit invariant, and track the lowest
  ## remaining machine-budget vector this observer ever saw (the anti-vacuity
  ## evidence that the budget was genuinely driven towards exhaustion).
  for w in 0 ..< l.budgetCount:
    if not l.noOvercommit(w):
      inc violations
  inc samples
  let rem = l.remainingVec(MachineBudgetIndex)
  if rem.cpuSlots < minVec.cpuSlots: minVec.cpuSlots = rem.cpuSlots
  if rem.memUnits < minVec.memUnits: minVec.memUnits = rem.memUnits
  if rem.procs < minVec.procs: minVec.procs = rem.procs
  if rem.ioWeight < minVec.ioWeight: minVec.ioWeight = rem.ioWeight

# --- the deliberately BROKEN claim (negative control only) ------------------
#
# What a "just put the counters in shared memory" implementation looks like: a
# whole-word subtract with NO per-dimension fit test, in the same ascending word
# order, over the same raw CAS the real claim uses. It is defined here in the test
# rather than in `src/`, so the shipping API has no way to do this.

proc brokenClaim(l: var ShmLease; v: ResourceVec; pool: int) =
  let want = packVec(v)
  for w in [MachineBudgetIndex, poolBudgetIndex(pool)]:
    var cur = l.packedRemaining(w)
    while true:
      let desired = cur - want          # no fitsPacked: THIS is the injected defect
      if l.casPackedRemaining(w, cur, desired): break

proc brokenRelease(l: var ShmLease; v: ResourceVec; pool: int) =
  let give = packVec(v)
  for w in [poolBudgetIndex(pool), MachineBudgetIndex]:
    var cur = l.packedRemaining(w)
    while true:
      let desired = cur + give
      if l.casPackedRemaining(w, cur, desired): break

# --- the child --------------------------------------------------------------

proc childMain(childId: int; path: string; wantBase: pointer; rounds: int;
    pipeW: cint; readyW: cint; goR: cint; runningW: cint; stopR: cint;
    broken: bool) {.noreturn.} =
  var rep = ChildReport(childId: uint64(childId), base: cast[uint64](wantBase),
    pool: uint64(childId mod NPools),
    minCpu: uint64(DimMax), minMem: uint64(DimMax),
    minProcs: uint64(DimMax), minIo: uint64(DimMax))
  var minVec = vec(DimMax, DimMax, DimMax, DimMax)

  # Attach at the base the parent chose for THIS child, with MAP_FIXED over the
  # region the parent reserved before forking. Every child therefore observes the
  # same segment through a different virtual address.
  var l = attachLeaseSegment(path, wantBase)
  if not l.available:
    discard writeFull(pipeW, addr rep, sizeof(rep))
    quitChild(11)
  if cast[uint](l.mappedBase()) != cast[uint](wantBase):
    discard writeFull(pipeW, addr rep, sizeof(rep))
    quitChild(12)

  # --- START BARRIER + STOP GATE: what makes CONTENTION STRUCTURAL -----------
  #
  # Without any synchronisation, contention was incidental: forking and attaching
  # costs ~1 ms while a child's whole 20000-round loop costs less than that in a
  # release build, so the children could and did run END TO END SEQUENTIALLY. The
  # observed consequence was a gate whose CAS-retry count ranged from 135689 down to
  # ZERO across runs, making `retryCount > 0` a bet on scheduling (~4% failure over a
  # 60-run batch) rather than a statement about the design. That assertion is
  # load-bearing: without it, "0 overcommit violations" is also the expected result
  # of a gate in which no two claims ever raced, so it is what makes the headline
  # number mean anything.
  #
  # A start barrier ALONE is not enough, and measurement said so: releasing six
  # blocked readers on one `close` still spreads their wakeups over ~1 ms on a loaded
  # host, which is the same order as a child's entire run, so 23% of release runs
  # still contained a pair of children whose windows did not intersect. Timing cannot
  # be fixed with more timing.
  #
  # So there are two gates, and together they make simultaneity a FACT rather than a
  # probability:
  #   1. START BARRIER — announce "attached", then block until the parent has
  #      collected every child's announcement and closes the go pipe. No child begins
  #      before every child is attached.
  #   2. STOP GATE — after its first round, each child announces "I am inside the
  #      loop", and then NO child may leave the loop until the parent closes the stop
  #      pipe. The parent closes it only after receiving all N announcements.
  #      Therefore at the instant the parent has all N announcements, all N children
  #      are provably inside the hammering loop, and none can exit. That instant is
  #      recorded and asserted to lie inside every child's [startNs, endNs].
  # A hard `maxRounds` cap keeps the child terminating even if the parent dies.
  var one: byte = 1
  if not writeFull(readyW, addr one, 1):
    discard writeFull(pipeW, addr rep, sizeof(rep))
    quitChild(13)
  discard close(readyW)
  var goByte: byte
  discard read(goR, addr goByte, 1)     # returns 0 at EOF: the release signal
  discard close(goR)
  setNonBlocking(stopR)
  rep.startNs = nowNs()

  let myPool = int(rep.pool)
  let keepAt = (rounds * 3) div 4
  let maxRounds = rounds * 8
  var rng = 0x9E3779B97F4A7C15'u64 xor (uint64(childId) * 2654435761'u64 + 1'u64)
  var held = vec(0, 0, 0, 0)
  var stopped = false
  var round = -1

  while true:
    inc round
    sampleAll(l, rep.violations, rep.samples, minVec)

    let a = nextRand(rng)
    let v = vec(uint32(1 + (a mod 3)),
                uint32(2 + ((a shr 8) mod 19)),
                uint32(1 + ((a shr 16) mod 2)),
                uint32(5 + ((a shr 24) mod 21)))

    if broken:
      brokenClaim(l, v, myPool)
      inc rep.claims
      sampleAll(l, rep.violations, rep.samples, minVec)
      brokenRelease(l, v, myPool)
      inc rep.releases
    else:
      var r: Reservation
      case l.claim(v, r, poolIndex = myPool)
      of csGranted:
        inc rep.claims
        # Sample WHILE holding: this is the window in which an overcommit would be
        # visible if one were possible.
        sampleAll(l, rep.violations, rep.samples, minVec)
        if l.release(r):
          inc rep.releases
        else:
          inc rep.errors
      of csRefused:
        inc rep.refusals
      else:
        inc rep.errors

      # Take one reservation and NEVER release it, so the parent can check the
      # budget deficit against a sum it knows exactly.
      if round == keepAt and rep.heldCount == 0:
        var tries = 0
        while tries < 200_000:
          var hr: Reservation
          if l.claim(HeldVec, hr, poolIndex = myPool) == csGranted:
            inc rep.claims
            inc rep.heldCount
            held = held + HeldVec
            break
          inc tries
          discard sched_yield()

    # Announce "I am inside the loop" exactly once, after the first round. The
    # parent's stop gate stays shut until it has heard this from EVERY child.
    if round == 0:
      if not writeFull(runningW, addr one, 1):
        discard writeFull(pipeW, addr rep, sizeof(rep))
        quitChild(14)
      discard close(runningW)

    # Poll the stop gate cheaply (once every 64 rounds) while the requested rounds
    # remain, then on every round once they are done.
    if (round and 63) == 0 or round + 1 >= rounds:
      if stopSignalled(stopR): stopped = true
    if (round + 1 >= rounds and stopped) or round + 1 >= maxRounds:
      break

  discard close(stopR)
  rep.roundsDone = uint64(round + 1)
  sampleAll(l, rep.violations, rep.samples, minVec)
  rep.endNs = nowNs()
  rep.heldCpu = uint64(held.cpuSlots)
  rep.heldMem = uint64(held.memUnits)
  rep.heldProcs = uint64(held.procs)
  rep.heldIo = uint64(held.ioWeight)
  rep.minCpu = uint64(minVec.cpuSlots)
  rep.minMem = uint64(minVec.memUnits)
  rep.minProcs = uint64(minVec.procs)
  rep.minIo = uint64(minVec.ioWeight)
  rep.ok = 1
  if not writeFull(pipeW, addr rep, sizeof(rep)):
    quitChild(4)
  quitChild(0)

# --- the harness ------------------------------------------------------------

type RunResult = object
  reports: seq[ChildReport]
  parentBase: uint64
  parentViolations: uint64
  parentSamples: uint64
  parentMin: ResourceVec
  allRunningNs: uint64
    ## The instant at which the parent had heard "I am inside the loop" from EVERY
    ## child. Because the stop gate is still shut at that instant, no child can have
    ## left the loop — so all N were hammering simultaneously, and this timestamp is
    ## the witness. Asserted to lie inside every child's [startNs, endNs].

proc runHarness(l: var ShmLease; path: string; rounds: int;
    broken: bool): RunResult =
  ## Fork `NChildren` children, each mapping the segment at a DELIBERATELY
  ## DIFFERENT virtual base, and let them hammer the budget while the parent
  ## samples the invariant from its own base.
  let segSize = l.segmentSize()

  # MAP_FIXED requires a PAGE-ALIGNED address, and the page size is a HOST property:
  # 4 KiB on x86-64 Linux and Intel macOS, but 16 KiB on Apple Silicon. Striding the
  # probe bases by the segment size (4 KiB here) therefore produced a misaligned
  # base — and a silent `EINVAL` — for 5 of 7 children on macOS/arm64 while
  # "working" for the two whose index happened to be a multiple of 4. Reproduced on
  # Darwin 25.5 / arm64; ask the OS instead of assuming.
  let pageSize = int(sysconf(SC_PAGESIZE))
  doAssert pageSize > 0
  let stride = ((segSize + pageSize - 1) div pageSize) * pageSize

  # One reservation, made BEFORE the fork, so every child inherits it at the same
  # address and `region + i * stride` is guaranteed pairwise distinct. This is what
  # makes the differing bases deliberate rather than accidental.
  let regionSize = stride * (NChildren + 1)
  let region = mmap(nil, regionSize, PROT_NONE,
    MAP_PRIVATE or MAP_ANONYMOUS, cint(-1), 0)
  doAssert region != MAP_FAILED, "could not reserve the MAP_FIXED probe region"
  # The parent's own mapping must lie OUTSIDE the reserved region, so the parent is
  # a genuine (N+1)-th distinct base rather than an alias of some child's.
  doAssert cast[uint](l.mappedBase()) < cast[uint](region) or
    cast[uint](l.mappedBase()) >= cast[uint](region) + uint(regionSize),
    "the parent's mapping unexpectedly landed inside the probe region"

  var fds: array[0..1, cint]        # child reports -> parent
  var readyFds: array[0..1, cint]   # child "I have attached" -> parent
  var goFds: array[0..1, cint]      # parent broadcast release -> children
  var runningFds: array[0..1, cint] # child "I am inside the loop" -> parent
  var stopFds: array[0..1, cint]    # parent broadcast "you may leave" -> children
  doAssert pipe(fds) == 0
  doAssert pipe(readyFds) == 0
  doAssert pipe(goFds) == 0
  doAssert pipe(runningFds) == 0
  doAssert pipe(stopFds) == 0

  var pids: seq[Pid]
  for i in 0 ..< NChildren:
    let childBase = cast[pointer](cast[uint](region) + uint(i * stride))
    let pid = fork()
    if pid == 0:
      discard close(fds[0])
      discard close(readyFds[0])
      discard close(runningFds[0])
      discard close(goFds[1])       # the child must NOT hold a write end of a gate,
      discard close(stopFds[1])     # or it would never see EOF on the release
      childMain(i, path, childBase, rounds, fds[1], readyFds[1], goFds[0],
        runningFds[1], stopFds[0], broken)
    doAssert pid > 0
    pids.add pid
  discard close(fds[1])
  discard close(readyFds[1])
  discard close(runningFds[1])
  discard close(goFds[0])
  discard close(stopFds[0])

  # GATE 1 — wait for EVERY child to announce that it has attached, then release them
  # all with one `close`, which wakes every blocked reader on the same event.
  for i in 0 ..< NChildren:
    var b: byte
    doAssert readFull(readyFds[0], addr b, 1),
      "child " & $i & " never reached the start barrier"
  discard close(readyFds[0])
  discard close(goFds[1])           # BROADCAST: all children start hammering now

  # GATE 2 — wait until every child has announced that it is INSIDE the loop. The
  # stop gate is still shut, so no child can have left: at this instant all N are
  # provably hammering the same budget word at once. Record the witness timestamp.
  for i in 0 ..< NChildren:
    var b: byte
    doAssert readFull(runningFds[0], addr b, 1),
      "child " & $i & " never entered the hammering loop"
  discard close(runningFds[0])
  result.allRunningNs = nowNs()

  # Sample from the PARENT's mapping (a third distinct base), which is now genuinely
  # concurrent with all N children rather than possibly after some of them finished.
  # A FIXED budget, so the parent's contribution to the invariant-sample count is a
  # constant rather than a measure of how busy the machine was.
  result.parentBase = cast[uint64](l.mappedBase())
  result.parentMin = vec(DimMax, DimMax, DimMax, DimMax)
  for _ in 0 ..< ParentSampleBudget:
    sampleAll(l, result.parentViolations, result.parentSamples, result.parentMin)
  doAssert result.parentSamples == uint64(ParentSampleBudget)

  discard close(stopFds[1])         # BROADCAST: the children may now leave the loop

  # DRAIN THE REPORT PIPE BEFORE REAPING. Reaping first is a classic pipe deadlock
  # and it bit this harness: the parent sat in `waitpid` while children sat in
  # `write`, because N reports no longer fit the pipe's buffer once `ChildReport`
  # grew. Draining first removes the dependency on pipe capacity altogether rather
  # than staying just under whatever it happens to be — the previous ordering was
  # never correct, only lucky.
  for i in 0 ..< NChildren:
    var rep: ChildReport
    doAssert readFull(fds[0], addr rep, sizeof(rep)),
      "short read of child report " & $i
    result.reports.add rep
  discard close(fds[0])

  for k in 0 ..< pids.len:
    var st: cint
    doAssert waitpid(pids[k], st, 0) == pids[k]
    doAssert WIFEXITED(st) and WEXITSTATUS(st) == 0,
      "child " & $k & " did not exit cleanly (exited=" & $WIFEXITED(st) &
      " status=" & $WEXITSTATUS(st) & " signalled=" & $WIFSIGNALED(st) &
      " signal=" & $WTERMSIG(st) & ")"

  discard munmap(region, regionSize)

# ===========================================================================
# PART 1 — the gate.
# ===========================================================================

suite "M2 gate: N processes over one shared packed budget":
  test "no overcommit, no lost update, released == claimed, differing bases":
    let path = freshPath("gate")
    defer: cleanup(path)
    var caps = @[MachineCap]
    for p in 0 ..< NPools: caps.add PoolCap
    var l = createLeaseSegment(path, caps)
    check l.available
    check l.budgetCount == 1 + NPools

    let rounds = roundsForRun()
    let run = runHarness(l, path, rounds, broken = false)
    check run.reports.len == NChildren

    # --- every child actually ran -------------------------------------------
    var totalClaims, totalReleases, totalRefusals, totalErrors: uint64 = 0
    var totalSamples, totalViolations, totalHeldCount: uint64 = 0
    var heldAll = vec(0, 0, 0, 0)
    var heldByPool: array[NPools, ResourceVec]
    var claimsByPool, releasesByPool: array[NPools, uint64]
    var bases: seq[uint64] = @[run.parentBase]
    for rep in run.reports:
      check rep.ok == 1
      check rep.errors == 0
      check rep.claims > 0'u64
      check rep.samples > 0'u64
      totalClaims += rep.claims
      totalReleases += rep.releases
      totalRefusals += rep.refusals
      totalErrors += rep.errors
      totalSamples += rep.samples
      totalViolations += rep.violations
      totalHeldCount += rep.heldCount
      let held = vec(uint32(rep.heldCpu), uint32(rep.heldMem),
        uint32(rep.heldProcs), uint32(rep.heldIo))
      heldAll = heldAll + held
      heldByPool[int(rep.pool)] = heldByPool[int(rep.pool)] + held
      claimsByPool[int(rep.pool)] += rep.claims
      releasesByPool[int(rep.pool)] += rep.releases
      bases.add rep.base

    # --- 1. NO OVERCOMMIT EVER OBSERVED -------------------------------------
    # N+1 independent observers, each at its own virtual base, sampling every
    # budget word. See PART 2 for the proof this assertion can fail.
    check totalViolations == 0'u64
    check run.parentViolations == 0'u64
    check totalSamples + run.parentSamples > 0'u64
    check l.noOvercommitAnywhere()

    # --- the invariant-sample count is DERIVED, not observed -----------------
    # Each child samples once per round, once more per GRANTED claim while holding
    # it, and once at the end; a kept (never-released) claim is counted in `claims`
    # without its own sample. So the count is an exact function of the round and
    # claim counts. Asserting the identity does two things: it makes the reported
    # figure reproducible rather than load-dependent, and it catches a miscounted or
    # skipped sample, which would silently weaken the no-overcommit evidence.
    for rep in run.reports:
      check rep.roundsDone >= uint64(rounds)
      # ...and the hard `maxRounds` cap was NOT reached. A child that exits via the
      # cap left the loop without the parent's stop gate, which silently degrades
      # this run to start-barrier-only reliability — the configuration that was
      # measured to leave 23% of runs with a non-overlapping pair. The simultaneity
      # witness below is asserted independently of how a child exited, so a
      # cap-exit is not a vacuity path; but it IS a change of regime, and the point
      # of this assertion is that the gate says so instead of quietly carrying on.
      # (Measured: per-child rounds run ~20.7k-27.4k against a 160k cap, so the
      # margin is roughly 6-8x, not a tight fit.)
      check rep.roundsDone < uint64(rounds * 8)
      check rep.samples == rep.roundsDone + (rep.claims - rep.heldCount) + 1'u64
    check run.parentSamples == uint64(ParentSampleBudget)

    # --- anti-vacuity: the children's windows really did OVERLAP -------------
    # Checked BEFORE the retry assertion, because if either gate ever breaks this is
    # the assertion that says so — `retryCount == 0` is the symptom, serial execution
    # is the cause, and diagnosing it from the retry count alone wasted a run batch
    # already.
    #
    # `allRunningNs` is the instant the parent held all N "I am inside the loop"
    # announcements while the stop gate was still shut, so every child was inside its
    # loop then. Asserting that one instant lies within every child's window is a
    # DIRECT statement of simultaneity; the pairwise intersection below follows from
    # it, and is kept because it is the property being claimed.
    # CLOCK_MONOTONIC is comparable across processes on one host.
    for rep in run.reports:
      check rep.startNs <= run.allRunningNs
      check rep.endNs >= run.allRunningNs
    for i in 0 ..< run.reports.len:
      for j in (i + 1) ..< run.reports.len:
        let a = run.reports[i]
        let b = run.reports[j]
        check a.startNs < b.endNs
        check b.startNs < a.endNs

    # --- anti-vacuity: the budget really was contended ----------------------
    # Without these, "no overcommit" could just mean "nothing was ever tight".
    check totalRefusals > 0'u64          # the fit test genuinely had to refuse
    # CAS contention genuinely occurred. Load-bearing: without it, zero violations
    # is also the expected result of a gate where no two claims ever raced. It is
    # sound only because the start barrier above makes the overlap structural — this
    # assertion used to fail ~4% of the time in a release build, when the children
    # ran end to end sequentially.
    check l.retryCount(MachineBudgetIndex) > 0'u64
    var minCpuSeen = run.parentMin.cpuSlots
    for rep in run.reports:
      if uint32(rep.minCpu) < minCpuSeen: minCpuSeen = uint32(rep.minCpu)
    check minCpuSeen <= 1'u32            # driven to (near) exhaustion

    # --- 4. POSITION INDEPENDENCE (SM-7): the bases really do differ --------
    check bases.len == NChildren + 1
    for i in 0 ..< bases.len:
      for j in (i + 1) ..< bases.len:
        check bases[i] != bases[j]

    # --- 2. NO LOST UPDATE --------------------------------------------------
    # (a) shared counters == the sum of what each process believes it did.
    check l.claimCount(MachineBudgetIndex) == totalClaims
    check l.releaseCount(MachineBudgetIndex) == totalReleases
    for p in 0 ..< NPools:
      check l.claimCount(poolBudgetIndex(p)) == claimsByPool[p]
      check l.releaseCount(poolBudgetIndex(p)) == releasesByPool[p]
    check totalClaims - totalReleases == totalHeldCount

    # (b) the counter-independent check: the budget deficit is EXACTLY the sum of
    # the reservations the children still hold. A single dropped claim or dropped
    # release breaks this equality.
    check totalHeldCount > 0'u64         # the check is not vacuous
    var expectedHeld = vec(0, 0, 0, 0)
    for rep in run.reports:
      for _ in 0 ..< int(rep.heldCount): expectedHeld = expectedHeld + HeldVec
    check heldAll == expectedHeld
    check l.outstandingVec(MachineBudgetIndex) == heldAll
    check l.remainingVec(MachineBudgetIndex) == MachineCap - heldAll
    for p in 0 ..< NPools:
      check l.outstandingVec(poolBudgetIndex(p)) == heldByPool[p]

    # (c) and the same fact via the per-dimension unit accounting.
    for w in 0 ..< l.budgetCount:
      let deficit = l.capacityVec(w) - l.remainingVec(w)
      for d in LeaseDim:
        check l.claimedUnits(w, d) - l.releasedUnits(w, d) ==
          uint64(vecField(deficit, d))

    # --- 3. TOTAL RELEASED == TOTAL CLAIMED ---------------------------------
    # Give back, on the dead children's behalf, exactly what they still held.
    # (That this is necessary at all is SM-6's leak, which M7 owns; here it is the
    # mechanism that lets the conservation check be exact.)
    for rep in run.reports:
      for _ in 0 ..< int(rep.heldCount):
        check l.releaseVec(HeldVec, poolIndex = int(rep.pool))
    for w in 0 ..< l.budgetCount:
      check l.packedRemaining(w) == l.packedCapacity(w)   # bit-for-bit
      check l.claimCount(w) == l.releaseCount(w)
      for d in LeaseDim:
        check l.claimedUnits(w, d) == l.releasedUnits(w, d)
    check l.remainingVec(MachineBudgetIndex) == MachineCap
    # One more release must be REFUSED, not silently fabricate capacity.
    check not l.releaseVec(HeldVec, poolIndex = 0)
    check l.packedRemaining(MachineBudgetIndex) == l.packedCapacity(MachineBudgetIndex)

    # --- 4 (continued). every value re-reads correctly at yet another base ---
    check l.storedPointerCheck()
    let claims0 = l.claimCount(MachineBudgetIndex)
    let far = mmap(nil, l.segmentSize(), PROT_NONE,
      MAP_PRIVATE or MAP_ANONYMOUS, cint(-1), 0)
    check far != MAP_FAILED
    var view = attachLeaseSegment(path, far)
    check view.available
    check cast[uint](view.mappedBase()) == cast[uint](far)
    check cast[uint](view.mappedBase()) != cast[uint](l.mappedBase())
    check view.budgetCount == l.budgetCount
    check view.claimCount(MachineBudgetIndex) == claims0
    for w in 0 ..< view.budgetCount:
      check view.remainingVec(w) == l.remainingVec(w)
      check view.capacityVec(w) == l.capacityVec(w)
    check view.ownerPid() == uint64(getpid())
    check view.ownerVerdict() == avLive
    check view.storedPointerCheck()
    # And a claim issued through the far mapping is visible through the near one.
    var r: Reservation
    check view.claim(vec(1, 2, 1, 3), r, poolIndex = 1) == csGranted
    check l.remainingVec(MachineBudgetIndex) == MachineCap - vec(1, 2, 1, 3)
    check view.release(r)
    check l.packedRemaining(MachineBudgetIndex) == l.packedCapacity(MachineBudgetIndex)
    view.detach()

    # Overlap window: the span in which ALL children were provably hammering at once.
    # Signed, because a broken gate makes it negative and that must READ as negative
    # rather than wrap into a nonsense unsigned number.
    var latestStart = run.reports[0].startNs
    var earliestEnd = run.reports[0].endNs
    var totalRounds: uint64 = 0
    for rep in run.reports:
      if rep.startNs > latestStart: latestStart = rep.startNs
      if rep.endNs < earliestEnd: earliestEnd = rep.endNs
      totalRounds += rep.roundsDone
    let overlapUs = (int64(earliestEnd) - int64(latestStart)) div 1000
    echo "  [gate] children=", NChildren, " rounds/child>=", rounds,
      " (actual total ", totalRounds, ")",
      " claims=", totalClaims, " releases=", totalReleases,
      " refusals=", totalRefusals,
      " CAS retries(machine)=", l.retryCount(MachineBudgetIndex),
      " rollbacks(machine)=", l.rollbackCount(MachineBudgetIndex),
      " all-children-overlap=", overlapUs, "us",
      " invariant samples=", totalSamples + run.parentSamples,
      " (children ", totalSamples, " + parent ", run.parentSamples, " fixed)",
      " violations=", totalViolations + run.parentViolations,
      " min cpu remaining seen=", minCpuSeen
    l.detach()

# ===========================================================================
# PART 2 — the negative control: the SAME harness must FAIL without the fit test.
# ===========================================================================

suite "M2 gate has teeth: the same harness over a fit-check-free claim":
  test "a whole-word subtract with no per-dimension fit test IS caught":
    # `RunQuota-Observation-Store.milestones.org` * Introduction:
    #   "An invariant is proven only by a test that FAILS when the invariant is
    #    violated -- not by inspection."
    # So run the identical multi-process harness with the identical sampler, and
    # change exactly one thing: the claim skips `fitsPacked`. If the sampler then
    # reports zero violations, PART 1's zero means nothing.
    let path = freshPath("broken")
    defer: cleanup(path)
    var caps = @[BrokenMachineCap]
    for p in 0 ..< NPools: caps.add BrokenPoolCap
    var l = createLeaseSegment(path, caps)
    check l.available

    let run = runHarness(l, path, BrokenRounds, broken = true)
    var totalViolations: uint64 = 0
    var totalSamples: uint64 = 0
    for rep in run.reports:
      check rep.ok == 1
      totalViolations += rep.violations
      totalSamples += rep.samples
    totalViolations += run.parentViolations
    totalSamples += run.parentSamples

    check totalSamples > 0'u64
    check totalViolations > 0'u64       # <-- the detector fires, as it must
    echo "  [negative control] fit-check-free claim produced ", totalViolations,
      " observed overcommit violations over ", totalSamples, " samples"
    l.detach()
