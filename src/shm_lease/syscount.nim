## A KERNEL-MAINTAINED syscall counter for this process, so SM-2 can be measured
## instead of argued.
##
## `RunQuota-Observation-Store.milestones.org` SM-2: *"Zero syscalls when
## uncontended. The fast path performs an atomic operation and never enters the
## kernel. **Verified by syscall counting, not by reading code.**"* The emphasis is
## the campaign's, and it rules out the obvious cheap answer — a counter the
## library increments itself would be measuring its own opinion. What is needed is
## a number the KERNEL maintains, so that a syscall the library did not intend to
## make still shows up.
##
## macOS: `task_info(mach_task_self(), TASK_EVENTS_INFO)` exposes `syscalls_unix`,
## a per-task count maintained by the kernel. Calibrated on Darwin 25.5 / arm64,
## 2026-07-31: 1000 `getppid()` calls move it by exactly 1000; 10^6 pure userspace
## iterations move it by exactly 0; one `os_sync_wake_by_address_any` moves it by
## exactly 1. That exactness is what makes "delta == 0 over 200000 fast-path
## operations" a measurement rather than a hope, and
## `tests/test_shm_lease_waitword.nim` re-establishes the calibration in-suite
## before relying on it.
##
## Linux: DELIBERATELY UNAVAILABLE. Linux exposes no cheap per-task syscall
## counter (`/proc/<pid>/stat` and `schedstat` carry scheduling figures, not
## syscall counts), and the alternatives — a `perf_event_open` on the
## `raw_syscalls:sys_enter` tracepoint, or a seccomp/ptrace shim — need privileges
## a test suite should not assume and would ship as code that has never run.
## Rather than that, the Linux route is the EXTERNAL tracer the milestone names:
## `just test-syscalls` runs the fast-path binary under `strace -c -f` and counts
## from the outside. `syscallCountAvailable()` returns false there, and the tests
## SKIP the in-process assertion loudly rather than passing vacuously.
##
## Windows and everything else: unavailable, like the rest of the portable arm.

const syscallCountSupported* = defined(macosx)

when defined(macosx):
  {.emit: """/*TYPESECTION*/
#include <mach/mach.h>
#include <mach/task_info.h>

/* Returns the kernel's count of UNIX (BSD) syscalls made by this task, or
   0xFFFFFFFFFFFFFFFF when task_info is unavailable. TASK_EVENTS_INFO also carries
   `syscalls_mach` and `csw`; the unix counter is the one that maps onto "did this
   code path enter the kernel", since a futex-class park/wake is a BSD syscall. */
static unsigned long long shmLeaseUnixSyscalls(void) {
  struct task_events_info info;
  mach_msg_type_number_t cnt = TASK_EVENTS_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_EVENTS_INFO, (task_info_t)&info, &cnt)
      != KERN_SUCCESS) {
    return (unsigned long long)-1;
  }
  return (unsigned long long)info.syscalls_unix;
}

/* **M8**: the SAME kernel record's context-switch count for this task. The
   preemption study needs a witness for "the role holder was taken off a core"
   that does not come from the library's own opinion, for exactly the reason the
   syscall counter above does not: a count this code maintained would measure what
   it believes rather than what the scheduler did. `csw` is maintained by the
   kernel alongside `syscalls_unix`, so one `task_info` call reads either and the
   calibration that establishes one establishes the other. */
static unsigned long long shmLeaseContextSwitches(void) {
  struct task_events_info info;
  mach_msg_type_number_t cnt = TASK_EVENTS_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_EVENTS_INFO, (task_info_t)&info, &cnt)
      != KERN_SUCCESS) {
    return (unsigned long long)-1;
  }
  return (unsigned long long)info.csw;
}
""".}
  proc shmLeaseUnixSyscalls(): uint64 {.importc: "shmLeaseUnixSyscalls", nodecl.}
  proc shmLeaseContextSwitches(): uint64 {.importc: "shmLeaseContextSwitches",
    nodecl.}

  proc syscallCountAvailable*(): bool =
    shmLeaseUnixSyscalls() != high(uint64)

  proc unixSyscallCount*(): uint64 =
    ## Kernel-maintained count of UNIX syscalls made by this task.
    ##
    ## NOTE FOR CALLERS: reading it is itself a Mach syscall, not a UNIX one, so
    ## bracketing a region with two calls does not perturb the number being
    ## measured. Verified as part of the in-suite calibration.
    let v = shmLeaseUnixSyscalls()
    if v == high(uint64): 0'u64 else: v

  proc contextSwitchCount*(): uint64 =
    ## **M8**: the kernel's count of context switches for this TASK — the whole
    ## process, not one thread, which is the granularity `task_info` reports at.
    ##
    ## READ IT AT WINDOW GRANULARITY, NOT PER ROUND. It costs a Mach syscall, so
    ## bracketing a two-microsecond combine round with two of these would measure
    ## the instrument. `benchmarks/probe_preemption.nim` uses it across a whole
    ## measured window, as the AMBIENT switch rate the per-round wall-minus-CPU
    ## figures are read against, and calibrates it in the same batch as the
    ## syscall counter above.
    let v = shmLeaseContextSwitches()
    if v == high(uint64): 0'u64 else: v

else:
  proc syscallCountAvailable*(): bool = false
  proc unixSyscallCount*(): uint64 = 0'u64
  proc contextSwitchCount*(): uint64 = 0'u64
