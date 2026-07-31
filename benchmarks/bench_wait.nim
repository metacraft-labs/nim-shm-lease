## Cost of the M3 blocking wrapper's FAST PATHS, and of a real park/unpark.
##
## Scope note, same as `bench_claim.nim`: this is the POC's own self-contained
## measurement. The comparison that decides anything — a shared-memory wait against
## the socket round trip it would replace, as a fraction of real build wall time —
## is campaign M1 (baseline) and M8 (verdict), both of which need a real
## `repro build` and a real RunQuota daemon. Nothing here is a verdict.
##
## What it measures, and why each number is the one that matters:
##
##   1. UNCONTENDED WAIT — the word already differs, so the waiter returns after a
##      single atomic load. This is the path SM-2 is about, and the number to
##      compare against a syscall (~hundreds of ns) and against a socket round trip
##      (~tens of microseconds).
##   2. UNCONTENDED WAKE — nobody is parked, so the waker returns after a single
##      atomic load. The point of measuring it separately is that this is the case a
##      naive implementation gets wrong: an unconditional wake syscall costs a full
##      kernel entry on every release even when there is nothing to wake.
##   3. FORCED WAKE SYSCALL — the same wake with the fast path bypassed, i.e. what
##      (2) would cost without the waiter-count check. The RATIO between (2) and (3)
##      is the honest statement of what the fast path buys.
##   4. PARK + WAKE ROUND TRIP across two threads — the slow path, for scale.
##
## READ THE VARIANCE BEFORE QUOTING ANYTHING. These figures move run to run on a
## loaded host, exactly as `bench_claim.nim`'s do. Quote a range from several runs,
## never a single number.

import std/[monotimes, os, posix, strutils, times]
import shm_lease/[waitword, syscount]

const
  FastIters = 5_000_000
  SyscallIters = 200_000
  RoundTrips = 20_000

proc freshPath(tag: string): string =
  getTempDir() / ("shmlease-benchwait-" & tag & "-" & $getpid() & ".seg")

proc nsPerOp(elapsed: Duration; ops: int): float =
  float(elapsed.inNanoseconds) / float(ops)

type Ctx = object
  seg: ptr WaitSegment
  slot: int
  rounds: int

var gCtx: Ctx

proc responder(p: pointer) {.thread.} =
  ## Mirrors the driver: park until the driver bumps slot 0, then bump slot 1.
  var seen0 = 0'u32
  for _ in 0 ..< gCtx.rounds:
    while true:
      let v = gCtx.seg[].slotValue(0)
      if v != seen0:
        seen0 = v
        break
      discard waitOn(gCtx.seg[].base, gCtx.seg[].slotOffset(0), seen0,
        1_000_000_000'i64)
    discard gCtx.seg[].publishGrant(1, 0'u64)

when isMainModule:
  echo "nim-shm-lease M3 wait-word benchmark"
  echo "  backend        : ", WaitWordBackend
  echo "  available      : ", waitWordAvailable()
  echo "  page size      : ", pageSize()
  echo "  syscall counter: ", syscallCountAvailable()

  if not waitWordAvailable():
    echo "  (unavailable on this platform — nothing to measure)"
  else:
    let path = freshPath("fast")
    defer: removeFile(path)
    var seg = createWaitSegment(path, 4)
    doAssert seg.available
    let base = seg.base
    let off = seg.slotOffset(0)
    prefaultWaitWord(base, off)
    let cur = seg.slotValue(0)

    # Warm up.
    for _ in 0 ..< 10_000: discard waitOn(base, off, cur + 1)

    resetWaitWordCounters()
    let s0 = unixSyscallCount()
    let t0 = getMonoTime()
    for _ in 0 ..< FastIters: discard waitOn(base, off, cur + 1)
    let waitNs = nsPerOp(getMonoTime() - t0, FastIters)
    let s1 = unixSyscallCount()

    let t1 = getMonoTime()
    for _ in 0 ..< FastIters: discard wakeAll(base, off)
    let wakeNs = nsPerOp(getMonoTime() - t1, FastIters)
    let s2 = unixSyscallCount()

    let t2 = getMonoTime()
    for _ in 0 ..< SyscallIters: discard wakeRaw(base, off)
    let sysNs = nsPerOp(getMonoTime() - t2, SyscallIters)
    let s3 = unixSyscallCount()

    echo "  uncontended wait : ", formatFloat(waitNs, ffDecimal, 2),
      " ns/op over ", FastIters, " ops  (", s1 - s0, " syscalls)"
    echo "  uncontended wake : ", formatFloat(wakeNs, ffDecimal, 2),
      " ns/op over ", FastIters, " ops  (", s2 - s1, " syscalls)"
    echo "  forced wake call : ", formatFloat(sysNs, ffDecimal, 2),
      " ns/op over ", SyscallIters, " ops  (", s3 - s2, " syscalls)"
    if wakeNs > 0:
      echo "  fast path is ", formatFloat(sysNs / wakeNs, ffDecimal, 1),
        "x cheaper than the unconditional wake syscall it replaces"

    # --- 4: a real park/wake round trip between two threads.
    gCtx = Ctx(seg: addr seg, slot: 0, rounds: RoundTrips)
    var th: Thread[pointer]
    createThread(th, responder, nil)
    var seen1 = seg.slotValue(1)
    let t3 = getMonoTime()
    for _ in 0 ..< RoundTrips:
      discard seg.publishGrant(0, 0'u64)
      while true:
        let v = seg.slotValue(1)
        if v != seen1:
          seen1 = v
          break
        discard waitOn(seg.base, seg.slotOffset(1), seen1, 1_000_000_000'i64)
    let rtNs = nsPerOp(getMonoTime() - t3, RoundTrips)
    joinThread(th)
    echo "  park+wake round trip: ", formatFloat(rtNs, ffDecimal, 0),
      " ns over ", RoundTrips, " round trips (SLOW path, for scale)"
    seg.detach()
