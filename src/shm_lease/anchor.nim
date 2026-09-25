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
##
## Three arms: Linux and macOS (below, unchanged), and WINDOWS, where the anchor is
## implemented ahead of the segments that carry it there because a consumer --
## `runquota`'s published stats table -- already records and judges one. Its sources
## are in `RunQuota-Shared-Memory-Structures.md` §"Implemented on Windows"; the one
## that departs from the original design table is the boot id. Everything else lands
## on the portable arm, which reports no anchor at all.

const anchorSupported* = defined(linux) or defined(macosx) or defined(windows)

type AnchorVerdict* = enum
  ## Why an anchor was judged live or dead. Reported rather than collapsed to a
  ## bool so M7's reclamation can log WHICH check fired.
  ##
  ## Declared once, for every arm: the verdict is part of the contract, not of
  ## any one platform's way of reaching it.
  avLive              ## boot matches, pid exists, start time matches (or unknown)
  avStaleBoot         ## recorded on a previous boot ⇒ pid is meaningless
  avOwnerGone         ## pid no longer exists
  avPidReused         ## pid exists but its start time differs ⇒ a DIFFERENT process
  avNoOwner           ## no owner recorded (pid 0)

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

when defined(linux) or defined(macosx):
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

elif defined(windows):
  # --- Windows arm -------------------------------------------------------------
  #
  # `RunQuota-Shared-Memory-Structures.md` §"Anchoring without `/proc`" is the
  # design: the boot + pid + start-time scheme ports unchanged, with different
  # sources for each field. The one departure from that section's first table
  # is the boot id, and the spec records why (§"The boot id on Windows"):
  # "now minus `GetTickCount64()`" is not stable within a boot, and a boot id
  # that moves makes every live segment read as `avStaleBoot`.
  import std/winlean

  const
    ProcessQueryLimitedInformation = 0x1000'i32
      ## The right-sized right. Granted for processes this account may not
      ## fully open, so the start time of a daemon running as another account
      ## is still readable.
    Synchronize = 0x0010_0000'i32
    WaitObject0 = 0'i32
    StillActive = 259'i32
    ErrorInvalidParameter = 87'i32
      ## What `OpenProcess` reports for a pid that names no process. Every
      ## other failure (access denied above all) means the pid DOES name one.
    SystemTimeOfDayInformation = 3'i32

  type SystemTimeOfDayInfo = object
    ## `SYSTEM_TIMEOFDAY_INFORMATION`, the layout `NtQuerySystemInformation`
    ## has returned for this class since NT 4. `winternl.h` declares it as
    ## opaque bytes; these are the fields every system-information tool reads.
    bootTime: int64       ## FILETIME of the boot, SHIFTED by every clock step
    currentTime: int64
    timeZoneBias: int64
    timeZoneId: uint32
    reserved: uint32
    bootTimeBias: uint64  ## the sum of every clock step applied since boot
    sleepTimeBias: uint64

  proc ntQuerySystemInformation(infoClass: int32; info: pointer; infoLen: uint32;
                                returnLen: ptr uint32): int32 {.
    stdcall, dynlib: "ntdll.dll", importc: "NtQuerySystemInformation".}
  proc getTickCount64(): uint64 {.
    stdcall, dynlib: "kernel32.dll", importc: "GetTickCount64".}
  proc getSystemTimeAsFileTime(ft: var FILETIME) {.
    stdcall, dynlib: "kernel32.dll", importc: "GetSystemTimeAsFileTime".}

  proc fileTimeValue(ft: FILETIME): uint64 {.inline.} =
    (uint64(cast[uint32](ft.dwHighDateTime)) shl 32) or
      uint64(cast[uint32](ft.dwLowDateTime))

  proc openForAnchor(pid: uint64; synchronize: var bool): Handle =
    ## Open `pid` with the smallest access that answers both anchor questions.
    ## SYNCHRONIZE is preferred, because a zero-timeout wait is the exact "has
    ## it exited?" test and an exit code of 259 is not; a process this account
    ## may query but not wait on still answers through `GetExitCodeProcess`.
    ## Windows pids are DWORDs, so a wider value names nothing.
    synchronize = true
    if pid == 0'u64 or pid > uint64(high(uint32)):
      return Handle(0)
    let dwPid = cast[DWORD](uint32(pid))
    result = openProcess(Synchronize or ProcessQueryLimitedInformation,
      WINBOOL(0), dwPid)
    if result == Handle(0) and getLastError() != ErrorInvalidParameter:
      synchronize = false
      result = openProcess(ProcessQueryLimitedInformation, WINBOOL(0), dwPid)

  proc processStartTime*(pid: int): uint64 =
    ## The process creation time from `GetProcessTimes`, in 100 ns FILETIME
    ## units, or 0 when unknown (no such process, or one this account may not
    ## query at all).
    ##
    ## A documented API that returns the value directly, which is a better
    ## source than either Unix arm has. Compared only against another value
    ## produced on the same host and boot, like the other arms' stamps.
    if pid <= 0: return 0'u64
    var synchronize = false
    let handle = openForAnchor(uint64(pid), synchronize)
    if handle == Handle(0): return 0'u64
    defer: discard closeHandle(handle)
    var creation, exitTime, kernelTime, userTime: FILETIME
    if getProcessTimes(handle, creation, exitTime, kernelTime, userTime) == 0:
      return 0'u64
    fileTimeValue(creation)

  proc bootId*(): uint64 =
    ## Per-boot identity, never zero, and the SAME value in every process of
    ## one boot whatever account it runs as.
    ##
    ## THE KERNEL'S BOOT TIME WITH EVERY CLOCK STEP TAKEN BACK OUT. The kernel
    ## keeps the boot instant as a FILETIME and shifts it by the size of every
    ## step applied to the system clock, accumulating the same shifts in a
    ## separate bias; the difference is the boot instant as first recorded,
    ## which nothing within a boot can move. The class needs no privilege, so a
    ## daemon running as LocalSystem and a client in an ordinary session
    ## compute the same number.
    ##
    ## NOT `now - GetTickCount64()`, which the design table first suggested.
    ## That difference is only as stable as the wall clock: it drifts with every
    ## slew, jumps with every step, and straddles a millisecond boundary between
    ## any two calls, and a boot id that moves makes every live segment read as
    ## `avStaleBoot`. It is kept only as the fallback for a host on which the
    ## query fails, rounded to a minute so that it is at least stable between
    ## calls that do not straddle a clock change or a minute boundary.
    var tod: SystemTimeOfDayInfo
    var got = 0'u32
    if ntQuerySystemInformation(SystemTimeOfDayInformation, addr tod,
        uint32(sizeof(tod)), addr got) == 0'i32 and
        got >= uint32(sizeof(tod)) and tod.bootTime > 0'i64:
      return (uint64(tod.bootTime) - tod.bootTimeBias) or 1'u64
    var now: FILETIME
    getSystemTimeAsFileTime(now)
    const minute = 60'u64 * 10_000_000'u64
    let bootInstant = fileTimeValue(now) - getTickCount64() * 10_000'u64
    ((bootInstant div minute) * minute) or 1'u64

  proc pidAlive*(pid: uint64): bool =
    ## Does a process with this pid exist right now?
    ##
    ## A PROCESS OBJECT OUTLIVES ITS PROCESS while anyone holds a handle to it,
    ## and while it does its pid stays out of circulation and `OpenProcess`
    ## succeeds. So an open that succeeds is not yet proof of life: the object
    ## must also be unsignalled. An open refused for any reason but "no such
    ## process" means the pid names a process this account may not open,
    ## which is existence, exactly as `EPERM` is on the POSIX arm.
    var synchronize = false
    let handle = openForAnchor(pid, synchronize)
    if handle == Handle(0):
      return pid != 0'u64 and pid <= uint64(high(uint32)) and
        getLastError() != ErrorInvalidParameter
    defer: discard closeHandle(handle)
    if synchronize:
      return waitForSingleObject(handle, 0'i32) != WaitObject0
    var code: int32 = 0
    if getExitCodeProcess(handle, code) == 0: return true
    code == StillActive

else:
  # --- portable arm ----------------------------------------------------------
  proc processStartTime*(pid: int): uint64 = 0'u64
  proc bootId*(): uint64 = 1'u64
  proc pidAlive*(pid: uint64): bool = false

when anchorSupported:
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
  proc anchorVerdict*(recordedBoot, recordedPid, recordedStart: uint64): AnchorVerdict =
    avNoOwner
  proc ownerAliveAnchor*(recordedBoot, recordedPid, recordedStart: uint64): bool = false
