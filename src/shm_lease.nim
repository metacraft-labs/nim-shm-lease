## `nim-shm-lease` — a lock-free, file-backed, multi-dimensional RESERVATION over
## a packed shared-memory budget word.
##
## Sibling to [`nim-shm-queue`](../nim-shm-queue) and
## [`nim-shm-gset`](../nim-shm-gset), and the POC library of the RunQuota
## Observation Store & Shared-Memory Transport campaign
## (`reprobuild-specs/RunQuota-Observation-Store.milestones.org`). This module is
## **M2**: the "easy part" of admission per
## `reprobuild-specs/RunQuota-Shared-Memory-Transport.md` §"1. The fit check and
## claim are the easy part".
##
## WHY THIS IS NOT THE G-SET. The design spec rules `nim-shm-gset` out for
## admission on a structural ground: the G-Set's safety argument is that it has no
## per-element mutable value and no atomic read-modify-write, so the lost-update
## race class cannot occur — while admission is *inherently* read-modify-write
## (decrement available capacity, decide grant or refuse). That does NOT imply
## admission needs a daemon. Lock-free structures do read-modify-write routinely,
## and this module is the demonstration:
##
##   read the packed budget → test fit per dimension → CAS the decremented value
##   → retry on contention.
##
## WHAT M2 DELIBERATELY DOES NOT DO. The spec's §2 is explicit that *policy* is
## the real obstacle: a pure CAS loop admits whoever arrives first and happens to
## fit, which STARVES large claims. This module is therefore a correct
## no-overcommit reservation and **not** an admission policy. Anti-starvation
## (SM-4) belongs to the flat-combining arbiter of M5/M6, observations to M4, and
## kill-injection + reclamation to M7. Nothing here should be read as a claim that
## first-come-if-it-fits is an acceptable admission policy; it is the substrate the
## policy is built on.
##
## **M4 has since landed too**: `shm_lease/obsring` is the OBSERVATION RING — a
## bounded MPSC channel carrying execution observations to the daemon, riding
## `nim-shm-queue`'s Layer 1 in a THIRD, independent segment. Its producer never
## blocks and never fails an execution, its drops are counted and surfaced, and its
## consumer parks on M3's wait word rather than polling. Again a separate segment
## and a separate format version, for the same reason: a ring-format change must not
## be able to destabilise admission.
##
## **M3 has since landed alongside it**: `shm_lease/waitword` is the futex-class
## cross-process blocking wrapper (SM-1, SM-2), re-exported from this module. It is
## a SEPARATE segment with its own format, deliberately — the budget segment's
## layout and format version are untouched by M3, and the header words
## `LhOffReserved1..5` remain reserved for M5's combiner role/sequence and M7's
## reclamation epoch. Claiming is still non-blocking (SM-8); the wait primitive is
## what M5 will use to park a client that has nothing else to run.
##
## WHAT IT DOES GUARANTEE, and how each is proven:
##
##   * **No overcommit, ever.** A budget word's remaining value never underflows in
##     any dimension, because the fit test is per-field and precedes the CAS, and
##     the CAS only commits against the value that was actually tested. Proven by
##     `tests/test_shm_lease_multiprocess.nim`, which samples every budget word
##     from every process and asserts `remaining[d] <= capacity[d]` — an assertion
##     that catches both an underflowing claim (the field wraps to a huge value)
##     and an over-release (the field exceeds capacity). The same harness run with
##     a deliberately fit-check-free claim FAILS that assertion, which is what
##     makes the assertion evidence rather than decoration.
##   * **No lost update.** Every mutation is a CAS with retry; nothing is a blind
##     store. Proven by comparing each process's own count of successful claims and
##     releases against the shared-memory counters, and — the stronger check — by
##     asserting that the budget deficit at quiescence equals the EXACT sum of the
##     reservations the child processes deliberately still hold.
##   * **Total released == total claimed.** Releasing every outstanding
##     reservation restores `remaining == capacity` bit-for-bit, and a further
##     release is REFUSED rather than corrupting the word.
##   * **Position independence (SM-7).** Only offsets, counts, and packed VALUES
##     live in the segment; no absolute pointer ever does. Proven by mapping the
##     segment at deliberately different virtual bases (`MAP_FIXED` over a
##     pre-reserved region) in every participating process and asserting every
##     operation stays correct across those differing bases.
##
## ENGINEERING PLAYBOOK (inherited from `nim-shm-gset`, and required by the design
## spec's §"The engineering playbook does transfer"):
##
##   * file-backed `mmap(MAP_SHARED)`, so the segment survives producer death and
##     `exec`;
##   * offsets and counts only — position independent;
##   * publish-before-write: the segment is fully initialised, its magic
##     release-stored, and only THEN renamed into its final, discoverable name;
##   * boot id + owner pid + owner process START TIME anchoring (start time is what
##     defeats pid reuse — see `shm_lease/anchor`);
##   * deterministic schedule hooks at every CAS and publish site
##     (`-d:shmLeaseScheduleHooks`, mirroring `-d:shmGSetScheduleHooks`);
##   * a portable no-op arm that compiles everywhere and reports unavailable off
##     Linux and macOS.
##
## MULTI-WORD BUDGETS AND THE FIXED CLAIM ORDER. Per-pool and per-machine budgets
## occupy their own words (§1: "Per-pool and per-machine budgets occupy their own
## words, claimed in a fixed order to avoid cycles"). The order here is
## **ascending budget-record index**, with index 0 (`MachineBudgetIndex`) reserved
## for the per-machine budget and index `1 + poolIndex` for pool `poolIndex`:
##
##   claim:    ascending index  (machine, then pools in ascending pool order)
##   rollback: descending index (the mirror image of the partial claim)
##   release:  descending index
##
## Because every claimant takes words in strictly ascending index order, the
## waits-for relation is a strict order and no cycle is constructible. This is
## **enforced, not merely documented**: `claimWords` REFUSES a non-ascending index
## list with `csOutOfOrder`, and there is a test for it.

import ./shm_lease/[hooks, packed, anchor, waitword, syscount, obsring, arbiter,
  reclaim]
export packed
export waitword
export syscount
export obsring
export arbiter
export reclaim
export hooks.SchedulePoint, hooks.scheduleHooksEnabled
export anchor.AnchorVerdict, anchor.bootId, anchor.processStartTime,
  anchor.pidAlive, anchor.anchorVerdict, anchor.ownerAliveAnchor
when defined(shmLeaseScheduleHooks):
  export hooks.setScheduleHook, hooks.ScheduleHook

const shmLeaseSupported* = defined(linux) or defined(macosx)
  ## False on any platform without POSIX `mmap(MAP_SHARED)`; every operation then
  ## reports `csUnavailable` / false so a caller degrades instead of failing.

func align8*(n: int): int {.inline.} = (n + 7) and not 7
func align4k*(n: int): int {.inline.} = (n + 4095) and not 4095

const
  ShmLeaseMagic* = 0x534C_4D48_53_00_01'u64
    ## "SHM LS" — identifies a shm_lease budget segment.
  ShmLeaseFormatVersion* = 1'u32
    ## Bumped on ANY change to the on-segment layout below. Attach fails loudly on
    ## a mismatch rather than reinterpreting foreign bytes.
  MaxBudgetWords* = 256
    ## Upper bound on budget records in one segment (machine + up to 255 pools).
    ## A bound exists so a corrupt header can never make an attacher compute a
    ## nonsense mapping size.
  MaxClaimWords* = 8
    ## Upper bound on budget words one claim may span. Bounded so a claim is
    ## allocation-free and its rollback is a fixed-size loop.
  MachineBudgetIndex* = 0
    ## The per-machine budget is always word 0 — the FIRST word in the fixed claim
    ## order, so every claim in the system agrees on where it starts.

func poolBudgetIndex*(poolIndex: int): int {.inline.} = 1 + poolIndex
  ## Word index of per-pool budget `poolIndex` (pools are 0-based).

# --- segment header: offsets only, base-independent -------------------------
#
# Every 8-byte field sits on an 8-byte-aligned offset so the atomic accesses are
# well-defined in every process's mapping. NOTHING here is an address.
const
  LhOffMagic* = 0                  ## u64, published LAST (release)
  LhOffFormatVersion* = 8          ## u32
  LhOffFlags* = 12                 ## u32 (reserved)
  LhOffCreatorBootId* = 16         ## u64 anchor: boot
  LhOffOwnerPid* = 24              ## u64 anchor: creator pid
  LhOffOwnerStartTime* = 32        ## u64 anchor: creator process START TIME
  LhOffBudgetCount* = 40           ## u64 number of budget records
  LhOffBudgetsOff* = 48            ## u64 byte OFFSET of the budget-record array
  LhOffSegmentSize* = 56           ## u64 total segment byte size
  LhOffMemUnitBytes* = 64          ## u64 memory coarsening unit, for cross-check
  LhOffDimCount* = 72              ## u64 packed dimensions, for cross-check
  LhOffProbe* = 80                 ## u64 reserved; written ONLY by the
                                   ## stored-pointer negative test
  LhOffReserved1* = 88             ## u64 **M7**: the RECLAMATION EPOCH — a
                                   ## monotone count of slots reclaimed from dead
                                   ## owners (`shm_lease/reclaim`). M2 reserved
                                   ## this word with exactly that note and M7
                                   ## takes it, so no offset moved, no field
                                   ## changed size, and the format version does
                                   ## not move: a segment on which nothing was
                                   ## ever reclaimed is byte-for-byte the segment
                                   ## M2 created.
  LhOffRole* = 96                  ## u64 **M5**: the COMBINER ROLE WORD,
                                   ## `[epoch][ownerSlot][committed]`. The commit
                                   ## flag lives INSIDE this word, so the
                                   ## acquisition CAS and the commit CAS are the
                                   ## same CAS on the same word — MV2's Finding 4,
                                   ## which is a LAYOUT constraint and could not
                                   ## have been retrofitted without a format bump.
  LhOffCombineSeq* = 104           ## u64 **M5**: the COMBINE SEQUENCE — the
                                   ## highest COMMITTED epoch, monotone. A ledger
                                   ## entry is effective iff its stamp is <= this.
  LhOffRequestsOff* = 112          ## u64 **M5**: byte OFFSET of the request-slot
                                   ## array (0 when the segment has none)
  LhOffRequestCount* = 120         ## u64 **M5**: number of request slots
                                   ##
                                   ## These four were `LhOffReserved2..5` up to
                                   ## M5 and are the same offsets under new names;
                                   ## MV2's model and the structures spec still
                                   ## refer to the first two by the old names, and
                                   ## `shm_lease/arbiter`'s docstring carries the
                                   ## mapping. Nothing outside this file used the
                                   ## old identifiers, so no alias is kept — one
                                   ## name per offset.
  LeaseHeaderSize* = 128

# --- one budget record: exactly 128 bytes ----------------------------------
#
# `remaining` is the single CAS target; `capacity` is immutable after
# initialisation. The counters are OBSERVABILITY, not part of the safety argument:
# they are bumped after the CAS, so a process killed in between leaves them
# slightly behind (that window is M7's to close). The authoritative conservation
# facts are `remaining` itself and `capacity`, which move atomically together with
# every claim and release.
const
  BrOffRemaining* = 0              ## u64 atomic, packed REMAINING capacity
  BrOffCapacity* = 8               ## u64 immutable, packed TOTAL capacity
  BrOffClaims* = 16                ## u64 atomic, granted claims on this word
  BrOffReleases* = 24              ## u64 atomic, releases on this word
  BrOffRefusals* = 32              ## u64 atomic, claims refused (did not fit)
  BrOffRetries* = 40               ## u64 atomic, CAS retries (contention)
  BrOffRollbacks* = 48             ## u64 atomic, partial-claim rollbacks
  BrOffReserved* = 56              ## u64 reserved
  BrOffClaimedUnits* = 64          ## u64[4] atomic, granted units per dimension
  BrOffReleasedUnits* = 96         ## u64[4] atomic, released units per dimension
  BudgetRecordSize* = 128

func leaseSegmentSize*(budgetCount: int; requestSlots: int = 0): int {.inline.} =
  ## Page-rounded byte size of a segment with `budgetCount` budget records and
  ## `requestSlots` M5 request slots.
  ##
  ## The request array is appended AFTER the budget records, and `requestSlots = 0`
  ## reproduces M2's size exactly — so a segment created without an arbiter is
  ## byte-for-byte the segment M2 created, and the format version does not move.
  ## An M2-era segment read by an M5-aware process reports `LhOffRequestCount == 0`
  ## and its arbiter view is simply unavailable, which is a graceful degrade rather
  ## than a mismatch.
  align4k(LeaseHeaderSize + budgetCount * BudgetRecordSize +
    requestSlots * RequestSlotSize)

type
  ClaimStatus* = enum
    ## Outcome of a claim. Non-blocking by construction: a claim either takes the
    ## capacity now or reports that it did not — it NEVER parks the caller (SM-8;
    ## the queue-and-grant path is M5).
    csGranted       ## the whole vector was taken on every named budget word
    csRefused       ## it did not fit; nothing was taken (any partial claim was
                    ## rolled back)
    csInvalidVec    ## a dimension exceeded `DimMax`
    csBadBudget     ## a named budget index is out of range
    csOutOfOrder    ## the budget indices were not strictly ascending — the fixed
                    ## claim order is ENFORCED, not merely documented
    csUnavailable   ## the segment is not attached (portable arm / attach failed)

  Reservation* = object
    ## A granted reservation. PROCESS-LOCAL by design: it holds the vector and the
    ## budget-word indices needed to give the capacity back, and no address. It is
    ## not stored in shared memory (a per-reservation shared record with an owner
    ## anchor is M7's reclamation work, and `shm_lease/anchor` already provides the
    ## predicate it will need).
    granted*: bool
    vec*: ResourceVec
    words*: array[MaxClaimWords, int32]
    wordCount*: int

func isGranted*(r: Reservation): bool {.inline.} = r.granted

when shmLeaseSupported:
  import std/[os, posix, times]

  type
    ShmBase* = ptr UncheckedArray[byte]
      ## The mapped base in THIS process. Every access is `base + offset`; the base
      ## itself is never written into the segment.

    ShmLease* = object
      ## An attached view of a budget segment. `available` is false after any
      ## create/attach failure.
      available*: bool
      isOwner*: bool
      path*: string
      base: ShmBase
      size: int
      fd: cint
      budgetCount*: int
      budgetsOff: int
      boot: uint64
      requestSlots*: int       ## M5: request slots in this segment (0 = none)
      requestsOff: int

  # --- offset-addressed atomics (C11/GCC builtins) --------------------------
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
  proc casU64(base: ShmBase; off: int; expected: var uint64;
      desired: uint64): bool {.inline.} =
    atomicCompareExchangeN(atField(base, off, uint64), addr expected, desired,
      false, ATOMIC_ACQ_REL, ATOMIC_ACQUIRE)
  proc addU64(base: ShmBase; off: int; d: uint64) {.inline.} =
    discard atomicAddFetch(atField(base, off, uint64), d, ATOMIC_RELAXED)
  proc subU64(base: ShmBase; off: int; d: uint64) {.inline.} =
    discard atomicSubFetch(atField(base, off, uint64), d, ATOMIC_RELAXED)
  proc loadU32Acquire(base: ShmBase; off: int): uint32 {.inline.} =
    atomicLoadN(atField(base, off, uint32), ATOMIC_ACQUIRE)
  proc storeU32Release(base: ShmBase; off: int; v: uint32) {.inline.} =
    atomicStoreN(atField(base, off, uint32), v, ATOMIC_RELEASE)
  proc storeU32Relaxed(base: ShmBase; off: int; v: uint32) {.inline.} =
    atomicStoreN(atField(base, off, uint32), v, ATOMIC_RELAXED)

  # --- mapping ---------------------------------------------------------------

  proc mapFd(fd: cint; size: int; wantBase: pointer): ShmBase =
    ## Map `size` bytes of `fd` MAP_SHARED. When `wantBase` is non-nil the mapping
    ## is forced there with `MAP_FIXED`.
    ##
    ## `MAP_FIXED` REPLACES whatever already occupies the range, so a caller MUST
    ## have reserved it first (typically `mmap(nil, size, PROT_NONE,
    ## MAP_PRIVATE|MAP_ANONYMOUS)`). This is a first-class API rather than a
    ## test-only backdoor because SM-7 — "the segment is correct when mapped at a
    ## different virtual base in every process" — is only PROVABLE if a test can
    ## choose the bases; letting the kernel pick would leave two forked processes
    ## very likely at the SAME address, which proves nothing.
    if wantBase != nil:
      let pf = mmap(wantBase, size, PROT_READ or PROT_WRITE,
        MAP_SHARED or MAP_FIXED, fd, 0)
      if pf == MAP_FAILED: return nil
      return cast[ShmBase](pf)
    let p = mmap(nil, size, PROT_READ or PROT_WRITE, MAP_SHARED, fd, 0)
    if p == MAP_FAILED: return nil
    cast[ShmBase](p)

  proc budgetOff(l: ShmLease; idx: int): int {.inline.} =
    l.budgetsOff + idx * BudgetRecordSize

  proc headerValid(base: ShmBase; boot: uint64; size: int): bool =
    if loadU64Acquire(base, LhOffMagic) != ShmLeaseMagic: return false
    if loadU32Acquire(base, LhOffFormatVersion) != ShmLeaseFormatVersion: return false
    if loadU64Relaxed(base, LhOffCreatorBootId) != boot: return false
    if loadU64Relaxed(base, LhOffMemUnitBytes) != uint64(MemUnitBytes): return false
    if loadU64Relaxed(base, LhOffDimCount) != uint64(LeaseDimCount): return false
    let n = loadU64Relaxed(base, LhOffBudgetCount)
    if n == 0 or n > uint64(MaxBudgetWords): return false
    let off = loadU64Relaxed(base, LhOffBudgetsOff)
    if off != uint64(LeaseHeaderSize): return false
    if int(off) + int(n) * BudgetRecordSize > size: return false
    if loadU64Relaxed(base, LhOffSegmentSize) != uint64(size): return false
    # M5's request array, when the segment has one. Validated with the same
    # suspicion as the budget array: a corrupt count or offset must make the
    # attach FAIL rather than produce a view that indexes outside the mapping.
    let rq = loadU64Relaxed(base, LhOffRequestCount)
    if rq != 0:
      if rq > uint64(MaxRequestSlots): return false
      let rqOff = loadU64Relaxed(base, LhOffRequestsOff)
      if rqOff != off + n * uint64(BudgetRecordSize): return false
      if int(rqOff) + int(rq) * RequestSlotSize > size: return false
    true

  # --- creation: publish-before-write ---------------------------------------

  proc createLeaseSegment*(path: string;
      capacities: openArray[ResourceVec];
      requestSlots: int = 0): ShmLease =
    ## OWNER side: create a segment whose budget word `i` starts at
    ## `capacities[i]`. `capacities[0]` is the per-machine budget
    ## (`MachineBudgetIndex`); `capacities[1 + p]` is pool `p`'s budget.
    ##
    ## `requestSlots > 0` additionally allocates M5's request-slot array, which is
    ## what makes the flat-combining arbiter available on this segment. The default
    ## is 0, so every existing caller creates the byte-identical M2 segment.
    ##
    ## PUBLISH-BEFORE-WRITE. The segment is built under a unique temp name, every
    ## field is written, the magic is release-stored LAST, and only then is the file
    ## `rename`d into its final name. So the instant the final name is
    ## discoverable, the contents are complete — a concurrent attacher can never
    ## observe a half-initialised segment, and a crash before the rename leaves
    ## nothing discoverable to observe.
    result.available = false
    result.isOwner = true
    result.fd = -1
    result.path = path
    result.boot = bootId()
    if capacities.len == 0 or capacities.len > MaxBudgetWords: return
    if requestSlots < 0 or requestSlots > MaxRequestSlots: return
    for c in capacities:
      if not validVec(c): return
    let size = leaseSegmentSize(capacities.len, requestSlots)
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

    # Geometry + budgets first...
    storeU32Relaxed(base, LhOffFlags, 0)
    storeU64Relaxed(base, LhOffBudgetCount, uint64(capacities.len))
    storeU64Relaxed(base, LhOffBudgetsOff, uint64(LeaseHeaderSize))
    storeU64Relaxed(base, LhOffSegmentSize, uint64(size))
    storeU64Relaxed(base, LhOffMemUnitBytes, uint64(MemUnitBytes))
    storeU64Relaxed(base, LhOffDimCount, uint64(LeaseDimCount))
    storeU64Relaxed(base, LhOffProbe, 0)
    # M7: the reclamation epoch starts at zero. Written explicitly rather than
    # relied on from `ftruncate`'s zero fill, so the header's initial state is
    # stated in one place.
    storeU64Relaxed(base, LhOffReserved1, 0)
    # M5: the arbiter's two words start from a QUIESCENT state — role unowned at
    # epoch 0, committed (so the first acquisition has nothing to repair), and the
    # combine sequence at 0.
    storeU64Relaxed(base, LhOffRole, roleWord(RoleNoOwner, 0, true))
    storeU64Relaxed(base, LhOffCombineSeq, 0)
    let requestsOff = LeaseHeaderSize + capacities.len * BudgetRecordSize
    storeU64Relaxed(base, LhOffRequestsOff,
      if requestSlots > 0: uint64(requestsOff) else: 0'u64)
    storeU64Relaxed(base, LhOffRequestCount, uint64(requestSlots))
    if requestSlots > 0:
      initArbiterArea(base, requestsOff, requestSlots)
    for i in 0 ..< capacities.len:
      let off = LeaseHeaderSize + i * BudgetRecordSize
      let packedCap = packVec(capacities[i])
      storeU64Relaxed(base, off + BrOffRemaining, packedCap)
      storeU64Relaxed(base, off + BrOffCapacity, packedCap)
      storeU64Relaxed(base, off + BrOffClaims, 0)
      storeU64Relaxed(base, off + BrOffReleases, 0)
      storeU64Relaxed(base, off + BrOffRefusals, 0)
      storeU64Relaxed(base, off + BrOffRetries, 0)
      storeU64Relaxed(base, off + BrOffRollbacks, 0)
      storeU64Relaxed(base, off + BrOffReserved, 0)
      for d in 0 ..< LeaseDimCount:
        storeU64Relaxed(base, off + BrOffClaimedUnits + d * 8, 0)
        storeU64Relaxed(base, off + BrOffReleasedUnits + d * 8, 0)
    # ...then the anchor: boot id + owner pid + owner process START TIME. Start
    # time is the field that defeats pid reuse (see shm_lease/anchor).
    scheduleHook(slpBeforeAnchorPublish)
    storeU64Relaxed(base, LhOffCreatorBootId, result.boot)
    storeU64Relaxed(base, LhOffOwnerPid, uint64(getpid()))
    storeU64Relaxed(base, LhOffOwnerStartTime, processStartTime(int(getpid())))
    storeU32Release(base, LhOffFormatVersion, ShmLeaseFormatVersion)
    # ...and the magic LAST, with a release store: an attacher that acquire-loads
    # the magic necessarily also observes everything above.
    scheduleHook(slpBeforeMagicPublish)
    storeU64Release(base, LhOffMagic, ShmLeaseMagic)
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
    if not headerValid(mapped, result.boot, size):
      discard munmap(cast[pointer](mapped), size); discard close(fd); return
    result.base = mapped
    result.size = size
    result.fd = fd
    result.budgetCount = int(loadU64Relaxed(mapped, LhOffBudgetCount))
    result.budgetsOff = int(loadU64Relaxed(mapped, LhOffBudgetsOff))
    result.requestSlots = int(loadU64Relaxed(mapped, LhOffRequestCount))
    result.requestsOff = int(loadU64Relaxed(mapped, LhOffRequestsOff))
    result.available = true

  proc attachLeaseSegment*(path: string; wantBase: pointer = nil): ShmLease =
    ## Attach to an existing segment. Returns an unavailable lease (never creates,
    ## never repairs) when the file is missing, the wrong size, or the header is
    ## stale — wrong magic, wrong format version, wrong boot id, or a
    ## `MemUnitBytes` / dimension-count disagreement, which would mean the peer was
    ## built with a different coarsening and its numbers mean something else.
    ##
    ## `wantBase`, when non-nil, forces the mapping to that address with
    ## `MAP_FIXED`; the caller must have reserved the range. This is how the SM-7
    ## test puts each process's mapping at a DIFFERENT virtual base.
    result.available = false
    result.isOwner = false
    result.fd = -1
    result.path = path
    result.boot = bootId()
    if not fileExists(path): return
    var size = 0
    try: size = int(getFileSize(path))
    except CatchableError: return
    if size < LeaseHeaderSize + BudgetRecordSize: return
    let fd = open(path.cstring, O_RDWR)
    if fd < 0: return
    let base = mapFd(fd, size, wantBase)
    if base.isNil:
      discard close(fd); return
    if not headerValid(base, result.boot, size):
      discard munmap(cast[pointer](base), size); discard close(fd); return
    result.base = base
    result.size = size
    result.fd = fd
    result.budgetCount = int(loadU64Relaxed(base, LhOffBudgetCount))
    result.budgetsOff = int(loadU64Relaxed(base, LhOffBudgetsOff))
    result.requestSlots = int(loadU64Relaxed(base, LhOffRequestCount))
    result.requestsOff = int(loadU64Relaxed(base, LhOffRequestsOff))
    result.available = true

  proc detach*(l: var ShmLease) =
    ## Unmap + close. Does NOT unlink the backing file: other processes may still
    ## hold reservations against it, and the file IS the segment's lifetime (it
    ## survives owner death and `exec`, which is why it is file-backed).
    if not l.base.isNil:
      discard munmap(cast[pointer](l.base), l.size)
      l.base = nil
    if l.fd > 0:
      discard close(l.fd)
    l.fd = -1
    l.size = 0
    l.available = false

  # --- raw single-word primitives -------------------------------------------
  #
  # Exported because M5's flat-combining arbiter needs to drive budget words
  # directly with a global view, and because the M2 gate's NEGATIVE control (a
  # deliberately fit-check-free claim) must be expressible in a test without
  # weakening the shipping API.

  proc packedRemaining*(l: ShmLease; idx: int): uint64 {.inline.} =
    ## Acquire-load of budget word `idx`'s packed remaining capacity.
    if not l.available or idx < 0 or idx >= l.budgetCount: return 0
    loadU64Acquire(l.base, l.budgetOff(idx) + BrOffRemaining)

  proc packedCapacity*(l: ShmLease; idx: int): uint64 {.inline.} =
    if not l.available or idx < 0 or idx >= l.budgetCount: return 0
    loadU64Relaxed(l.base, l.budgetOff(idx) + BrOffCapacity)

  proc casPackedRemaining*(l: ShmLease; idx: int; expected: var uint64;
      desired: uint64): bool {.inline.} =
    ## Raw CAS on a budget word. Callers own the fit argument; the shipping claim
    ## path establishes it with `fitsPacked` BEFORE calling this.
    if not l.available or idx < 0 or idx >= l.budgetCount: return false
    scheduleHook(slpBeforeBudgetCas)
    result = casU64(l.base, l.budgetOff(idx) + BrOffRemaining, expected, desired)
    scheduleHook(slpAfterBudgetCas)

  proc remainingVec*(l: ShmLease; idx: int = MachineBudgetIndex): ResourceVec {.inline.} =
    unpackVec(l.packedRemaining(idx))

  proc capacityVec*(l: ShmLease; idx: int = MachineBudgetIndex): ResourceVec {.inline.} =
    unpackVec(l.packedCapacity(idx))

  proc outstandingVec*(l: ShmLease; idx: int = MachineBudgetIndex): ResourceVec {.inline.} =
    ## `capacity - remaining`: the total currently reserved on this word. Saturating
    ## subtraction, so a corrupt (overcommitted) word reports 0 rather than a wrapped
    ## number — use `noOvercommit` to detect corruption, not this.
    l.capacityVec(idx) - l.remainingVec(idx)

  proc noOvercommit*(l: ShmLease; idx: int): bool {.inline.} =
    ## THE invariant, sampled: no dimension of `remaining` may exceed `capacity`.
    ##
    ## One comparison catches both failure directions. An under-flowing claim (a
    ## missing or wrong fit test) wraps the field to a huge value, so
    ## `remaining[d] > capacity[d]`. An over-release (a double release, or a
    ## release of a reservation that was never granted) also drives
    ## `remaining[d] > capacity[d]`. Either way the sum of outstanding reservations
    ## has stopped being bounded by the budget, which is exactly "overcommit".
    if not l.available: return true
    let rem = l.packedRemaining(idx)
    let cap = l.packedCapacity(idx)
    fitsPacked(cap, rem)

  proc noOvercommitAnywhere*(l: ShmLease): bool =
    for i in 0 ..< l.budgetCount:
      if not l.noOvercommit(i): return false
    true

  # --- counters (observability) ---------------------------------------------

  proc claimCount*(l: ShmLease; idx: int = MachineBudgetIndex): uint64 =
    if not l.available: return 0
    loadU64Relaxed(l.base, l.budgetOff(idx) + BrOffClaims)
  proc releaseCount*(l: ShmLease; idx: int = MachineBudgetIndex): uint64 =
    if not l.available: return 0
    loadU64Relaxed(l.base, l.budgetOff(idx) + BrOffReleases)
  proc refusalCount*(l: ShmLease; idx: int = MachineBudgetIndex): uint64 =
    if not l.available: return 0
    loadU64Relaxed(l.base, l.budgetOff(idx) + BrOffRefusals)
  proc retryCount*(l: ShmLease; idx: int = MachineBudgetIndex): uint64 =
    if not l.available: return 0
    loadU64Relaxed(l.base, l.budgetOff(idx) + BrOffRetries)
  proc rollbackCount*(l: ShmLease; idx: int = MachineBudgetIndex): uint64 =
    if not l.available: return 0
    loadU64Relaxed(l.base, l.budgetOff(idx) + BrOffRollbacks)
  proc claimedUnits*(l: ShmLease; idx: int; d: LeaseDim): uint64 =
    if not l.available: return 0
    loadU64Relaxed(l.base, l.budgetOff(idx) + BrOffClaimedUnits + ord(d) * 8)
  proc releasedUnits*(l: ShmLease; idx: int; d: LeaseDim): uint64 =
    if not l.available: return 0
    loadU64Relaxed(l.base, l.budgetOff(idx) + BrOffReleasedUnits + ord(d) * 8)

  # --- the claim / release core ---------------------------------------------

  proc claimWord(l: var ShmLease; idx: int; want: uint64;
      wantVec: ResourceVec; count: bool): bool =
    ## Lock-free claim on ONE budget word: read, test fit per dimension, CAS the
    ## decremented value, retry on contention. Returns false only when the vector
    ## does not fit (never because of contention — contention retries).
    let off = l.budgetOff(idx)
    var cur = loadU64Acquire(l.base, off + BrOffRemaining)
    while true:
      if not fitsPacked(cur, want):
        if count: addU64(l.base, off + BrOffRefusals, 1)
        return false
      let desired = packedSub(cur, want)
      scheduleHook(slpBeforeBudgetCas)
      let won = casU64(l.base, off + BrOffRemaining, cur, desired)
      scheduleHook(slpAfterBudgetCas)
      if won:
        if count:
          addU64(l.base, off + BrOffClaims, 1)
          for d in LeaseDim:
            let u = vecField(wantVec, d)
            if u != 0: addU64(l.base, off + BrOffClaimedUnits + ord(d) * 8, uint64(u))
        return true
      # Lost the CAS: `cur` now holds the freshly observed value. Retry — the fit
      # test is re-evaluated against what is actually there, which is why a lost
      # CAS can never turn into an overcommit.
      if count: addU64(l.base, off + BrOffRetries, 1)

  proc releaseWord(l: var ShmLease; idx: int; give: uint64;
      giveVec: ResourceVec; isRollback: bool): bool =
    ## Give capacity back to ONE budget word. The inverse of `claimWord`, with an
    ## OVER-RELEASE GUARD: if adding `give` would push any dimension above
    ## `capacity`, the release is REFUSED and the word is left untouched. A double
    ## release is therefore a reported error rather than silent corruption — the
    ## alternative would fabricate capacity that does not exist, which is the same
    ## harm as overcommit.
    let off = l.budgetOff(idx)
    let cap = loadU64Relaxed(l.base, off + BrOffCapacity)
    var cur = loadU64Acquire(l.base, off + BrOffRemaining)
    while true:
      if not fitsPacked(cap, cur): return false          # already corrupt
      if not fitsPacked(packedSub(cap, cur), give): return false  # over-release
      let desired = packedAdd(cur, give)
      scheduleHook(slpBeforeReleaseCas)
      if isRollback: scheduleHook(slpBeforeRollbackCas)
      let won = casU64(l.base, off + BrOffRemaining, cur, desired)
      scheduleHook(slpAfterReleaseCas)
      if won:
        if isRollback:
          # A rolled-back partial claim had NO net effect on this word, so it must
          # leave no trace in the claim accounting either: undo the claim counters
          # instead of counting a release. This keeps the accounting identity
          # `claimedUnits - releasedUnits == capacity - remaining` exact, and keeps
          # `claims` comparable with a caller's own count of granted claims.
          addU64(l.base, off + BrOffRollbacks, 1)
          subU64(l.base, off + BrOffClaims, 1)
          for d in LeaseDim:
            let u = vecField(giveVec, d)
            if u != 0: subU64(l.base, off + BrOffClaimedUnits + ord(d) * 8, uint64(u))
        else:
          addU64(l.base, off + BrOffReleases, 1)
          for d in LeaseDim:
            let u = vecField(giveVec, d)
            if u != 0: addU64(l.base, off + BrOffReleasedUnits + ord(d) * 8, uint64(u))
        return true
      addU64(l.base, off + BrOffRetries, 1)

  proc claimWords*(l: var ShmLease; v: ResourceVec; budgets: openArray[int];
      res: var Reservation): ClaimStatus =
    ## Claim `v` on every budget word in `budgets`, which MUST be strictly
    ## ascending — the FIXED CLAIM ORDER. A non-ascending list is refused with
    ## `csOutOfOrder` rather than reordered, because silently reordering would hide
    ## a caller that had constructed a cycle in some other, unenforced dimension.
    ##
    ## All-or-nothing: if a later word refuses, the earlier words are given back in
    ## DESCENDING order (the mirror image of the acquisition) and the result is
    ## `csRefused` with nothing held.
    res = Reservation()
    if not l.available: return csUnavailable
    if not validVec(v): return csInvalidVec
    if budgets.len == 0 or budgets.len > MaxClaimWords: return csBadBudget
    for i in 0 ..< budgets.len:
      if budgets[i] < 0 or budgets[i] >= l.budgetCount: return csBadBudget
      if i > 0 and budgets[i] <= budgets[i - 1]: return csOutOfOrder
    let want = packVec(v)
    var taken = 0
    for i in 0 ..< budgets.len:            # ASCENDING: no cycle is constructible
      if l.claimWord(budgets[i], want, v, count = true):
        inc taken
      else:
        for j in countdown(taken - 1, 0):  # DESCENDING rollback
          discard l.releaseWord(budgets[j], want, v, isRollback = true)
        return csRefused
    res.granted = true
    res.vec = v
    res.wordCount = budgets.len
    for i in 0 ..< budgets.len: res.words[i] = int32(budgets[i])
    csGranted

  proc claim*(l: var ShmLease; v: ResourceVec; res: var Reservation;
      poolIndex: int = -1): ClaimStatus =
    ## The common case: claim against the per-machine budget and, when
    ## `poolIndex >= 0`, additionally against that pool's budget — in the fixed
    ## order (machine word 0 first, then the pool word).
    if poolIndex < 0:
      var one = [MachineBudgetIndex]
      l.claimWords(v, one, res)
    else:
      var two = [MachineBudgetIndex, poolBudgetIndex(poolIndex)]
      l.claimWords(v, two, res)

  proc releaseWords*(l: var ShmLease; v: ResourceVec;
      budgets: openArray[int]): bool =
    ## Give `v` back on every named word, in DESCENDING index order. `budgets` is
    ## given in the same strictly ASCENDING form a claim uses (so the two calls are
    ## visibly mirror images); a non-ascending list is refused.
    ##
    ## Returns false if ANY word refused the release (over-release), having still
    ## released the others — a refusal here means the caller's bookkeeping is wrong,
    ## and the caller needs to know which words moved, so the partial result is
    ## reported rather than hidden.
    if not l.available: return false
    if not validVec(v): return false
    if budgets.len == 0 or budgets.len > MaxClaimWords: return false
    for i in 0 ..< budgets.len:
      if budgets[i] < 0 or budgets[i] >= l.budgetCount: return false
      if i > 0 and budgets[i] <= budgets[i - 1]: return false
    let give = packVec(v)
    result = true
    # Descending order, the mirror image of the ascending claim.
    for i in countdown(budgets.len - 1, 0):
      if not l.releaseWord(budgets[i], give, v, isRollback = false):
        result = false

  proc release*(l: var ShmLease; res: var Reservation): bool =
    ## Release a granted reservation on exactly the words it was taken from, in
    ## descending order. Idempotent-safe: a second call is a no-op returning false,
    ## because the handle is cleared on success.
    if not res.granted: return false
    if not l.available: return false
    let give = packVec(res.vec)
    result = true
    for i in countdown(res.wordCount - 1, 0):
      if not l.releaseWord(int(res.words[i]), give, res.vec, isRollback = false):
        result = false
    res = Reservation()

  proc releaseVec*(l: var ShmLease; v: ResourceVec; poolIndex: int = -1): bool =
    ## Release a vector on behalf of an owner that is not this process — the shape
    ## reclamation (M7) will need, and what the M2 gate uses when the parent gives
    ## back the reservations its children deliberately still held at exit.
    if poolIndex < 0:
      var one = [MachineBudgetIndex]
      l.releaseWords(v, one)
    else:
      var two = [MachineBudgetIndex, poolBudgetIndex(poolIndex)]
      l.releaseWords(v, two)

  # --- M5: binding the flat-combining arbiter to this segment ----------------

  proc arbiterView*(l: ShmLease; budgetIndex: int = MachineBudgetIndex):
      ArbiterView =
    ## Bind `shm_lease/arbiter` to this segment's role word, combine sequence,
    ## request array and ONE budget word. Returns an unavailable view when the
    ## segment was created without request slots — an M2-era segment degrades, it
    ## does not fail.
    ##
    ## **ONE BUDGET WORD, AND THE BOUNDARY IS DELIBERATE.** MV2 models a single
    ## budget dimension because "what MV2 is about is whose arithmetic runs and
    ## whether it survives a death, not how the word is packed"; the packed
    ## multi-dimensional fit test is M2's ground and the arbiter reuses it
    ## unchanged (`vecFits` is per dimension). Arbitrating several budget words at
    ## once — the machine word AND a pool word, in the fixed ascending order M2
    ## enforces — is NOT implemented and is not modelled anywhere.
    ##
    ## **DO NOT MIX `claimWords` AND THE ARBITER ON THE SAME BUDGET WORD.** The
    ## arbiter treats `remaining` as a CACHE that it recomputes from the ledger
    ## (constraint 2 of MV2's four), while `claimWords` treats it as an
    ## accumulator it CASes down. Both are correct alone; together the recompute
    ## would erase a concurrent claim. The authority for an arbitrated word is the
    ## ledger, and `heldSum` is how to read it.
    result = ArbiterView(available: false)
    if not l.available or l.requestSlots <= 0: return
    if budgetIndex < 0 or budgetIndex >= l.budgetCount: return
    result.base = l.base
    result.roleOff = LhOffRole
    result.seqOff = LhOffCombineSeq
    result.reclaimOff = LhOffReserved1
    result.remainingOff = l.budgetOff(budgetIndex) + BrOffRemaining
    result.slotsOff = l.requestsOff
    result.slotCount = l.requestSlots
    result.capacity = unpackVec(loadU64Relaxed(l.base,
      l.budgetOff(budgetIndex) + BrOffCapacity))
    result.boot = l.boot
    result.available = true

  proc arbiterClient*(l: ShmLease; slot: int;
      budgetIndex: int = MachineBudgetIndex): ArbiterClient =
    ## A client handle bound to `slot`, with the default bounded steal timeout.
    ## The caller still has to `registerSlot`, which is what writes the anchor.
    ArbiterClient(view: l.arbiterView(budgetIndex), slot: slot,
      stealAfterNs: DefaultStealAfterNs,
      anchorProbeAfterNs: DefaultAnchorProbeAfterNs)

  # --- anchoring -------------------------------------------------------------

  proc creatorBootId*(l: ShmLease): uint64 =
    if not l.available: return 0
    loadU64Relaxed(l.base, LhOffCreatorBootId)
  proc ownerPid*(l: ShmLease): uint64 =
    if not l.available: return 0
    loadU64Relaxed(l.base, LhOffOwnerPid)
  proc ownerStartTime*(l: ShmLease): uint64 =
    if not l.available: return 0
    loadU64Relaxed(l.base, LhOffOwnerStartTime)

  proc ownerVerdict*(l: ShmLease): AnchorVerdict =
    ## Judge the segment's owner from its recorded anchor. `avPidReused` is the
    ## verdict that only start time can produce, and it is the reason the field
    ## exists in M2 rather than M7.
    if not l.available: return avNoOwner
    anchorVerdict(l.creatorBootId(), l.ownerPid(), l.ownerStartTime())

  proc ownerAlive*(l: ShmLease): bool = l.ownerVerdict() == avLive

  # --- position independence -------------------------------------------------

  proc mappedBase*(l: ShmLease): pointer {.inline.} =
    ## This process's mapping base. Used by the SM-7 test to prove the
    ## participating processes really are at DIFFERENT virtual addresses; the value
    ## is never written into the segment.
    cast[pointer](l.base)

  proc segmentSize*(l: ShmLease): int {.inline.} = l.size

  proc storedPointerCheck*(l: ShmLease): bool =
    ## Position-independence audit (SM-7), complementary to the MAP_FIXED test.
    ##
    ## Asserts that (a) every field the header declares to be an OFFSET is a small
    ## in-segment offset, and (b) no 8-byte-aligned word anywhere in the live part
    ## of the segment falls inside this mapping's address window
    ## `[base, base + size)` — which is what a leaked absolute pointer would look
    ## like, and what would fault or silently misread at a different base.
    ##
    ## This is a heuristic (a packed budget word could in principle collide with an
    ## address), so it is a SECOND line of defence: the primary proof is the
    ## multi-process differing-bases test. Returns false on a violation.
    if not l.available: return false
    let size = l.size
    if int(loadU64Relaxed(l.base, LhOffBudgetsOff)) >= size: return false
    if int(loadU64Relaxed(l.base, LhOffSegmentSize)) != size: return false
    let lo = cast[uint](l.base)
    let hi = lo + uint(size)
    # The live part now includes M5's request slots when the segment has them: a
    # leaked absolute pointer in a ledger entry or a want vector would be exactly
    # as fatal at a different base as one in a budget word, so it is audited the
    # same way rather than left outside the window the checker looks at.
    let liveEnd = l.budgetsOff + l.budgetCount * BudgetRecordSize +
      l.requestSlots * RequestSlotSize
    var off = 0
    while off + 8 <= liveEnd:
      let w = uint(loadU64Relaxed(l.base, off))
      if w >= lo and w < hi: return false
      off += 8
    true

  proc assertNoStoredPointers*(l: ShmLease) =
    doAssert l.storedPointerCheck(),
      "shm_lease: a word in the segment falls inside this mapping's address " &
      "window — absolute-pointer leak (position independence, SM-7)"

  proc writeProbeWord*(l: ShmLease; v: uint64) =
    ## TEST SUPPORT: write the reserved probe word. Its only purpose is to let
    ## `tests/test_shm_lease.nim` forge an absolute pointer in the segment and
    ## prove `storedPointerCheck` catches it — a checker that has never been seen
    ## to fail has not been shown to check anything.
    if l.available: storeU64Relaxed(l.base, LhOffProbe, v)

else:
  # --- portable no-op arm ---------------------------------------------------
  #
  # Compiles everywhere; every operation reports unavailable, exactly like
  # `nim-shm-gset`'s and `nim-shm-queue`'s portable arms, so a caller degrades
  # rather than failing to build. Windows lands here: per the design spec the
  # Windows transport is deferred (`WaitOnAddress` is documented as
  # within-process only, so the wake path of M3 needs named kernel objects), and
  # that gap is recorded in the README's capability record rather than silently
  # omitted.
  type
    ShmBase* = ptr UncheckedArray[byte]
    ShmLease* = object
      available*: bool
      isOwner*: bool
      path*: string
      budgetCount*: int
      requestSlots*: int

  proc createLeaseSegment*(path: string;
      capacities: openArray[ResourceVec];
      requestSlots: int = 0): ShmLease =
    ShmLease(available: false, isOwner: true, path: path,
      budgetCount: capacities.len, requestSlots: requestSlots)
  proc arbiterView*(l: ShmLease; budgetIndex: int = MachineBudgetIndex):
      ArbiterView = ArbiterView(available: false)
  proc arbiterClient*(l: ShmLease; slot: int;
      budgetIndex: int = MachineBudgetIndex): ArbiterClient =
    ArbiterClient(view: ArbiterView(available: false), slot: slot)
  proc attachLeaseSegment*(path: string; wantBase: pointer = nil): ShmLease =
    ShmLease(available: false, path: path)
  proc detach*(l: var ShmLease) = discard
  proc packedRemaining*(l: ShmLease; idx: int): uint64 = 0
  proc packedCapacity*(l: ShmLease; idx: int): uint64 = 0
  proc casPackedRemaining*(l: ShmLease; idx: int; expected: var uint64;
      desired: uint64): bool = false
  proc remainingVec*(l: ShmLease; idx: int = MachineBudgetIndex): ResourceVec =
    ResourceVec()
  proc capacityVec*(l: ShmLease; idx: int = MachineBudgetIndex): ResourceVec =
    ResourceVec()
  proc outstandingVec*(l: ShmLease; idx: int = MachineBudgetIndex): ResourceVec =
    ResourceVec()
  proc noOvercommit*(l: ShmLease; idx: int): bool = true
  proc noOvercommitAnywhere*(l: ShmLease): bool = true
  proc claimCount*(l: ShmLease; idx: int = MachineBudgetIndex): uint64 = 0
  proc releaseCount*(l: ShmLease; idx: int = MachineBudgetIndex): uint64 = 0
  proc refusalCount*(l: ShmLease; idx: int = MachineBudgetIndex): uint64 = 0
  proc retryCount*(l: ShmLease; idx: int = MachineBudgetIndex): uint64 = 0
  proc rollbackCount*(l: ShmLease; idx: int = MachineBudgetIndex): uint64 = 0
  proc claimedUnits*(l: ShmLease; idx: int; d: LeaseDim): uint64 = 0
  proc releasedUnits*(l: ShmLease; idx: int; d: LeaseDim): uint64 = 0
  proc claimWords*(l: var ShmLease; v: ResourceVec; budgets: openArray[int];
      res: var Reservation): ClaimStatus =
    res = Reservation(); csUnavailable
  proc claim*(l: var ShmLease; v: ResourceVec; res: var Reservation;
      poolIndex: int = -1): ClaimStatus =
    res = Reservation(); csUnavailable
  proc releaseWords*(l: var ShmLease; v: ResourceVec;
      budgets: openArray[int]): bool = false
  proc release*(l: var ShmLease; res: var Reservation): bool = false
  proc releaseVec*(l: var ShmLease; v: ResourceVec; poolIndex: int = -1): bool = false
  proc creatorBootId*(l: ShmLease): uint64 = 0
  proc ownerPid*(l: ShmLease): uint64 = 0
  proc ownerStartTime*(l: ShmLease): uint64 = 0
  proc ownerVerdict*(l: ShmLease): AnchorVerdict = avNoOwner
  proc ownerAlive*(l: ShmLease): bool = false
  proc mappedBase*(l: ShmLease): pointer = nil
  proc segmentSize*(l: ShmLease): int = 0
  proc storedPointerCheck*(l: ShmLease): bool = true
  proc assertNoStoredPointers*(l: ShmLease) = discard
  proc writeProbeWord*(l: ShmLease; v: uint64) = discard
