## Cost of ONE OBSERVATION, on every path the M4 ring has.
##
## Scope note, the same one `bench_claim.nim` and `bench_wait.nim` carry: this is
## the POC's own self-contained measurement. The comparison that decides anything —
## the per-execution observation cost against the socket completion report it would
## replace, as a fraction of real build wall time — is campaign M1 (baseline) and M8
## (verdict), both of which need a real `repro build` and a real RunQuota daemon.
## Nothing here is a verdict.
##
## What it measures, and why each number is the one that matters:
##
##   1. APPEND, ring not full — the hot path OS-1 is about: a ticket CAS, a memcpy,
##      a release store, a seq-cst fence and a 32-bit load. This is the number that
##      has to be small enough that capture-on-by-default is defensible.
##   2. APPEND, ring FULL — the DROP path. It must be no more expensive than (1):
##      the whole point of dropping rather than blocking is that back-pressure never
##      reaches the process being observed. A happy-path benchmark never measures
##      this, which is exactly why it is here.
##   3. APPEND that must SIGNAL — the empty-to-non-empty transition, with a waiter
##      registered so the wake syscall is really issued. This is what a transition
##      costs, and (1) vs (3) is what the "signal only on the transition" rule buys
##      on every append that is NOT a transition.
##   4. DRAIN — the consumer side, for completeness.
##   5. ONE-WAY WRITE and SOCKET ROUND TRIP — the same observation delivered by the
##      cheapest IPC there is, and by the request/reply the transport spec forbids.
##      Both are LOWER BOUNDS on a socket completion report (no daemon work, no
##      scheduling latency), so the ratios understate what the ring saves.
##
## READ THE VARIANCE BEFORE QUOTING ANYTHING. These figures move run to run on a
## loaded host. Quote a range from several runs, never a single number.

import std/[monotimes, os, posix, strutils, times]
import shm_lease/[obsring, waitword, syscount]

const
  AppendIters = 500_000
  SignalIters = 20_000
  IpcIters = 200_000
  RecLen = 48
  BigCap = 1 shl 19     ## big enough that `AppendIters` never fills it
  SmallCap = 64

proc freshPath(tag: string): string =
  getTempDir() / ("shmlease-benchobs-" & tag & "-" & $getpid() & ".seg")

proc nsPerOp(elapsed: Duration; ops: int): float =
  float(elapsed.inNanoseconds) / float(ops)

proc cleanup(p: string) =
  try: removeFile(p)
  except CatchableError: discard

when not obsRingSupported:
  echo "obsring unavailable on this platform (portable no-op arm) — nothing to measure"
else:
  var rec: array[RecLen, byte]
  for i in 0 ..< RecLen: rec[i] = byte(i)
  var buf: array[RecLen, byte]
  var n = 0

  # 1 — append into a ring with room -----------------------------------------
  let openPath = freshPath("open")
  var openRing = createObsRing(openPath, BigCap, RecLen)
  doAssert openRing.available
  # PRE-TOUCH the slot area, so the figure below is the STEADY-STATE append cost
  # rather than a measurement of first-touch paging over a fresh 30-odd MB mapping.
  # The residual gap between this arm and the drop arm (roughly 14 ns against 4 ns
  # on this host) is the record copy, the slot's length field and the release store
  # — i.e. real work the drop path skips, not paging.
  block:
    let ps = pageSize()
    var off = 0
    while off < openRing.size:
      openRing.base[off] = openRing.base[off]
      off += ps
  var s0 = unixSyscallCount()
  var t0 = getMonoTime()
  for _ in 0 ..< AppendIters:
    discard openRing.publish(rec)
  var el = getMonoTime() - t0
  let appendNs = nsPerOp(el, AppendIters)
  let appendSys = unixSyscallCount() - s0
  echo "append (ring has room)   : ", formatFloat(appendNs, ffDecimal, 2),
    " ns/op over ", AppendIters, " ops, ", appendSys, " syscalls, ",
    openRing.droppedCount(), " drops"

  # 2 — append into a FULL ring (the drop path) --------------------------------
  let fullPath = freshPath("full")
  var fullRing = createObsRing(fullPath, SmallCap, RecLen)
  doAssert fullRing.available
  for _ in 0 ..< SmallCap * 2: discard fullRing.publish(rec)   # saturate
  doAssert fullRing.droppedCount() > 0
  let dropsBefore = fullRing.droppedCount()
  s0 = unixSyscallCount()
  t0 = getMonoTime()
  for _ in 0 ..< AppendIters:
    discard fullRing.publish(rec)
  el = getMonoTime() - t0
  let dropNs = nsPerOp(el, AppendIters)
  echo "append (ring FULL, drops): ", formatFloat(dropNs, ffDecimal, 2),
    " ns/op over ", AppendIters, " ops, ", unixSyscallCount() - s0, " syscalls, ",
    fullRing.droppedCount() - dropsBefore, " counted drops"

  # 3 — an append that must SIGNAL ---------------------------------------------
  # A waiter is registered by hand (nobody is actually parked), so `wakeAll` really
  # issues the syscall. That is the honest cost of a transition: the wake is made,
  # it simply finds the kernel empty.
  let sigPath = freshPath("signal")
  var sigRing = createObsRing(sigPath, BigCap, RecLen)
  doAssert sigRing.available
  discard atomicAddFetch(cast[ptr uint32](addr sigRing.base[
    sigRing.waitOff + WwOffWaiters]), 1'u32, ATOMIC_SEQ_CST)
  s0 = unixSyscallCount()
  t0 = getMonoTime()
  for _ in 0 ..< SignalIters:
    # Re-arm the idle token each time: a transition is by definition a one-off, so
    # measuring "what a transition costs" means paying for one on every iteration.
    atomicStoreN(cast[ptr uint32](addr sigRing.base[ObsOffIdle]), 1'u32,
      ATOMIC_SEQ_CST)
    discard sigRing.publish(rec)
  el = getMonoTime() - t0
  let signalNs = nsPerOp(el, SignalIters)
  echo "append that SIGNALS      : ", formatFloat(signalNs, ffDecimal, 2),
    " ns/op over ", SignalIters, " ops, ", unixSyscallCount() - s0,
    " syscalls, ", sigRing.signalCount(), " signals  -> the transition costs ",
    formatFloat(signalNs / max(appendNs, 0.001), ffDecimal, 1),
    "x a plain append. THAT RATIO IS THE WHOLE ARGUMENT for signalling only on the ",
    "empty-to-non-empty transition rather than on every append."

  # 4 — drain -------------------------------------------------------------------
  let drainPath = freshPath("drain")
  var drainRing = createObsRing(drainPath, BigCap, RecLen)
  doAssert drainRing.available
  const DrainIters = 400_000
  for _ in 0 ..< DrainIters: discard drainRing.publish(rec)
  t0 = getMonoTime()
  var got = 0
  for _ in 0 ..< DrainIters:
    if drainRing.drainOne(buf, n) == odrGot: inc got
  el = getMonoTime() - t0
  echo "drain (consumer side)    : ", formatFloat(nsPerOp(el, DrainIters), ffDecimal, 2),
    " ns/op over ", got, " records"

  # 5 — the IPC lower bounds ----------------------------------------------------
  let devNull = open("/dev/null".cstring, O_WRONLY)
  doAssert devNull >= 0
  t0 = getMonoTime()
  for _ in 0 ..< IpcIters:
    discard write(devNull, addr rec[0], RecLen)
  el = getMonoTime() - t0
  let writeNs = nsPerOp(el, IpcIters)
  echo "one-way write(2)         : ", formatFloat(writeNs, ffDecimal, 2), " ns/op"
  discard close(devNull)

  var sv: array[2, cint]
  doAssert socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0
  var reply: array[1, byte]
  t0 = getMonoTime()
  for _ in 0 ..< IpcIters:
    discard write(sv[0], addr rec[0], RecLen)
    discard read(sv[1], addr buf[0], RecLen)
    discard write(sv[1], addr reply[0], 1)
    discard read(sv[0], addr reply[0], 1)
  el = getMonoTime() - t0
  let rtripNs = nsPerOp(el, IpcIters)
  echo "socket round trip        : ", formatFloat(rtripNs, ffDecimal, 2), " ns/op"
  discard close(sv[0])
  discard close(sv[1])

  echo "RATIOS (lower bounds, since neither IPC arm includes any daemon work): ",
    "one-way write / append = ", formatFloat(writeNs / max(appendNs, 0.001), ffDecimal, 1),
    "x; socket round trip / append = ",
    formatFloat(rtripNs / max(appendNs, 0.001), ffDecimal, 1), "x"

  drainRing.detach(); cleanup(drainPath)
  sigRing.detach(); cleanup(sigPath)
  fullRing.detach(); cleanup(fullPath)
  openRing.detach(); cleanup(openPath)
