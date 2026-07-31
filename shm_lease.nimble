import std/[strutils]
version       = readFile("version.txt").strip()
author        = "Metacraft Labs"
description   = "Shared-memory, lock-free, file-backed multi-dimensional RESERVATION " &
  "over a packed budget word (CPU slots, coarse memory units, process count and " &
  "IO weight in one 64-bit CAS), plus a futex-class cross-process blocking wrapper " &
  "whose uncontended path makes no syscall at all."
license       = "Apache-2.0"
srcDir        = "src"
skipDirs      = @["tests", "benchmarks"]

requires "nim >= 2.0.0"

const nimFlags = "--hints:off --threads:on --warning:BareExcept:off --path:src "

task test, "Build + run the nim-shm-lease test suite":
  # Packing/fit arithmetic, fixed-claim-order enforcement, anchoring (boot + pid +
  # process START TIME), over-release refusal, and the NEGATIVE controls that give
  # the overcommit detector and the stored-pointer checker teeth.
  exec "nim c -r " & nimFlags & "tests/test_shm_lease.nim"
  # THE M2 GATE: N real processes claiming/releasing against one shared packed
  # budget, each at a DELIBERATELY DIFFERENT virtual base (MAP_FIXED).
  exec "nim c -r " & nimFlags & "tests/test_shm_lease_multiprocess.nim"
  # M3: the futex-class blocking wrapper. Capability record, the kernel syscall
  # counter calibrated before it is trusted, SM-2's two fast paths measured at
  # zero against a forced-syscall control, spurious-wakeup tolerance, and the
  # macOS prefault hazard exhibited.
  exec "nim c -r " & nimFlags & "tests/test_shm_lease_waitword.nim"
  # THE M3 GATE: real processes at DELIBERATELY DIFFERENT virtual bases — a waiter
  # blocks and a second process wakes it, a blocked waiter burns no CPU while a
  # spinning control burns a core, and the fast path costs zero syscalls.
  exec "nim c -r " & nimFlags & "tests/test_shm_lease_wait_multiprocess.nim"
  # The same suite compiled with the deterministic schedule hooks enabled, proving
  # the seams exist at every CAS/publish/wait/wake site and are behaviour-preserving.
  exec "nim c -r " & nimFlags &
    "-d:shmLeaseScheduleHooks tests/test_shm_lease_hooks.nim"
