## **M8 — THE PREEMPTION STUDY.** How long a client holds the arbiter role, and
## what admission costs, under deliberate CPU oversubscription.
##
## ===========================================================================
## WHAT THIS IS, AND — MORE IMPORTANTLY — WHAT IT IS NOT
## ===========================================================================
##
## `RunQuota-Observation-Store.milestones.org` ** M8 asks for THREE configurations
## — the current socket daemon, shm flat-combining, and a hybrid — and a
## RECOMMENDATION over them. **THIS PROBE MEASURES EXACTLY ONE OF THE THREE**, the
## shm flat-combining arm, because the other two do not exist in this repo: the
## socket-daemon arm needs RunQuota's real daemon and the M1 baseline, both
## DEFERRED to the integration boundary by the campaign's own sequencing, and the
## hybrid was never built. Nothing printed here is the M8 verdict, and a reader who
## treats it as one is reading a third of a comparison as the whole of it.
##
## What it DOES settle is the specific risk the design flagged and never measured
## — `RunQuota-Shared-Memory-Transport.md` §"The residual objection: combiner
## preemption":
##
##   *"A build is definitionally CPU-oversubscribed, and a build client holding the
##   combiner role is a large, CPU-hungry process that the OS scheduler is entirely
##   willing to deschedule. ... If measurement shows preemption still dominates,
##   the correct fallback is a hybrid."*
##
## So this probe's output decides whether the hybrid is even a live question. That
## is a smaller claim than M8's and a better-supported one.
##
## ===========================================================================
## THE INSTRUMENT IS CALIBRATED BEFORE IT IS TRUSTED
## ===========================================================================
##
## This campaign has been bitten by uncalibrated measurement more than once (M2's
## unbounded invariant sampler, whose rate tracked machine load; M4's gate B, which
## conflated CPU and wall time). So `calibrate()` runs FIRST, every run, and prints
## its results whether or not anybody reads them:
##
##   1. **The syscall counter, against a known answer.** 1000 `getppid()` MUST move
##      it by exactly 1000 and 10^6 userspace iterations by exactly 0 — M4's
##      calibration, re-established here rather than cited, because a counter
##      nobody has shown to count proves nothing about the clocks below.
##   2. **`CLOCK_MONOTONIC`'s cost, syscall count and RESOLUTION.** Two of these
##      per combine round is the whole of the primary instrument, so its cost is
##      subtracted-from-nothing and simply reported, and its resolution is the
##      floor below which a held-role duration is not a measurement. Measured on
##      the reference host: ~13 ns/call, ZERO syscalls over 10^6, and a resolution
##      of 41 ns — a 24 MHz timebase. A round reported as 0 ns means "under one
##      tick", counted separately rather than averaged in.
##   3. **`CLOCK_THREAD_CPUTIME_ID`'s cost and syscall count**, and this one is the
##      reason the CPU arm is a SEPARATE BUILD: on the reference host it costs
##      ~110 ns and EXACTLY ONE SYSCALL PER CALL. Two of those inside the held-role
##      window would be measuring the instrument at the p50, so the wall-only build
##      is the primary distribution and the CPU build exists to attribute the TAIL,
##      where 220 ns of instrument against a multi-millisecond window is noise.
##   4. **CPU time and wall time are kept apart** — the lesson M4's gate B was
##      failed for. Held-role duration is WALL time on purpose (a descheduled
##      holder still holds the role); off-CPU time is wall MINUS thread CPU over
##      the same window; the load model is verified by a CPU-time ratio, never by
##      a wall-clock one.
##   5. **Many short measurements, not few long ones** — M4's other finding. Every
##      figure here is per-round or per-request, and the fixed-work load unit the
##      ambient probe uses is ~10 ms rather than seconds, so a single measurement
##      cannot straddle a DVFS transition or a P-to-E-core migration. That
##      migration is real and large on this class of host: the same 200M-iteration
##      loop measured 59.9 ms of CPU on a performance core and 113.4 ms on an
##      efficiency core, a 1.9x swing in CPU time for identical work.
##
## ===========================================================================
## THE LOAD MODEL, STATED SO IT CAN BE DISAGREED WITH
## ===========================================================================
##
## Oversubscription is injected as `multiplier * logicalCpus` load-generator
## PROCESSES. Each one runs a dependent-load pointer chase over a private 4 MiB
## buffer mixed with arithmetic: a pure register spinner would be an optimistic
## model, because a real build's compiler processes evict the arbiter's cache lines
## as well as competing for cores. It is still a model — it does not fork, does not
## allocate, does not do I/O, and does not have a build's bursty phase structure.
##
## THE REQUESTED LOAD IS NOT ASSUMED TO HAVE ARRIVED. The parent runs a fixed-work
## unit throughout every measured window and reports its WALL/CPU ratio, which is
## the oversubscription the run ACTUALLY experienced. The host's load average is
## printed alongside it and is deliberately not used as the load figure: this host
## runs GitHub runners and its load average does not fall to zero, so "idle" here
## means "nothing injected", not "quiet".
##
## THE ADMISSION RATE IS FAR ABOVE ANYTHING A BUILD PRODUCES, and that is the
## point of the number rather than a caveat — the same framing
## `probe_obs_contention` uses. RunQuota admits once per EXECUTION; this probe's
## clients re-request as fast as they are answered. So the role is contended orders
## of magnitude harder than a build contends it, which makes this an UPPER BOUND on
## the preemption exposure rather than an estimate of it.
##
## ===========================================================================
## RUNNING IT
## ===========================================================================
##
## `just preemption-study` builds all three arms (no timing / wall / wall+cpu) and
## runs the sweep in each. Knobs, all optional:
##
##   SHM_LEASE_PREEMPT_CLIENTS    arbiter client processes      (default 6)
##   SHM_LEASE_PREEMPT_SECONDS    measured window per rep       (default 3)
##   SHM_LEASE_PREEMPT_REPS       reps per load point           (default 3)
##   SHM_LEASE_PREEMPT_LOADS      oversubscription multipliers  (default 0,2,4,8)
##   SHM_LEASE_PREEMPT_STEAL_MS   override `stealAfterNs`       (default: library)
##
## READ THE VARIANCE, NEVER A SINGLE FIGURE. Every rep is printed, and each load
## point ends with the MIN..MAX across its reps. Several records in this campaign
## had to be corrected for false precision; quote the range.

import std/[bitops, monotimes, os, posix, strutils]
import shm_lease

const
  ProbeSupported = defined(linux) or defined(macosx)

when not ProbeSupported:
  echo "probe_preemption: unavailable on this platform (needs mmap(MAP_SHARED))"
else:

  const
    RoleTiming = defined(shmLeaseRoleTiming)
    RoleCpuTiming = defined(shmLeaseRoleCpuTiming)

    HistBuckets = 1024
      ## Log-linear histogram, 16 sub-buckets per octave: exact for 0..31 ns and
      ## never worse than 6.25% above that. Percentiles are reported at the
      ## bucket's LOWER bound, so every printed figure is a value the distribution
      ## actually reached or passed.
    SubBits = 4

    MaxClients = 32
    ParkNs = 2_000_000'i64
      ## Bounded park. The steal detector needs the caller to COME BACK, so a
      ## waiter never parks indefinitely. NOTE WHERE THIS SHOWS UP IN THE OUTPUT:
      ## it is the admission p99.9, which sits at ~2.5 ms in every configuration
      ## because it is this retry cadence and NOT the arbiter. An engine obeying
      ## SM-8 polls admission and would not have it at all.
    RequestDeadlineNs = 10_000_000_000'i64
    HoldSpins = 40
      ## How long a granted client holds capacity before releasing it.
    AmbientUnitIters = 3_000_000
      ## The parent's fixed-work unit, ~2.6 ms of CPU on the reference host:
      ## short enough that one unit cannot straddle a DVFS transition or a
      ## P-to-E-core migration and average two different machines together, long
      ## enough that the clock's cost is nothing against it.

    MachineCap = vec(8, 32, 8, 40)

  type
    Hist = object
      count: uint64
      total: uint64
      minV: uint64
      maxV: uint64
      b: array[HistBuckets, uint32]

    ChildReport = object
      ok: uint64
      childId: uint64
      errors: uint64
      requests: uint64
      granted: uint64
      refused: uint64
      timeouts: uint64
      startNs: int64
      endNs: int64
      syscalls: uint64        ## UNIX syscalls made during the window
      contextSwitches: uint64 ## task context switches during the window
      stats: ArbiterStats
      acquired: uint64        ## combine attempts that HELD the role
      committed: uint64
      fenced: uint64
      noWorkHeld: uint64      ## acquired, decided nothing, handed back
      subTick: uint64         ## held-role windows measured as 0 ns, i.e.
                              ## under one clock tick
      over100us: uint64
      over1ms: uint64
      over10ms: uint64
      offCpuOver1ms: uint64
      heldTailNs: uint64      ## SUM of the held-role windows >= 1 ms. With
                              ## `held.total` this answers the question the
                              ## percentiles cannot: what SHARE of all the
                              ## time the role spent held was spent in a
                              ## preempted window. "Preemption dominates" is a
                              ## claim about that share, not about a maximum.
      held: Hist
      admission: Hist
      offCpu: Hist
      heldCpu: Hist

    LoadPointResult = object
      p50, p90, p99, p999, pMax: uint64

  proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
  proc quitChild(code: cint) {.noreturn.} = cExit(code)
  proc getloadavg(a: ptr cdouble; n: cint): cint {.importc,
    header: "<stdlib.h>".}

  let ClockThreadCpuTimeId {.importc: "CLOCK_THREAD_CPUTIME_ID",
    header: "<time.h>".}: ClockId
    ## Always available TO THE PROBE, even in the arms where the LIBRARY was built
    ## without `-d:shmLeaseRoleCpuTiming`. The define gates the two clock reads
    ## INSIDE the held-role window, where their cost matters; the parent's ambient
    ## load probe runs outside every measured window and pays nothing anybody
    ## reads. So "what oversubscription did this run actually experience" is
    ## answered in EVERY arm rather than only in the expensive one — which matters,
    ## because a sweep whose load did not arrive is a sweep that measured nothing.

  proc nowNs(): int64 {.inline.} = getMonoTime().ticks
    ## THE SAME CLOCK THE ARBITER STAMPS `acquiredNs` WITH. Using a different one
    ## here would make admission latency and held-role duration incomparable, and
    ## the whole point is to read them against each other.

  proc threadCpuNs(): int64 =
    var ts: Timespec
    if clock_gettime(ClockThreadCpuTimeId, ts) != 0: return 0
    int64(ts.tv_sec) * 1_000_000_000'i64 + int64(ts.tv_nsec)

  # -------------------------------------------------------------------------
  # HISTOGRAM
  # -------------------------------------------------------------------------

  func bucketOf(v: uint64): int =
    if v < 32: return int(v)
    let oct = 63 - countLeadingZeroBits(v)
    let sub = int((v shr (oct - SubBits)) and 15)
    result = (oct - 3) * 16 + sub
    if result >= HistBuckets: result = HistBuckets - 1

  func bucketLow(b: int): uint64 =
    if b < 32: return uint64(b)
    let oct = b div 16 + 3
    let sub = b mod 16
    uint64(16 + sub) shl (oct - SubBits)

  proc add(h: var Hist; v: uint64) =
    if h.count == 0 or v < h.minV: h.minV = v
    if v > h.maxV: h.maxV = v
    inc h.count
    h.total += v
    inc h.b[bucketOf(v)]

  proc merge(dst: var Hist; src: Hist) =
    if src.count == 0: return
    if dst.count == 0 or src.minV < dst.minV: dst.minV = src.minV
    if src.maxV > dst.maxV: dst.maxV = src.maxV
    dst.count += src.count
    dst.total += src.total
    for i in 0 ..< HistBuckets: dst.b[i] += src.b[i]

  proc pct(h: Hist; p: float): uint64 =
    ## The LOWER bound of the bucket the rank lands in, so the figure is one the
    ## distribution really attained. Bucket width is 0 below 32 ns and <=6.25%
    ## above it; do not read more precision than that into it.
    if h.count == 0: return 0
    let target = uint64(float(h.count) * p)
    var cum = 0'u64
    for i in 0 ..< HistBuckets:
      cum += uint64(h.b[i])
      if cum > target: return bucketLow(i)
    h.maxV

  proc summary(h: Hist): LoadPointResult =
    LoadPointResult(p50: h.pct(0.50), p90: h.pct(0.90), p99: h.pct(0.99),
      p999: h.pct(0.999), pMax: h.maxV)

  proc fmtNs(v: uint64): string =
    if v < 1_000'u64: $v & "ns"
    elif v < 1_000_000'u64: formatFloat(float(v) / 1e3, ffDecimal, 2) & "us"
    elif v < 1_000_000_000'u64: formatFloat(float(v) / 1e6, ffDecimal, 2) & "ms"
    else: formatFloat(float(v) / 1e9, ffDecimal, 2) & "s"

  proc line(label: string; s: LoadPointResult; n: uint64): string =
    label & " n=" & $n &
      " p50=" & fmtNs(s.p50) & " p90=" & fmtNs(s.p90) &
      " p99=" & fmtNs(s.p99) & " p99.9=" & fmtNs(s.p999) &
      " max=" & fmtNs(s.pMax)

  # -------------------------------------------------------------------------
  # SMALL POSIX HELPERS (the shapes M2/M3/M5 already paid for)
  # -------------------------------------------------------------------------

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
    ## The parent holds the only write end: one `close` is a broadcast EOF that no
    ## reader can mistake for "not yet".
    var b: byte
    read(fd, addr b, 1) == 0

  proc envInt(name: string; dflt: int): int =
    result = dflt
    try:
      let raw = getEnv(name)
      if raw.len > 0: result = parseInt(raw.strip())
    except CatchableError: discard

  proc loadAvg1(): float =
    var a: array[3, cdouble]
    if getloadavg(addr a[0], 3) < 1: return -1.0
    float(a[0])

  proc wantFor(childId, req: int): ResourceVec =
    ## Deterministic per-(client, request), and spread so the packing has real
    ## choices: six clients asking these vectors cannot all be granted at once
    ## against `MachineCap`, so requests genuinely wait and admission latency is a
    ## measurement of the protocol rather than of an idle fast path.
    let c = uint32(childId)
    vec(1 + (c + uint32(req)) mod 3'u32,
        2 + (c * 3 + uint32(req) * 5) mod 11'u32,
        1,
        3 + (c * 2 + uint32(req)) mod 7'u32)

  # -------------------------------------------------------------------------
  # THE LOAD GENERATOR
  # -------------------------------------------------------------------------

  proc loadGenMain(stopR: cint; bufWords: int) {.noreturn.} =
    ## A dependent-load pointer chase over a private buffer, mixed with
    ## arithmetic. NOT a register spinner: a build's competing processes evict the
    ## arbiter's cache lines as well as taking its cores, and a load model that
    ## only takes cores flatters the thing under test.
    setNonBlocking(stopR)
    let buf = cast[ptr UncheckedArray[uint64]](alloc0(bufWords * 8))
    # A permutation-ish chain with a large stride, so each load depends on the
    # previous one and the prefetcher cannot hide it.
    let stride = 1021
    for i in 0 ..< bufWords:
      buf[i] = uint64((i + stride) mod bufWords)
    var idx = 0'u64
    var acc = 0'u64
    while true:
      for _ in 0 ..< 200_000:
        idx = buf[int(idx)]
        acc = acc xor (idx * 2654435761'u64)
        buf[int(idx)] = buf[int(idx)] xor (acc and 0'u64) # a store, value-neutral
      if stopSignalled(stopR): break
    if acc == 0xDEADBEEF'u64: discard write(2, cstring"x", 1)
    quitChild(0)

  # -------------------------------------------------------------------------
  # THE ARBITER CLIENT
  # -------------------------------------------------------------------------

  proc clientMain(childId: int; path: string; repPath: string; readyW: cint;
      goR: cint; stopR: cint; stealMs: int) {.noreturn.} =
    var rep = cast[ptr ChildReport](alloc0(sizeof(ChildReport)))
    rep.childId = uint64(childId)

    var l = attachLeaseSegment(path)
    if not l.available: quitChild(11)
    var c = l.arbiterClient(childId)
    if not c.registerSlot(childId): quitChild(12)
    if stealMs > 0: c.stealAfterNs = int64(stealMs) * 1_000_000'i64

    var one: byte = 1
    if not writeFull(readyW, addr one, 1): quitChild(13)
    discard close(readyW)
    var goByte: byte
    discard read(goR, addr goByte, 1)
    discard close(goR)
    setNonBlocking(stopR)

    var r: CombineRound
    var req = 0

    template noteRound(rr: CombineRound) =
      ## Record the held-role window IF this attempt held the role. `acquiredNs`
      ## is zero for every attempt that never won the CAS — `cbRoleBusy`,
      ## `cbLostRace`, and the two pre-acquisition `cbNoWork` screens — which is
      ## exactly the set that must NOT appear in a held-role distribution.
      when RoleTiming:
        if rr.acquiredNs != 0:
          inc rep.acquired
          case rr.status
          of cbCommitted: inc rep.committed
          of cbFenced: inc rep.fenced
          else: inc rep.noWorkHeld
          if rr.releasedNs != 0:
            let d = rr.releasedNs - rr.acquiredNs
            let du = if d < 0: 0'u64 else: uint64(d)
            if du == 0: inc rep.subTick
            rep.held.add du
            if du >= 100_000'u64: inc rep.over100us
            if du >= 1_000_000'u64:
              inc rep.over1ms
              rep.heldTailNs += du
            if du >= 10_000_000'u64: inc rep.over10ms
            when RoleCpuTiming:
              let cpu = rr.releasedCpuNs - rr.acquiredCpuNs
              let cpuU = if cpu < 0: 0'u64 else: uint64(cpu)
              rep.heldCpu.add cpuU
              # OFF-CPU TIME: wall minus thread CPU over the SAME window. This is
              # what turns "the tail is long" into "the tail is the holder not
              # running", and it is the only figure here that can say so.
              let off = if du > cpuU: du - cpuU else: 0'u64
              rep.offCpu.add off
              if off >= 1_000_000'u64: inc rep.offCpuOver1ms

    rep.startNs = nowNs()
    let sys0 = unixSyscallCount()
    let csw0 = contextSwitchCount()

    while true:
      if stopSignalled(stopR): break
      let want = wantFor(childId, req)
      inc req
      let tPub = nowNs()
      if c.publishRequest(want) != psPublished:
        inc rep.errors
        break
      inc rep.requests
      var answer = ansNone
      let deadline = tPub + RequestDeadlineNs
      while answer != ansGranted and answer != ansRefused:
        discard c.tryCombine(r)
        noteRound(r)
        if c.view.answerArrived(c.slot):
          answer = c.collectAnswer()
          break
        answer = c.awaitAnswer(ParkNs)
        if nowNs() > deadline:
          inc rep.timeouts
          break
      let tAns = nowNs()
      if answer == ansGranted:
        rep.admission.add uint64(max(0'i64, tAns - tPub))
        inc rep.granted
        for _ in 0 ..< HoldSpins: discard nowNs()
        if not c.releaseGrant(): inc rep.errors
        # A releaser combining is what delivers the freed capacity to the
        # waiters, so it is part of the workload rather than an extra.
        discard c.tryCombine(r)
        noteRound(r)
      elif answer == ansRefused:
        rep.admission.add uint64(max(0'i64, tAns - tPub))
        inc rep.refused
        inc rep.errors # every want here fits an idle machine
      else:
        # Timed out with the request still on the board. Drain it, or the next
        # `publishRequest` fails `psNotIdle` and the run ends early.
        let drainDeadline = nowNs() + RequestDeadlineNs
        while nowNs() < drainDeadline:
          discard c.tryCombine(r)
          noteRound(r)
          if c.view.answerArrived(c.slot):
            if c.collectAnswer() == ansGranted: discard c.releaseGrant()
            break
          discard c.awaitAnswer(ParkNs)

    rep.endNs = nowNs()
    rep.syscalls = unixSyscallCount() - sys0
    rep.contextSwitches = contextSwitchCount() - csw0
    rep.stats = c.stats
    rep.ok = 1
    let fd = open(repPath.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o600)
    if fd < 0: quitChild(14)
    if not writeFull(fd, rep, sizeof(ChildReport)): quitChild(15)
    discard close(fd)
    quitChild(0)

  # -------------------------------------------------------------------------
  # CALIBRATION
  # -------------------------------------------------------------------------

  proc ambientUnit(): (int64, int64) =
    ## One fixed-work unit, timed in BOTH clocks. Returns (wallNs, cpuNs). Kept
    ## near 10 ms deliberately: long enough that 13 ns of clock is nothing, short
    ## enough that one unit cannot straddle a frequency change or a core
    ## migration and average two different machines together.
    var acc = 0'u64
    let c0 = threadCpuNs()
    let w0 = nowNs()
    for i in 0 ..< AmbientUnitIters:
      acc = acc xor (uint64(i) * 2654435761'u64)
      acc = acc + (acc shr 13)
    let w1 = nowNs()
    let c1 = threadCpuNs()
    if acc == 12345'u64: echo "" # keep the loop
    (w1 - w0, c1 - c0)

  proc monoResolutionNs(): int64 =
    ## The smallest NONZERO step `CLOCK_MONOTONIC` takes. Below this a held-role
    ## duration is not a small number, it is an unresolved one — which is why the
    ## probe counts sub-tick rounds separately instead of averaging them in.
    result = high(int64)
    var prev = nowNs()
    for _ in 0 ..< 200_000:
      let n = nowNs()
      if n > prev:
        let d = n - prev
        if d < result: result = d
      prev = n
    if result == high(int64): result = 0

  proc cpuResolutionNs(): int64 =
    result = high(int64)
    var prev = threadCpuNs()
    for _ in 0 ..< 20_000:
      let n = threadCpuNs()
      if n > prev:
        let d = n - prev
        if d < result: result = d
      prev = n
    if result == high(int64): result = 0

  proc calibrate() =
    echo "--- calibration (the instrument, before anything is measured with it) ---"
    echo "  timing arm compiled in: ",
      (if RoleCpuTiming: "wall + thread-CPU" elif RoleTiming: "wall only"
        else: "NONE (control build: no held-role distribution)")
    if not syscallCountAvailable():
      echo "  syscall counter: UNAVAILABLE on this platform — the syscall-freedom",
        " claims below are NOT established here"
    else:
      var s0 = unixSyscallCount()
      for _ in 0 ..< 1000: discard getppid()
      let dGetppid = unixSyscallCount() - s0
      var acc = 0'u64
      s0 = unixSyscallCount()
      for i in 0 ..< 1_000_000: acc = acc xor uint64(i)
      let dUser = unixSyscallCount() - s0
      echo "  syscall counter: 1000 getppid -> ", dGetppid,
        " (want exactly 1000); 1e6 userspace -> ", dUser, " (want exactly 0)",
        (if dGetppid == 1000 and dUser == 0: "  [CALIBRATED]"
          else: "  [*** NOT CALIBRATED — distrust every syscall figure below ***]")
      if acc == 1'u64: echo ""

    block:
      const N = 1_000_000
      let s0 = unixSyscallCount()
      let t0 = nowNs()
      var sink = 0'i64
      for _ in 0 ..< N: sink = sink xor nowNs()
      let t1 = nowNs()
      let ds = unixSyscallCount() - s0
      echo "  CLOCK_MONOTONIC: ", formatFloat(float(t1 - t0) / float(N),
        ffDecimal, 2), " ns/call, ", ds, " syscalls over ", N,
        ", resolution ", monoResolutionNs(), " ns",
        (if ds == 0: "  [free — safe inside the held-role window]"
          else: "  [*** COSTS SYSCALLS — the primary instrument perturbs ***]")
      if sink == 1'i64: echo ""

    block:
      const N = 200_000
      let s0 = unixSyscallCount()
      let t0 = nowNs()
      var sink = 0'i64
      for _ in 0 ..< N: sink = sink xor threadCpuNs()
      let t1 = nowNs()
      let ds = unixSyscallCount() - s0
      echo "  CLOCK_THREAD_CPUTIME_ID: ",
        formatFloat(float(t1 - t0) / float(N), ffDecimal, 2), " ns/call, ",
        ds, " syscalls over ", N, ", resolution ", cpuResolutionNs(), " ns"
      echo "    ^ THIS is why the CPU arm is a SEPARATE BUILD: at one syscall per",
        " call, two of them inside a 2.5 us held-role window would be measuring",
        " the clock. The wall-only arm is the primary distribution; the CPU arm",
        " attributes the TAIL, where this cost is noise."
      if sink == 1'i64: echo ""

    block:
      let t0 = nowNs()
      var cs = 0'u64
      for _ in 0 ..< 20_000: cs = cs xor contextSwitchCount()
      let t1 = nowNs()
      echo "  task context-switch counter: ",
        formatFloat(float(t1 - t0) / 20_000.0, ffDecimal, 2),
        " ns/call — WINDOW granularity only, never per round"
      if cs == 1'u64: echo ""

    block:
      var wMin = high(int64)
      var wMax = 0'i64
      var cMin = high(int64)
      var cMax = 0'i64
      for _ in 0 ..< 8:
        let (w, c) = ambientUnit()
        wMin = min(wMin, w); wMax = max(wMax, w)
        cMin = min(cMin, c); cMax = max(cMax, c)
      echo "  fixed-work unit (", AmbientUnitIters, " iters), 8 samples: wall ",
        fmtNs(uint64(wMin)), "..", fmtNs(uint64(wMax)), "  cpu ",
        fmtNs(uint64(cMin)), "..", fmtNs(uint64(cMax))
      echo "    ^ the CPU spread at ZERO injected load is this host's noise floor",
        " — P-core/E-core placement alone moves identical work ~2x, so a CPU-time",
        " figure that moved by that much moved for placement, not for load."

  # -------------------------------------------------------------------------
  # ONE MEASURED WINDOW
  # -------------------------------------------------------------------------

  type RunResult = object
    reports: seq[ChildReport]
    heldAll: Hist
    admissionAll: Hist
    offCpuAll: Hist
    ambientWallNs: int64
    ambientCpuNs: int64
    ambientUnits: int
    loadBefore: float
    loadAfter: float
    reclaimPasses: int
    reclaimed: int
    liveSkipped: int
    graceSkipped: int
    windowNs: int64

  proc runWindow(path: string; clients: int; loadProcs: int; windowNs: int64;
      stealMs: int): RunResult =
    var l = createLeaseSegment(path, [MachineCap], requestSlots = clients)
    doAssert l.available, "could not create the lease segment"
    defer:
      l.detach()
      try: removeFile(path)
      except CatchableError: discard

    result.loadBefore = loadAvg1()

    var readyFds, goFds, stopFds, loadStopFds: array[0..1, cint]
    doAssert pipe(readyFds) == 0
    doAssert pipe(goFds) == 0
    doAssert pipe(stopFds) == 0
    doAssert pipe(loadStopFds) == 0

    # LOAD FIRST, and given time to reach steady state before the clients start:
    # a generator still faulting in its buffer is not yet load.
    var loadPids: seq[Pid]
    for _ in 0 ..< loadProcs:
      let pid = fork()
      if pid == 0:
        discard close(loadStopFds[1])
        discard close(readyFds[0]); discard close(readyFds[1])
        discard close(goFds[0]); discard close(goFds[1])
        discard close(stopFds[0]); discard close(stopFds[1])
        loadGenMain(loadStopFds[0], 512 * 1024)
      doAssert pid > 0
      loadPids.add pid
    if loadProcs > 0: sleep(400)

    var pids: seq[Pid]
    for i in 0 ..< clients:
      let pid = fork()
      if pid == 0:
        discard close(readyFds[0])
        discard close(goFds[1])
        discard close(stopFds[1])
        discard close(loadStopFds[0]); discard close(loadStopFds[1])
        clientMain(i, path, path & ".rep." & $i, readyFds[1], goFds[0],
          stopFds[0], stealMs)
      doAssert pid > 0
      pids.add pid
    discard close(readyFds[1])
    discard close(goFds[0])
    discard close(stopFds[0])

    # START GATE: nobody begins before everybody has attached, so the contention
    # is structural rather than a function of fork latency (M2's lesson, reused
    # rather than re-derived).
    for i in 0 ..< clients:
      var b: byte
      doAssert readFull(readyFds[0], addr b, 1),
        "client " & $i & " never reached the start barrier"
    discard close(readyFds[0])
    let t0 = nowNs()
    discard close(goFds[1]) # BROADCAST: begin

    # The parent is otherwise idle during the window, so it does the two jobs
    # that must not run inside a client: the ambient load probe, and the
    # reclamation sweep (which costs ~3 syscalls per occupied slot and MUST NOT
    # be called from inside a combine round).
    let v = l.arbiterView()
    var rc = newReclaimer(v)
    var nextReclaim = t0 + 50_000_000'i64
    while nowNs() - t0 < windowNs:
      let (w, cpu) = ambientUnit()
      result.ambientWallNs += w
      result.ambientCpuNs += cpu
      inc result.ambientUnits
      if nowNs() >= nextReclaim:
        let rep = rc.reclaimPass()
        inc result.reclaimPasses
        result.reclaimed += rep.reclaimed
        result.liveSkipped += rep.live
        result.graceSkipped += rep.grace
        nextReclaim = nowNs() + 50_000_000'i64
    result.windowNs = nowNs() - t0
    discard close(stopFds[1]) # BROADCAST: stop
    result.loadAfter = loadAvg1()

    for k in 0 ..< pids.len:
      var st: cint
      doAssert waitpid(pids[k], st, 0) == pids[k]
      doAssert WIFEXITED(st) and WEXITSTATUS(st) == 0,
        "client " & $k & " did not exit cleanly (status " & $WEXITSTATUS(st) & ")"
    discard close(loadStopFds[1])
    for k in 0 ..< loadPids.len:
      var st: cint
      doAssert waitpid(loadPids[k], st, 0) == loadPids[k]

    for i in 0 ..< clients:
      let rp = path & ".rep." & $i
      let fd = open(rp.cstring, O_RDONLY)
      doAssert fd >= 0, "client " & $i & " left no report at " & rp
      var rep = cast[ptr ChildReport](alloc0(sizeof(ChildReport)))
      doAssert readFull(fd, rep, sizeof(ChildReport)), "short report read"
      discard close(fd)
      discard unlink(rp.cstring)
      result.heldAll.merge rep.held
      result.admissionAll.merge rep.admission
      result.offCpuAll.merge rep.offCpu
      result.reports.add rep[]
      dealloc(rep)

  # -------------------------------------------------------------------------
  # DRIVER
  # -------------------------------------------------------------------------

  proc totals(rr: RunResult): tuple[requests, granted, timeouts, errors,
      acquired, committed, fenced, subTick, over100us, over1ms, over10ms,
      offCpuOver1ms, heldTailNs, steals, anchorSteals, anchorProbes, busy, lost,
      parks, fastAnswers, wakes, wakeSyscalls, csw, syscalls: uint64] =
    for rep in rr.reports:
      result.requests += rep.requests
      result.granted += rep.granted
      result.timeouts += rep.timeouts
      result.errors += rep.errors
      result.acquired += rep.acquired
      result.committed += rep.committed
      result.fenced += rep.fenced
      result.subTick += rep.subTick
      result.over100us += rep.over100us
      result.over1ms += rep.over1ms
      result.over10ms += rep.over10ms
      result.offCpuOver1ms += rep.offCpuOver1ms
      result.heldTailNs += rep.heldTailNs
      result.steals += rep.stats.steals
      result.anchorSteals += rep.stats.anchorSteals
      result.anchorProbes += rep.stats.anchorProbes
      result.busy += rep.stats.roundsBusy
      result.lost += rep.stats.roundsLost
      result.parks += rep.stats.parks
      result.fastAnswers += rep.stats.fastAnswers
      result.wakes += rep.stats.wakeCalls
      result.wakeSyscalls += rep.stats.wakeSyscalls
      result.csw += rep.contextSwitches
      result.syscalls += rep.syscalls

  proc main() =
    let clients = min(MaxClients, max(2, envInt("SHM_LEASE_PREEMPT_CLIENTS", 6)))
    let seconds = max(1, envInt("SHM_LEASE_PREEMPT_SECONDS", 3))
    let reps = max(1, envInt("SHM_LEASE_PREEMPT_REPS", 3))
    let stealMs = envInt("SHM_LEASE_PREEMPT_STEAL_MS", 0)
    var loads: seq[int]
    let rawLoads = getEnv("SHM_LEASE_PREEMPT_LOADS")
    if rawLoads.len > 0:
      for part in rawLoads.split(','):
        try: loads.add parseInt(part.strip())
        except CatchableError: discard
    if loads.len == 0: loads = @[0, 2, 4, 8]

    let ncpu = int(sysconf(SC_NPROCESSORS_ONLN))
    echo "=== nim-shm-lease M8 preemption study — the SHM ARM ONLY ==="
    echo "  NOT the M8 verdict: the socket-daemon arm (needs M1) and the hybrid",
      " arm (never built) are ABSENT."
    echo "  logical cpus: ", ncpu, "   clients: ", clients,
      "   window: ", seconds, "s   reps: ", reps,
      "   loads: ", loads.join(","), "x",
      (if stealMs > 0: "   stealAfterNs override: " & $stealMs & "ms" else: "")
    echo "  host load average now: ", formatFloat(loadAvg1(), ffDecimal, 2),
      "  (this host runs CI; 'idle' below means NOTHING INJECTED, not quiet)"
    echo ""
    calibrate()
    echo ""

    for mult in loads:
      let loadProcs = mult * ncpu
      echo "--- oversubscription ", mult, "x  (", loadProcs,
        " injected load processes + ", clients, " clients on ", ncpu, " cpus) ---"
      var heldReps: seq[LoadPointResult]
      var admReps: seq[LoadPointResult]
      var ratioReps: seq[float]
      for rep in 0 ..< reps:
        let path = getTempDir() / ("shmlease-m8-" & $getpid() & "-" & $mult &
          "-" & $rep & ".seg")
        let rr = runWindow(path, clients, loadProcs, int64(seconds) *
            1_000_000_000'i64,
          stealMs)
        let t = totals(rr)
        # THE LOAD THE RUN ACTUALLY EXPERIENCED, not the load it asked for. A
        # fixed-work unit that took 4x its CPU time in wall time waited behind
        # three other runnable threads for every one it ran; that ratio is the
        # oversubscription, and the requested multiplier is only a request.
        let ratio =
          if rr.ambientCpuNs > 0:
            float(rr.ambientWallNs) / float(rr.ambientCpuNs)
          else: 0.0
        ratioReps.add ratio
        echo "  [rep ", rep, "] loadavg ",
          formatFloat(rr.loadBefore, ffDecimal, 1), " -> ",
          formatFloat(rr.loadAfter, ffDecimal, 1),
          "   MEASURED oversubscription (fixed-work wall/cpu) ",
          formatFloat(ratio, ffDecimal, 2), "x over ", rr.ambientUnits,
          " units, mean cpu/unit ",
          fmtNs(uint64(rr.ambientCpuNs div max(1, rr.ambientUnits)))
        echo "    requests=", t.requests, " granted=", t.granted,
          " timeouts=", t.timeouts, " errors=", t.errors,
          "   admission rate ", int(float(t.granted) /
            (float(rr.windowNs) / 1e9)), "/s"
        echo "    ", line("admission", rr.admissionAll.summary,
          rr.admissionAll.count)
        admReps.add rr.admissionAll.summary
        when RoleTiming:
          echo "    ", line("held-role", rr.heldAll.summary, rr.heldAll.count)
          heldReps.add rr.heldAll.summary
          echo "    held-role rounds: acquired=", t.acquired, " committed=",
            t.committed, " fenced(stolen mid-round)=", t.fenced,
            " sub-tick(<1 clock tick)=", t.subTick
          echo "    held-role tail: >=100us ", t.over100us, " (",
            formatFloat(100.0 * float(t.over100us) /
              float(max(1'u64, rr.heldAll.count)), ffDecimal, 4), "%)",
            "  >=1ms ", t.over1ms, "  >=10ms ", t.over10ms
          # THE TWO SHARES. "Does preemption dominate" is a claim about these and
          # not about the maximum: OCCUPANCY says how much of the wall clock the
          # role is held by anyone at all (an arbiter nobody is waiting on cannot
          # be a bottleneck), and TAIL SHARE says how much of that held time went
          # into windows long enough to be a descheduled holder rather than a
          # round. A design in which preemption dominates has a large tail share.
          echo "    role OCCUPANCY (sum of held windows / wall window): ",
            formatFloat(100.0 * float(rr.heldAll.total) / float(max(1'i64,
              rr.windowNs)), ffDecimal, 2), "%   of which >=1ms windows are ",
            formatFloat(100.0 * float(t.heldTailNs) /
              float(max(1'u64, rr.heldAll.total)), ffDecimal, 2),
            "% (TAIL SHARE)"
          when RoleCpuTiming:
            echo "    ", line("off-CPU while holding", rr.offCpuAll.summary,
              rr.offCpuAll.count)
            echo "    off-CPU >=1ms while holding: ", t.offCpuOver1ms,
              "   OFF-CPU SHARE of all held time: ",
              formatFloat(100.0 * float(rr.offCpuAll.total) /
                float(max(1'u64, rr.heldAll.total)), ffDecimal, 2), "%"
            echo "      ^ THE ATTRIBUTION. If the tail were long ROUNDS rather",
              " than descheduled holders, this share would be near zero while the",
              " tail share above stayed large."
        else:
          echo "    held-role: NOT MEASURED in this build (control arm)"
        echo "    role contention: busy=", t.busy, " lostRace=", t.lost,
          "   STEAL DETECTOR: steals=", t.steals, " (anchor-authorised ",
          t.anchorSteals, ", anchor probes ", t.anchorProbes, ")"
        echo "    blocking: parks=", t.parks, " fastAnswers=", t.fastAnswers,
          " wakes=", t.wakes, " wakeSyscalls=", t.wakeSyscalls,
          "   task ctx switches=", t.csw, " syscalls=", t.syscalls
        echo "    RECLAMATION (M7): passes=", rr.reclaimPasses, " reclaimed=",
          rr.reclaimed, " liveSkipped=", rr.liveSkipped, " graceSkipped=",
          rr.graceSkipped
      # THE RANGE, not a point value.
      proc rangeOf(s: seq[LoadPointResult]; f: proc(
          x: LoadPointResult): uint64):
          string =
        if s.len == 0: return "-"
        var lo = high(uint64)
        var hi = 0'u64
        for x in s:
          let v = f(x)
          lo = min(lo, v); hi = max(hi, v)
        fmtNs(lo) & ".." & fmtNs(hi)
      echo "  ACROSS ", reps, " REPS (min..max — quote THIS, not a single rep):"
      block:
        var lo = 1e18
        var hi = 0.0
        for x in ratioReps:
          lo = min(lo, x); hi = max(hi, x)
        echo "    MEASURED oversubscription ", formatFloat(lo, ffDecimal, 2),
          "x..", formatFloat(hi, ffDecimal, 2), "x  (requested ", mult,
          "x injected + the clients themselves)"
      echo "    admission  p50 ", rangeOf(admReps, proc(
          x: LoadPointResult): uint64 = x.p50),
        "  p99 ", rangeOf(admReps, proc(x: LoadPointResult): uint64 = x.p99),
        "  p99.9 ", rangeOf(admReps, proc(x: LoadPointResult): uint64 = x.p999),
        "  max ", rangeOf(admReps, proc(x: LoadPointResult): uint64 = x.pMax)
      when RoleTiming:
        echo "    held-role  p50 ", rangeOf(heldReps, proc(
            x: LoadPointResult): uint64 = x.p50),
          "  p99 ", rangeOf(heldReps, proc(x: LoadPointResult): uint64 = x.p99),
          "  p99.9 ", rangeOf(heldReps, proc(
              x: LoadPointResult): uint64 = x.p999),
          "  max ", rangeOf(heldReps, proc(x: LoadPointResult): uint64 = x.pMax)
      echo ""

    echo "=== end. Read the ranges, not the point values. ==="
    echo "NOT MEASURED HERE, and M8 is NOT complete without them: the socket-daemon",
      " configuration (needs RunQuota's daemon and the M1 baseline, both deferred",
      " to the integration boundary) and the hybrid configuration (never built)."

  main()
