## `nim-shm-lease` **M3** — a futex-class cross-process blocking wrapper.
##
## Design authority: `reprobuild-specs/RunQuota-Shared-Memory-Transport.md`
## §"Waiting Without Spinning"; campaign milestone
## `reprobuild-specs/RunQuota-Observation-Store.milestones.org` ** M3, which this
## module implements and whose gate lives in
## `tests/test_shm_lease_wait_multiprocess.nim`.
##
## WHY THIS EXISTS. The whole motivation for shared memory is to remove IPC
## waiting from process startup, and a busy wait would *defeat* that motivation
## rather than serve it: a build is CPU-saturated by design, so a spinning waiter
## steals a core from the very actions it waits for. That is SM-1, and it is an
## INVARIANT rather than a quality goal. The complementary property is SM-2: the
## uncontended path must be pure userspace — one atomic operation, no syscall —
## because a design that entered the kernel on every uncontended operation would
## have reinstated the cost it set out to remove.
##
## So this module has exactly two fast paths, and both are syscall-free:
##
##   * **Waiter fast path** — `waitOn` compares the word in userspace first. If it
##     already differs from what the caller expected, the grant is already there:
##     return `wrNotEqual` having executed one atomic load and no syscall.
##   * **Waker fast path** — `wakeAll` / `wakeOne` read the waiter count in
##     userspace first. With no registered waiter there is nobody to wake:
##     return `wkNoWaiters` having executed one seq-cst fence, one atomic load and
##     NO syscall. The fence is what makes skipping the syscall sound rather than
##     merely cheap — see `waitOn`'s docstring — and it is not a syscall, so SM-2
##     is unaffected by it.
##
## Both are MEASURED, not asserted: `tests/test_shm_lease_waitword.nim` reads a
## kernel-maintained syscall counter (`shm_lease/syscount`) across a large batch of
## fast-path operations and requires the delta to be exactly zero, with a negative
## control in the same test that forces the syscall and requires the counter to
## move. See that file for the numbers.
##
## THE LAYOUT — 8 bytes, position independent, offsets only:
##
##   | offset | field     | meaning                                             |
##   |--------|-----------|-----------------------------------------------------|
##   | +0     | u32 value | the compared word; a waker BUMPS it to publish      |
##   | +4     | u32 waiters | number of parked waiters; what gates the wake syscall |
##
## Nothing here is an address, so a wait word is correct at whatever virtual base
## each process happens to map it (SM-7) — and the blocking still works across
## those differing bases, which is the property M3's gate exists to prove.
##
## PLATFORM SUPPORT (verified on this repo's host; see the capability record in
## `README.md`):
##
##   * **Linux** — `futex(FUTEX_WAIT / FUTEX_WAKE)` **without**
##     `FUTEX_PRIVATE_FLAG`. A shared futex keys on the underlying **inode +
##     offset**, not the virtual address, which is exactly what lets a file-backed
##     segment mapped at a different base in every process still block correctly.
##     The campaign says to ASSERT this rather than assume it, so `wsProcessLocal`
##     below exists purely so the gate can show that the private variant does NOT
##     wake across processes.
##   * **macOS 14.4+** — `os_sync_wait_on_address` / `os_sync_wake_by_address_any`
##     / `os_sync_wake_by_address_all` with `OS_SYNC_WAIT_ON_ADDRESS_SHARED`. The
##     symbols are **weak-imported** and checked at runtime, so a binary built
##     against a 14.4 SDK still runs on an older macOS and simply reports
##     `waitWordAvailable() == false` there.
##   * **Windows** — OUT OF SCOPE, deliberately. `WaitOnAddress` is documented as
##     working only within a process; a cross-process wake needs named kernel
##     objects. The gap is recorded in the capability record rather than silently
##     omitted, and Windows lands on the portable no-op arm below.
##
## THE PREFAULT HAZARD — MEASURED, NOT THEORETICAL. On macOS,
## `os_sync_wait_on_address` returns **`EFAULT` when the page holding the wait word
## has not yet been faulted into the CALLING process**, even though the mapping is
## valid and an ordinary load from it would succeed. This bites exactly where M3
## lives: a child that inherits or re-maps a segment across `fork` has a valid
## mapping with no populated PTE, so a park issued before any access to the word
## fails instantly instead of blocking — which reads as "the wait primitive does
## not work" rather than as a paging detail. Reproduced on Darwin 25.5 / arm64,
## 2026-07-31: an untouched `MAP_FIXED` mapping gives `EFAULT` immediately, and the
## SAME address after a single atomic load blocks and times out correctly.
## `waitOn` therefore touches the word before parking, and `parkRaw` exists so
## `tests/test_shm_lease_waitword.nim` can demonstrate the failure rather than
## leave the guard as an unfalsifiable comment.
##
## WHAT M3 IS NOT. There is no admission policy here, no arbiter, and no grant
## assignment. `RunQuota-Shared-Memory-Transport.md` §"4. Grant-then-wake, never
## wake-then-retry" requires the releasing party to ASSIGN capacity and wake only
## the waiters it granted; that is the flat-combining arbiter of M5, and this
## module is the blocking primitive it will be built on. What M3 does own is the
## rule that makes grant-then-wake implementable: **each waiter gets its own wait
## word** (a shared wait word reintroduces the thundering herd by construction),
## which is why `WaitSegment` below is an array of per-waiter slots rather than one
## global word.

const
  waitWordSupported* = defined(linux) or defined(macosx)
    ## Compile-time platform support. False on Windows and anywhere else, where the
    ## portable no-op arm reports unavailable rather than failing to build.

  WaitWordMinMacOsVersion* = "14.4"
    ## `os_sync_wait_on_address` and friends are public API since macOS 14.4
    ## (iOS/tvOS 17.4, watchOS 10.4). Recorded here, in the capability record in
    ## `README.md`, and enforced at RUNTIME by `waitWordAvailable()` — the symbols
    ## are weak-imported, so an older host reports unavailable instead of failing
    ## to launch.

  WaitWordBackend* =
    when defined(linux):
      "futex(FUTEX_WAIT/FUTEX_WAKE) without FUTEX_PRIVATE_FLAG"
    elif defined(macosx):
      "os_sync_wait_on_address / os_sync_wake_by_address_* with OS_SYNC_*_SHARED"
    else:
      "none — portable no-op arm"

  WaitWordSize* = 8
    ## Bytes occupied by one wait word: `value` (u32) then `waiters` (u32).
  WwOffValue* = 0
  WwOffWaiters* = 4

type
  WaitScope* = enum
    ## Which keying the primitive uses.
    ##
    ## `wsProcessLocal` is NOT an optimisation offered to callers — it is here so
    ## the gate can prove `wsShared` is load-bearing. The campaign requires the
    ## cross-process keying rule to be ASSERTED rather than assumed, and the way to
    ## assert it is to show that the process-local variant, at the same file offset
    ## in the same shared mapping, does NOT receive a cross-process wake.
    wsShared        ## futex without `FUTEX_PRIVATE_FLAG`; `OS_SYNC_*_SHARED`
    wsProcessLocal  ## `FUTEX_*_PRIVATE`; `OS_SYNC_WAIT_ON_ADDRESS_NONE`

  WaitResult* = enum
    wrNotEqual      ## FAST PATH: the word already differed — NO syscall was made
    wrWoken         ## returned from the kernel; MAY be spurious, so re-validate
    wrTimedOut      ## the bounded wait elapsed
    wrUnavailable   ## no primitive on this platform / OS version
    wrError         ## the wait syscall failed; see `waitWordLastErrno`

  WakeResult* = enum
    wkNoWaiters     ## FAST PATH: the word records no waiter — NO syscall was made
    wkWoke          ## the wake syscall was issued and found at least one waiter
    wkNobodyParked  ## the wake syscall WAS issued but found nobody inside the
                    ## kernel — a waiter had registered without having parked yet.
                    ## Distinguished from `wkNoWaiters` on purpose: one of these
                    ## costs a syscall and the other does not, and SM-2 is about
                    ## exactly that difference
    wkUnavailable
    wkError         ## the wake syscall failed; see `waitWordLastErrno`

var waitWordLastErrno* {.threadvar.}: cint
  ## `errno` captured by the C shim IMMEDIATELY after a failing wait/wake, so it
  ## cannot be clobbered by intervening Nim code. Diagnostic only.

# --- observability counters --------------------------------------------------
#
# These are a CROSS-CHECK, not the proof. SM-2 is proven by the kernel's own
# syscall counter (`shm_lease/syscount`); these say what this library BELIEVES it
# did, and a test that finds the two disagreeing has found a bug in one of them.
var
  wwFastWaits* {.threadvar.}: uint64   ## `waitOn` calls that returned without parking
  wwParks* {.threadvar.}: uint64       ## wait syscalls actually issued
  wwFastWakes* {.threadvar.}: uint64   ## wake calls that found no waiter
  wwWakeSyscalls* {.threadvar.}: uint64 ## wake syscalls actually issued

proc resetWaitWordCounters*() =
  wwFastWaits = 0; wwParks = 0; wwFastWakes = 0; wwWakeSyscalls = 0

when waitWordSupported:
  # `hooks` is imported HERE rather than at the top so the portable no-op arm does
  # not carry an unused import — `just lint`'s `nim check --os:windows` pass would
  # otherwise report it, and that cross-check exists precisely to keep the portable
  # arm clean rather than merely compiling.
  import ./hooks
  import std/[os, posix, times]

  type ShmBase = ptr UncheckedArray[byte]
    ## Deliberately NOT exported: `shm_lease` already exports a structurally
    ## identical `ShmBase`, and exporting a second one would make the name
    ## ambiguous for any module importing both. Callers pass the one from
    ## `shm_lease`; the two are the same type.

  # --- the platform shims ----------------------------------------------------
  #
  # Written as a C shim rather than a Nim `importc` of the raw entry points for
  # two reasons: on macOS the symbols must be WEAK-IMPORTED and NULL-checked at
  # run time (that is the whole macOS-14.4 story), and on both platforms `errno`
  # must be captured in the same C statement sequence as the failing call.

  when defined(macosx):
    {.emit: """/*TYPESECTION*/
#include <stdint.h>
#include <stddef.h>
#include <errno.h>

/* Declared here rather than via <os/os_sync_wait_on_address.h> so the weak import
   is explicit and independent of the SDK's deployment-target machinery. The ABI
   is the public one documented for macOS 14.4:
     int os_sync_wait_on_address(void *addr, uint64_t value, size_t size,
                                 os_sync_wait_on_address_flags_t flags);
   with os_sync_wait_on_address_flags_t == uint32_t and
   OS_SYNC_WAIT_ON_ADDRESS_SHARED == 1, OS_CLOCK_MACH_ABSOLUTE_TIME == 32. */
extern int os_sync_wait_on_address(void *, uint64_t, size_t, uint32_t)
  __attribute__((weak_import));
extern int os_sync_wait_on_address_with_timeout(void *, uint64_t, size_t,
  uint32_t, uint32_t, uint64_t) __attribute__((weak_import));
extern int os_sync_wake_by_address_any(void *, size_t, uint32_t)
  __attribute__((weak_import));
extern int os_sync_wake_by_address_all(void *, size_t, uint32_t)
  __attribute__((weak_import));

/* Runtime availability: on a host older than macOS 14.4 the weak symbols resolve
   to NULL and every operation reports unavailable instead of crashing. */
static int shmLeaseWwAvailable(void) {
  return (os_sync_wait_on_address != 0) &&
         (os_sync_wait_on_address_with_timeout != 0) &&
         (os_sync_wake_by_address_any != 0) &&
         (os_sync_wake_by_address_all != 0);
}

static int shmLeaseWwPark(void *addr, uint32_t value, long long timeoutNs,
                          int shared, int *errOut) {
  int rc;
  uint32_t flags = shared ? 1u : 0u;   /* OS_SYNC_WAIT_ON_ADDRESS_SHARED */
  *errOut = 0;
  if (!shmLeaseWwAvailable()) { *errOut = ENOTSUP; return -1; }
  errno = 0;
  if (timeoutNs > 0) {
    rc = os_sync_wait_on_address_with_timeout(addr, (uint64_t)value, 4, flags,
                                              32 /*OS_CLOCK_MACH_ABSOLUTE_TIME*/,
                                              (uint64_t)timeoutNs);
  } else {
    rc = os_sync_wait_on_address(addr, (uint64_t)value, 4, flags);
  }
  if (rc < 0) *errOut = errno;
  return rc;
}

static int shmLeaseWwWake(void *addr, int all, int shared, int *errOut) {
  int rc;
  uint32_t flags = shared ? 1u : 0u;   /* OS_SYNC_WAKE_BY_ADDRESS_SHARED */
  *errOut = 0;
  if (!shmLeaseWwAvailable()) { *errOut = ENOTSUP; return -1; }
  errno = 0;
  rc = all ? os_sync_wake_by_address_all(addr, 4, flags)
           : os_sync_wake_by_address_any(addr, 4, flags);
  if (rc < 0) *errOut = errno;
  return rc;
}
""".}
    let
      WwErrTimedOut = ETIMEDOUT
    const
      WwErrNoWaiters* = cint(2)   ## ENOENT: the wake found nobody parked
  else:
    {.emit: """/*TYPESECTION*/
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <limits.h>
#include <time.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <linux/futex.h>

static int shmLeaseWwAvailable(void) { return 1; }

/* FUTEX_WAIT / FUTEX_WAKE *without* FUTEX_PRIVATE_FLAG. This is the whole point:
   a shared futex keys on the underlying INODE + OFFSET rather than on the virtual
   address, so a file-backed segment mapped at a different base in every process
   still yields the same futex key -- which is what lets position independence
   (SM-7) and cross-process blocking coexist. The PRIVATE variant, keyed on
   (mm, address), is reachable only through `shared == 0` and exists so the gate
   can show it does NOT wake across processes. */
static int shmLeaseWwPark(void *addr, uint32_t value, long long timeoutNs,
                          int shared, int *errOut) {
  struct timespec ts;
  struct timespec *tp = 0;
  int op = shared ? FUTEX_WAIT : (FUTEX_WAIT | FUTEX_PRIVATE_FLAG);
  long rc;
  *errOut = 0;
  if (timeoutNs > 0) {
    ts.tv_sec = (time_t)(timeoutNs / 1000000000LL);
    ts.tv_nsec = (long)(timeoutNs % 1000000000LL);
    tp = &ts;
  }
  errno = 0;
  rc = syscall(SYS_futex, addr, op, (int)value, tp, (void *)0, 0);
  if (rc < 0) *errOut = errno;
  return (int)rc;
}

static int shmLeaseWwWake(void *addr, int all, int shared, int *errOut) {
  int op = shared ? FUTEX_WAKE : (FUTEX_WAKE | FUTEX_PRIVATE_FLAG);
  long rc;
  *errOut = 0;
  errno = 0;
  rc = syscall(SYS_futex, addr, op, all ? INT_MAX : 1, (void *)0, (void *)0, 0);
  if (rc < 0) *errOut = errno;
  return (int)rc;
}
""".}
    let
      WwErrTimedOut = ETIMEDOUT
    const
      WwErrNoWaiters* = cint(0)
        ## Linux `FUTEX_WAKE` reports "woke 0" as a SUCCESS (return 0), not an
        ## error, so there is no distinguished errno for "nobody was parked".

  proc shmLeaseWwAvailable(): cint {.importc: "shmLeaseWwAvailable", nodecl.}
  proc shmLeaseWwPark(adr: pointer; value: uint32; timeoutNs: int64;
    shared: cint; errOut: ptr cint): cint {.importc: "shmLeaseWwPark", nodecl.}
  proc shmLeaseWwWake(adr: pointer; all: cint; shared: cint;
    errOut: ptr cint): cint {.importc: "shmLeaseWwWake", nodecl.}

  proc waitWordAvailable*(): bool =
    ## RUNTIME availability. On macOS this is the `WaitWordMinMacOsVersion` check:
    ## the `os_sync_*` symbols are weak-imported, so on a host older than macOS
    ## 14.4 they resolve to NULL and this returns false — the binary still runs and
    ## the caller degrades, exactly as the portable arm does off Linux/macOS.
    shmLeaseWwAvailable() != 0

  # --- offset-addressed atomics ---------------------------------------------

  template atField(base: ShmBase; offset: int; T: typedesc): ptr T =
    cast[ptr T](addr base[offset])

  proc loadU32Acquire(base: ShmBase; off: int): uint32 {.inline.} =
    atomicLoadN(atField(base, off, uint32), ATOMIC_ACQUIRE)
  proc loadU32SeqCst(base: ShmBase; off: int): uint32 {.inline.} =
    atomicLoadN(atField(base, off, uint32), ATOMIC_SEQ_CST)
  proc storeU32Release(base: ShmBase; off: int; v: uint32) {.inline.} =
    atomicStoreN(atField(base, off, uint32), v, ATOMIC_RELEASE)
  proc addU32SeqCst(base: ShmBase; off: int; d: uint32): uint32 {.inline.} =
    atomicAddFetch(atField(base, off, uint32), d, ATOMIC_SEQ_CST)
  proc subU32SeqCst(base: ShmBase; off: int; d: uint32): uint32 {.inline.} =
    atomicSubFetch(atField(base, off, uint32), d, ATOMIC_SEQ_CST)
  proc loadU64Acquire(base: ShmBase; off: int): uint64 {.inline.} =
    atomicLoadN(atField(base, off, uint64), ATOMIC_ACQUIRE)
  proc loadU64Relaxed(base: ShmBase; off: int): uint64 {.inline.} =
    atomicLoadN(atField(base, off, uint64), ATOMIC_RELAXED)
  proc storeU64Relaxed(base: ShmBase; off: int; v: uint64) {.inline.} =
    atomicStoreN(atField(base, off, uint64), v, ATOMIC_RELAXED)
  proc storeU64Release(base: ShmBase; off: int; v: uint64) {.inline.} =
    atomicStoreN(atField(base, off, uint64), v, ATOMIC_RELEASE)
  proc loadU32Relaxed(base: ShmBase; off: int): uint32 {.inline.} =
    atomicLoadN(atField(base, off, uint32), ATOMIC_RELAXED)
  proc storeU32Relaxed(base: ShmBase; off: int; v: uint32) {.inline.} =
    atomicStoreN(atField(base, off, uint32), v, ATOMIC_RELAXED)

  proc fullFence() {.inline.} =
    ## The seq-cst fence of the store-buffering (Dekker) pair between a publisher's
    ## value bump and the waker's read of the waiter count. Deliberately spelled the
    ## same way as `src/shm_lease/obsring.nim`'s `fullFence`, which solves the
    ## structurally identical problem for its idle-token / `tail - head` pair: this
    ## module is adopting a pattern the library already contains, not inventing one.
    ##
    ## NOT exported, because `obsring` defines its own no-argument `fullFence` and
    ## two exported ones would be an ambiguous identifier at every import site.
    atomicThreadFence(ATOMIC_SEQ_CST)

  # --- the primitive ---------------------------------------------------------

  proc waitWordValue*(base: ShmBase; off: int): uint32 {.inline.} =
    ## Acquire-load the compared word. Pure userspace, always.
    loadU32Acquire(base, off + WwOffValue)

  proc waitWordWaiters*(base: ShmBase; off: int): uint32 {.inline.} =
    ## How many waiters are currently parked on this word. This is what gates the
    ## wake syscall, so it is the field that makes the waker's fast path possible.
    loadU32Relaxed(base, off + WwOffWaiters)

  proc prefaultWaitWord*(base: ShmBase; off: int) {.inline.} =
    ## Force the page holding the wait word to be faulted into THIS process.
    ##
    ## LOAD-BEARING ON macOS, not defensive. `os_sync_wait_on_address` returns
    ## `EFAULT` for an address whose page has not yet been touched by the calling
    ## process — which is precisely the state a child is in after `fork` + a fresh
    ## `MAP_FIXED` of the segment. Reproduced on Darwin 25.5 / arm64: the untouched
    ## mapping fails instantly with `EFAULT`, and the same address after one atomic
    ## RMW parks and times out correctly. `tests/test_shm_lease_waitword.nim`
    ## demonstrates both halves through `parkRaw`, so this is a measured hazard
    ## rather than a cautious comment.
    ##
    ## An RMW rather than a load, so the page is faulted in WRITABLE — the waiter
    ## is about to write the waiter count on the same page anyway.
    discard addU32SeqCst(base, off + WwOffWaiters, 0)

  proc parkRaw*(base: ShmBase; off: int; expected: uint32;
      timeoutNs: int64 = 0; scope: WaitScope = wsShared): WaitResult =
    ## The bare wait syscall: NO fast-path check, NO waiter registration, NO
    ## prefault. Exported for two reasons and no others — the gate needs to inject
    ## a park that is guaranteed to enter the kernel (so the syscall counter has
    ## something to count), and the prefault hazard above needs a way to be
    ## exhibited. Production callers want `waitOn`.
    scheduleHook(slpBeforeWaitPark)
    var err: cint = 0
    let rc = shmLeaseWwPark(addr base[off + WwOffValue], expected, timeoutNs,
      cint(if scope == wsShared: 1 else: 0), addr err)
    scheduleHook(slpAfterWaitPark)
    waitWordLastErrno = err
    if rc >= 0: return wrWoken
    if err == WwErrTimedOut: return wrTimedOut
    if err == EAGAIN or err == EINTR: return wrWoken
    wrError

  proc wakeRaw*(base: ShmBase; off: int; all: bool = true;
      scope: WaitScope = wsShared): WakeResult =
    ## The bare wake syscall, issued UNCONDITIONALLY — it does not consult the
    ## waiter count, so it always enters the kernel.
    ##
    ## Exported so the gate can (a) give the syscall counter a known-nonzero
    ## control to measure against the fast path's zero, and (b) inject SPURIOUS
    ## WAKEUPS: a wake delivered while the value is unchanged is exactly the event
    ## every one of these primitives is permitted to manufacture, and the waiter
    ## must survive it. Production callers want `wakeAll` / `wakeOne`.
    scheduleHook(slpBeforeWakeSyscall)
    var err: cint = 0
    let rc = shmLeaseWwWake(addr base[off + WwOffValue],
      cint(if all: 1 else: 0), cint(if scope == wsShared: 1 else: 0), addr err)
    scheduleHook(slpAfterWakeSyscall)
    waitWordLastErrno = err
    inc wwWakeSyscalls
    when defined(linux):
      # FUTEX_WAKE returns the NUMBER of waiters woken and reports "nobody was
      # parked" as a successful 0, not as an errno. `rc >= 0` therefore called
      # every wake `wkWoke`, including the ones that found the kernel empty --
      # collapsing the two outcomes this type exists to keep apart. The count
      # is right there in the return value; use it.
      if rc > 0: return wkWoke
      if rc == 0: return wkNobodyParked
    else:
      if rc >= 0: return wkWoke
      if err == WwErrNoWaiters and err != 0: return wkNobodyParked
    wkError

  proc waitOn*(base: ShmBase; off: int; expected: uint32;
      timeoutNs: int64 = 0; scope: WaitScope = wsShared): WaitResult =
    ## Block until the word differs from `expected`, a wake arrives, or the bounded
    ## timeout elapses. `timeoutNs <= 0` means block indefinitely.
    ##
    ## THE FAST PATH (SM-2): if the word already differs, this performs ONE atomic
    ## load and returns `wrNotEqual` — no syscall, no waiter registration, no
    ## contention on the waiter count. That is the uncontended case, and it is the
    ## case the design exists to make cheap.
    ##
    ## THE SLOW PATH: register as a waiter, RE-CHECK, and only then park.
    ##
    ## BE PRECISE ABOUT WHAT THE RE-CHECK DOES. It is a SYSCALL-AVOIDANCE step, not
    ## the lost-wakeup guard: a waker that publishes between the first check and the
    ## registration is caught by the KERNEL's compare-and-park, which is atomic and
    ## returns immediately when the word no longer holds `expected`. That is the
    ## defining property of a futex-class primitive, and
    ## `tests/test_shm_lease_hooks.nim` drives exactly that interleaving through the
    ## `slpBeforeWaitPark` seam — publishing with NO wake syscall at all and
    ## requiring the waiter to come back anyway.
    ##
    ## What the WAKER's fast path needs is a different guarantee, and it is worth
    ## being exact about where it comes from — an earlier version of this docstring
    ## was not, and the imprecision was a real defect rather than a wording nit.
    ##
    ## The shape is store-buffering (SB). The waker stores the value and then loads
    ## `waiters`; the waiter increments `waiters` and then reads the value. The bad
    ## outcome is BOTH sides missing the other: the waker reads `waiters == 0` and
    ## skips the wake syscall while the waiter reads the OLD value and parks — and
    ## nothing recovers it, because the kernel's compare-and-park re-reads that same
    ## stale value, and no instruction the waiter's core executes can drain another
    ## core's store buffer.
    ##
    ## THE ORDERING IS PROVIDED BY AN EXPLICIT SEQ-CST FENCE IN `wakeAll` /
    ## `wakeOne`, immediately before the load of `waiters`. It is NOT provided by
    ## sequential consistency across the pair: the value store is `ATOMIC_RELEASE`,
    ## not seq-cst, so there is no single total order containing it, and herd7 finds
    ## the lost wakeup ALLOWED under C11 and under x86-TSO for the unfenced form
    ## (`verification/litmus/grant-bump-vs-waiters{,-x86}.litmus`). ARMv8's RCsc
    ## `STLR`/`LDAR` pair forbade it, which is the only reason the unfenced code
    ## never misbehaved on the arm64 host it was developed on. The fenced form is
    ## required Forbidden under all three models
    ## (`grant-bump-vs-waiters-FENCED-fix`, `-x86-FENCED`, `-aarch64-FENCED`).
    ##
    ## THE WAITER SIDE NEEDS NO FENCE, and one is deliberately not added. Its
    ## `addU32SeqCst` is a seq-cst read-modify-write — a `LOCK`ed instruction on x86
    ## and `LDADDAL` (or an `LDAXR`/`STLXR` loop) on ARM64 — which already orders the
    ## increment against the following load of the value. herd7 confirms it: the
    ## fenced-publisher/unfenced-waiter pair, exactly as shipped, is Forbidden under
    ## C11, x86-TSO and AArch64. A second fence here would cost the SLOW path an
    ## instruction to buy nothing, and an unjustified barrier is the next reader's
    ## invitation to remove the justified one with it.
    ##
    ## SPURIOUS WAKEUPS ARE GUARANTEED by every primitive behind this call, so
    ## `wrWoken` means "look again", never "your grant is ready". Callers MUST
    ## re-validate; `awaitValueChange` below is the canonical loop.
    if loadU32Acquire(base, off + WwOffValue) != expected:
      inc wwFastWaits
      return wrNotEqual                      # ONE atomic load; no syscall
    scheduleHook(slpBeforeWaiterRegister)
    discard addU32SeqCst(base, off + WwOffWaiters, 1)
    scheduleHook(slpAfterWaiterRegister)
    if loadU32SeqCst(base, off + WwOffValue) != expected:
      discard subU32SeqCst(base, off + WwOffWaiters, 1)
      inc wwFastWaits
      return wrNotEqual                      # still no syscall
    inc wwParks
    result = parkRaw(base, off, expected, timeoutNs, scope)
    discard subU32SeqCst(base, off + WwOffWaiters, 1)

  proc wakeAll*(base: ShmBase; off: int; scope: WaitScope = wsShared): WakeResult =
    ## Wake every waiter parked on this word.
    ##
    ## THE FAST PATH (SM-2): with no registered waiter this performs one atomic
    ## load and returns `wkNoWaiters` — no syscall. That matters more than it
    ## looks: the uncontended case is the common one, and a wake that entered the
    ## kernel unconditionally would reinstate the per-operation syscall this whole
    ## design removes. (Measured: an unconditional `os_sync_wake_by_address_all`
    ## with nobody parked still costs a full syscall and returns `ENOENT` — which
    ## this wrapper reports as `wkNobodyParked`, distinct from the syscall-free
    ## `wkNoWaiters`.)
    ##
    ## THE FENCE IS WHAT MAKES SKIPPING THE SYSCALL SOUND, and it is here rather
    ## than at the call sites on purpose: the *decision* to skip is taken on the
    ## next line, so the precondition for that decision — that everything this
    ## thread published before calling is globally visible before `waiters` is read
    ## — is enforced where it is relied upon. See `waitOn`'s docstring for the
    ## store-buffering shape it excludes and `verification/litmus/` for the herd7
    ## verdicts that pin it.
    fullFence()
    if loadU32SeqCst(base, off + WwOffWaiters) == 0:
      inc wwFastWakes
      return wkNoWaiters
    wakeRaw(base, off, all = true, scope = scope)

  proc wakeOne*(base: ShmBase; off: int; scope: WaitScope = wsShared): WakeResult =
    ## Wake at most one waiter. This is the shape M5's grant-then-wake needs: the
    ## arbiter assigns capacity to a specific waiter and wakes only that waiter, so
    ## wakes never exceed grants (SM-3) and no herd forms.
    ##
    ## Same fence, same reason as `wakeAll` — and it matters MORE here, because M5
    ## reaches this path once per grant.
    fullFence()
    if loadU32SeqCst(base, off + WwOffWaiters) == 0:
      inc wwFastWakes
      return wkNoWaiters
    wakeRaw(base, off, all = false, scope = scope)

  proc publishValue*(base: ShmBase; off: int; v: uint32) {.inline.} =
    ## Release-store the compared word. Everything the publisher wrote BEFORE this
    ## call is visible to a waiter that acquire-loads the word afterwards, which is
    ## what lets a grant payload ride alongside the wait word without a second
    ## synchronisation step.
    scheduleHook(slpBeforeWakePublish)
    storeU32Release(base, off + WwOffValue, v)

  proc bumpAndWake*(base: ShmBase; off: int; scope: WaitScope = wsShared): WakeResult =
    ## Publish "something changed" (bump the word) and then wake. The bump is what
    ## makes the waiter's fast path work: a waiter that arrives after the bump
    ## observes a different value and never parks at all.
    ##
    ## The release store below and the `waiters` load inside `wakeAll` are the
    ## store-buffering pair `waitOn`'s docstring describes; the seq-cst fence that
    ## separates them lives inside `wakeAll`, so it cannot be lost by a caller that
    ## assembles the same two steps itself.
    let cur = loadU32Relaxed(base, off + WwOffValue)
    publishValue(base, off, cur + 1)
    wakeAll(base, off, scope)

  proc awaitValueChange*(base: ShmBase; off: int; lastSeen: uint32;
      timeoutNs: int64 = 0; scope: WaitScope = wsShared;
      parks: ptr int = nil): WaitResult =
    ## The canonical waiter loop: block until the word differs from `lastSeen`,
    ## RE-VALIDATING after every wake because spurious wakeups are permitted by
    ## every primitive under this call. `parks`, when non-nil, accumulates how many
    ## times the loop actually entered the kernel — which is how the gate shows a
    ## spurious wake was survived (it re-parks) rather than silently mistaken for a
    ## grant.
    ##
    ## Note that the timeout applies PER PARK, not to the loop as a whole; a caller
    ## that needs a deadline should re-derive the remaining time itself. The gate
    ## uses a generous per-park timeout purely so a wedged run fails loudly instead
    ## of hanging a CI job.
    prefaultWaitWord(base, off)
    while true:
      if loadU32Acquire(base, off + WwOffValue) != lastSeen:
        return wrNotEqual
      let r = waitOn(base, off, lastSeen, timeoutNs, scope)
      if not parks.isNil and r != wrNotEqual: inc parks[]
      case r
      of wrNotEqual: return wrNotEqual
      of wrWoken: discard          # spurious or real — the loop re-validates
      else: return r

  # ===========================================================================
  # A file-backed segment of PER-WAITER wait slots.
  # ===========================================================================
  #
  # `RunQuota-Shared-Memory-Transport.md` §"4. Grant-then-wake": "Each waiter MUST
  # have its own result slot and its own wait word. A shared wait word
  # reintroduces the herd by construction." So the segment is an ARRAY of slots
  # from the start, even though M3 only proves block/wake on one of them.
  #
  # The engineering playbook is the same one M2 established and the design spec
  # requires: file-backed `mmap(MAP_SHARED)`, offsets only, publish-before-write,
  # boot-id + pid + start-time anchoring.

  import ./anchor

  const
    WaitSegMagic* = 0x534C_5741_4954_01'u64   ## "SLWAIT" — a shm_lease wait segment
    WaitSegFormatVersion* = 1'u32
    MaxWaitSlots* = 4096

    # header, 64 bytes; every 8-byte field on an 8-byte boundary
    WsOffMagic* = 0
    WsOffFormatVersion* = 8
    WsOffFlags* = 12
    WsOffBootId* = 16
    WsOffOwnerPid* = 24
    WsOffOwnerStartTime* = 32
    WsOffSlotCount* = 40
    WsOffSlotsOff* = 48
    WsOffSegmentSize* = 56
    WaitSegHeaderSize* = 64

    # one slot, 32 bytes
    WslOffValue* = 0        ## u32 — the wait word's compared value (a grant seq)
    WslOffWaiters* = 4      ## u32 — the wait word's waiter count
    WslOffPayload* = 8      ## u64 — the grant, published BEFORE the value bump
    WslOffReserved1* = 16   ## u64 reserved (M5: per-waiter result slot)
    WslOffReserved2* = 24   ## u64 reserved (M7: owner anchor / deadline)
    WaitSlotSize* = 32

  proc pageSize*(): int {.inline.} =
    ## The host page size, asked rather than assumed.
    ##
    ## M2 hard-coded 4096 in two places and paid for it: pages are 16 KiB on Apple
    ## Silicon, so a `MAP_FIXED` probe strided by 4096 produced a silent `EINVAL`
    ## for every base that was not a multiple of 4. That hazard is carried forward
    ## into M3 by the milestone's `:notes:` precisely because this module's gate has
    ## the same differing-bases requirement. `leaseSegmentSize` in M2 still rounds
    ## to 4 KiB (its `:deferred:` (9), which wants a format bump); this NEW segment
    ## has no such compatibility constraint, so it is page-sized correctly from the
    ## start.
    let ps = int(sysconf(SC_PAGESIZE))
    if ps > 0: ps else: 4096

  proc waitSegmentSize*(slotCount: int): int =
    let raw = WaitSegHeaderSize + slotCount * WaitSlotSize
    let ps = pageSize()
    ((raw + ps - 1) div ps) * ps

  type
    WaitSegment* = object
      ## An attached view of a wait-slot segment. `available` is false after any
      ## create/attach failure, so a caller degrades rather than faulting.
      available*: bool
      isOwner*: bool
      path*: string
      base*: ShmBase
      size*: int
      fd: cint
      slotCount*: int
      slotsOff*: int

  proc mapFd(fd: cint; size: int; wantBase: pointer): ShmBase =
    ## `MAP_FIXED` when `wantBase` is non-nil — the caller must have reserved the
    ## range (typically one pre-`fork` `PROT_NONE` region). This is a first-class
    ## API for the same reason it is in M2: "blocking still works across differing
    ## bases" is only PROVABLE if the test can choose the bases, and two forked
    ## children both calling `mmap(nil, ...)` would very likely land at the same
    ## address and prove nothing.
    if wantBase != nil:
      let pf = mmap(wantBase, size, PROT_READ or PROT_WRITE,
        MAP_SHARED or MAP_FIXED, fd, 0)
      if pf == MAP_FAILED: return nil
      return cast[ShmBase](pf)
    let p = mmap(nil, size, PROT_READ or PROT_WRITE, MAP_SHARED, fd, 0)
    if p == MAP_FAILED: return nil
    cast[ShmBase](p)

  proc waitSegHeaderValid(base: ShmBase; boot: uint64; size: int): bool =
    if loadU64Acquire(base, WsOffMagic) != WaitSegMagic: return false
    if atomicLoadN(atField(base, WsOffFormatVersion, uint32), ATOMIC_ACQUIRE) !=
       WaitSegFormatVersion: return false
    if loadU64Relaxed(base, WsOffBootId) != boot: return false
    let n = loadU64Relaxed(base, WsOffSlotCount)
    if n == 0 or n > uint64(MaxWaitSlots): return false
    if loadU64Relaxed(base, WsOffSlotsOff) != uint64(WaitSegHeaderSize): return false
    if WaitSegHeaderSize + int(n) * WaitSlotSize > size: return false
    if loadU64Relaxed(base, WsOffSegmentSize) != uint64(size): return false
    true

  proc createWaitSegment*(path: string; slotCount: int): WaitSegment =
    ## PUBLISH-BEFORE-WRITE, exactly as `createLeaseSegment` does it: build under a
    ## unique temp name, write every field, release-store the magic LAST, and only
    ## then `rename` into the final name. The instant the final name resolves, the
    ## contents are complete.
    result.available = false
    result.isOwner = true
    result.fd = -1
    result.path = path
    if slotCount <= 0 or slotCount > MaxWaitSlots: return
    let size = waitSegmentSize(slotCount)
    let boot = bootId()
    try:
      let dir = parentDir(path)
      if dir.len > 0: createDir(dir)
    except CatchableError: return
    let uniq = int(epochTime() * 1_000_000) mod 1_000_000
    let tmp = path & ".tmp." & $getpid() & "." & $uniq
    let tfd = open(tmp.cstring, O_RDWR or O_CREAT or O_EXCL, 0o600)
    if tfd < 0: return
    if ftruncate(tfd, Off(size)) != 0:
      discard close(tfd); discard unlink(tmp.cstring); return
    let base = mapFd(tfd, size, nil)
    if base.isNil:
      discard close(tfd); discard unlink(tmp.cstring); return
    storeU32Relaxed(base, WsOffFlags, 0)
    storeU64Relaxed(base, WsOffSlotCount, uint64(slotCount))
    storeU64Relaxed(base, WsOffSlotsOff, uint64(WaitSegHeaderSize))
    storeU64Relaxed(base, WsOffSegmentSize, uint64(size))
    for i in 0 ..< slotCount:
      let off = WaitSegHeaderSize + i * WaitSlotSize
      storeU32Relaxed(base, off + WslOffValue, 0)
      storeU32Relaxed(base, off + WslOffWaiters, 0)
      storeU64Relaxed(base, off + WslOffPayload, 0)
      storeU64Relaxed(base, off + WslOffReserved1, 0)
      storeU64Relaxed(base, off + WslOffReserved2, 0)
    scheduleHook(slpBeforeAnchorPublish)
    storeU64Relaxed(base, WsOffBootId, boot)
    storeU64Relaxed(base, WsOffOwnerPid, uint64(getpid()))
    storeU64Relaxed(base, WsOffOwnerStartTime, processStartTime(int(getpid())))
    atomicStoreN(atField(base, WsOffFormatVersion, uint32), WaitSegFormatVersion,
      ATOMIC_RELEASE)
    scheduleHook(slpBeforeMagicPublish)
    storeU64Release(base, WsOffMagic, WaitSegMagic)
    discard munmap(cast[pointer](base), size)
    discard close(tfd)
    scheduleHook(slpBeforeSegmentRename)
    try:
      moveFile(tmp, path)
    except OSError:
      discard unlink(tmp.cstring); return
    scheduleHook(slpAfterSegmentRename)
    let fd = open(path.cstring, O_RDWR)
    if fd < 0: return
    let mapped = mapFd(fd, size, nil)
    if mapped.isNil:
      discard close(fd); return
    if not waitSegHeaderValid(mapped, boot, size):
      discard munmap(cast[pointer](mapped), size); discard close(fd); return
    result.base = mapped
    result.size = size
    result.fd = fd
    result.slotCount = slotCount
    result.slotsOff = WaitSegHeaderSize
    result.available = true

  proc attachWaitSegment*(path: string; wantBase: pointer = nil): WaitSegment =
    ## Attach to an existing segment, optionally forcing the mapping to `wantBase`
    ## with `MAP_FIXED`. Never creates and never repairs: a missing file, a wrong
    ## size, or a stale header (wrong magic, wrong format version, wrong boot id)
    ## yields an unavailable segment.
    result.available = false
    result.isOwner = false
    result.fd = -1
    result.path = path
    if not fileExists(path): return
    var size = 0
    try: size = int(getFileSize(path))
    except CatchableError: return
    if size < WaitSegHeaderSize + WaitSlotSize: return
    let fd = open(path.cstring, O_RDWR)
    if fd < 0: return
    let base = mapFd(fd, size, wantBase)
    if base.isNil:
      discard close(fd); return
    if not waitSegHeaderValid(base, bootId(), size):
      discard munmap(cast[pointer](base), size); discard close(fd); return
    result.base = base
    result.size = size
    result.fd = fd
    result.slotCount = int(loadU64Relaxed(base, WsOffSlotCount))
    result.slotsOff = int(loadU64Relaxed(base, WsOffSlotsOff))
    result.available = true

  proc detach*(s: var WaitSegment) =
    if not s.base.isNil:
      discard munmap(cast[pointer](s.base), s.size)
      s.base = nil
    if s.fd > 0: discard close(s.fd)
    s.fd = -1
    s.size = 0
    s.available = false

  proc slotOffset*(s: WaitSegment; slot: int): int {.inline.} =
    ## Byte offset of a slot's wait word. An OFFSET, never an address — which is
    ## what lets every process address the same slot from its own base.
    s.slotsOff + slot * WaitSlotSize

  proc mappedBase*(s: WaitSegment): pointer {.inline.} = cast[pointer](s.base)
  proc ownerPid*(s: WaitSegment): uint64 =
    if not s.available: 0'u64 else: loadU64Relaxed(s.base, WsOffOwnerPid)
  proc ownerVerdict*(s: WaitSegment): AnchorVerdict =
    if not s.available: return avNoOwner
    anchorVerdict(loadU64Relaxed(s.base, WsOffBootId),
      loadU64Relaxed(s.base, WsOffOwnerPid),
      loadU64Relaxed(s.base, WsOffOwnerStartTime))

  proc slotValue*(s: WaitSegment; slot: int): uint32 {.inline.} =
    waitWordValue(s.base, s.slotOffset(slot))
  proc slotWaiters*(s: WaitSegment; slot: int): uint32 {.inline.} =
    waitWordWaiters(s.base, s.slotOffset(slot))
  proc slotPayload*(s: WaitSegment; slot: int): uint64 {.inline.} =
    loadU64Acquire(s.base, s.slotOffset(slot) + WslOffPayload)

  proc publishGrant*(s: WaitSegment; slot: int; payload: uint64;
      scope: WaitScope = wsShared): WakeResult =
    ## Publish a grant into a waiter's own slot and wake that waiter.
    ##
    ## ORDER MATTERS: the payload is stored first, then the wait word is bumped
    ## with a RELEASE store, so a waiter that acquire-loads the changed word is
    ## guaranteed to see the payload that went with it. And the wake comes AFTER
    ## the publish, never before — a waiter woken before its grant exists would
    ## have to re-check and sleep again, which is the wake-then-retry pattern the
    ## design spec calls a defect rather than a strategy.
    if not s.available: return wkUnavailable
    if slot < 0 or slot >= s.slotCount: return wkUnavailable
    let off = s.slotOffset(slot)
    storeU64Relaxed(s.base, off + WslOffPayload, payload)
    let cur = loadU32Relaxed(s.base, off + WslOffValue)
    publishValue(s.base, off, cur + 1)
    wakeAll(s.base, off, scope)

  proc awaitGrant*(s: WaitSegment; slot: int; lastSeen: uint32;
      timeoutNs: int64 = 0; scope: WaitScope = wsShared;
      parks: ptr int = nil): WaitResult =
    ## Block until this slot's wait word moves off `lastSeen`, re-validating after
    ## every wake. Read the payload with `slotPayload` AFTER this returns
    ## `wrNotEqual`.
    if not s.available: return wrUnavailable
    if slot < 0 or slot >= s.slotCount: return wrUnavailable
    awaitValueChange(s.base, s.slotOffset(slot), lastSeen, timeoutNs, scope, parks)

  proc storedPointerCheck*(s: WaitSegment): bool =
    ## Position-independence audit: no 8-byte-aligned word in the live part of the
    ## segment may fall inside THIS mapping's address window, which is what a
    ## leaked absolute pointer would look like. Heuristic, exactly as M2's is — the
    ## primary proof is the differing-bases gate.
    if not s.available: return false
    let lo = cast[uint](s.base)
    let hi = lo + uint(s.size)
    let liveEnd = s.slotsOff + s.slotCount * WaitSlotSize
    var off = 0
    while off + 8 <= liveEnd:
      let w = uint(loadU64Relaxed(s.base, off))
      if w >= lo and w < hi: return false
      off += 8
    true

else:
  # --- portable no-op arm ----------------------------------------------------
  #
  # Compiles everywhere, reports unavailable everywhere. WINDOWS LANDS HERE, and
  # deliberately: `WaitOnAddress` is documented as working only within a process,
  # so a cross-process wake needs named kernel objects. The campaign puts that
  # explicitly out of scope for M3 and requires the gap to be RECORDED rather than
  # silently omitted — see the capability record in `README.md`. Note the
  # asymmetry worth keeping in mind when Windows is eventually taken up: the fast
  # path (no wait) still costs zero syscalls there, and it is only the WAKE that
  # needs the named object.
  type
    ShmBase = ptr UncheckedArray[byte]
    WaitSegment* = object
      available*: bool
      isOwner*: bool
      path*: string
      base*: ShmBase
      size*: int
      slotCount*: int
      slotsOff*: int

  const
    WaitSegMagic* = 0x534C_5741_4954_01'u64
    WaitSegFormatVersion* = 1'u32
    MaxWaitSlots* = 4096
    WaitSegHeaderSize* = 64
    WaitSlotSize* = 32
    WslOffValue* = 0
    WslOffWaiters* = 4
    WslOffPayload* = 8
    WslOffReserved1* = 16
    WslOffReserved2* = 24
    WwErrNoWaiters* = cint(0)

  proc waitWordAvailable*(): bool = false
  proc pageSize*(): int = 4096
  proc waitSegmentSize*(slotCount: int): int =
    WaitSegHeaderSize + slotCount * WaitSlotSize
  proc waitWordValue*(base: ShmBase; off: int): uint32 = 0
  proc waitWordWaiters*(base: ShmBase; off: int): uint32 = 0
  proc prefaultWaitWord*(base: ShmBase; off: int) = discard
  proc parkRaw*(base: ShmBase; off: int; expected: uint32;
    timeoutNs: int64 = 0; scope: WaitScope = wsShared): WaitResult = wrUnavailable
  proc wakeRaw*(base: ShmBase; off: int; all: bool = true;
    scope: WaitScope = wsShared): WakeResult = wkUnavailable
  proc waitOn*(base: ShmBase; off: int; expected: uint32;
    timeoutNs: int64 = 0; scope: WaitScope = wsShared): WaitResult = wrUnavailable
  proc wakeAll*(base: ShmBase; off: int;
    scope: WaitScope = wsShared): WakeResult = wkUnavailable
  proc wakeOne*(base: ShmBase; off: int;
    scope: WaitScope = wsShared): WakeResult = wkUnavailable
  proc publishValue*(base: ShmBase; off: int; v: uint32) = discard
  proc bumpAndWake*(base: ShmBase; off: int;
    scope: WaitScope = wsShared): WakeResult = wkUnavailable
  proc awaitValueChange*(base: ShmBase; off: int; lastSeen: uint32;
    timeoutNs: int64 = 0; scope: WaitScope = wsShared;
    parks: ptr int = nil): WaitResult = wrUnavailable
  proc createWaitSegment*(path: string; slotCount: int): WaitSegment =
    WaitSegment(available: false, isOwner: true, path: path, slotCount: slotCount)
  proc attachWaitSegment*(path: string; wantBase: pointer = nil): WaitSegment =
    WaitSegment(available: false, path: path)
  proc detach*(s: var WaitSegment) = discard
  proc slotOffset*(s: WaitSegment; slot: int): int =
    WaitSegHeaderSize + slot * WaitSlotSize
  proc mappedBase*(s: WaitSegment): pointer = nil
  proc ownerPid*(s: WaitSegment): uint64 = 0
  proc slotValue*(s: WaitSegment; slot: int): uint32 = 0
  proc slotWaiters*(s: WaitSegment; slot: int): uint32 = 0
  proc slotPayload*(s: WaitSegment; slot: int): uint64 = 0
  proc publishGrant*(s: WaitSegment; slot: int; payload: uint64;
    scope: WaitScope = wsShared): WakeResult = wkUnavailable
  proc awaitGrant*(s: WaitSegment; slot: int; lastSeen: uint32;
    timeoutNs: int64 = 0; scope: WaitScope = wsShared;
    parks: ptr int = nil): WaitResult = wrUnavailable
  proc storedPointerCheck*(s: WaitSegment): bool = true
