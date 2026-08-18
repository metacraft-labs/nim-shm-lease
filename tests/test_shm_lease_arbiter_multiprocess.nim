## THE M5 GATE — a multi-process flat-combining arbiter whose ROLE MIGRATES.
##
## `RunQuota-Observation-Store.milestones.org` ** M5 :gate:
##   "Multi-process test where the arbiter role migrates between client processes.
##    Asserts (a) wakes <= grants under a release that frees capacity for several
##    waiters, (b) no waiter ever re-checks-and-sleeps (no wake without a grant),
##    (c) admission decisions are identical to a single-threaded reference
##    implementation given the same request sequence -- so packing quality is
##    provably unchanged by making the arbiter migrate."
##   :proves: SM-3; partial SM-4
##
## MOCKS: none, and none are possible. The property under test is that a
## SERIALIZATION POINT MIGRATES BETWEEN ADDRESS SPACES, so the test uses `fork`ed
## processes, a real file-backed `mmap(MAP_SHARED)` segment, real `mmap` at
## deliberately distinct addresses, and the real futex-class park. Threads would
## not test this: they share one address space, which is precisely what the design
## says must not be relied on. The SINGLE-THREADED REFERENCE in PART 3 is not a
## mock either — it is the specification of the admission policy, written
## independently of the arbiter and compared against it, which is what the gate's
## clause (c) asks for.
##
## HOW EACH CLAUSE IS PROVEN, AND WHY EACH ASSERTION CAN FAIL:
##
## 0. THE ROLE REALLY MIGRATES, AND IT IS STRUCTURAL RATHER THAN INCIDENTAL.
##    M2 paid for this lesson: its gate asserted CAS retries > 0 without forcing
##    the children to overlap, and ~4% of release runs failed because the children
##    ran end to end. Timing cannot be fixed with more timing, so there are THREE
##    gates here, and together they make migration a FACT:
##      1. START BARRIER — no child begins until every child has attached.
##      2. COMBINED GATE — each child announces the first round it COMMITS, and
##         the parent waits for that announcement from EVERY child.
##      3. STOP GATE — no child may leave its loop until the parent has heard all
##         N announcements. So at the instant the parent has them, every child has
##         owned the role at least once and none has exited.
##    Because every child owns at least one epoch, the epoch-ordered sequence of
##    owners contains all N of them and therefore has at least N-1 CHANGES of
##    owner. That assertion is made FIRST, before the clauses that depend on it,
##    so a regression names the cause rather than a symptom. PART 3 is the proof
##    that it can be absent: the identical workload with a single permitted
##    combiner produces exactly ONE distinct owner.
##
## (a) WAKES <= GRANTS UNDER A RELEASE THAT FREES CAPACITY FOR SEVERAL WAITERS.
##    PART 2 is that scenario, controlled: the parent holds nearly the whole
##    budget, four children publish requests that CANNOT fit and park in the
##    kernel, the parent waits until every one of them has actually parked, and
##    only then releases and runs ONE round. That round grants all four and wakes
##    exactly four. The assertion is `wakes == grants` for the round and
##    `wakes <= grants` in aggregate, and it fails under `amCounterPublish` — see
##    `tests/test_shm_lease_arbiter.nim`, where a republished counter bump makes
##    wakes exceed grants in a deterministic setting.
##
## (b) NO WAITER EVER RE-CHECKS AND SLEEPS, ASSERTED AS A PROPERTY OF THE CODE
##    RATHER THAN OF THE KERNEL. Two assertions, on the two sides of the wake:
##      * PUBLISHER — `check st.wakeCalls <= st.answersPublished`. Every wake
##        `publishOne` issues is preceded, in the same straight-line block, by the
##        successful value CAS it announces. A wake delivered before its answer
##        existed cannot satisfy this.
##      * WAITER — `check st.parksWokenIncomplete == 0`. A park that returns with
##        its WAIT WORD MOVED was woken by this protocol, and grant-then-wake
##        (payload, then value, then wake) means it must find the payload its
##        value word is tagged with. Publishing the value ahead of its payload
##        makes this fire. The anti-vacuity companion —
##        `check sc.wokenWithAnswer > 0`, i.e. waiters really were woken rather
##        than merely never woken wrongly — is asserted in PART 2, where the
##        parent has PROOF that all four waiters were in the kernel before the
##        only round ran. In the churn arm it would be a bet on how often a 20 ms
##        park loses to a round, which is exactly the kind of assertion this gate
##        stopped making.
##    **WHAT IS NOT ASSERTED, AND WHY.** An earlier version asserted that no park
##    ever returned from a wake with the wait word unchanged. That is a property of
##    the KERNEL's wait primitive, not of this code: a spurious wakeup is permitted
##    and would have failed the gate on a run in which nothing was wrong. The count
##    is still collected and PRINTED (`parksSpurious`), because a protocol defect
##    that woke waiters early would inflate it — but it is an observation, and the
##    assertions above are what clause (b) rests on.
##
## (c) DECISIONS IDENTICAL TO A SINGLE-THREADED REFERENCE. Every committed round
##    records the held-set it scanned and every decision it took, in order; the
##    parent merges those logs by epoch — rounds are totally ordered by the commit
##    CAS, so this is the real serialization order — and replays them through a
##    REFERENCE ADMISSION FUNCTION that keeps its OWN budget arithmetic. It
##    asserts three things at every round: no slot is held that the reference
##    never granted (a discarded round's grant surviving would show up here), the
##    arbiter's held sum equals the reference's, and every decision is the one the
##    reference would have taken. PART 4 is the proof that this can fail: four real
##    waiters, one round, and a fit test blind to its own proposals — the replay
##    reports the two decisions the reference would not have taken. Its BOUNDARY —
##    what the replay can and cannot see, and why an under-counting held-set is
##    absorbed rather than reported — is stated at `replay` below, along with what
##    the reference does and does not share with the arbiter.
##
## WHAT THIS GATE DOES NOT PROVE. M6's anti-starvation (a large claim is admitted
## within a bounded wait) and M7's kill injection and reclamation are out of scope
## and are not sampled here. A request that does not fit stays pending, which is
## how a waiter exists at all, and nothing here bounds how long it stays that way.
##
## AND IT IS NOT A REGRESSION DETECTOR FOR THE DEFECT IT FOUND. Clause (c) caught
## the two-load `heldVec` read that no invariant in the suite caught — but its
## SENSITIVITY WAS MEASURED, twice, by removing the re-validation and re-running
## this gate: 1 firing in 33 runs on the build that first shipped, and ZERO firings
## in 33 runs on this one (2,297 committed rounds replayed, every assertion green).
## One firing in 66 runs. It is a DISCOVERY mechanism; anyone relying on it to
## notice that defect coming back would almost certainly miss it, and the argument
## at `heldVec` is what the correctness actually rests on.

import std/[algorithm, os, posix, unittest]
import shm_lease

# --- geometry ---------------------------------------------------------------

const
  NChildren = 6
  ParentSlot = NChildren            ## the parent is a client too, in PART 2
  NSlots = NChildren + 1

  MachineCap = vec(8, 64, 8, 100)
    ## 8 CPU slots against six children asking for 1..3 each: the budget is
    ## genuinely oversubscribed, so requests really do have to wait.

  RequestsPerChild = 8
  MaxLoggedRounds = 1024
  MaxLoggedDecisions = NSlots

  ParkNs = 20_000_000'i64           ## bounded park; a wedged run fails loudly
  RequestDeadlineNs = 20_000_000_000'i64
  PostQuotaRounds = 2_000_000       ## hard cap on the "keep combining" tail
  TailDeadlineNs = 30_000_000_000'u64
    ## ...and a wall-clock cap beside it, because the tail's job is to keep the
    ## OTHER children served until the parent says everyone is done. In the
    ## single-combiner control that duty is the whole reason the run terminates:
    ## nobody else may take the role, so if the lone combiner stopped early every
    ## other child would sit out its request deadline. Two caps rather than one
    ## because an iteration count alone measures this host's speed.

  ParentSampleBudget = 20_000
    ## The parent samples the no-overcommit invariant a FIXED number of times, for
    ## the reason M2's harness gives: a figure that moves with ambient load cannot
    ## be quoted as a measured property.

type
  ChildMode = enum
    cmCombine        ## the full protocol: publish, combine, collect, release
    cmSingleCombiner ## only child 0 may take the role; the rest are pure waiters

  LoggedDecision = object
    slot: uint16
    kind: uint16     ## `DecisionKind`, widened so the record has no padding holes
    gen: uint32
    want: uint64

  LoggedRound = object
    epoch: uint32
    owner: uint16
    decisionCount: uint16
    heldMask: uint64
    held: uint64                    ## packed, by the ARBITER's arithmetic
    decisions: array[MaxLoggedDecisions, LoggedDecision]

  ChildReport = object
    ## Written to the child's OWN FILE rather than to a pipe — see `writeReport`
    ## for the deadlock that made that necessary.
    ok: uint64
    childId: uint64
    base: uint64                    ## the virtual base this child mapped at
    errors: uint64
    deadlineMisses: uint64
    logFull: uint64
    obligationRequests: uint64      ## requests published by the role-obligation
                                    ## phase, so the request accounting below
                                    ## stays an EXACT identity rather than a bound
    startNs: uint64
    endNs: uint64
    stats: ArbiterStats
    roundCount: uint64
    rounds: array[MaxLoggedRounds, LoggedRound]

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
proc quitChild(code: cint) {.noreturn.} = cExit(code)

var tmpCounter = 0
proc freshPath(tag: string): string =
  inc tmpCounter
  getTempDir() / ("shmlease-m5-" & tag & "-" & $getpid() & "-" & $tmpCounter & ".seg")

proc cleanup(path: string) =
  try: removeFile(path)
  except CatchableError: discard
  # ...and any child report a failed run left behind: the parent unlinks them as
  # it reads them, so these exist only when a run did not finish.
  for i in 0 ..< NChildren:
    try: removeFile(path & ".rep." & $i)
    except CatchableError: discard

proc nowNs(): uint64 =
  var ts: Timespec
  discard clock_gettime(CLOCK_MONOTONIC, ts)
  uint64(ts.tv_sec) * 1_000_000_000'u64 + uint64(ts.tv_nsec)

proc writeFull(fd: cint; p: pointer; n: int): bool =
  var done = 0
  while done < n:
    let w = write(fd, cast[pointer](cast[uint](p) + uint(done)), n - done)
    if w <= 0: return false
    done += int(w)
  true

proc readFull(fd: cint; p: pointer; n: int): bool =
  var done = 0
  while done < n:
    let r = read(fd, cast[pointer](cast[uint](p) + uint(done)), n - done)
    if r <= 0: return false
    done += int(r)
  true

proc setNonBlocking(fd: cint) =
  discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) or O_NONBLOCK)

proc stopSignalled(fd: cint): bool =
  ## The parent holds the only write end: while it is open and empty a
  ## non-blocking read returns EAGAIN, and one `close` is a broadcast EOF that no
  ## reader can mistake for "not yet".
  var b: byte
  read(fd, addr b, 1) == 0

proc stableHeld(v: ArbiterView; ok: var bool): ResourceVec =
  ## Sum the EFFECTIVE grants under a seqlock-style guard, and say whether the
  ## sample is usable.
  ##
  ## THE LEDGER SUM IS A MULTI-WORD READ, AND "held <= capacity" IS NOT AN
  ## INVARIANT OF A NAIVE ONE. Read slot A, watch it be released, watch a new
  ## round grant that capacity to slot B, then read slot B: both are counted and
  ## the sum can exceed the capacity while nothing is wrong. Measured: one sample
  ## in ~160,000 tripped exactly that. It is the same reason MV2 states
  ## `BudgetExact` only at `Quiet` rather than at every state.
  ##
  ## The guard makes the sample sound rather than approximate. If the role word
  ## and the combine sequence are unchanged across the scan then NO ROUND
  ## COMMITTED during it, so no grant was added; the only concurrent mutations are
  ## releases, and every entry counted was therefore already granted and not yet
  ## released when the scan began — i.e. all of them were held SIMULTANEOUSLY, and
  ## `sum <= capacity` really is asserted of a state the system was in.
  ok = false
  let role0 = v.roleSnapshot()
  let seq0 = v.combineSeq()
  var total = ResourceVec()
  for i in 0 ..< v.slotCount:
    let e = v.ledgerAt(i)
    if ledgerDec(e) == ldGrant and ledgerEpoch(e) <= seq0:
      # The decision and the amount are two words; re-validate the pair, exactly
      # as `heldVec` does, or a release-and-re-request in the middle of this scan
      # attributes the new amount to the old grant.
      let w = v.wantAt(i)
      if v.ledgerAt(i) != e: continue
      total = total + unpackVec(w)
  if v.roleSnapshot() == role0 and v.combineSeq() == seq0:
    ok = true
  total

proc wantFor(childId, req: int): ResourceVec =
  ## A deterministic per-(child, request) vector — deterministic so a failing run
  ## can be re-read, and spread so the packing has real choices to make.
  let c = uint32(childId)
  vec(1 + (c + uint32(req)) mod 3'u32,
      2 + (c * 3 + uint32(req) * 5) mod 11'u32,
      1,
      3 + (c * 2 + uint32(req)) mod 7'u32)

proc logRound(rep: var ChildReport; r: CombineRound) =
  if rep.roundCount >= uint64(MaxLoggedRounds):
    rep.logFull = 1
    return
  var lr = LoggedRound(epoch: r.epoch, owner: r.owner,
    decisionCount: uint16(min(r.decisionCount, MaxLoggedDecisions)),
    heldMask: r.heldMask, held: packVec(r.held))
  for i in 0 ..< int(lr.decisionCount):
    lr.decisions[i] = LoggedDecision(slot: r.decisions[i].slot,
      kind: uint16(ord(r.decisions[i].kind)), gen: r.decisions[i].gen,
      want: r.decisions[i].want)
  rep.rounds[rep.roundCount] = lr
  inc rep.roundCount

# ===========================================================================
# THE CHILD
# ===========================================================================

proc writeReport(repPath: string; rep: ptr ChildReport): bool =
  ## THE ROUND LOG GOES THROUGH A FILE, NOT A PIPE, and the reason is a deadlock
  ## this harness actually hit rather than a preference. `ChildReport` carries up
  ## to 1024 logged rounds and is ~150 KiB; a pipe holds 64 KiB at most, so a child
  ## writing its report BLOCKS until the parent drains it — and if the parent is
  ## still at one of the gates, waiting for a byte from a child that is itself
  ## blocked in that write, neither ever moves. Sampled and confirmed: parent in
  ## `read`, child in `write`. Shrinking the record would only move the cliff, so
  ## the fix is to stop making report size a synchronisation question at all. The
  ## one-byte gate pipes stay pipes; they are three orders of magnitude inside the
  ## buffer.
  let fd = open(repPath.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o600)
  if fd < 0: return false
  result = writeFull(fd, rep, sizeof(ChildReport))
  discard close(fd)

proc childMain(childId: int; path: string; wantBase: pointer; mode: ChildMode;
    repPath: string; readyW: cint; goR: cint; combinedW: cint; go2R: cint;
    pubW: cint; go3R: cint; quotaW: cint; stopR: cint) {.noreturn.} =
  # A heap allocation, deliberately: `ChildReport` carries the round log and is
  # far too large for the stack of a forked child.
  var rep = cast[ptr ChildReport](alloc0(sizeof(ChildReport)))
  rep.childId = uint64(childId)
  rep.base = cast[uint64](wantBase)

  var l = attachLeaseSegment(path, wantBase)
  if not l.available or cast[uint](l.mappedBase()) != cast[uint](wantBase):
    discard writeReport(repPath, rep)
    quitChild(11)
  var c = l.arbiterClient(childId)
  if not c.registerSlot(childId):
    discard writeReport(repPath, rep)
    quitChild(12)
  let mayCombine = mode == cmCombine or
    (mode == cmSingleCombiner and childId == 0)

  # START BARRIER: announce "attached", then block until the parent releases every
  # child with one `close`. No child begins before every child is attached, so the
  # contention is structural rather than a function of fork latency.
  var one: byte = 1
  if not writeFull(readyW, addr one, 1):
    discard writeReport(repPath, rep); quitChild(13)
  discard close(readyW)
  var goByte: byte
  discard read(goR, addr goByte, 1)
  discard close(goR)
  setNonBlocking(stopR)
  rep.startNs = nowNs()

  var announced = false
  var r: CombineRound
  let quota = RequestsPerChild
  let deadlineNs = uint64(RequestDeadlineNs)

  proc announceCombined() =
    if not announced:
      announced = true
      discard writeFull(combinedW, addr one, 1)
      discard close(combinedW)

  # ------------------------------------------------------------------------
  # THE ROLE OBLIGATION, and it is what makes migration STRUCTURAL.
  # ------------------------------------------------------------------------
  #
  # A child does not begin its measured workload until it has PERSONALLY OWNED
  # THE ROLE at least once. It keeps a small request outstanding — so there is
  # always work to combine, and `workPending` is true — and races for the role
  # until it wins one round.
  #
  # The first version of this harness left that to chance: the parent simply
  # waited for every child to announce a committed round, and about one run in six
  # a child was answered by its peers so promptly that it never needed to combine
  # at all, so the announcement never came and the gate died at the barrier. That
  # is the same defect M2 had — a property the gate DEPENDS on left to scheduling —
  # and the same fix applies: make the child establish it rather than the parent
  # hope for it. Nothing is handed to anybody: the role is still won by a
  # contended CAS against five other processes, and `busy`/`lost` in the summary
  # line are the races it lost on the way.
  if mayCombine:
    var committed = false
    var mine = false
    var attempts = 0
    let obligationDeadline = nowNs() + 10_000_000_000'u64
    while not committed and attempts < 1_000_000:
      inc attempts
      if not mine and c.publishRequest(vec(1, 1, 1, 1)) == psPublished:
        mine = true
        inc rep.obligationRequests
      if c.tryCombine(r) == cbCommitted:
        logRound(rep[], r)
        committed = true
      if mine and c.view.answerArrived(c.slot):
        if c.collectAnswer() == ansGranted:
          discard c.releaseGrant()
        mine = false
      if nowNs() > obligationDeadline: break
    # SETTLE THE OBLIGATION REQUEST BEFORE THE MEASURED WORKLOAD BEGINS. Leaving
    # one outstanding would make the first request of the quota fail with
    # `psNotIdle` — the slot is a one-request-at-a-time resource by construction,
    # which is the very precondition M5 exists to satisfy.
    let drainDeadline = nowNs() + uint64(RequestDeadlineNs)
    while mine and nowNs() < drainDeadline:
      discard c.tryCombine(r)
      if r.status == cbCommitted: logRound(rep[], r)
      if c.view.answerArrived(c.slot):
        if c.collectAnswer() == ansGranted:
          discard c.releaseGrant()
        mine = false
      else:
        discard c.awaitAnswer(ParkNs)
    if not committed or mine: inc rep.errors
  announceCombined()

  # THE PHASE BARRIER. The obligation phase and the measured workload are kept
  # APART, and the reason is a property of M5 rather than of the harness: the scan
  # is first-fit in ascending slot order and there is NO anti-starvation — that is
  # M6, deliberately not implemented here. Overlapping the two phases keeps the
  # budget saturated, and a high-index slot then waits behind the low-index ones
  # for as long as the load lasts; measured, it stalled a child past a five-second
  # drain. Separating the phases keeps each one's demand inside the capacity, so
  # the gate measures the arbiter rather than the starvation M6 owns.
  var go2Byte: byte
  discard read(go2R, addr go2Byte, 1)
  discard close(go2R)

  # PUBLISH THE FIRST MEASURED REQUEST WHILE NOBODY IS COMBINING, and then wait
  # again. This is what makes the packing decisions STRUCTURAL rather than a
  # matter of who happened to be scheduled: when the third barrier opens, all six
  # requests are on the board at once and they ask for 12 CPU slots against a
  # capacity of 8, so the first round CANNOT grant them all and the arbiter has to
  # take a real packing decision. Published before the barrier rather than after
  # it because a child still combining would otherwise answer a request that had
  # arrived early, and the run would be back to measuring the scheduler. (Observed:
  # without this, one run in eight had every decision a grant, and the anti-vacuity
  # assertion below correctly failed.)
  let firstWant = wantFor(childId, 0)
  var prePublished = c.publishRequest(firstWant) == psPublished
  if not prePublished: inc rep.errors
  discard writeFull(pubW, addr one, 1)
  discard close(pubW)
  var go3Byte: byte
  discard read(go3R, addr go3Byte, 1)
  discard close(go3R)

  for req in 0 ..< quota:
    let want = wantFor(childId, req)
    if req == 0 and prePublished:
      prePublished = false            # already on the board, by construction
    elif c.publishRequest(want) != psPublished:
      inc rep.errors
      break
    let deadline = nowNs() + deadlineNs
    var answer = ansNone
    while answer != ansGranted and answer != ansRefused:
      if mayCombine and rep.logFull == 0:
        # A round is only ever DROPPED FROM THE LOG if the log is full, and the
        # child stops combining before that can happen — so "every committed round
        # is in some child's log" is a property of the code, not an assumption the
        # replay makes.
        if c.tryCombine(r) == cbCommitted:
          logRound(rep[], r)
          announceCombined()
      if c.view.answerArrived(c.slot):
        answer = c.collectAnswer()
        break
      answer = c.awaitAnswer(ParkNs)
      if nowNs() > deadline:
        inc rep.deadlineMisses
        break
    if answer == ansGranted:
      # Hold briefly, then give it back and immediately run a round: a release is
      # what frees capacity for the waiters, and the releaser combining is what
      # delivers it to them.
      for spin in 0 ..< 50: discard nowNs()
      if not c.releaseGrant(): inc rep.errors
      if mayCombine and rep.logFull == 0:
        if c.tryCombine(r) == cbCommitted:
          logRound(rep[], r)
          announceCombined()
    elif answer == ansRefused:
      inc rep.errors          # every want in this workload fits an idle machine
    else:
      inc rep.errors

  # Announce that this child's request quota is complete. The parent will not open
  # the stop gate until it has heard this from EVERY child, which is what keeps a
  # child that has finished from abandoning the others: in the single-combiner
  # control nobody else may take the role, so the lone combiner leaving early
  # would strand every remaining request.
  discard writeFull(quotaW, addr one, 1)
  discard close(quotaW)

  # THE STOP GATE: keep working until the parent says everyone is done. A child
  # that has finished its quota keeps COMBINING, which is what keeps the others
  # live, and the two caps keep it terminating even if the parent dies.
  var tail = 0
  let tailDeadline = nowNs() + TailDeadlineNs
  while tail < PostQuotaRounds:
    inc tail
    if mayCombine and rep.logFull == 0:
      if c.tryCombine(r) == cbCommitted:
        logRound(rep[], r)
        announceCombined()
    if stopSignalled(stopR): break
    if nowNs() > tailDeadline: break
    discard sched_yield()
  discard close(stopR)
  if not announced and mayCombine:
    # It never committed a round; the parent's gate will report the shortfall.
    discard
  rep.endNs = nowNs()
  rep.stats = c.stats
  rep.ok = 1
  if not writeReport(repPath, rep): quitChild(4)
  quitChild(0)

# ===========================================================================
# THE HARNESS
# ===========================================================================

type RunResult = object
  reports: seq[ChildReport]
  parentBase: uint64
  parentSamples: uint64
  overcommitSamples: uint64
  allCombinedNs: uint64
    ## The instant the parent held "I committed a round" from EVERY child while
    ## the stop gate was still shut — so at that instant the role had provably
    ## been owned by all N of them and none had exited.

proc runHarness(l: var ShmLease; path: string; mode: ChildMode): RunResult =
  let segSize = l.segmentSize()
  # PAGE SIZE IS A HOST PROPERTY — 16 KiB on Apple Silicon — and M2 paid for
  # assuming otherwise: a `MAP_FIXED` base strided by 4096 is misaligned for 3 of
  # every 4 children and fails with a silent `EINVAL`.
  let ps = int(sysconf(SC_PAGESIZE))
  doAssert ps > 0
  let stride = ((segSize + ps - 1) div ps) * ps
  let regionSize = stride * (NChildren + 1)
  let region = mmap(nil, regionSize, PROT_NONE,
    MAP_PRIVATE or MAP_ANONYMOUS, cint(-1), 0)
  doAssert region != MAP_FAILED
  doAssert cast[uint](l.mappedBase()) < cast[uint](region) or
    cast[uint](l.mappedBase()) >= cast[uint](region) + uint(regionSize)

  var readyFds, goFds, combinedFds, go2Fds, pubFds, go3Fds, quotaFds,
    stopFds: array[0..1, cint]
  doAssert pipe(readyFds) == 0
  doAssert pipe(go2Fds) == 0
  doAssert pipe(pubFds) == 0
  doAssert pipe(go3Fds) == 0
  doAssert pipe(goFds) == 0
  doAssert pipe(combinedFds) == 0
  doAssert pipe(quotaFds) == 0
  doAssert pipe(stopFds) == 0

  var pids: seq[Pid]
  for i in 0 ..< NChildren:
    let childBase = cast[pointer](cast[uint](region) + uint(i * stride))
    let pid = fork()
    if pid == 0:
      discard close(readyFds[0])
      discard close(combinedFds[0])
      discard close(pubFds[0])
      discard close(quotaFds[0])
      discard close(goFds[1])
      discard close(go2Fds[1])
      discard close(go3Fds[1])
      discard close(stopFds[1])
      childMain(i, path, childBase, mode, path & ".rep." & $i, readyFds[1],
        goFds[0], combinedFds[1], go2Fds[0], pubFds[1], go3Fds[0], quotaFds[1],
        stopFds[0])
    doAssert pid > 0
    pids.add pid
  discard close(readyFds[1])
  discard close(combinedFds[1])
  discard close(pubFds[1])
  discard close(quotaFds[1])
  discard close(goFds[0])
  discard close(go2Fds[0])
  discard close(go3Fds[0])
  discard close(stopFds[0])

  # GATE 1 — every child has attached.
  for i in 0 ..< NChildren:
    var b: byte
    doAssert readFull(readyFds[0], addr b, 1),
      "child " & $i & " never reached the start barrier"
  discard close(readyFds[0])
  discard close(goFds[1])              # BROADCAST: begin

  # GATE 2 — every child that may combine has COMMITTED A ROUND. The stop gate is
  # still shut, so none of them has left: at this instant the role has been owned
  # by all of them.
  let expectCombined =
    if mode == cmSingleCombiner: 1 else: NChildren
  for i in 0 ..< expectCombined:
    var b: byte
    doAssert readFull(combinedFds[0], addr b, 1),
      "only " & $i & " of " & $expectCombined & " children ever owned the role"
  discard close(combinedFds[0])
  result.allCombinedNs = nowNs()
  discard close(go2Fds[1])             # BROADCAST: publish your first request

  # GATE 2b — every child's first measured request is on the board, and no round
  # has run since. The next round therefore sees ALL of them.
  for i in 0 ..< NChildren:
    var b: byte
    doAssert readFull(pubFds[0], addr b, 1),
      "child " & $i & " never published its first measured request"
  discard close(pubFds[0])
  discard close(go3Fds[1])             # BROADCAST: the measured workload begins

  # Sample the invariant from the parent's own mapping, a distinct base, while the
  # children are provably all still inside their loops.
  result.parentBase = cast[uint64](l.mappedBase())
  let v = l.arbiterView()
  for _ in 0 ..< ParentSampleBudget:
    var usable = false
    let held = stableHeld(v, usable)
    if usable:
      inc result.parentSamples
      if not vecFits(held, MachineCap): inc result.overcommitSamples
    if not l.noOvercommit(MachineBudgetIndex): inc result.overcommitSamples

  # GATE 3 — every child has finished its request quota. Only now may the stop
  # gate open: a combiner that left while another child still had a request
  # outstanding would strand it, and in the single-combiner control it would
  # strand ALL of them.
  for i in 0 ..< NChildren:
    var b: byte
    doAssert readFull(quotaFds[0], addr b, 1),
      "child " & $i & " never finished its request quota"
  discard close(quotaFds[0])

  discard close(stopFds[1])            # BROADCAST: you may leave

  # REAP FIRST, THEN READ THE REPORT FILES. With the reports out of the pipes
  # this ordering is safe by construction: nothing a child does after the stop
  # gate can block on the parent.
  for k in 0 ..< pids.len:
    var st: cint
    doAssert waitpid(pids[k], st, 0) == pids[k]
    doAssert WIFEXITED(st) and WEXITSTATUS(st) == 0,
      "child " & $k & " did not exit cleanly (status " & $WEXITSTATUS(st) & ")"
  for i in 0 ..< NChildren:
    let rp = path & ".rep." & $i
    let fd = open(rp.cstring, O_RDONLY)
    doAssert fd >= 0, "child " & $i & " left no report at " & rp
    var rep = ChildReport()
    doAssert readFull(fd, addr rep, sizeof(ChildReport)),
      "short read of child report " & $i
    discard close(fd)
    discard unlink(rp.cstring)
    result.reports.add rep
  discard munmap(region, regionSize)

# ===========================================================================
# THE SINGLE-THREADED REFERENCE IMPLEMENTATION — the gate's clause (c).
# ===========================================================================
#
# This is the admission policy, written out once, plainly, with no concurrency in
# it: keep what is held, and for each request in the order it was considered,
# grant it iff it fits in `capacity - held - what this round has already granted`,
# refuse it iff it could never fit, and otherwise leave it pending.
#
# WHAT IT SHARES WITH THE ARBITER, STATED EXACTLY. It shares the `ResourceVec`
# type, `unpackVec`, and the saturating `-` operator — the vocabulary the logged
# record is written in, which it could not read without. What it does NOT share is
# the POLICY: `referenceAdmit` below re-derives the fit test and the ordering from
# the specification rather than calling `vecFits`, `availableVec` or anything else
# in `shm_lease/arbiter`, and it keeps its own `refHeld` ledger rather than reading
# the arbiter's. That is what makes an agreement a cross-check: a bug in the
# arbiter's decision rule cannot hide inside a shared implementation of it. A bug
# in `unpackVec` or in saturating subtraction COULD hide, and is not what this
# gate is for.
#
# It is driven by the arbiter's own linearisation order: rounds ascending by
# epoch (the commit CAS totally orders them), decisions in the order the round
# took them. Releases are ENVIRONMENTAL — they happen when a client chooses — so
# the round's recorded held-set is what tells the reference which of the grants it
# knows about had been given back by the time that round scanned. That is an input
# from the run, not an answer copied from it: the reference still checks that no
# slot is held that IT never granted, that the sums agree, and that every decision
# is the one it would have made.
#
# THE BOUNDARY OF CLAUSE (c), STATED SO NOBODY READS MORE INTO IT. Step (2) below
# clears `refHeld[s]` for EVERY slot absent from the round's `heldMask`, because
# that is how a release is inferred. The consequence is that an UNDER-COUNTING
# `heldMask` is absorbed as "the client must have released" and is never reported:
# clause (c) proves decision identity GIVEN the round's held-set, and it validates
# that held-set's AMOUNT (step 3, `heldMismatches`) but not its MEMBERSHIP in the
# under-counting direction. Over-counting IS caught — a slot held that the
# reference never granted is a `phantomHold`, which is Finding 4's damage. So: a
# discarded round's grant surviving would be seen; a round that silently dropped a
# live grant from its own view would not be, and is ruled out by the argument in
# `heldVec` rather than by this replay.

type
  ReplayResult = object
    rounds: int
    decisions: int
    grants: int
    pendingCount: int
    refusals: int
    mismatches: int          ## decisions the reference would not have taken
    phantomHolds: int        ## a slot held that the reference never granted
    heldMismatches: int      ## the arbiter's held sum != the reference's
    firstMismatch: string
    finalHeld: ResourceVec
    finalHeldSlots: set[uint8]

proc referenceAdmit(capacity, held, proposed, want: ResourceVec): DecisionKind =
  ## THE POLICY, in one function. First-fit against what is genuinely free,
  ## counting this round's own grants — a request that cannot fit an IDLE machine
  ## is refused outright, anything else that does not fit right now waits.
  let free = (capacity - held) - proposed
  if want.cpuSlots <= free.cpuSlots and want.memUnits <= free.memUnits and
     want.procs <= free.procs and want.ioWeight <= free.ioWeight:
    return dkGrant
  if want.cpuSlots > capacity.cpuSlots or want.memUnits > capacity.memUnits or
     want.procs > capacity.procs or want.ioWeight > capacity.ioWeight:
    return dkRefuse
  dkPending

proc replay(rounds: seq[LoggedRound]; capacity: ResourceVec): ReplayResult =
  var refHeld: array[NSlots, uint64]      # packed want per slot, 0 = not held
  result.rounds = rounds.len
  for rd in rounds:
    # (1) NO PHANTOM CAPACITY. A slot the arbiter counted as holding capacity must
    #     be one the reference granted and has not seen released. A grant from a
    #     round that was discarded — Finding 4's damage — appears exactly here.
    for s in 0 ..< NSlots:
      let bit = (rd.heldMask shr s) and 1'u64
      if bit == 1'u64 and refHeld[s] == 0'u64:
        inc result.phantomHolds
        if result.firstMismatch.len == 0:
          result.firstMismatch = "epoch " & $rd.epoch & ": slot " & $s &
            " held but never granted"
    # (2) Releases are environmental: what the reference holds and the round did
    #     not count has been given back since the reference last looked.
    for s in 0 ..< NSlots:
      if ((rd.heldMask shr s) and 1'u64) == 0'u64: refHeld[s] = 0'u64
    # (3) THE SUMS MUST AGREE, and the reference computes its own.
    var held = ResourceVec()
    for s in 0 ..< NSlots:
      if refHeld[s] != 0'u64: held = held + unpackVec(refHeld[s])
    if held != unpackVec(rd.held):
      inc result.heldMismatches
      if result.firstMismatch.len == 0:
        result.firstMismatch = "epoch " & $rd.epoch & ": held " & $unpackVec(rd.held) &
          " but the reference says " & $held
    # (4) EVERY DECISION IS THE ONE THE REFERENCE WOULD HAVE TAKEN.
    var proposed = ResourceVec()
    for i in 0 ..< int(rd.decisionCount):
      let d = rd.decisions[i]
      let want = unpackVec(d.want)
      let expected = referenceAdmit(capacity, held, proposed, want)
      let actual = DecisionKind(d.kind)
      inc result.decisions
      case actual
      of dkGrant: inc result.grants
      of dkPending: inc result.pendingCount
      of dkRefuse: inc result.refusals
      if actual != expected:
        inc result.mismatches
        if result.firstMismatch.len == 0:
          result.firstMismatch = "epoch " & $rd.epoch & " slot " & $d.slot &
            ": arbiter said " & $actual & ", reference says " & $expected &
            " (want " & $want & ", held " & $held & ", proposed " & $proposed & ")"
      if actual == dkGrant:
        proposed = proposed + want
        refHeld[d.slot] = d.want
  for s in 0 ..< NSlots:
    if refHeld[s] != 0'u64:
      result.finalHeld = result.finalHeld + unpackVec(refHeld[s])
      result.finalHeldSlots.incl uint8(s)

proc mergeRounds(run: RunResult): seq[LoggedRound] =
  ## Every committed round, from every process, in EPOCH ORDER. The epoch is
  ## unique per committed round because it is minted by the acquisition CAS and
  ## confirmed by the commit CAS on the same word, so this really is the
  ## serialization order rather than an approximation of it.
  for rep in run.reports:
    for i in 0 ..< int(rep.roundCount):
      result.add rep.rounds[i]
  result.sort(proc (a, b: LoggedRound): int = cmp(a.epoch, b.epoch))

proc ownerSequence(rounds: seq[LoggedRound]): (int, int) =
  ## (distinct owners, changes of owner across consecutive epochs).
  var seen: set[uint8]
  var changes = 0
  for i in 0 ..< rounds.len:
    seen.incl uint8(rounds[i].owner)
    if i > 0 and rounds[i].owner != rounds[i - 1].owner: inc changes
  (seen.card, changes)

# ===========================================================================
# PART 1 — the gate.
# ===========================================================================

suite "M5 gate: the arbiter role migrates between processes":
  test "migration, wakes <= grants, no wake without a grant, decisions identical":
    let path = freshPath("gate")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [MachineCap], requestSlots = NSlots)
    check l.available
    check l.requestSlots == NSlots

    let run = runHarness(l, path, cmCombine)
    check run.reports.len == NChildren

    var totalErrors, totalDeadline, totalLogFull, totalObligation: uint64 = 0
    var st = ArbiterStats()
    var bases: seq[uint64] = @[run.parentBase]
    for rep in run.reports:
      check rep.ok == 1
      totalErrors += rep.errors
      totalDeadline += rep.deadlineMisses
      totalLogFull += rep.logFull
      totalObligation += rep.obligationRequests
      bases.add rep.base
      st.roundsCommitted += rep.stats.roundsCommitted
      st.roundsBusy += rep.stats.roundsBusy
      st.roundsLost += rep.stats.roundsLost
      st.roundsFenced += rep.stats.roundsFenced
      st.steals += rep.stats.steals
      st.grantDecisions += rep.stats.grantDecisions
      st.refuseDecisions += rep.stats.refuseDecisions
      st.grantsPublished += rep.stats.grantsPublished
      st.answersPublished += rep.stats.answersPublished
      st.wakeCalls += rep.stats.wakeCalls
      st.wakeSyscalls += rep.stats.wakeSyscalls
      st.parks += rep.stats.parks
      st.parksWokenWithAnswer += rep.stats.parksWokenWithAnswer
      st.parksWokenIncomplete += rep.stats.parksWokenIncomplete
      st.parksSpurious += rep.stats.parksSpurious
      st.parksTimedOut += rep.stats.parksTimedOut
      st.fastAnswers += rep.stats.fastAnswers
      st.requests += rep.stats.requests
      st.grantsCollected += rep.stats.grantsCollected
      st.releases += rep.stats.releases
    check totalErrors == 0'u64
    check totalDeadline == 0'u64
    # The round log holds EVERY committed round, which is what the replay below
    # depends on. A child stops combining rather than dropping one, so this is a
    # report that the workload stayed inside its budget, not a soundness risk.
    check totalLogFull == 0'u64

    let rounds = mergeRounds(run)
    check rounds.len == int(st.roundsCommitted)

    # --- 0. THE ROLE REALLY MIGRATED. ASSERTED FIRST, ON PURPOSE -------------
    # If this fails, everything below is measuring a single-combiner run and would
    # pass for the wrong reason. PART 4 runs exactly that configuration and shows
    # these two numbers collapse to 1 and 0.
    let (owners, changes) = ownerSequence(rounds)
    check owners == NChildren
    check changes >= NChildren - 1
    # Every child's mapping was at its own virtual base, so the role migrated
    # between ADDRESS SPACES and not merely between handles (SM-7 carried forward).
    check bases.len == NChildren + 1
    for i in 0 ..< bases.len:
      for j in (i + 1) ..< bases.len:
        check bases[i] != bases[j]
    # NOT ASSERTED, AND DELIBERATELY REMOVED: `roundsBusy + roundsLost > 0`.
    # It was here to say "the migration was contended", and it asserted nothing of
    # the sort — those are counters of races LOST on the way to the role, and
    # whether any are lost is a question about this host's scheduler, not about
    # the protocol. Measured over 40 runs of this gate: `busy` ranged 0..280 and
    # `lost` 0..19, and two release runs had both at zero while every structural
    # claim below held. That is precisely the defect M2 was failed for — a
    # property the gate DEPENDS on left to scheduling — reintroduced as an
    # incidental counter. The claim it was reaching for is already carried, and
    # carried STRUCTURALLY, by `owners == NChildren` and
    # `changes >= NChildren - 1` above: every child personally owned the role
    # while every other child was still inside its loop, so the serialization
    # point provably moved between six live address spaces. The two numbers stay
    # in the summary line below as OBSERVATIONS, which is what they are.

    # --- 1. NO OVERCOMMIT, EVER ---------------------------------------------
    check run.overcommitSamples == 0'u64
    # Not every attempt yields a usable sample — one that straddles a commit is
    # discarded rather than counted — so this is a floor, and it is stated as one
    # instead of pretending the budget was a measurement.
    check run.parentSamples > uint64(ParentSampleBudget div 2)
    let v = l.arbiterView()
    check vecFits(v.heldSum(), MachineCap)
    check l.noOvercommit(MachineBudgetIndex)

    # --- 2. (a) WAKES <= GRANTS ---------------------------------------------
    # No want in this workload exceeds the capacity, so every answer published is
    # a GRANT and the aggregate reading is unambiguous. `amCounterPublish` makes
    # this fail deterministically in the unit suite.
    check st.refuseDecisions == 0'u64
    check st.grantDecisions > 0'u64
    check st.wakeCalls <= st.grantDecisions
    check st.answersPublished == st.grantDecisions
    check st.wakeSyscalls <= st.wakeCalls

    # --- 3. (b) NO WAKE WITHOUT A GRANT --------------------------------------
    # THE PUBLISHER SIDE: every wake was preceded by the answer it announces.
    check st.wakeCalls <= st.answersPublished
    # THE WAITER SIDE: every park this protocol actually woke found a complete,
    # coherent answer. A value word published ahead of its payload lands here.
    # `check st.parks > 0` beside it says waiters really did sleep; the
    # anti-vacuity that they were really WOKEN is PART 2's, where the parent has
    # proof that all four waiters were in the kernel before the only round ran —
    # here it would be a statement about how often a 20 ms park beats a round,
    # which is the kind of scheduling-dependent assertion this gate does not make.
    check st.parks > 0'u64
    check st.parksWokenIncomplete == 0'u64

    # --- 4. NO LOST REQUEST --------------------------------------------------
    # Every request was answered, every grant decided was collected exactly once,
    # and everything collected was given back.
    # ...an EXACT identity, not a bound: the measured quota plus the requests the
    # role-obligation phase published to have something to combine.
    check totalObligation > 0'u64
    check st.requests == uint64(NChildren * RequestsPerChild) + totalObligation
    check st.grantsCollected == st.grantDecisions
    check st.releases == st.grantsCollected

    # --- 5. (c) DECISIONS IDENTICAL TO THE REFERENCE -------------------------
    let rr = replay(rounds, MachineCap)
    check rr.rounds == rounds.len
    check rr.decisions > 0
    check rr.mismatches == 0
    check rr.phantomHolds == 0
    check rr.heldMismatches == 0
    if rr.mismatches + rr.phantomHolds + rr.heldMismatches > 0:
      echo "  [gate] FIRST DIVERGENCE: ", rr.firstMismatch
    # ...and the replay was not vacuous: the arbiter really did have to leave
    # requests pending, which is where a packing decision is actually taken.
    check rr.grants > 0
    check rr.pendingCount > 0

    # --- 6. CONSERVATION AT THE END ------------------------------------------
    # Every slot the ledger still counts as holding capacity is one the reference
    # also granted and has not seen released. (The converse is not asserted: a
    # release that landed after the last logged round is invisible to the replay,
    # and inventing an assertion that cannot see it would be worse than saying so.)
    let finalMask = block:
      var m: uint64
      discard v.heldVec(m)
      m
    for s in 0 ..< NSlots:
      if ((finalMask shr s) and 1'u64) == 1'u64:
        check uint8(s) in rr.finalHeldSlots

    echo "  [m5 gate] children=", NChildren, " rounds=", rounds.len,
      " owners=", owners, " owner-changes=", changes,
      " steals=", st.steals, " fenced=", st.roundsFenced,
      " busy=", st.roundsBusy, " lost=", st.roundsLost,
      " grants=", st.grantDecisions, " wakes=", st.wakeCalls,
      " wake-syscalls=", st.wakeSyscalls,
      " parks=", st.parks, " (timeouts ", st.parksTimedOut,
      ", woken-with-answer ", st.parksWokenWithAnswer,
      ", incomplete ", st.parksWokenIncomplete,
      ", spurious ", st.parksSpurious, ")",
      " fast-answers=", st.fastAnswers,
      " decisions=", rr.decisions, " (grant ", rr.grants, " / pending ",
      rr.pendingCount, ") reference mismatches=", rr.mismatches
    l.detach()

# ===========================================================================
# PART 2 — clause (a) in its own controlled scenario.
# ===========================================================================

type WaiterReport = object
  ok: uint64
  parks: uint64
  parksWokenWithAnswer: uint64
  parksWokenIncomplete: uint64
  parksSpurious: uint64
  fastAnswers: uint64
  granted: uint64
  base: uint64

const NWaiters = 4

proc waiterMain(childId: int; path: string; wantBase: pointer; want: ResourceVec;
    repFd: cint; readyW: cint; goR: cint; parkedW: cint) {.noreturn.} =
  var rep = WaiterReport(base: cast[uint64](wantBase))
  var l = attachLeaseSegment(path, wantBase)
  if not l.available:
    discard writeFull(repFd, addr rep, sizeof(rep)); quitChild(11)
  var c = l.arbiterClient(childId)
  if not c.registerSlot(childId):
    discard writeFull(repFd, addr rep, sizeof(rep)); quitChild(12)
  if c.publishRequest(want) != psPublished:
    discard writeFull(repFd, addr rep, sizeof(rep)); quitChild(13)
  var one: byte = 1
  discard writeFull(readyW, addr one, 1)
  discard close(readyW)
  var goByte: byte
  discard read(goR, addr goByte, 1)
  discard close(goR)

  # A PURE WAITER: it never takes the role. That is the controlled part of this
  # scenario — the only round that runs is the parent's release round, so "wakes
  # <= grants" is measured over a window whose grants are known exactly.
  var announced = false
  let deadline = nowNs() + uint64(RequestDeadlineNs)
  var answer = ansNone
  while answer != ansGranted:
    answer = c.awaitAnswer(200_000_000'i64)
    if not announced and c.stats.parks > 0'u64:
      announced = true
      discard writeFull(parkedW, addr one, 1)
      discard close(parkedW)
    if answer == ansRefused: break
    if nowNs() > deadline: break
  rep.parks = c.stats.parks
  rep.parksWokenWithAnswer = c.stats.parksWokenWithAnswer
  rep.parksWokenIncomplete = c.stats.parksWokenIncomplete
  rep.parksSpurious = c.stats.parksSpurious
  rep.fastAnswers = c.stats.fastAnswers
  rep.granted = if answer == ansGranted: 1'u64 else: 0'u64
  rep.ok = 1
  discard writeFull(repFd, addr rep, sizeof(rep))
  quitChild(0)

type WaiterScenario = object
  ## The outcome of one controlled scenario: a set of real waiter processes parked
  ## in the kernel on their own wait words, and the ONE round the parent then ran.
  round: CombineRound
  parks: uint64
  wokenWithAnswer: uint64
  incomplete: uint64
  spurious: uint64
  granted: uint64
  ok: bool

proc runWaiterScenario(path: string; l: var ShmLease; waiterWant: ResourceVec;
    preHold: ResourceVec; mutations: ArbiterMutations): WaiterScenario =
  ## Fork `NWaiters` PURE WAITERS — processes that publish a request and never
  ## take the role — wait until every one of them has actually entered the kernel,
  ## and then run EXACTLY ONE round in the parent. Controlling the number of
  ## rounds is what makes the wake accounting a measurement: every grant and every
  ## wake in the window belongs to that single round.
  ##
  ## `preHold`, when non-zero, is capacity the parent takes and then RELEASES
  ## immediately before the round — the gate's "a release that frees capacity for
  ## several waiters".
  var parent = l.arbiterClient(ParentSlot)
  doAssert parent.registerSlot(ParentSlot)
  parent.mutations = mutations
  let holding = preHold != ResourceVec()
  if holding:
    doAssert parent.publishRequest(preHold) == psPublished
    var r0: CombineRound
    doAssert parent.tryCombine(r0) == cbCommitted
    doAssert parent.collectAnswer() == ansGranted
    doAssert not vecFits(waiterWant, MachineCap - parent.view.heldSum()),
      "the pre-held capacity must make the waiters' request NOT fit"

  let segSize = l.segmentSize()
  let ps = int(sysconf(SC_PAGESIZE))
  let stride = ((segSize + ps - 1) div ps) * ps
  let regionSize = stride * (NWaiters + 1)
  let region = mmap(nil, regionSize, PROT_NONE,
    MAP_PRIVATE or MAP_ANONYMOUS, cint(-1), 0)
  doAssert region != MAP_FAILED

  var repFds: array[NWaiters, array[0..1, cint]]
  var readyFds, goFds, parkedFds: array[0..1, cint]
  for i in 0 ..< NWaiters: doAssert pipe(repFds[i]) == 0
  doAssert pipe(readyFds) == 0
  doAssert pipe(goFds) == 0
  doAssert pipe(parkedFds) == 0
  var pids: seq[Pid]
  for i in 0 ..< NWaiters:
    let childBase = cast[pointer](cast[uint](region) + uint(i * stride))
    let pid = fork()
    if pid == 0:
      for j in 0 ..< NWaiters:
        discard close(repFds[j][0])
        if j != i: discard close(repFds[j][1])
      discard close(readyFds[0]); discard close(parkedFds[0])
      discard close(goFds[1])
      waiterMain(i, path, childBase, waiterWant, repFds[i][1], readyFds[1],
        goFds[0], parkedFds[1])
    doAssert pid > 0
    pids.add pid
  for i in 0 ..< NWaiters: discard close(repFds[i][1])
  discard close(readyFds[1]); discard close(parkedFds[1])
  discard close(goFds[0])

  for i in 0 ..< NWaiters:
    var b: byte
    doAssert readFull(readyFds[0], addr b, 1),
      "waiter " & $i & " never published its request"
  discard close(readyFds[0])
  discard close(goFds[1])

  # THE GATE THAT MAKES THIS A MEASUREMENT: nothing happens until every waiter has
  # ACTUALLY ENTERED THE KERNEL. Without it, "wakes == grants" could be four
  # fast-path answers with nobody ever parked, which would prove nothing about
  # waking.
  for i in 0 ..< NWaiters:
    var b: byte
    doAssert readFull(parkedFds[0], addr b, 1), "waiter " & $i & " never parked"
  discard close(parkedFds[0])

  if holding:
    doAssert parent.releaseGrant()
  doAssert parent.tryCombine(result.round) == cbCommitted

  for i in 0 ..< NWaiters:
    var rep = WaiterReport()
    doAssert readFull(repFds[i][0], addr rep, sizeof(rep))
    discard close(repFds[i][0])
    doAssert rep.ok == 1
    result.parks += rep.parks
    result.wokenWithAnswer += rep.parksWokenWithAnswer
    result.incomplete += rep.parksWokenIncomplete
    result.spurious += rep.parksSpurious
    result.granted += rep.granted
  for k in 0 ..< pids.len:
    var stt: cint
    doAssert waitpid(pids[k], stt, 0) == pids[k]
    doAssert WIFEXITED(stt) and WEXITSTATUS(stt) == 0
  discard munmap(region, regionSize)
  result.ok = true

proc toLogged(r: CombineRound): LoggedRound =
  ## The same conversion the children use, so the reference replay below is run
  ## over exactly the record the gate replays.
  result = LoggedRound(epoch: r.epoch, owner: r.owner,
    decisionCount: uint16(min(r.decisionCount, MaxLoggedDecisions)),
    heldMask: r.heldMask, held: packVec(r.held))
  for i in 0 ..< int(result.decisionCount):
    result.decisions[i] = LoggedDecision(slot: r.decisions[i].slot,
      kind: uint16(ord(r.decisions[i].kind)), gen: r.decisions[i].gen,
      want: r.decisions[i].want)

suite "M5 gate (a): a release that frees capacity for several waiters":
  test "one round grants four parked waiters and wakes exactly four":
    let path = freshPath("release")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [MachineCap], requestSlots = NSlots)
    check l.available
    # The parent takes nearly the whole budget, so nothing the waiters ask for can
    # fit until it gives it back — and then it gives it back.
    let sc = runWaiterScenario(path, l, vec(2, 2, 1, 2), vec(7, 7, 1, 7), {})
    check sc.ok
    let r = sc.round
    check r.grants == NWaiters                 # the freed capacity reached them all
    check r.published == NWaiters
    check r.wakes == r.grants                  # <-- (a) WAKES <= GRANTS, exactly
    check r.wakeSyscalls <= r.wakes
    check r.wakeSyscalls > 0                   # ...and real waiters were in the kernel
    check sc.granted == uint64(NWaiters)
    check sc.parks >= uint64(NWaiters)         # every waiter really did sleep
    # <-- (b), BOTH HALVES, in the scenario where the wake is a fact rather than a
    # hope: the parent did not release until every waiter had ACTUALLY ENTERED THE
    # KERNEL, so the wakes below were delivered to parked processes.
    check sc.wokenWithAnswer > 0'u64           # waiters really were woken...
    check sc.incomplete == 0'u64               # ...and every one found its answer
    check vecFits(l.arbiterView().heldSum(), MachineCap)
    echo "  [m5 (a)] waiters=", NWaiters, " grants=", r.grants,
      " wakes=", r.wakes, " wake-syscalls=", r.wakeSyscalls,
      " parks=", sc.parks, " woken-with-answer=", sc.wokenWithAnswer,
      " incomplete=", sc.incomplete, " spurious=", sc.spurious
    l.detach()

# ===========================================================================
# PART 3 — the same workload with a SINGLE combiner.
# ===========================================================================

suite "M5 gate (c): packing is unchanged by making the arbiter migrate":
  test "a single-combiner run has ONE owner and the SAME reference agreement":
    # Two things at once, and both matter. It is the TEETH for PART 1's migration
    # assertion — the identical harness with one permitted combiner produces
    # exactly one distinct owner and zero owner changes, so PART 1's `owners == 6`
    # is measuring something that can be absent. And it is the gate's own stated
    # purpose: the decisions match the same single-threaded reference whether the
    # role migrates or not, which is what "packing quality is provably unchanged"
    # means.
    let path = freshPath("single")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [MachineCap], requestSlots = NSlots)
    check l.available
    let run = runHarness(l, path, cmSingleCombiner)
    var rounds = mergeRounds(run)
    check rounds.len > 0
    let (owners, changes) = ownerSequence(rounds)
    check owners == 1                    # <-- PART 1's assertion, absent
    check changes == 0
    let rr = replay(rounds, MachineCap)
    check rr.mismatches == 0
    check rr.phantomHolds == 0
    check rr.heldMismatches == 0
    check rr.grants > 0
    # THE LOG-FULL GUARD, WHICH PART 1 HAD AND THIS ARM DID NOT — and its absence
    # cost a real diagnosis. A child stops combining once its round log is full, so
    # in THIS arm, where child 0 is the only permitted combiner, a full log strands
    # every other child and the run fails as an unexplained crop of deadline misses
    # in `errs` below. Observed exactly that: 1024 rounds (== MaxLoggedRounds)
    # against a normal 31..40, and `errs == 11`. Asserted here so the condition
    # surfaces as ITSELF. What made the log fill was the arbiter committing
    # do-nothing rounds for a request that could not fit; `decidableWork` now
    # declines to take the role for those, so the count stays in its normal range.
    var totalLogFull: uint64 = 0
    for rep in run.reports: totalLogFull += rep.logFull
    check totalLogFull == 0'u64
    check rounds.len < MaxLoggedRounds
    var errs: uint64 = 0
    for rep in run.reports: errs += rep.errors + rep.deadlineMisses
    check errs == 0'u64
    echo "  [m5 single-combiner] rounds=", rounds.len, " owners=", owners,
      " changes=", changes, " decisions=", rr.decisions,
      " mismatches=", rr.mismatches
    l.detach()

# ===========================================================================
# PART 4 — the reference has teeth.
# ===========================================================================

suite "M5 gate has teeth: the reference CATCHES a broken fit test":
  test "a round blind to its own proposals diverges from the reference":
    # `RunQuota-Observation-Store.milestones.org` * Introduction: "An invariant is
    # proven only by a test that FAILS when the invariant is violated." The
    # reference replay is the gate's clause (c), so it needs a run in which the
    # arbiter is WRONG and the replay says so.
    #
    # The scenario is the same controlled one as clause (a) and the divergence is
    # STRUCTURAL rather than lucky: four real waiter processes each ask for 3 CPU
    # slots against a capacity of 8, all four are parked before the round starts,
    # and the round's fit test is blind to its own proposals — MV2's
    # `CountOwnProposals = FALSE`, `shm_lease_combine_fit_MC.cfg`. Every one of the
    # four fits the view the round STARTED with, so all four are granted: 12 slots
    # out of 8. The reference grants two and leaves two pending, and reports the
    # other two as divergences. An earlier version of this control ran the churn
    # harness with the mutation switched on and asserted `mismatches > 0`; it
    # passed most of the time and produced ZERO divergences when no single round
    # happened to decide two fitting requests at once. A control that fires "most
    # of the time" is not a control.
    let path = freshPath("blind")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [MachineCap], requestSlots = NSlots)
    check l.available
    let sc = runWaiterScenario(path, l, vec(3, 4, 1, 10), ResourceVec(),
      {amBlindFit})
    check sc.ok
    check sc.round.grants == NWaiters             # 12 CPU slots out of 8
    check not vecFits(l.arbiterView().heldSum(), MachineCap)   # OVERCOMMITTED
    let rr = replay(@[toLogged(sc.round)], MachineCap)
    check rr.decisions == NWaiters
    check rr.mismatches == NWaiters - 2           # <-- the detector fires
    echo "  [m5 negative control] blind fit test: ", rr.mismatches,
      " of ", rr.decisions, " decisions diverged from the reference; first: ",
      rr.firstMismatch

    # And the identical scenario on the SHIPPING path grants exactly what the
    # reference says it should, so the divergence above is the mutation talking
    # and not the scenario.
    let path2 = freshPath("blindok")
    defer: cleanup(path2)
    var l2 = createLeaseSegment(path2, [MachineCap], requestSlots = NSlots)
    check l2.available
    let sc2 = runWaiterScenario(path2, l2, vec(3, 4, 1, 10), ResourceVec(), {})
    check sc2.ok
    check sc2.round.grants == 2
    check vecFits(l2.arbiterView().heldSum(), MachineCap)
    let rr2 = replay(@[toLogged(sc2.round)], MachineCap)
    check rr2.mismatches == 0
    check rr2.pendingCount == NWaiters - 2
    l.detach()
    l2.detach()
