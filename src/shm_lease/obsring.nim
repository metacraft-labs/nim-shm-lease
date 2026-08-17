## `nim-shm-lease` **M4** — the OBSERVATION RING: a bounded multi-producer /
## single-consumer channel carrying execution observations from clients to the
## RunQuota daemon, in its **own segment**, with **counted** drops and a consumer
## that **never polls**.
##
## Design authority, in order of precedence:
##   * `reprobuild-specs/RunQuota-Shared-Memory-Structures.md` — THE FORMAT AND
##     ALGORITHM CONTRACT: the conventions every segment obeys (position
##     independence, publish-before-write, anchoring, format versioning, page-size
##     awareness, schedule hooks, portable no-op arm) and §"Structures Not Yet
##     Built", which is this structure.
##   * `reprobuild-specs/RunQuota-Shared-Memory-Transport.md` §"The Observation
##     Ring" (the requirements) and §"Waiting Without Spinning".
##   * `reprobuild-specs/RunQuota-Observation-Store.md` §"Write Path" and
##     §"Capture completeness" (what the ring carries, and why a drop must be
##     visible).
##   * campaign milestone `RunQuota-Observation-Store.milestones.org` ** M4, whose
##     gate lives in `tests/test_shm_lease_obs_multiprocess.nim`.
##
## WHY A RING AND NOT A SET. `nim-shm-gset` dedups at the source, which is right
## for path probes and FATAL for events: two executions of the same test are two
## facts, not one. The ring preserves multiplicity. That argument is the transport
## spec's; it is restated here only because it is the reason this module exists at
## all rather than a reuse of the sibling library.
##
## WHAT IT RIDES. The coordination protocol is NOT reimplemented here: the
## ticket-CAS reservation, the release-store publish, the single-consumer drain and
## the atomic SIGNALLED drop counter all come from `nim-shm-queue`'s Layer 1
## (`shm_queue/ring`), through its `EmbeddedRing` view — the shape it already
## provides for "a caller who owns a shared region and wants the same MPSC ring as a
## sub-structure at a fixed byte offset", which is exactly reprobuild's action-cache
## control region and now exactly this. So there is one MPSC implementation in the
## organisation, not two, and this module owns only what is genuinely new:
##
##   1. the SEGMENT (header, anchoring, publish-before-write, page-aware sizing);
##   2. the WAIT WORD and the SIGNALLING RULE that keep the consumer off the CPU;
##   3. the COMPLETENESS accounting that makes a truncated window un-presentable
##      as a complete one.
##
## ------------------------------------------------------------------------------
## THE FIVE RULES THIS MODULE EXISTS TO ENFORCE
## ------------------------------------------------------------------------------
##
## **1. Publishing never blocks, never fsyncs, never fails an execution (OS-1).**
## `publish` is a ticket CAS, a `memcpy` and a release store. On a full ring it does
## NOT wait for a slot: it bumps the ring's atomic drop counter and returns
## `oprDropped`. Losing an observation is always preferable to perturbing the work
## being observed, so there is no `opBlockProducer` arm here even though the
## substrate offers one — that policy is right for io-mon's dependency queue, whose
## records are load-bearing, and wrong for observations, which are advisory.
##
## **2. Publishing adds no round trip.** There is no reply, no acknowledgement and
## no handle to wait on. A producer never learns that its observation was accepted
## by the daemon; it learns only whether the ring took the bytes.
##
## **3. Drops are counted AND surfaced (OS-2).** `droppedCount` is the ring's
## kernel-of-the-matter number and `windowCompleteness` turns it into a verdict:
## a window across which the drop counter moved is `ccTruncated` and MUST NOT be
## presented as complete. A thinned sample presented as complete is worse than no
## data, because it reads as authoritative.
##
## **4. The consumer never polls.** An idle consumer blocks on the wait word (M3's
## primitive, `shm_lease/waitword`). A quiet ring therefore costs ZERO consumer
## wakeups and zero CPU — see `awaitRecord`.
##
## **5. Producers signal only on the empty-to-non-empty transition.** Signalling on
## every append would reinstate the per-observation syscall this whole design exists
## to remove. That is a GATE, not an optimisation, and it is measured by counting
## wake syscalls rather than asserted.
##
## ------------------------------------------------------------------------------
## THE SIGNALLING RULE, STATED PRECISELY (and why the obvious form is WRONG)
## ------------------------------------------------------------------------------
##
## The obvious implementation of "signal on the empty-to-non-empty transition" is to
## snapshot `tail - head` before appending and signal when the snapshot was zero.
## **That is a lost wakeup.** Consider two producers and a consumer:
##
##   1. P2 reads `tail - head` and observes the ring NON-empty, so it has already
##      decided not to signal;
##   2. the consumer drains everything, observes the ring empty, and parks;
##   3. P2 appends — and the consumer sleeps on a non-empty ring.
##
## Nothing in that sequence is exotic; it is the ordinary case where a producer is
## slightly ahead of its own append. So the emptiness test is taken from the party
## that actually knows: **the consumer publishes an IDLE TOKEN before it sleeps, and
## a producer signals only if it CLAIMS that token.** The token is the consumer's own
## statement "I have seen the ring empty and I am about to sleep" — the
## empty-to-non-empty condition, asserted by the only party in a position to assert
## it correctly.
##
## Claiming is a CAS from 1 to 0, so **exactly one producer signals per transition**
## however many are appending. That is strictly stronger than a plain "is anybody
## waiting" test, which lets every producer inside the wake-latency window issue its
## own redundant syscall: measured at ELEVEN signals for a single transition under a
## 5000-append burst before the token existed, and exactly one after.
##
## That leaves exactly one race, and it is closed the same way M3's is — by a
## SEQ-CST STORE/LOAD PAIR (a Dekker pattern) on both sides, with an explicit
## seq-cst fence rather than relying on the ordering that a particular CAS mapping
## happens to give:
##
##   producer: publish the record   ... FENCE(seq_cst) ... load the idle token
##   consumer: store the idle token ... FENCE(seq_cst) ... load `tail - head`
##
## In the single total order the fences impose, at least one of the two loads must
## observe the other side's store: either the producer sees the token and wakes the
## consumer, or the consumer sees the pending record and does not park. And even if
## both were to fail, the KERNEL's atomic compare-and-park is a second guard — the
## consumer parks against the wait-word VALUE it read, and a signal that bumps that
## value between the check and the park makes the park return immediately instead of
## sleeping. `tests/test_shm_lease_hooks.nim` drives exactly that interleaving
## through the `slpBeforeObsConsumerPark` seam.
##
## The cost of the rule on the hot path is one seq-cst fence and one 32-bit load —
## no syscall, and no contention with other producers (the token shares the wait
## word's cache line, which is a line away from the ring's `tail`).
##
## ------------------------------------------------------------------------------
## THE SEGMENT — offsets only, position independent (SM-7)
## ------------------------------------------------------------------------------
##
## Its OWN segment, format version 1. M3 established that pattern for the wait
## segment and the structures spec generalises it: a ring-format change must not be
## able to destabilise admission, so the observation ring shares no bytes with the
## lease segment and its format version moves independently.
##
##   | offset | size | contents                                                  |
##   |--------|------|-----------------------------------------------------------|
##   | 0      | 128  | header (magic written LAST, release; anchors; geometry)   |
##   | 128    | 64   | the consumer's WAIT WORD, on its own cache line          |
##   | 192    | ...  | the embedded `shm_queue` ring: header then `capacity` slots|
##
## Nothing in the segment is an address, so every process may map it at a different
## virtual base and the wake still lands (M3's inode+offset keying rule). The total
## size is rounded to the HOST page size via `sysconf(_SC_PAGESIZE)` — never 4096,
## which is 16 KiB on Apple Silicon and is the hazard that bit M2 and is carried
## forward through M3's and M4's `:notes:`.
##
## ------------------------------------------------------------------------------
## NO DAEMON ATTACHED
## ------------------------------------------------------------------------------
##
## The ring is usable with no consumer. `publish` never consults consumer liveness —
## that would put a `kill(2)` probe on the hot path — so with nobody draining, a
## client simply fills the ring and then drops, and every drop is counted. A client
## that wants the standalone-mode fallback (append to the local store directly) asks
## `consumerVerdict` / `consumerAttached` OUT OF BAND, at whatever cadence it likes.
## A missing daemon is never an error and never fails a run (OS-4).

# `hooks` and `waitword` are imported INSIDE the supported branch rather than here,
# so the portable arm carries no unused import — `just lint`'s `nim check
# --os:windows` pass would otherwise report one, and that cross-check exists
# precisely to keep the portable arm clean rather than merely compiling.
import ./anchor

const obsRingSupported* = defined(linux) or defined(macosx)
  ## Compile-time platform support. Windows and anything else land on the portable
  ## no-op arm at the bottom of this file: everything compiles, everything reports
  ## unavailable, and a consumer degrades rather than failing to build.

const
  ObsRingBackend* =
    when obsRingSupported:
      "shm_queue Layer 1 embedded ring + shm_lease wait word"
    else:
      "none — portable no-op arm"

  ObsSegMagic* = 0x534C_4F42_5352_01'u64   ## "SLOBSR" — a shm_lease observation ring
  ObsSegFormatVersion* = 1'u32
    ## Bumped on ANY change to the layout below. Per-segment, and deliberately
    ## independent of the lease and wait segments' versions.

  # --- header (128 bytes) ----------------------------------------------------
  ObsOffMagic* = 0              ## u64, written LAST with release ordering
  ObsOffFormatVersion* = 8      ## u32
  ObsOffFlags* = 12             ## u32, reserved
  ObsOffBootId* = 16            ## u64 — anchor
  ObsOffOwnerPid* = 24          ## u64 — anchor
  ObsOffOwnerStartTime* = 32    ## u64 — anchor; defeats pid reuse
  ObsOffCapacity* = 40          ## u64 — ring slots (power of two)
  ObsOffMaxRecordLen* = 48      ## u64 — bytes per record
  ObsOffWaitOff* = 56           ## u64 — byte offset of the consumer wait word
  ObsOffRingOff* = 64           ## u64 — byte offset of the embedded ring header
  ObsOffSegmentSize* = 72       ## u64
  ObsOffSignals* = 80           ## u64 — empty-to-non-empty signals issued
  ObsOffConsumerPid* = 88       ## u64 — 0 when no daemon has attached
  ObsOffConsumerBoot* = 96      ## u64
  ObsOffConsumerStart* = 104    ## u64
  ObsOffReserved1* = 112        ## u64 — reserved
  ObsOffReserved2* = 120        ## u64 — reserved
  ObsHeaderSize* = 128

  ObsWaitOff* = 128
    ## The consumer's wait word (`u32 value` + `u32 waiters`, M3's layout), on its
    ## OWN 64-byte line. Producers read the idle token below on every append and CAS
    ## `tail` on every append; putting the two in one line would make the signalling
    ## check contend with the reservation it is supposed to be free of.
  ObsOffIdle* = ObsWaitOff + 8
    ## u32 IDLE TOKEN. 1 means "the consumer has observed the ring empty and is
    ## parking"; a producer CASes it 1 -> 0 to CLAIM the empty-to-non-empty
    ## transition, so exactly one producer signals per transition.
  ObsWaitBlockSize* = 64
  ObsRingOff* = ObsWaitOff + ObsWaitBlockSize   ## 192

  MaxObsCapacity* = 1 shl 20
  MaxObsRecordLen* = 1 shl 16

  # --- the optional record TAG ----------------------------------------------
  #
  # "Extension payloads ride the same ring, tagged with `extension_id` and
  # `schema_version`, OPAQUE TO THE TRANSPORT" (transport spec). Opaque is the
  # operative word: the ring neither reads nor validates the tag. These helpers
  # exist so the two clients agree on where the tag lives without the ring
  # acquiring an opinion about what follows it.
  ObsTagSize* = 8
  ObsTagOffExtensionId* = 0     ## u32
  ObsTagOffSchemaVersion* = 4   ## u16
  ObsTagOffKind* = 6            ## u16

type
  ObsPublishResult* = enum
    ## What one append did. NONE of these is a failure of the execution being
    ## observed; a caller that treats any of them as fatal has violated OS-1.
    oprPublished    ## appended, and signalled iff the consumer was idle
    oprDropped      ## the ring was full: SIGNALLED drop, the counter moved
    oprOversize     ## longer than `maxRecordLen`; the ring is UNCHANGED and this
                    ## is NOT counted as a drop — it is a caller bug, not pressure
    oprUnavailable  ## no segment attached (portable arm, or attach failed)

  ObsDrainResult* = enum
    odrEmpty        ## nothing to drain, or the head slot is not yet published
    odrGot          ## a record was copied into the caller's buffer
    odrOverflowBuf  ## the caller's buffer is smaller than the stored record

  ObsWaitResult* = enum
    owrReady        ## the ring is non-empty — drain it
    owrTimedOut     ## the bounded wait elapsed with the ring still empty
    owrUnavailable  ## no wait primitive here, or no segment attached

  CaptureCompleteness* = enum
    ## OS-2 in one type. A window is complete only if the drop counter did not move
    ## across it; anything else is `ccTruncated` and MUST be recorded as such.
    ccComplete
    ccTruncated

  ObsTag* = object
    extensionId*: uint32
    schemaVersion*: uint16
    kind*: uint16

# --- tag helpers (pure, available on every arm) -------------------------------

proc encodeObsTag*(buf: var openArray[byte]; tag: ObsTag): bool =
  ## Write the 8-byte tag prefix into the caller's buffer. The caller assembles
  ## `tag ++ payload` in its OWN buffer and then calls `publish`, so the hot path
  ## still allocates nothing and the transport still copies exactly once.
  if buf.len < ObsTagSize: return false
  let e = tag.extensionId
  buf[ObsTagOffExtensionId + 0] = byte(e and 0xFF)
  buf[ObsTagOffExtensionId + 1] = byte((e shr 8) and 0xFF)
  buf[ObsTagOffExtensionId + 2] = byte((e shr 16) and 0xFF)
  buf[ObsTagOffExtensionId + 3] = byte((e shr 24) and 0xFF)
  buf[ObsTagOffSchemaVersion + 0] = byte(tag.schemaVersion and 0xFF)
  buf[ObsTagOffSchemaVersion + 1] = byte((tag.schemaVersion shr 8) and 0xFF)
  buf[ObsTagOffKind + 0] = byte(tag.kind and 0xFF)
  buf[ObsTagOffKind + 1] = byte((tag.kind shr 8) and 0xFF)
  true

proc decodeObsTag*(buf: openArray[byte]; tag: var ObsTag): bool =
  ## Read the tag prefix back. Returns false for a buffer too short to hold one —
  ## the ring does not validate tags, so this is the consumer's own check.
  if buf.len < ObsTagSize: return false
  tag.extensionId = uint32(buf[ObsTagOffExtensionId + 0]) or
    (uint32(buf[ObsTagOffExtensionId + 1]) shl 8) or
    (uint32(buf[ObsTagOffExtensionId + 2]) shl 16) or
    (uint32(buf[ObsTagOffExtensionId + 3]) shl 24)
  tag.schemaVersion = uint16(buf[ObsTagOffSchemaVersion + 0]) or
    (uint16(buf[ObsTagOffSchemaVersion + 1]) shl 8)
  tag.kind = uint16(buf[ObsTagOffKind + 0]) or
    (uint16(buf[ObsTagOffKind + 1]) shl 8)
  true

when obsRingSupported:
  import ./hooks
  import ./waitword
  import std/[os, posix, times]
  from shm_queue/ring import EmbeddedRing, initEmbeddedRing, resetEmbeddedRing,
    tryPush, tryDrainOne, PushResult, DrainResult, prPushed, prDropped,
    prOversize, prConsumerGone, drEmpty, drGot, drOverflowBuf, embeddedRingSize,
    embeddedRingHeaderSize
  from shm_queue/segment import RingOffTail, RingOffHead, RingOffDropped

  type ShmBase = ptr UncheckedArray[byte]
    ## Deliberately NOT exported, for the reason `waitword` gives: `shm_lease`
    ## already exports a structurally identical `ShmBase` and a second exported one
    ## would make the name ambiguous. The two are the same type.

  # --- offset-addressed atomics ---------------------------------------------

  template atField(base: ShmBase; offset: int; T: typedesc): ptr T =
    cast[ptr T](addr base[offset])

  proc loadU64Acquire(base: ShmBase; off: int): uint64 {.inline.} =
    atomicLoadN(atField(base, off, uint64), ATOMIC_ACQUIRE)
  proc loadU64Relaxed(base: ShmBase; off: int): uint64 {.inline.} =
    atomicLoadN(atField(base, off, uint64), ATOMIC_RELAXED)
  proc storeU64Relaxed(base: ShmBase; off: int; v: uint64) {.inline.} =
    atomicStoreN(atField(base, off, uint64), v, ATOMIC_RELAXED)
  proc storeU64Release(base: ShmBase; off: int; v: uint64) {.inline.} =
    atomicStoreN(atField(base, off, uint64), v, ATOMIC_RELEASE)
  proc addU64SeqCst(base: ShmBase; off: int; d: uint64): uint64 {.inline.} =
    atomicAddFetch(atField(base, off, uint64), d, ATOMIC_SEQ_CST)
  proc loadU32Acquire(base: ShmBase; off: int): uint32 {.inline.} =
    atomicLoadN(atField(base, off, uint32), ATOMIC_ACQUIRE)
  proc loadU32SeqCst(base: ShmBase; off: int): uint32 {.inline.} =
    atomicLoadN(atField(base, off, uint32), ATOMIC_SEQ_CST)
  proc storeU32Relaxed(base: ShmBase; off: int; v: uint32) {.inline.} =
    atomicStoreN(atField(base, off, uint32), v, ATOMIC_RELAXED)
  proc storeU32Release(base: ShmBase; off: int; v: uint32) {.inline.} =
    atomicStoreN(atField(base, off, uint32), v, ATOMIC_RELEASE)
  proc addU32SeqCst(base: ShmBase; off: int; d: uint32): uint32 {.inline.} =
    atomicAddFetch(atField(base, off, uint32), d, ATOMIC_SEQ_CST)
  proc subU32SeqCst(base: ShmBase; off: int; d: uint32): uint32 {.inline.} =
    atomicSubFetch(atField(base, off, uint32), d, ATOMIC_SEQ_CST)
  proc storeU32SeqCst(base: ShmBase; off: int; v: uint32) {.inline.} =
    atomicStoreN(atField(base, off, uint32), v, ATOMIC_SEQ_CST)
  proc casU32(base: ShmBase; off: int; expected: uint32; desired: uint32): bool {.inline.} =
    var exp = expected
    atomicCompareExchangeN(atField(base, off, uint32), addr exp, desired,
      false, ATOMIC_SEQ_CST, ATOMIC_SEQ_CST)

  proc fullFence() {.inline.} =
    ## The seq-cst fence of the Dekker pair described in this module's header. It is
    ## written explicitly rather than left to whatever ordering the CAS mapping
    ## happens to provide, because "the compiler emitted a barrier there on this
    ## architecture" is not a memory-model argument and ARM64 is exactly where that
    ## reasoning fails.
    atomicThreadFence(ATOMIC_SEQ_CST)

  # --- geometry --------------------------------------------------------------

  # THE BORROWED GEOMETRY IS PINNED. Everything from `ObsRingOff` onwards is
  # `nim-shm-queue`'s Layer-1 layout, which this segment's format version cannot
  # speak for: a change to the embedded ring header or the slot stride would
  # silently change what an `ObsSegFormatVersion == 1` segment means. Asserting the
  # borrowed constants here turns that into a BUILD failure — at which point the
  # right response is to bump `ObsSegFormatVersion`, not to update the numbers.
  static:
    doAssert embeddedRingHeaderSize() == 24,
      "shm_queue's embedded ring header changed size; bump ObsSegFormatVersion"
    doAssert embeddedRingSize(4, 48) == 24 + 4 * 64,
      "shm_queue's slot stride changed; bump ObsSegFormatVersion"

  proc obsSegmentSize*(capacity, maxRecordLen: int): int =
    ## Page-rounded total size. `pageSize()` comes from `waitword` and asks
    ## `sysconf(_SC_PAGESIZE)` rather than assuming 4096 (16 KiB on Apple Silicon).
    let raw = ObsRingOff + embeddedRingSize(capacity, maxRecordLen)
    let ps = pageSize()
    ((raw + ps - 1) div ps) * ps

  type
    ObsRing* = object
      ## An attached view of an observation-ring segment. `available` is false after
      ## any create/attach failure, so a caller degrades instead of faulting.
      available*: bool
      isOwner*: bool
      path*: string
      base*: ShmBase
      size*: int
      fd: cint
      capacity*: int
      maxRecordLen*: int
      waitOff*: int
      ring*: EmbeddedRing

  proc mapFd(fd: cint; size: int; wantBase: pointer): ShmBase =
    ## `MAP_FIXED` when `wantBase` is non-nil. A first-class API for the same reason
    ## it is one in M2 and M3: "correct at a different virtual base in every
    ## process" is only PROVABLE if the test can choose the bases, and two forked
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

  proc obsHeaderValid(base: ShmBase; boot: uint64; size: int): bool =
    ## Validated on attach with ACQUIRE loads. A consumer that does not recognise
    ## the format version REFUSES rather than interpreting unknown bytes.
    if loadU64Acquire(base, ObsOffMagic) != ObsSegMagic: return false
    if loadU32Acquire(base, ObsOffFormatVersion) != ObsSegFormatVersion: return false
    if loadU64Relaxed(base, ObsOffBootId) != boot: return false
    let cap = loadU64Relaxed(base, ObsOffCapacity)
    if cap == 0 or cap > uint64(MaxObsCapacity): return false
    if (cap and (cap - 1)) != 0: return false        # power of two: `mod` is a mask
    let mrl = loadU64Relaxed(base, ObsOffMaxRecordLen)
    if mrl == 0 or mrl > uint64(MaxObsRecordLen): return false
    if loadU64Relaxed(base, ObsOffWaitOff) != uint64(ObsWaitOff): return false
    if loadU64Relaxed(base, ObsOffRingOff) != uint64(ObsRingOff): return false
    if loadU64Relaxed(base, ObsOffSegmentSize) != uint64(size): return false
    if ObsRingOff + embeddedRingSize(int(cap), int(mrl)) > size: return false
    true

  proc createObsRing*(path: string; capacity, maxRecordLen: int): ObsRing =
    ## OWNER (daemon) side: create + map a fresh segment.
    ##
    ## PUBLISH-BEFORE-WRITE, the convention every segment in this campaign obeys:
    ## the segment is built under a unique temp name, every field is written, the
    ## magic is release-stored LAST, and only then is it `rename`d into place. A
    ## reader that observes the magic has, by that release, observed everything
    ## written before it; a crash before the rename leaves nothing discoverable.
    result.available = false
    result.isOwner = true
    result.fd = -1
    result.path = path
    if capacity <= 0 or capacity > MaxObsCapacity: return
    if (capacity and (capacity - 1)) != 0: return   # power of two (ticket masking)
    if maxRecordLen <= 0 or maxRecordLen > MaxObsRecordLen: return
    let size = obsSegmentSize(capacity, maxRecordLen)
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
    storeU32Relaxed(base, ObsOffFlags, 0)
    storeU64Relaxed(base, ObsOffCapacity, uint64(capacity))
    storeU64Relaxed(base, ObsOffMaxRecordLen, uint64(maxRecordLen))
    storeU64Relaxed(base, ObsOffWaitOff, uint64(ObsWaitOff))
    storeU64Relaxed(base, ObsOffRingOff, uint64(ObsRingOff))
    storeU64Relaxed(base, ObsOffSegmentSize, uint64(size))
    storeU64Relaxed(base, ObsOffSignals, 0)
    storeU64Relaxed(base, ObsOffConsumerPid, 0)
    storeU64Relaxed(base, ObsOffConsumerBoot, 0)
    storeU64Relaxed(base, ObsOffConsumerStart, 0)
    storeU64Relaxed(base, ObsOffReserved1, 0)
    storeU64Relaxed(base, ObsOffReserved2, 0)
    storeU32Relaxed(base, ObsWaitOff + WwOffValue, 0)
    storeU32Relaxed(base, ObsWaitOff + WwOffWaiters, 0)
    storeU32Relaxed(base, ObsOffIdle, 0)
    resetEmbeddedRing(initEmbeddedRing(base, ObsRingOff, capacity, maxRecordLen))
    scheduleHook(slpBeforeAnchorPublish)
    storeU64Relaxed(base, ObsOffBootId, boot)
    storeU64Relaxed(base, ObsOffOwnerPid, uint64(getpid()))
    storeU64Relaxed(base, ObsOffOwnerStartTime, processStartTime(int(getpid())))
    storeU32Release(base, ObsOffFormatVersion, ObsSegFormatVersion)
    scheduleHook(slpBeforeMagicPublish)
    storeU64Release(base, ObsOffMagic, ObsSegMagic)
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
    if not obsHeaderValid(mapped, boot, size):
      discard munmap(cast[pointer](mapped), size); discard close(fd); return
    result.base = mapped
    result.size = size
    result.fd = fd
    result.capacity = capacity
    result.maxRecordLen = maxRecordLen
    result.waitOff = ObsWaitOff
    result.ring = initEmbeddedRing(mapped, ObsRingOff, capacity, maxRecordLen)
    result.available = true

  proc attachObsRing*(path: string; wantBase: pointer = nil): ObsRing =
    ## PRODUCER (or a restarted consumer) side. NEVER creates and never repairs: a
    ## missing file, a wrong size, an unrecognised format version or a stale boot id
    ## yields an unavailable ring, and the caller degrades — a client whose daemon
    ## has not started yet must not race a half-initialised segment into existence.
    ##
    ## The geometry is read back from the header, so an attacher never has to agree
    ## with the creator out of band.
    result.available = false
    result.isOwner = false
    result.fd = -1
    result.path = path
    if not fileExists(path): return
    var size = 0
    try: size = int(getFileSize(path))
    except CatchableError: return
    if size <= ObsRingOff: return
    let fd = open(path.cstring, O_RDWR)
    if fd < 0: return
    let base = mapFd(fd, size, wantBase)
    if base.isNil:
      discard close(fd); return
    if not obsHeaderValid(base, bootId(), size):
      discard munmap(cast[pointer](base), size); discard close(fd); return
    result.base = base
    result.size = size
    result.fd = fd
    result.capacity = int(loadU64Relaxed(base, ObsOffCapacity))
    result.maxRecordLen = int(loadU64Relaxed(base, ObsOffMaxRecordLen))
    result.waitOff = int(loadU64Relaxed(base, ObsOffWaitOff))
    result.ring = initEmbeddedRing(base, int(loadU64Relaxed(base, ObsOffRingOff)),
      result.capacity, result.maxRecordLen)
    result.available = true

  proc detach*(r: var ObsRing) =
    if not r.base.isNil:
      discard munmap(cast[pointer](r.base), r.size)
      r.base = nil
    if r.fd > 0: discard close(r.fd)
    r.fd = -1
    r.size = 0
    r.available = false

  proc mappedBase*(r: ObsRing): pointer {.inline.} = cast[pointer](r.base)

  # --- accounting ------------------------------------------------------------

  proc acceptedCount*(r: ObsRing): uint64 {.inline.} =
    ## Records the ring ACCEPTED (the ticket counter). `accepted + dropped` is what
    ## the producers offered; `accepted - pending` is what the consumer has taken.
    if not r.available: return 0
    loadU64Acquire(r.base, ObsRingOff + RingOffTail)

  proc drainedCount*(r: ObsRing): uint64 {.inline.} =
    ## Records the consumer has retired (the consumer-owned head ticket).
    if not r.available: return 0
    loadU64Acquire(r.base, ObsRingOff + RingOffHead)

  proc droppedCount*(r: ObsRing): uint64 {.inline.} =
    ## SIGNALLED ring-full drops, from `nim-shm-queue`'s atomic counter. This is the
    ## number OS-2 is about: it is what makes a truncated window admit to being
    ## truncated instead of presenting as complete.
    if not r.available: return 0
    loadU64Acquire(r.base, ObsRingOff + RingOffDropped)

  proc pendingCount*(r: ObsRing): uint64 {.inline.} =
    ## Reserved-but-not-yet-drained tickets. Bounded by `capacity`.
    if not r.available: return 0
    loadU64Acquire(r.base, ObsRingOff + RingOffTail) -
      loadU64Acquire(r.base, ObsRingOff + RingOffHead)

  proc signalCount*(r: ObsRing): uint64 {.inline.} =
    ## How many empty-to-non-empty signals have been issued. The instrument for the
    ## "signal only on the transition" gate that does not need a syscall counter —
    ## and the one that still works on Linux, where no cheap in-process syscall
    ## counter exists.
    if not r.available: return 0
    loadU64Acquire(r.base, ObsOffSignals)

  proc consumerIdle*(r: ObsRing): bool {.inline.} =
    ## Is the consumer's idle token published — i.e. has the consumer observed the
    ## ring empty and committed to sleeping? Observability only: producers use the
    ## CAS in `publish`, never this. Tests use it to establish the precondition the
    ## signalling rule is defined against instead of sleeping and hoping.
    if not r.available: return false
    loadU32Acquire(r.base, ObsOffIdle) != 0

  proc windowCompleteness*(r: ObsRing; dropsAtWindowStart: uint64): CaptureCompleteness =
    ## OS-2, as a verdict rather than a number a caller may forget to look at. A
    ## window across which the drop counter moved is TRUNCATED, and a truncated
    ## window must never be recorded as complete: statistics over a silently
    ## thinned sample are worse than absent statistics, because they read as
    ## authoritative.
    if not r.available: return ccTruncated   # unknown loss is not completeness
    if r.droppedCount() > dropsAtWindowStart: ccTruncated else: ccComplete

  # --- consumer identity (standalone-mode support) ---------------------------

  proc registerConsumer*(r: ObsRing) =
    ## Publish this process as the draining daemon, with the campaign's full anchor
    ## (boot id + pid + process START TIME), so a producer asking whether a daemon
    ## is attached cannot be fooled by pid reuse.
    if not r.available: return
    storeU64Relaxed(r.base, ObsOffConsumerBoot, bootId())
    storeU64Relaxed(r.base, ObsOffConsumerStart, processStartTime(int(getpid())))
    storeU64Release(r.base, ObsOffConsumerPid, uint64(getpid()))

  proc deregisterConsumer*(r: ObsRing) =
    ## Clean shutdown. Producers keep publishing (and keep counting drops); they do
    ## not fail, and they are not told.
    if not r.available: return
    storeU64Release(r.base, ObsOffConsumerPid, 0)

  proc consumerVerdict*(r: ObsRing): AnchorVerdict =
    ## Which anchor check fired, rather than a boolean — the same reason M2 gives:
    ## reclamation and diagnostics must be able to log WHY, and `avPidReused` is a
    ## different fact from `avOwnerGone`.
    ##
    ## Deliberately NOT called by `publish`: consulting it costs a `kill(2)` probe,
    ## and putting a syscall on the observation hot path is precisely the thing this
    ## module exists to avoid. A client polls it out of band to decide whether to
    ## use standalone mode.
    if not r.available: return avNoOwner
    anchorVerdict(loadU64Relaxed(r.base, ObsOffConsumerBoot),
      loadU64Acquire(r.base, ObsOffConsumerPid),
      loadU64Relaxed(r.base, ObsOffConsumerStart))

  proc consumerAttached*(r: ObsRing): bool {.inline.} =
    r.consumerVerdict() == avLive

  # --- the producer hot path -------------------------------------------------

  proc signalConsumer(r: ObsRing) {.inline.} =
    ## Bump the wait word and wake. The bump is what makes a consumer that arrives
    ## AFTER it take the fast path and never park at all; the wake is gated inside
    ## `wakeAll` on the waiter count, so it costs a syscall only when somebody is
    ## genuinely parked.
    scheduleHook(slpBeforeObsSignal)
    discard addU64SeqCst(r.base, ObsOffSignals, 1)
    discard bumpAndWake(r.base, r.waitOff)

  proc publish*(r: ObsRing; rec: openArray[byte]): ObsPublishResult =
    ## THE HOT PATH. One ticket CAS, one `memcpy`, one release store, one seq-cst
    ## fence and one 32-bit load. No syscall, no fsync, no blocking, no reply, and
    ## no way to fail the execution being observed (OS-1).
    ##
    ## On a full ring this DROPS and the ring's atomic drop counter moves
    ## (`oprDropped`). It does not wait for a slot: the substrate offers a
    ## block-on-full policy and it is deliberately not used here, because blocking a
    ## monitored process to preserve an advisory record inverts the priority this
    ## whole component exists to enforce.
    if not r.available: return oprUnavailable
    scheduleHook(slpBeforeObsPublish)
    let pr = r.ring.tryPush(rec)
    scheduleHook(slpAfterObsPublish)
    case pr
    of prOversize: return oprOversize
    of prDropped: return oprDropped
    of prConsumerGone: return oprDropped    # unreachable: this ring is drop-on-full
    of prPushed: discard
    # THE SIGNALLING RULE. See this module's header for why the emptiness test is
    # the consumer's idle token rather than a `tail - head` snapshot: only the
    # consumer knows it has decided to sleep, and a producer's own emptiness
    # snapshot is a lost wakeup waiting to happen. The CAS makes the claim
    # exclusive, so a burst of producers issues ONE signal between them.
    fullFence()
    if loadU32SeqCst(r.base, ObsOffIdle) != 0 and casU32(r.base, ObsOffIdle, 1, 0):
      r.signalConsumer()
    oprPublished

  proc publishForcedSignal*(r: ObsRing; rec: openArray[byte]): ObsPublishResult =
    ## THE NEGATIVE CONTROL, exported for the gate and for nothing else: the naive
    ## implementation that signals on EVERY append, which the transport spec names
    ## explicitly as the thing that "would restore the syscall this design removes".
    ##
    ## It exists so the "signal only on the empty-to-non-empty transition" claim is
    ## measured against something rather than asserted: under an identical workload
    ## this arm makes one wake syscall per append and `publish` makes one per
    ## transition, and the two numbers are counted with the KERNEL's own counter.
    if not r.available: return oprUnavailable
    let pr = r.ring.tryPush(rec)
    case pr
    of prOversize: return oprOversize
    of prDropped: return oprDropped
    of prConsumerGone: return oprDropped
    of prPushed: discard
    scheduleHook(slpBeforeObsSignal)
    discard addU64SeqCst(r.base, ObsOffSignals, 1)
    let cur = waitWordValue(r.base, r.waitOff)
    publishValue(r.base, r.waitOff, cur + 1)
    discard wakeRaw(r.base, r.waitOff)      # UNCONDITIONAL: always a syscall
    oprPublished

  # --- the consumer ----------------------------------------------------------

  proc drainOne*(r: ObsRing; outBuf: var openArray[byte];
      outLen: var int): ObsDrainResult =
    ## SINGLE-consumer drain of the next ready ticket. A slot a producer is still
    ## writing reads as `odrEmpty` and is retried, never returned as garbage — that
    ## is the substrate's release-store publish protocol, and it is why "no torn
    ## records" is a property of the structure rather than of a checksum.
    outLen = 0
    if not r.available: return odrEmpty
    case r.ring.tryDrainOne(outBuf, outLen)
    of drEmpty: odrEmpty
    of drGot: odrGot
    of drOverflowBuf: odrOverflowBuf

  proc awaitRecord*(r: ObsRing; timeoutNs: int64 = 0;
      parks: ptr int = nil): ObsWaitResult =
    ## BLOCK until the ring is non-empty. **This is the whole "consumer MUST NOT
    ## poll" requirement in one procedure**: an idle consumer is parked in the
    ## kernel, consuming no CPU and costing zero wakeups, until a producer's
    ## empty-to-non-empty signal arrives.
    ##
    ## The protocol, and every step of it is load-bearing:
    ##
    ##   1. if the ring is already non-empty, return — NO syscall (the common case
    ##      for a busy daemon, and the reason a backlog costs nothing);
    ##   2. read the wait word's value;
    ##   3. publish the IDLE TOKEN and register as a waiter (both seq-cst) — this is
    ##      the consumer telling every producer "I have seen the ring empty and I am
    ##      about to sleep", and the token is what the signalling rule keys on;
    ##   4. FENCE, then re-check the ring: a record published before the token
    ##      became visible must not be slept through;
    ##   5. re-check the value: a signal that landed between 2 and 3 must not be
    ##      slept through either;
    ##   6. park against the value read in 2. The KERNEL's atomic compare-and-park
    ##      is the final guard — a signal landing between 5 and 6 bumps the value
    ##      and the park returns immediately rather than sleeping.
    ##
    ## `parks`, when non-nil, accumulates how many times the loop actually entered
    ## the kernel. That is the number the idle gate asserts is ZERO over a
    ## multi-second quiet window, and a polling implementation could not produce it.
    if not r.available: return owrUnavailable
    if not waitWordAvailable(): return owrUnavailable
    # THE PREFAULT (M4's carried-forward hazard). On macOS a park on a page this
    # process has not touched fails INSTANTLY with EFAULT, which reads as "the
    # primitive does not work" rather than as a paging detail. This consumer reaches
    # for `parkRaw` directly — the case M3's note says MUST prefault itself.
    #
    # BE HONEST ABOUT WHAT THIS CALL IS WORTH HERE: it is BELT AND BRACES, not the
    # guard. Removing it was mutation-tested and changed NOTHING, because the wait
    # word is faulted in three times over before any park — `attachObsRing` reads the
    # header magic, which is on the SAME page (asserted structurally in
    # `tests/test_shm_lease_obsring.nim`), and steps 2 and 3 below load the value and
    # RMW the waiter count. The call stays because it makes the requirement explicit
    # and survives a future reordering of those steps; the claim that it is
    # load-bearing here would be false, and M3's record says such a claim must be
    # checked by mutation rather than assumed.
    prefaultWaitWord(r.base, r.waitOff)
    while true:
      if r.pendingCount() > 0: return owrReady        # step 1 — no syscall
      let v = waitWordValue(r.base, r.waitOff)        # step 2
      scheduleHook(slpBeforeObsIdlePublish)
      storeU32SeqCst(r.base, ObsOffIdle, 1)                       # step 3
      discard addU32SeqCst(r.base, r.waitOff + WwOffWaiters, 1)
      fullFence()                                     # step 4 — the Dekker pair
      if r.pendingCount() > 0:
        discard subU32SeqCst(r.base, r.waitOff + WwOffWaiters, 1)
        storeU32SeqCst(r.base, ObsOffIdle, 0)
        return owrReady
      if loadU32SeqCst(r.base, r.waitOff + WwOffValue) != v:      # step 5
        discard subU32SeqCst(r.base, r.waitOff + WwOffWaiters, 1)
        storeU32SeqCst(r.base, ObsOffIdle, 0)
        continue
      scheduleHook(slpBeforeObsConsumerPark)
      let wr = parkRaw(r.base, r.waitOff, v, timeoutNs)           # step 6
      discard subU32SeqCst(r.base, r.waitOff + WwOffWaiters, 1)
      storeU32SeqCst(r.base, ObsOffIdle, 0)
      if not parks.isNil: inc parks[]
      case wr
      of wrTimedOut:
        if r.pendingCount() > 0: return owrReady
        return owrTimedOut
      of wrUnavailable, wrError:
        return owrUnavailable
      else:
        discard   # woken (possibly spuriously): the loop re-validates

  proc storedPointerCheck*(r: ObsRing): bool =
    ## Position-independence audit: no 8-byte-aligned word in the header, the wait
    ## block or the ring header may fall inside THIS mapping's address window, which
    ## is what a leaked absolute pointer would look like. A HEURISTIC, exactly as
    ## M2's and M3's are (a record payload could in principle collide with an
    ## address, which is why the slot area is excluded and why the primary proof is
    ## the differing-bases gate).
    if not r.available: return false
    let lo = cast[uint](r.base)
    let hi = lo + uint(r.size)
    var off = 0
    while off + 8 <= ObsRingOff + 24:
      let w = uint(loadU64Relaxed(r.base, off))
      if w >= lo and w < hi: return false
      off += 8
    true

else:
  # --- portable no-op arm ------------------------------------------------------
  #
  # Compiles everywhere, reports unavailable everywhere. WINDOWS LANDS HERE, and the
  # gap is RECORDED rather than silently omitted: `just lint` cross-checks this arm
  # with `nim check --os:windows`, so the "reports unavailable elsewhere" promise
  # cannot bit-rot. See the structures spec §Windows for the destination — a
  # file-backed `CreateFileMappingW` region plus per-slot named auto-reset events,
  # with the 64 KiB ALLOCATION GRANULARITY (not the page size) governing any fixed
  # base.
  type
    ShmBase = ptr UncheckedArray[byte]
    ObsRing* = object
      available*: bool
      isOwner*: bool
      path*: string
      base*: ShmBase
      size*: int
      capacity*: int
      maxRecordLen*: int
      waitOff*: int

  proc obsSegmentSize*(capacity, maxRecordLen: int): int =
    ObsRingOff + 24 + capacity * (16 + maxRecordLen)
  proc createObsRing*(path: string; capacity, maxRecordLen: int): ObsRing =
    ObsRing(available: false, isOwner: true, path: path, capacity: capacity,
      maxRecordLen: maxRecordLen, waitOff: ObsWaitOff)
  proc attachObsRing*(path: string; wantBase: pointer = nil): ObsRing =
    ObsRing(available: false, path: path, waitOff: ObsWaitOff)
  proc detach*(r: var ObsRing) = discard
  proc mappedBase*(r: ObsRing): pointer = nil
  proc acceptedCount*(r: ObsRing): uint64 = 0
  proc drainedCount*(r: ObsRing): uint64 = 0
  proc droppedCount*(r: ObsRing): uint64 = 0
  proc pendingCount*(r: ObsRing): uint64 = 0
  proc signalCount*(r: ObsRing): uint64 = 0
  proc windowCompleteness*(r: ObsRing;
    dropsAtWindowStart: uint64): CaptureCompleteness = ccTruncated
  proc registerConsumer*(r: ObsRing) = discard
  proc deregisterConsumer*(r: ObsRing) = discard
  proc consumerVerdict*(r: ObsRing): AnchorVerdict = avNoOwner
  proc consumerAttached*(r: ObsRing): bool = false
  proc consumerIdle*(r: ObsRing): bool = false
  proc publish*(r: ObsRing; rec: openArray[byte]): ObsPublishResult = oprUnavailable
  proc publishForcedSignal*(r: ObsRing;
    rec: openArray[byte]): ObsPublishResult = oprUnavailable
  proc drainOne*(r: ObsRing; outBuf: var openArray[byte];
      outLen: var int): ObsDrainResult =
    outLen = 0
    odrEmpty
  proc awaitRecord*(r: ObsRing; timeoutNs: int64 = 0;
    parks: ptr int = nil): ObsWaitResult = owrUnavailable
  proc storedPointerCheck*(r: ObsRing): bool = true
