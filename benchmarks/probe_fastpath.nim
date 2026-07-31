## A deliberately minimal SM-2 probe for an EXTERNAL syscall tracer.
##
## The in-suite SM-2 assertions read the kernel's own per-task syscall counter
## (`shm_lease/syscount`), which is exact and needs no privileges. This binary
## exists for the other half of the campaign's wording — "verified by syscall
## counting" with `strace` / `dtruss` — and for Linux, where there is no cheap
## in-process counter and the external tracer is the only route.
##
## It is written to make the trace trivial to read: everything before the measured
## region happens up front, the measured region is a bare loop over the two fast
## paths with NOTHING else in it, and the only output is a single `write` at the
## very end. So a `strace -c` summary over the whole process should attribute ZERO
## calls to `futex`, and a `dtruss -c` summary zero to any wait/wake entry point —
## for 2 x 200000 fast-path operations.
##
## Run it through `just test-syscalls`, which knows the tracer for the host.
##
## Pass `--control` to run the SAME number of FORCED wakes instead, so the tracer
## has a known-nonzero comparison. A trace tool that reports zero for both is
## reporting nothing.

import std/[os, posix]
import shm_lease/[waitword, syscount]

const Iters = 200_000

when isMainModule:
  let control = paramCount() >= 1 and paramStr(1) == "--control"
  let path = getTempDir() / ("shmlease-probe-" & $getpid() & ".seg")
  var seg = createWaitSegment(path, 4)
  doAssert seg.available, "could not create the probe segment"
  let base = seg.base
  let off = seg.slotOffset(0)
  prefaultWaitWord(base, off)
  let cur = seg.slotValue(0)

  # Warm-up OUTSIDE the measured region: first-touch faults, lazy binding, and any
  # one-off allocation happen here so they cannot be mistaken for fast-path cost.
  for _ in 0 ..< 1000:
    discard waitOn(base, off, cur + 1)
    discard wakeAll(base, off)

  resetWaitWordCounters()
  let s0 = unixSyscallCount()

  # ---- THE MEASURED REGION: nothing here but the two fast paths -------------
  if control:
    for _ in 0 ..< Iters:
      discard wakeRaw(base, off)          # always a syscall — the control
  else:
    for _ in 0 ..< Iters:
      discard waitOn(base, off, cur + 1)  # word already differs: no syscall
    for _ in 0 ..< Iters:
      discard wakeAll(base, off)          # nobody parked: no syscall
  # --------------------------------------------------------------------------

  let s1 = unixSyscallCount()
  let mode = if control: "control (forced wakes)" else: "fast path"
  let counted = if syscallCountAvailable(): $(s1 - s0) else: "n/a"
  echo "probe_fastpath: mode=", mode, " iters=", Iters,
    " in-process kernel syscall delta=", counted,
    " parks=", wwParks, " wakeSyscalls=", wwWakeSyscalls,
    " fastWaits=", wwFastWaits, " fastWakes=", wwFastWakes
  seg.detach()
  try: removeFile(path)
  except CatchableError: discard
