## Segment anchoring: boot id + owner pid + process START TIME.
##
## A shared-memory reservation has no kernel-guaranteed liveness signal — the
## socket transport gets one for free from connection closure, and this one does
## not (`RunQuota-Shared-Memory-Transport.md` §5). The replacement is an explicit
## anchor, and the spec is emphatic about all three components:
##
##   * `bootId` — a segment file left over from a previous boot is meaningless,
##     because pids from that boot say nothing about this one.
##   * `ownerPid` — who created the segment.
##   * `ownerStartTime` — **start time is what defeats pid reuse.** Without it, a
##     new process that happens to be handed a dead owner's pid makes a stale
##     segment look live (or, worse in M7, makes a live reservation look reclaimable).
##
## Reclamation itself is M7. The FIELDS and the predicate that consults them land
## here in M2 deliberately, because the spec says the crash-safety discipline
## "MUST be designed in from the start; it cannot be retrofitted onto a structure
## whose operations are not individually recoverable". `ownerAliveAnchor` below is
## already the M7 predicate, and `tests/test_shm_lease.nim` proves start time is
## actually consulted by forging a same-pid / wrong-start-time anchor.
##
## `processStartTime` returns 0 when the value cannot be determined (an exited
## process, a platform without the interface). A zero start time is treated as
## UNKNOWN, never as "matches": an anchor with an unknown start time falls back to
## the weaker boot+pid judgement, which is stated rather than silently assumed.

const anchorSupported* = defined(linux) or defined(macosx)

when defined(macosx):
  # macOS exposes a process's start time through `sysctl(KERN_PROC/KERN_PROC_PID)`
  # as `kinfo_proc.kp_proc.p_starttime` (a `struct timeval`). Wrapping
  # `struct kinfo_proc` in Nim would mean mirroring a large, version-sensitive
  # BSD struct; a three-line C shim is both smaller and immune to layout drift,
  # since the C compiler reads the real header. Emitted into the TYPESECTION so it
  # precedes every use in the generated translation unit.
  {.emit: """/*TYPESECTION*/
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <string.h>
static unsigned long long shmLeaseProcStartUsec(int pid) {
  struct kinfo_proc kp;
  size_t len = sizeof(kp);
  int mib[4];
  mib[0] = CTL_KERN; mib[1] = KERN_PROC; mib[2] = KERN_PROC_PID; mib[3] = pid;
  memset(&kp, 0, sizeof(kp));
  if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0) return 0ULL;
  if (len == 0) return 0ULL; /* no such process */
  return (unsigned long long)kp.kp_proc.p_starttime.tv_sec * 1000000ULL +
         (unsigned long long)kp.kp_proc.p_starttime.tv_usec;
}
""".}
  proc shmLeaseProcStartUsec(pid: cint): uint64 {.
    importc: "shmLeaseProcStartUsec", nodecl.}

when anchorSupported:
  import std/[posix]
  when defined(linux):
    import std/[strutils]

  proc processStartTime*(pid: int): uint64 =
    ## Monotonic-per-boot process start stamp, or 0 when unknown.
    ##
    ## Linux: field 22 of `/proc/<pid>/stat` (`starttime`, in clock ticks since
    ## boot). Parsed after the LAST `)` because `comm` may itself contain spaces
    ## and parentheses.
    ##
    ## macOS: `kp_proc.p_starttime` in microseconds since the epoch, via sysctl.
    ##
    ## The two units differ, which is fine — the value is only ever compared
    ## against another value produced on the SAME host and boot.
    when defined(linux):
      try:
        let raw = readFile("/proc/" & $pid & "/stat")
        let close = raw.rfind(')')
        if close < 0 or close + 2 >= raw.len: return 0'u64
        let fields = raw[close + 2 .. ^1].splitWhitespace()
        # After ") " the first field is `state`, i.e. overall field 3, so overall
        # field 22 (`starttime`) is index 19 here.
        if fields.len < 20: return 0'u64
        return parseBiggestUInt(fields[19])
      except CatchableError:
        return 0'u64
    else:
      return shmLeaseProcStartUsec(cint(pid))

  proc bootId*(): uint64 =
    ## Per-boot identity, never zero. Same shape as `nim-shm-gset.bootId` /
    ## `nim-shm-queue.segment.bootId` so the three libraries agree on staleness.
    when defined(linux):
      try:
        let raw = readFile("/proc/sys/kernel/random/boot_id")
        var h: uint64 = 1469598103934665603'u64
        for ch in raw:
          if ch != '-' and ch != '\n':
            h = (h xor uint64(ord(ch))) * 1099511628211'u64
        return (h or 1'u64)
      except CatchableError:
        discard
    # Fallback (and the macOS path): boot time from `kern.boottime` is not
    # reachable without another sysctl shim, so derive a per-boot-stable value
    # from this process's own ancestry instead: pid 1's start time changes on
    # every boot and never within one.
    let initStart = processStartTime(1)
    if initStart != 0'u64:
      return (initStart or 1'u64)
    var ts: Timespec
    discard clock_gettime(CLOCK_REALTIME, ts)
    (uint64(ts.tv_sec) or 1'u64)

  proc pidAlive*(pid: uint64): bool =
    ## Does a process with this pid exist right now? `ESRCH` means gone; `EPERM`
    ## means it exists but belongs to someone else.
    if pid == 0: return false
    if kill(Pid(pid), cint(0)) == 0: return true
    errno != ESRCH

  type AnchorVerdict* = enum
    ## Why an anchor was judged live or dead. Reported rather than collapsed to a
    ## bool so M7's reclamation can log WHICH check fired.
    avLive              ## boot matches, pid exists, start time matches (or unknown)
    avStaleBoot         ## recorded on a previous boot ⇒ pid is meaningless
    avOwnerGone         ## pid no longer exists
    avPidReused         ## pid exists but its start time differs ⇒ a DIFFERENT process
    avNoOwner           ## no owner recorded (pid 0)

  proc anchorVerdict*(recordedBoot, recordedPid, recordedStart: uint64): AnchorVerdict =
    ## The M7 predicate, landed in M2 so the fields are consulted from day one.
    if recordedPid == 0: return avNoOwner
    if recordedBoot != bootId(): return avStaleBoot
    if not pidAlive(recordedPid): return avOwnerGone
    let now = processStartTime(int(recordedPid))
    if recordedStart != 0'u64 and now != 0'u64 and now != recordedStart:
      return avPidReused
    avLive

  proc ownerAliveAnchor*(recordedBoot, recordedPid, recordedStart: uint64): bool =
    anchorVerdict(recordedBoot, recordedPid, recordedStart) == avLive

else:
  # --- portable arm ----------------------------------------------------------
  type AnchorVerdict* = enum
    avLive
    avStaleBoot
    avOwnerGone
    avPidReused
    avNoOwner

  proc processStartTime*(pid: int): uint64 = 0'u64
  proc bootId*(): uint64 = 1'u64
  proc pidAlive*(pid: uint64): bool = false
  proc anchorVerdict*(recordedBoot, recordedPid, recordedStart: uint64): AnchorVerdict =
    avNoOwner
  proc ownerAliveAnchor*(recordedBoot, recordedPid, recordedStart: uint64): bool = false
