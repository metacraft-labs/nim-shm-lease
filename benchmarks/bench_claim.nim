## Self-contained cost measurement for the packed-budget reservation.
##
## Scope note: this is the POC's OWN benchmark. The comparison that decides whether
## shared-memory admission is worth adopting — socket round trip versus this, as a
## fraction of real build wall time — is campaign M1 (baseline) and M8 (verdict),
## both of which need a real `repro build` and a real RunQuota daemon. Phase 1 is
## explicitly isolated-component work, so nothing here depends on either, and no
## number here should be read as a verdict.
##
## What it measures:
##   1. uncontended claim + release, single process, single thread — the fast path
##      the whole design exists for (one load, one per-dimension fit test, one CAS);
##   2. the same over a two-word (machine + pool) claim, to price the fixed-order
##      multi-word path;
##   3. contended claim + release across T threads on one budget word, to show how
##      the CAS retry rate grows — the number M8's preemption study needs a baseline
##      for.
##
## Run with `just bench` (release mode).
##
## READ THE VARIANCE BEFORE QUOTING ANY NUMBER FROM HERE. These figures move a lot
## run to run, and the contended ones move most: across five back-to-back release
## runs on one macOS/arm64 host the 2-thread aggregate came out anywhere from 70 to
## 118 ns, and independent runs elsewhere on the same host gave 75 and 89 ns against
## an earlier 147 ns — roughly a 2x spread on the same binary and the same machine.
## The uncontended figure is the only one with a usable range (24-46 ns on one budget
## word). So: run it several times, quote a RANGE, and treat a single number from a
## single run as noise. The measurement that actually decides anything is campaign
## M1/M8 against the socket, on an unloaded host.

import std/[monotimes, os, posix, strutils, times]
import shm_lease

const
  Iters = 2_000_000
  ThreadIters = 200_000

proc freshPath(tag: string): string =
  getTempDir() / ("shmlease-bench-" & tag & "-" & $getpid() & ".seg")

proc nsPerOp(elapsed: Duration; ops: int): float =
  float(elapsed.inNanoseconds) / float(ops)

# --- 1 + 2: uncontended -----------------------------------------------------

proc benchUncontended(pool: int; label: string) =
  let path = freshPath("uncontended" & $pool)
  defer: removeFile(path)
  var l = createLeaseSegment(path,
    [vec(1000, 1000, 1000, 1000), vec(1000, 1000, 1000, 1000)])
  doAssert l.available
  let v = vec(1, 4, 1, 10)
  var r: Reservation
  # Warm up the mapping (first touch faults the page in).
  for _ in 0 ..< 1000:
    doAssert l.claim(v, r, poolIndex = pool) == csGranted
    doAssert l.release(r)

  let t0 = getMonoTime()
  for _ in 0 ..< Iters:
    if l.claim(v, r, poolIndex = pool) == csGranted:
      discard l.release(r)
  let dt = getMonoTime() - t0
  echo label, ": ", formatFloat(nsPerOp(dt, Iters), ffDecimal, 1),
    " ns per claim+release pair (", Iters, " pairs, retries=",
    l.retryCount(MachineBudgetIndex), ")"
  l.detach()

# --- 3: contended -----------------------------------------------------------

var gPath: string
var gThreadOk: array[16, int]

proc worker(id: int) {.thread.} =
  {.cast(gcsafe).}:
    var l = attachLeaseSegment(gPath)
    doAssert l.available
    let v = vec(1, 1, 1, 1)
    var granted = 0
    for _ in 0 ..< ThreadIters:
      var r: Reservation
      if l.claim(v, r) == csGranted:
        inc granted
        discard l.release(r)
    gThreadOk[id] = granted
    l.detach()

proc benchContended(threads: int) =
  let path = freshPath("contended" & $threads)
  defer: removeFile(path)
  gPath = path
  var l = createLeaseSegment(path, [vec(1000, 1000, 1000, 1000)])
  doAssert l.available
  var ts = newSeq[Thread[int]](threads)
  let t0 = getMonoTime()
  for i in 0 ..< threads: createThread(ts[i], worker, i)
  for i in 0 ..< threads: joinThread(ts[i])
  let dt = getMonoTime() - t0
  let ops = threads * ThreadIters
  echo "contended, ", threads, " threads: ",
    formatFloat(nsPerOp(dt, ops), ffDecimal, 1),
    " ns per claim+release pair (aggregate), claims=", l.claimCount(0),
    " retries=", l.retryCount(0),
    " retries/claim=", formatFloat(float(l.retryCount(0)) /
      float(max(1'u64, l.claimCount(0))), ffDecimal, 2)
  doAssert l.packedRemaining(0) == l.packedCapacity(0), "conservation broken"
  doAssert l.noOvercommit(0)
  l.detach()

when isMainModule:
  echo "nim-shm-lease packed-budget reservation, ", hostOS, "/", hostCPU
  echo "  (POC-local numbers only; the socket comparison is campaign M1/M8)"
  benchUncontended(-1, "uncontended, 1 budget word (machine)   ")
  benchUncontended(0, "uncontended, 2 budget words (machine+pool)")
  for t in [1, 2, 4, 8]:
    benchContended(t)
