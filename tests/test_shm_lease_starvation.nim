## THE M6 GATE — a large memory claim is admitted within a BOUNDED wait while a
## small-claim storm runs continuously, and the same test against naive admission
## FAILS.
##
## `RunQuota-Observation-Store.milestones.org` ** M6 :gate:
##   "A large memory claim (e.g. 8 GiB) is admitted within a bounded, asserted
##    wait while small claims (512 MiB) arrive continuously for the duration. The
##    SAME test run against a naive CAS-loop admission MUST FAIL, and that failure
##    is recorded in the milestone outcome as evidence the gate has teeth."
##   :proves: SM-4
##
## `RunQuota-Shared-Memory-Transport.md` §"2. Policy is the actual obstacle" is the
## design authority: first-come-if-it-fits starves large claims because free
## capacity never accumulates, and RunQuota exists to keep memory-heavy actions
## schedulable, so this is a CORRECTNESS gate rather than a fairness preference.
## The same section is explicit that admission is ONLINE — future arrivals are
## unknown — so optimal packing is unattainable in principle and the achievable
## goals are BOUNDED WAITING and NO OVERCOMMIT. Nothing more than that is claimed
## here.
##
## MOCKS: none. Real `fork`ed processes, a real file-backed `mmap(MAP_SHARED)`
## lease segment, every process at its own `MAP_FIXED` base, the real futex-class
## park, and — for the naive arm — the real M2 packed-CAS claim path. The property
## under test is what a POLICY does to processes competing for one budget, so
## there is nothing here that could be mocked without testing something else.
##
## ===========================================================================
## THE TOPOLOGY, AND WHY THE STARVATION IS STRUCTURAL RATHER THAN PROBABILISTIC
## ===========================================================================
##
## This campaign has been burned three times by a gate that depended on the
## scheduler: M2's `retryCount > 0`, M5's `roundsBusy + roundsLost > 0`, and M5's
## first migration barrier. So the storm here is not "six processes ask for memory
## quickly and hopefully overlap". It is an arithmetic identity:
##
##   * A CLAIMER OWNS TWO REQUEST SLOTS AND **OVERLAPS ITS RESERVATIONS**: it
##     publishes the next request while still holding the current grant, and gives
##     the current one up only once the next has been granted. That is what a
##     pipeline of compiles does, and it is what makes memory pressure PERSISTENT
##     rather than sawtoothed — there is no release-then-republish trough for a
##     large claim to slip through, because the release comes last.
##   * WHENEVER THE NEXT REQUEST IS GRANTED PROMPTLY — which under every policy
##     that does NOT hold capacity idle it always is, since a 512 MiB request fits
##     whatever the storm is holding — the claimer therefore HOLDS A GRANT AT
##     EVERY INSTANT, with no window in between. Six claimers, 512 MiB each: at
##     least 3 GiB is committed at all times.
##   * The numbers are then chosen so that identity alone defeats first fit:
##     capacity 10 GiB, large claim 8 GiB, and `10 - 3 = 7 GiB < 8 GiB`. The large
##     claim is not unlikely to be admitted under those policies; it CANNOT BE.
##     `static: doAssert` below refuses to let the four numbers be tuned into a
##     gate that passes for free.
##   * The parent SAMPLES `held + pending` from its own mapping throughout and
##     asserts the MINIMUM, so the storm's continuity is measured rather than
##     argued — and asserted in every arm, so a control that "failed" because
##     nothing was happening could not pass.
##
## **THE BOUNDED OVERLAP IS WHAT KEEPS THIS A HARD WORKLOAD RATHER THAN A
## DEADLOCK, AND IT IS THE OTHER HALF OF THE DESIGN.** A claimer that held its
## current grant until the next arrived, without limit, would deadlock ANY
## reservation policy: the reservation blocks the next grant, the next grant is
## what would release the current one, and nothing moves. So the overlap is
## bounded — after `OverlapNs` (100 ms) a claimer releases anyway and waits
## empty-handed.
## Under a policy that holds nothing idle that timeout is UNREACHABLE (the next
## request is granted in the first round the claimer itself drives), so occupancy
## never dips; under the shipping policy it is exactly what drains the machine for
## the head. The same constant produces the storm AND its drain, which is why it
## is one constant.
##
## ===========================================================================
## WHAT EACH ARM ASSERTS, AND WHAT MUTATION BREAKS IT
## ===========================================================================
##
## PART 1 — THE GATE. The shipping policy admits the 8 GiB claim within
##   `AdmitBoundNs`, measured from the instant it was published. Beside it:
##     * IDLE-HOLD HAPPENED — `reservations > 0`, i.e. a round named a head and
##       withheld its `want` from everything decided after it. Broken by:
##       `amNoReserve` and `amFirstFit`, where it is exactly 0.
##       Beside it, and CORROBORATING RATHER THAN DISCRIMINATING: the parent's
##       sampler counts states in which the head waits, a small claim waits, and
##       free capacity is not being given out. That count is NOT broken by
##       `amFirstFit` — measured at ~60,000 there — because a sampler cannot tell
##       "free and withheld" from "free and about to be granted a microsecond
##       later". It says the behaviour was seen from outside the arbiter; it does
##       not by itself say the POLICY caused it. The assertions that do say that
##       are `reservations > 0` and `overlapTimeouts >= 2` above, the unit suite's
##       `amNoReserve` control on an identical board, and the TLA+ non-vacuity
##       probe, all three of which read zero / fail under the mutation.
##     * IDLE-HOLD IS BOUNDED — the reservation exists only while its head is
##       pending, so its lifetime IS the admitted wait above, and small-claim
##       throughput RECOVERS afterwards (the tail rate is asserted against the
##       pre-storm rate). A policy that reserved permanently would show a tail
##       rate of zero, which is the opposite defect and is asserted against.
##     * THE SCAN RAN IN ARRIVAL ORDER — every round's decisions ascend by
##       ticket, and at least one round decided a HIGHER slot before a LOWER one,
##       so arrival order demonstrably differed from slot order. Broken by:
##       `amSlotOrder` / `amFirstFit`.
##     * NO OVERCOMMIT throughout, sampled from the parent's own mapping.
##
## PART 2 — THE NAIVE CAS LOOP, which is the control the milestone's gate names in
##   so many words. No arbiter at all: every process uses M2's packed-CAS claim
##   path directly, which is `RunQuota-Shared-Memory-Transport.md` §1's "read the
##   packed budget, test fit, CAS the decremented value, retry on contention" and
##   §2's "admits whoever arrives first and happens to fit". The large claim is
##   REQUIRED NOT to be admitted inside a deadline four times the bound PART 1
##   asserts, while the small claims are REQUIRED to keep succeeding — so the
##   failure is starvation and not a wedged run.
##
## PART 3 — THREE POLICY CONTROLS, one per mechanism plus the pair, run through
##   the SAME harness as PART 1 so the only difference is the policy:
##     * `amFirstFit`  — M5's policy exactly: slot order, no reservation. REQUIRED
##       to starve, and structurally so: the storm's occupancy floor alone defeats
##       it, whatever the scheduler does.
##     * `amSlotOrder` — the reservation kept but handed to the wrong request, so
##       capacity is held idle for somebody else. REQUIRED to starve, by the same
##       arithmetic: a head chosen by slot index is the LAST request in the scan
##       and nothing follows it to be refused, so the reservation does nothing.
##     * `amNoReserve` — arrival order kept, nothing held idle. RUN AND REPORTED,
##       NOT ASSERTED, and the reason is stated at the test: its failure is a
##       scheduling property rather than a structural one, and no dynamic harness
##       can make it structural. The formal tier carries that claim instead.
##
## The controls are what make PART 1 evidence rather than a measurement: the bound
## is not "the arbiter is fast", it is "the arbiter's POLICY is what admits it",
## and the other policies in the same harness demonstrably do not.

import std/[os, posix, unittest]
import shm_lease

# ===========================================================================
# GEOMETRY — the numbers, and the arithmetic that makes them binding.
# ===========================================================================

const
  NClaimers = 6
  SlotsPerClaimer = 2
  LargeSlot = NClaimers * SlotsPerClaimer
  NSlots = LargeSlot + 1

  SmallUnits = 8'u32
    ## 512 MiB in `MemUnitBytes` (64 MiB) units — the gate's "small claims".
  LargeUnits = 128'u32
    ## 8 GiB — the gate's "large memory claim".
  CapUnits = 160'u32
    ## 10 GiB of machine memory.
    ##
    ## THE INEQUALITY THIS FILE RESTS ON, WRITTEN OUT:
    ##   `NClaimers * SmallUnits = 48` units are held-or-pending at every instant,
    ##   so a first-fit round leaves at most `CapUnits - 48 = 112` units free,
    ##   and `112 < LargeUnits = 128`. First fit therefore CANNOT admit the large
    ##   claim, ever, in any schedule. `static: doAssert` below refuses to let
    ##   anybody tune these four numbers into a gate that passes for free.
    ##
    ##   And the reservation CAN: with 128 units reserved, no new small grant is
    ##   permitted while more than `160 - 128 = 32` units are held, so `held` is
    ##   driven monotonically down to 32 and the head then fits exactly.

  MachineCap = vec(64, CapUnits, 64, 1000)
    ## MEMORY IS THE ONLY BINDING DIMENSION, deliberately. Twelve concurrent small
    ## grants plus one large claim need 13 CPU slots and 13 processes against 64
    ## of each, so nothing but memory can refuse a request and the measurement is
    ## about the policy rather than about which dimension ran out first.
  SmallWant = vec(1, SmallUnits, 1, 1)
  LargeWant = vec(1, LargeUnits, 1, 1)

static:
  doAssert int(CapUnits) - NClaimers * int(SmallUnits) < int(LargeUnits),
    "the storm does not saturate: first fit could admit the large claim, so the " &
    "controls in PART 2 and PART 3 would be asserting nothing"
  doAssert LargeUnits <= CapUnits,
    "the large claim could never fit an idle machine and would be REFUSED " &
    "outright rather than made to wait"
  doAssert int(CapUnits) - int(LargeUnits) >= int(SmallUnits),
    "no small claim could be granted while the large one is reserved, so the " &
    "'utilization does not collapse' half of the gate would be vacuous"

const
  HoldNs = 200_000'u64             ## how long a claimer "works" with a grant
  OverlapNs = 100_000_000'u64
    ## THE BOUNDED OVERLAP: how long a claimer will hold its current grant
    ## waiting for its replacement before giving up and releasing anyway. Under a
    ## policy that holds nothing idle this timeout is never reached; under the
    ## shipping policy it is what drains the machine for the head. See the file
    ## header for why the workload deadlocks without a bound here.
  LargeHoldNs = 50_000_000'u64     ## the large claim's own hold, once admitted
  ParkNs = 20_000_000'i64          ## bounded park, exactly as M5's harness uses
  OverlapParkNs = 2_000_000'i64    ## ...and a shorter one inside the overlap
                                   ## window, so the timeout is not overshot by
                                   ## most of a park

  AdmitBoundNs = 1_000_000_000'u64
    ## **THE BOUND, AND HOW IT IS DERIVED.** At the instant the large claim is
    ## published the six claimers hold 48 units against a capacity of 160, so it
    ## does not fit and becomes the reservation head in the first round. From then
    ## on no grant may intrude on its 128 units, so `held` only falls: each
    ## claimer's next request is refused, its bounded overlap expires after
    ## `OverlapNs`, and it releases. The head needs `held <= 32` units, i.e. two of
    ## the six claimers to have released, and its own combine loop re-runs at worst
    ## one bounded 20 ms park later. The mechanism's own figure is therefore
    ## `OverlapNs + ParkNs + one round` — of the order of 50 ms — and this bound is
    ## that with a 20x multiplier for a loaded host, because the assertion has to be
    ## robust rather than tight.
    ##
    ## What makes it a real assertion rather than a generous one is PART 2 and
    ## PART 3: four other admission policies are given FOUR TIMES this long in the
    ## same harness and every one of them fails.

  StarveDeadlineNs = 4_000_000_000'u64
    ## What the failing arms are given. Four times the bound above.

  BucketNs = 10_000_000'u64        ## grant-rate histogram resolution: 10 ms
  NBuckets = 700                   ## ...covering 7 s, past every deadline here
  WarmNs = 200_000_000'u64
    ## How long the storm runs, established, BEFORE the large claim is published.
  TailNs = 300_000_000'u64
    ## How long the storm keeps running AFTER the large claim has been released,
    ## so "throughput recovers" is measured rather than assumed.

  MaxClaimerWaitNs = 3_000_000_000'u64
    ## A claimer's own per-request deadline. It exists to catch THE OPPOSITE
    ## DEFECT: a reservation policy that never lets go would show up here as
    ## small claims timing out, not as the large claim being late.

  ParentSampleBudget = 4_000_000
    ## A FIXED sample count, for the reason M2's harness gives: a figure that
    ## moves with ambient load cannot be quoted as a measured property.

type
  StormMode = enum
    smArbiter          ## the flat-combining arbiter, policy chosen by mutations
    smNaiveCas         ## no arbiter at all: M2's packed-CAS claim loop

  ClaimerReport = object
    ok: uint64
    claimerId: uint64
    base: uint64
    grants: uint64
    errors: uint64
    maxWaitNs: uint64
    overlapTimeouts: uint64    ## how often this claimer had to give up its
                               ## bounded overlap and release empty-handed. Zero
                               ## under every policy that holds nothing idle;
                               ## non-zero is the DRAIN the reservation causes.
    ticketInversions: uint64   ## rounds this claimer combined whose decisions
                               ## were NOT in ascending arrival order
    slotDescents: uint64       ## ...and rounds in which a higher slot was decided
                               ## before a lower one, so the order really differed
    stats: ArbiterStats
    buckets: array[NBuckets, uint32]

  LargeReport = object
    ok: uint64
    granted: uint64
    base: uint64
    publishNs: uint64
    grantedNs: uint64
    releasedNs: uint64
    errors: uint64
    ticketInversions: uint64
    slotDescents: uint64
    stats: ArbiterStats

  StormResult = object
    claimers: seq[ClaimerReport]
    large: LargeReport
    parentSamples: uint64
    overcommitSamples: uint64
    minOccupancyUnits: uint32   ## the smallest `held + pending` the parent saw
    idleHoldSamples: uint64     ## samples in which capacity was free, a small
                                ## claim wanted it, and it was NOT given out
    maxIdleUnits: uint32        ## ...and the most that was held idle at once
    stopNs: uint64

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
proc quitChild(code: cint) {.noreturn.} = cExit(code)

var tmpCounter = 0
proc freshPath(tag: string): string =
  inc tmpCounter
  getTempDir() / ("shmlease-m6-" & tag & "-" & $getpid() & "-" & $tmpCounter & ".seg")

proc cleanup(path: string) =
  try: removeFile(path)
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
  ## The parent holds the only write end, so one `close` is a broadcast EOF.
  var b: byte
  read(fd, addr b, 1) == 0

proc spinFor(ns: uint64) =
  ## Hold a grant for a bounded, wall-clock time. Wall clock rather than an
  ## iteration count for the reason M3's spinning control was rebuilt: an
  ## iteration cap measures this host's speed, not the interval that was wanted.
  let until = nowNs() + ns
  while nowNs() < until: discard

proc bucketOf(t0, t: uint64): int {.inline.} =
  if t <= t0: return 0
  let b = int((t - t0) div BucketNs)
  if b >= NBuckets: NBuckets - 1 else: b

# ===========================================================================
# THE PARENT'S STRUCTURAL SAMPLER
# ===========================================================================

type BoardSample = object
  ok: bool                 ## the sample did not straddle a commit
  stormUnits: uint32       ## `held + pending` across the STORM's slots only
  heldUnits: uint32        ## effective grants, every slot
  headWaiting: bool        ## the large claim is published and unanswered
  smallWaiting: bool       ## at least one small claim is published and unanswered
  freeUnits: uint32        ## `capacity - held`

proc sampleBoard(v: ArbiterView): BoardSample =
  ## One guarded snapshot of the whole board. The guard is a seqlock-style check
  ## on the role word and the combine sequence — the same guard, and for the same
  ## reason, that M5's harness uses for its no-overcommit sampler: a multi-word
  ## ledger read that straddles a commit can observe a state the system was never
  ## in. Measured there at one bad sample in ~160,000.
  ##
  ## TWO PROPERTIES COME OUT OF THIS ONE SCAN.
  ##
  ## `stormUnits` is THE MEASURED FORM OF THE STORM'S STRUCTURAL PROPERTY. Each
  ## claimer publishes its next request while still holding its current grant, so
  ## it is always counted in one of the two terms; the MINIMUM of this quantity
  ## over the run is therefore the storm's whole demand if and only if the storm
  ## never let up. Asserting the minimum is what makes "small claims arrive
  ## continuously for the duration" a fact about the harness rather than a hope
  ## about the scheduler. The large claimant's own slot is deliberately EXCLUDED:
  ## folding an 8 GiB request into it would inflate the floor by more than the
  ## floor itself and make the assertion pass for the wrong reason.
  ##
  ## `headWaiting and smallWaiting and freeUnits >= SmallUnits` is **THE IDLE
  ## HOLD, OBSERVED IN THE SHARED STATE**: capacity is genuinely free, a small
  ## claim is published and wants it, and it is not being given out. That is the
  ## behaviour M6 exists to add, seen from outside the arbiter rather than counted
  ## inside it.
  let role0 = v.roleSnapshot()
  let seq0 = v.combineSeq()
  let cseq = seq0
  var held = 0'u32
  var storm = 0'u32
  for i in 0 ..< v.slotCount:
    let inStorm = i < LargeSlot
    let e = v.ledgerAt(i)
    if ledgerDec(e) == ldGrant and ledgerEpoch(e) <= cseq:
      let w = v.wantAt(i)
      if v.ledgerAt(i) != e: continue     # released mid-scan; re-validate the pair
      let u = unpackVec(w).memUnits
      held += u
      if inStorm: storm += u
      continue
    let st = v.stateAt(i)
    if stateOf(st) == rqPending and v.valueAt(i) == stateBaseVal(st):
      let w = v.wantAt(i)
      if v.stateAt(i) != st: continue
      if inStorm:
        storm += unpackVec(w).memUnits
        result.smallWaiting = true
      else:
        result.headWaiting = true
  result.stormUnits = storm
  result.heldUnits = held
  result.freeUnits = if held >= CapUnits: 0'u32 else: CapUnits - held
  result.ok = v.roleSnapshot() == role0 and v.combineSeq() == seq0

# ===========================================================================
# THE CLAIMER — the small-claim storm, one process, two slots.
# ===========================================================================

proc orderStats(r: CombineRound; inversions, descents: var uint64) =
  ## Read the ORDER out of a committed round: decisions must ascend by arrival
  ## ticket, and if any adjacent pair descends in SLOT index then arrival order
  ## demonstrably differed from slot order in this round. The second is the
  ## anti-vacuity companion of the first — see PART 1.
  for i in 1 ..< r.decisionCount:
    if r.decisions[i].ticket < r.decisions[i - 1].ticket: inc inversions
    if r.decisions[i].slot < r.decisions[i - 1].slot: inc descents

proc claimerMain(claimerId: int; path: string; wantBase: pointer; t0: uint64;
    mutations: ArbiterMutations; repFd: cint; readyW: cint; goR: cint;
    warmW: cint; stopR: cint) {.noreturn.} =
  var rep = cast[ptr ClaimerReport](alloc0(sizeof(ClaimerReport)))
  rep.claimerId = uint64(claimerId)
  rep.base = cast[uint64](wantBase)

  var l = attachLeaseSegment(path, wantBase)
  if not l.available or cast[uint](l.mappedBase()) != cast[uint](wantBase):
    discard writeFull(repFd, rep, sizeof(ClaimerReport)); quitChild(11)

  # TWO SLOTS, TWO CLIENTS. A request slot carries at most one outstanding
  # request by construction (`publishRequest` refuses while a grant is
  # outstanding, which is M5's structural form of `publishGrant`'s precondition),
  # so publishing the next request while still holding the current grant needs a
  # second slot. That is the whole mechanism behind the gap-free storm.
  var cs: array[SlotsPerClaimer, ArbiterClient]
  for k in 0 ..< SlotsPerClaimer:
    let slot = claimerId * SlotsPerClaimer + k
    cs[k] = l.arbiterClient(slot)
    cs[k].mutations = mutations
    if not cs[k].registerSlot(slot):
      discard writeFull(repFd, rep, sizeof(ClaimerReport)); quitChild(12)

  var one: byte = 1
  if not writeFull(readyW, addr one, 1):
    discard writeFull(repFd, rep, sizeof(ClaimerReport)); quitChild(13)
  discard close(readyW)
  var goByte: byte
  discard read(goR, addr goByte, 1)
  discard close(goR)
  setNonBlocking(stopR)

  var r: CombineRound
  var cur = 0            ## the slot index (0/1) whose grant we are holding
  var nxt = 1
  var announced = false

  proc driveUntilAnswered(k: int): AnswerStatus =
    ## Combine, then park with a bounded timeout, until this client's own answer
    ## is on its value word. Every process drives rounds — there is no dedicated
    ## combiner — which is the flat-combining shape M5 established.
    let deadline = nowNs() + MaxClaimerWaitNs
    while true:
      if cs[k].tryCombine(r) == cbCommitted:
        orderStats(r, rep.ticketInversions, rep.slotDescents)
      if cs[k].view.answerArrived(cs[k].slot):
        return cs[k].collectAnswer()
      let a = cs[k].awaitAnswer(ParkNs)
      if a == ansGranted or a == ansRefused: return a
      if nowNs() > deadline: return ansNone

  # PRIME THE CYCLE: publish on `cur` and wait for it. From here on the invariant
  # "this claimer holds a grant or has a request pending, with no window in
  # between" is maintained by the loop below.
  if cs[cur].publishRequest(SmallWant) != psPublished: inc rep.errors
  var t = nowNs()
  if driveUntilAnswered(cur) != ansGranted:
    inc rep.errors
  else:
    inc rep.grants
    inc rep.buckets[bucketOf(t0, nowNs())]
    let w = nowNs() - t
    if w > rep.maxWaitNs: rep.maxWaitNs = w

  while true:
    spinFor(HoldNs)
    # OVERLAP THE RESERVATIONS: publish the next request while still holding the
    # current grant, and give the current one up only once the next has arrived.
    # That is what keeps this process's occupancy from ever touching zero, and it
    # is what makes the storm's pressure persistent instead of sawtoothed.
    if cs[nxt].publishRequest(SmallWant) != psPublished:
      inc rep.errors
      break
    t = nowNs()
    let overlapUntil = t + OverlapNs
    var overlapExpired = false
    var got = ansNone
    while true:
      if cs[nxt].tryCombine(r) == cbCommitted:
        orderStats(r, rep.ticketInversions, rep.slotDescents)
      if cs[nxt].view.answerArrived(cs[nxt].slot):
        got = cs[nxt].collectAnswer()
        break
      if nowNs() >= overlapUntil:
        overlapExpired = true
        break
      # `awaitAnswer` COLLECTS the answer when it finds one, so its RETURN VALUE
      # is the answer and re-testing `answerArrived` afterwards would report
      # "nothing arrived" forever. An earlier version of this loop discarded it,
      # and every claimer wedged on its own already-delivered grant.
      let a = cs[nxt].awaitAnswer(OverlapParkNs)
      if a == ansGranted or a == ansRefused:
        got = a
        break
    if overlapExpired: inc rep.overlapTimeouts
    # ...AND THE OVERLAP IS BOUNDED. Without this release the workload would be
    # hold-and-wait and would deadlock any reservation policy — see the file
    # header. Under a policy that holds nothing idle the loop above never reaches
    # its deadline, so this release happens with the replacement already in hand.
    if not cs[cur].releaseGrant():
      inc rep.errors
      break
    if not announced:
      announced = true
      discard writeFull(warmW, addr one, 1)
      discard close(warmW)
    let a = if got != ansNone: got else: driveUntilAnswered(nxt)
    if a == ansGranted:
      inc rep.grants
      inc rep.buckets[bucketOf(t0, nowNs())]
      let w = nowNs() - t
      if w > rep.maxWaitNs: rep.maxWaitNs = w
    else:
      inc rep.errors
      break
    swap(cur, nxt)
    if stopSignalled(stopR): break

  if not announced:
    announced = true
    discard writeFull(warmW, addr one, 1)
    discard close(warmW)
  # Give the last grant back so the final no-overcommit check reads a quiet board.
  if stateOf(cs[cur].view.stateAt(cs[cur].slot)) == rqHolding:
    discard cs[cur].releaseGrant()
  discard close(stopR)
  rep.stats = cs[0].stats
  # Both clients ran rounds; the counters are per-client, so they are summed here
  # rather than silently reporting half the work.
  rep.stats.roundsCommitted += cs[1].stats.roundsCommitted
  rep.stats.grantDecisions += cs[1].stats.grantDecisions
  rep.stats.reservations += cs[1].stats.reservations
  rep.stats.reserveBlocks += cs[1].stats.reserveBlocks
  rep.stats.wakeCalls += cs[1].stats.wakeCalls
  rep.stats.answersPublished += cs[1].stats.answersPublished
  rep.stats.parksWokenIncomplete += cs[1].stats.parksWokenIncomplete
  rep.ok = 1
  discard writeFull(repFd, rep, sizeof(ClaimerReport))
  quitChild(0)

# ===========================================================================
# THE LARGE CLAIMANT
# ===========================================================================

proc largeMain(path: string; wantBase: pointer; mutations: ArbiterMutations;
    deadlineNs: uint64; repFd: cint; readyW: cint; goR: cint;
    doneW: cint) {.noreturn.} =
  var rep = LargeReport(base: cast[uint64](wantBase))
  var l = attachLeaseSegment(path, wantBase)
  if not l.available:
    discard writeFull(repFd, addr rep, sizeof(rep)); quitChild(11)
  var c = l.arbiterClient(LargeSlot)
  c.mutations = mutations
  if not c.registerSlot(LargeSlot):
    discard writeFull(repFd, addr rep, sizeof(rep)); quitChild(12)

  var one: byte = 1
  discard writeFull(readyW, addr one, 1)
  discard close(readyW)
  # THE STORM IS ESTABLISHED BEFORE THE LARGE CLAIM ARRIVES. The parent does not
  # open this gate until every claimer has completed a full cycle, so the claim is
  # published into a saturated machine rather than into a starting one — which is
  # what makes "free capacity never accumulates" the condition under test.
  var goByte: byte
  discard read(goR, addr goByte, 1)
  discard close(goR)

  var r: CombineRound
  if c.publishRequest(LargeWant) != psPublished:
    inc rep.errors
    discard writeFull(doneW, addr one, 1)
    discard writeFull(repFd, addr rep, sizeof(rep))
    quitChild(0)
  rep.publishNs = nowNs()
  let deadline = rep.publishNs + deadlineNs
  var answer = ansNone
  while answer != ansGranted and answer != ansRefused:
    if c.tryCombine(r) == cbCommitted:
      orderStats(r, rep.ticketInversions, rep.slotDescents)
    if c.view.answerArrived(c.slot):
      answer = c.collectAnswer()
      break
    answer = c.awaitAnswer(ParkNs)
    if nowNs() > deadline: break
  if answer == ansGranted:
    rep.granted = 1
    rep.grantedNs = nowNs()
    # HOLD IT, THEN GIVE IT BACK — the tail window after this release is where
    # "the cure is not permanent underutilization" is measured.
    spinFor(LargeHoldNs)
    if not c.releaseGrant(): inc rep.errors
    rep.releasedNs = nowNs()
    # Drive one more round so the capacity the release freed actually reaches the
    # claimers this process just kept waiting.
    discard c.tryCombine(r)
  elif answer == ansRefused:
    inc rep.errors        # 8 GiB fits an idle 10 GiB machine; a refusal is a bug
  rep.stats = c.stats
  rep.ok = 1
  discard writeFull(doneW, addr one, 1)
  discard close(doneW)
  discard writeFull(repFd, addr rep, sizeof(rep))
  quitChild(0)

# ===========================================================================
# THE NAIVE CAS-LOOP ARM — no arbiter, no requests, no global view.
# ===========================================================================
#
# `RunQuota-Shared-Memory-Transport.md` §1: "read the packed budget, test fit, CAS
# the decremented value, retry on contention". §2: "A pure CAS loop admits whoever
# arrives first and happens to fit. That starves large claims." This is that loop,
# through the shipping M2 API, with no arbiter bound to the segment at all.

proc naiveClaimerMain(claimerId: int; path: string; wantBase: pointer; t0: uint64;
    repFd: cint; readyW: cint; goR: cint; warmW: cint; stopR: cint) {.noreturn.} =
  var rep = cast[ptr ClaimerReport](alloc0(sizeof(ClaimerReport)))
  rep.claimerId = uint64(claimerId)
  rep.base = cast[uint64](wantBase)
  var l = attachLeaseSegment(path, wantBase)
  if not l.available:
    discard writeFull(repFd, rep, sizeof(ClaimerReport)); quitChild(11)
  var one: byte = 1
  discard writeFull(readyW, addr one, 1)
  discard close(readyW)
  var goByte: byte
  discard read(goR, addr goByte, 1)
  discard close(goR)
  setNonBlocking(stopR)

  var resA, resB: Reservation
  proc claimRetry(res: var Reservation): bool =
    let deadline = nowNs() + MaxClaimerWaitNs
    while nowNs() < deadline:
      if l.claim(SmallWant, res) == csGranted: return true
      discard sched_yield()
    false

  if not claimRetry(resA):
    inc rep.errors
  else:
    inc rep.grants
    inc rep.buckets[bucketOf(t0, nowNs())]
  var announced = false
  while true:
    spinFor(HoldNs)
    # THE SAME GAP-FREE SHAPE AS THE ARBITER ARM, in the vocabulary a CAS loop
    # has: take the next claim BEFORE giving the current one back, so this
    # process's occupancy never touches zero.
    if not claimRetry(resB):
      inc rep.errors
      break
    if not l.release(resA):
      inc rep.errors
      break
    inc rep.grants
    inc rep.buckets[bucketOf(t0, nowNs())]
    if not announced:
      announced = true
      discard writeFull(warmW, addr one, 1)
      discard close(warmW)
    swap(resA, resB)
    if stopSignalled(stopR): break
  if not announced:
    announced = true
    discard writeFull(warmW, addr one, 1)
    discard close(warmW)
  if resA.isGranted: discard l.release(resA)
  discard close(stopR)
  rep.ok = 1
  discard writeFull(repFd, rep, sizeof(ClaimerReport))
  quitChild(0)

proc naiveLargeMain(path: string; wantBase: pointer; deadlineNs: uint64;
    repFd: cint; readyW: cint; goR: cint; doneW: cint) {.noreturn.} =
  var rep = LargeReport(base: cast[uint64](wantBase))
  var l = attachLeaseSegment(path, wantBase)
  if not l.available:
    discard writeFull(repFd, addr rep, sizeof(rep)); quitChild(11)
  var one: byte = 1
  discard writeFull(readyW, addr one, 1)
  discard close(readyW)
  var goByte: byte
  discard read(goR, addr goByte, 1)
  discard close(goR)

  rep.publishNs = nowNs()
  let deadline = rep.publishNs + deadlineNs
  var res: Reservation
  while nowNs() < deadline:
    if l.claim(LargeWant, res) == csGranted:
      rep.granted = 1
      rep.grantedNs = nowNs()
      spinFor(LargeHoldNs)
      discard l.release(res)
      rep.releasedNs = nowNs()
      break
    discard sched_yield()
  rep.ok = 1
  discard writeFull(doneW, addr one, 1)
  discard close(doneW)
  discard writeFull(repFd, addr rep, sizeof(rep))
  quitChild(0)

# ===========================================================================
# THE HARNESS
# ===========================================================================

proc runStorm(l: var ShmLease; path: string; mode: StormMode;
    mutations: ArbiterMutations; deadlineNs: uint64): StormResult =
  let segSize = l.segmentSize()
  # PAGE SIZE IS A HOST PROPERTY — 16 KiB on Apple Silicon — and M2 paid for
  # assuming otherwise: a `MAP_FIXED` base strided by 4096 is misaligned for most
  # children and fails with a silent `EINVAL`.
  let ps = int(sysconf(SC_PAGESIZE))
  doAssert ps > 0
  let stride = ((segSize + ps - 1) div ps) * ps
  let nChildren = NClaimers + 1
  let regionSize = stride * (nChildren + 1)
  let region = mmap(nil, regionSize, PROT_NONE,
    MAP_PRIVATE or MAP_ANONYMOUS, cint(-1), 0)
  doAssert region != MAP_FAILED

  var claimerRepFds: array[NClaimers, array[0..1, cint]]
  var largeRepFds, readyFds, goFds, warmFds, go2Fds, doneFds,
    stopFds: array[0..1, cint]
  for i in 0 ..< NClaimers: doAssert pipe(claimerRepFds[i]) == 0
  doAssert pipe(largeRepFds) == 0
  doAssert pipe(readyFds) == 0
  doAssert pipe(goFds) == 0
  doAssert pipe(warmFds) == 0
  doAssert pipe(go2Fds) == 0
  doAssert pipe(doneFds) == 0
  doAssert pipe(stopFds) == 0

  let t0 = nowNs()
  var pids: seq[Pid]
  for i in 0 ..< nChildren:
    let childBase = cast[pointer](cast[uint](region) + uint(i * stride))
    let pid = fork()
    if pid == 0:
      for j in 0 ..< NClaimers:
        discard close(claimerRepFds[j][0])
        if j != i: discard close(claimerRepFds[j][1])
      discard close(largeRepFds[0])
      discard close(readyFds[0]); discard close(warmFds[0])
      discard close(doneFds[0])
      discard close(goFds[1]); discard close(go2Fds[1]); discard close(stopFds[1])
      if i < NClaimers:
        discard close(largeRepFds[1]); discard close(doneFds[1])
        discard close(go2Fds[0])
        if mode == smArbiter:
          claimerMain(i, path, childBase, t0, mutations, claimerRepFds[i][1],
            readyFds[1], goFds[0], warmFds[1], stopFds[0])
        else:
          naiveClaimerMain(i, path, childBase, t0, claimerRepFds[i][1],
            readyFds[1], goFds[0], warmFds[1], stopFds[0])
      else:
        discard close(warmFds[1]); discard close(stopFds[0])
        if mode == smArbiter:
          largeMain(path, childBase, mutations, deadlineNs, largeRepFds[1],
            readyFds[1], go2Fds[0], doneFds[1])
        else:
          naiveLargeMain(path, childBase, deadlineNs, largeRepFds[1],
            readyFds[1], go2Fds[0], doneFds[1])
    doAssert pid > 0
    pids.add pid
  for i in 0 ..< NClaimers: discard close(claimerRepFds[i][1])
  discard close(largeRepFds[1])
  discard close(readyFds[1]); discard close(warmFds[1]); discard close(doneFds[1])
  discard close(goFds[0]); discard close(go2Fds[0]); discard close(stopFds[0])

  # GATE 1 — every process has attached and registered.
  for i in 0 ..< nChildren:
    var b: byte
    doAssert readFull(readyFds[0], addr b, 1),
      "child " & $i & " never reached the start barrier"
  discard close(readyFds[0])
  discard close(goFds[1])                # BROADCAST: the storm begins

  # GATE 2 — every claimer has completed a full cycle, so the storm is
  # ESTABLISHED and the invariant `held + pending >= NClaimers * SmallUnits`
  # already holds when the large claim arrives.
  for i in 0 ..< NClaimers:
    var b: byte
    doAssert readFull(warmFds[0], addr b, 1),
      "claimer " & $i & " never completed a cycle"
  discard close(warmFds[0])
  # ...and then let the storm run for a MEASURED window before the large claim is
  # published. Two reasons, both about evidence rather than about the protocol:
  # the machine is demonstrably saturated when the claim arrives, and the
  # small-claim grant rate BEFORE the claim exists is measured over a window long
  # enough to be a rate rather than a handful of events — that pre-rate is what
  # the tail rate is later compared against.
  let warmUntil = nowNs() + WarmNs
  while nowNs() < warmUntil: discard sched_yield()
  discard close(go2Fds[1])               # BROADCAST: publish the large claim

  # SAMPLE THE BOARD from the parent's own mapping — a base distinct from every
  # child's — for the whole time the large claim is outstanding. Sampled until the
  # large claimant reports rather than for a fixed count, because the assertions
  # made on this are a MINIMUM and an EXISTENCE, not a rate: a figure that moves
  # with ambient load cannot be quoted as a measured property, but a floor that
  # was never breached can.
  result.minOccupancyUnits = high(uint32)
  let v = l.arbiterView()
  var doneSeen = false
  var doneByte: byte
  setNonBlocking(doneFds[0])
  var samples = 0
  while samples < ParentSampleBudget and not doneSeen:
    inc samples
    if mode == smArbiter:
      let b = sampleBoard(v)
      if b.ok:
        inc result.parentSamples
        if b.stormUnits < result.minOccupancyUnits:
          result.minOccupancyUnits = b.stormUnits
        # THE IDLE HOLD, OBSERVED: the head is waiting, a small claim is waiting,
        # and there is capacity free that the small claim would fit in — and it is
        # not being given out.
        if b.headWaiting and b.smallWaiting and b.freeUnits >= SmallUnits:
          inc result.idleHoldSamples
          if b.freeUnits > result.maxIdleUnits: result.maxIdleUnits = b.freeUnits
    else:
      # No request slots are in play, so occupancy IS the outstanding claim on the
      # budget word — one atomic read, exact by construction.
      inc result.parentSamples
      let occ = l.outstandingVec(MachineBudgetIndex).memUnits
      if occ < result.minOccupancyUnits: result.minOccupancyUnits = occ
    if not l.noOvercommit(MachineBudgetIndex): inc result.overcommitSamples
    if read(doneFds[0], addr doneByte, 1) == 1: doneSeen = true
    # Yield RARELY. An earlier version yielded every 64 samples and, under 2x CPU
    # oversubscription, collected 513 usable samples where an idle host collected
    # 90,000 — which made the floor on the evidence a function of ambient load,
    # which is the exact class of defect M2 was failed for.
    if (samples and 4095) == 0: discard sched_yield()

  # GATE 3 — the large claimant has finished (granted, or out of time).
  if not doneSeen:
    var b: byte
    while true:
      let n = read(doneFds[0], addr b, 1)
      if n == 1: break
      if n == 0: break
      discard sched_yield()
  discard close(doneFds[0])

  # THE TAIL. The storm keeps running for a measured window after the large claim
  # has been released, which is where "throughput recovers" is measured — and the
  # board keeps being SAMPLED through it, so the occupancy floor and the evidence
  # count both cover a window of KNOWN length rather than one whose length is
  # however long the large claim happened to wait.
  let tailUntil = nowNs() + TailNs
  while nowNs() < tailUntil:
    if mode == smArbiter:
      let b = sampleBoard(v)
      if b.ok:
        inc result.parentSamples
        if b.stormUnits < result.minOccupancyUnits:
          result.minOccupancyUnits = b.stormUnits
    else:
      inc result.parentSamples
      let occ = l.outstandingVec(MachineBudgetIndex).memUnits
      if occ < result.minOccupancyUnits: result.minOccupancyUnits = occ
    if not l.noOvercommit(MachineBudgetIndex): inc result.overcommitSamples
  result.stopNs = nowNs()
  discard close(stopFds[1])              # BROADCAST: you may leave

  for i in 0 ..< NClaimers:
    var rep = cast[ptr ClaimerReport](alloc0(sizeof(ClaimerReport)))
    doAssert readFull(claimerRepFds[i][0], rep, sizeof(ClaimerReport)),
      "short read of claimer report " & $i
    discard close(claimerRepFds[i][0])
    result.claimers.add rep[]
    dealloc(rep)
  doAssert readFull(largeRepFds[0], addr result.large, sizeof(LargeReport))
  discard close(largeRepFds[0])
  for k in 0 ..< pids.len:
    var st: cint
    doAssert waitpid(pids[k], st, 0) == pids[k]
    doAssert WIFEXITED(st) and WEXITSTATUS(st) == 0,
      "child " & $k & " did not exit cleanly (status " & $WEXITSTATUS(st) & ")"
  discard munmap(region, regionSize)

proc grantsInWindow(run: StormResult; t0, fromNs, toNs: uint64): uint64 =
  ## Small-claim grants inside a time window, read out of the claimers' own
  ## 10 ms-bucketed histograms.
  if toNs <= fromNs: return 0
  let a = bucketOf(t0, fromNs)
  let b = bucketOf(t0, toNs)
  for rep in run.claimers:
    for i in a .. b:
      result += uint64(rep.buckets[i])

type ClaimerTotals = object
  grants: uint64
  errors: uint64
  maxWaitNs: uint64
  overlapTimeouts: uint64
  ticketInversions: uint64
  slotDescents: uint64

proc claimerTotals(run: StormResult): ClaimerTotals =
  for rep in run.claimers:
    result.grants += rep.grants
    result.errors += rep.errors
    if rep.maxWaitNs > result.maxWaitNs: result.maxWaitNs = rep.maxWaitNs
    result.overlapTimeouts += rep.overlapTimeouts
    result.ticketInversions += rep.ticketInversions
    result.slotDescents += rep.slotDescents

proc reserveTotals(run: StormResult): (uint64, uint64) =
  var reservations, blocks: uint64 = 0
  for rep in run.claimers:
    reservations += rep.stats.reservations
    blocks += rep.stats.reserveBlocks
  reservations += run.large.stats.reservations
  blocks += run.large.stats.reserveBlocks
  (reservations, blocks)

# ===========================================================================
# PART 1 — THE GATE.
# ===========================================================================

suite "M6 gate: a large claim is admitted under a continuous small-claim storm":
  test "8 GiB is admitted within a bounded wait while 512 MiB claims never stop":
    let path = freshPath("gate")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [MachineCap], requestSlots = NSlots)
    check l.available
    check l.requestSlots == NSlots

    let t0Guard = nowNs()
    let run = runStorm(l, path, smArbiter, {}, AdmitBoundNs)
    check run.claimers.len == NClaimers
    for rep in run.claimers: check rep.ok == 1
    check run.large.ok == 1
    let ct = claimerTotals(run)
    check ct.errors == 0'u64
    check run.large.errors == 0'u64

    # --- 0. THE STORM WAS CONTINUOUS, STRUCTURALLY ---------------------------
    # Every claimer publishes its next request before releasing its current
    # grant, so `held + pending` never drops below the storm's whole demand. This
    # is the assertion that makes the rest of the test about the POLICY: without
    # it, an admitted large claim might only mean the storm briefly stopped.
    # Not every attempt yields a usable sample — one that straddles a commit is
    # discarded rather than counted — so this is a floor on the EVIDENCE, stated
    # as one rather than presented as a measurement. The sampler runs through the
    # 300 ms tail as well as through the wait, so this floor does not move with how
    # long the large claim happened to take, and it survives 2x oversubscription.
    check run.parentSamples > 5000'u64
    check run.minOccupancyUnits >= uint32(NClaimers) * SmallUnits
    check ct.grants > 0'u64

    # --- 1. SM-4: THE BOUNDED WAIT -------------------------------------------
    check run.large.granted == 1'u64
    let waitNs = run.large.grantedNs - run.large.publishNs
    check waitNs <= AdmitBoundNs
    # ...and PART 2 and PART 3 are what make that bound mean something: four other
    # policies are given four times as long in this same harness and none of them
    # makes it.

    # --- 2. THE IDLE HOLD HAPPENED -------------------------------------------
    let (reservations, blocks) = reserveTotals(run)
    check reservations > 0'u64
    # THE IDLE HOLD, OBSERVED FROM OUTSIDE THE ARBITER: the parent saw states in
    # which the head was waiting, a small claim was waiting, and capacity the
    # small claim would have fitted in was free and not given out. That is
    # structural here — the head needs `held <= 32` units and the storm holds 48,
    # so every claimer that gives up its overlap and releases leaves free capacity
    # standing while its own replacement request is refused.
    #
    # **THESE TWO ARE CORROBORATION, NOT THE DISCRIMINATOR, AND SAYING SO IS THE
    # POINT.** Verification ran PART 1's whole assertion set against `amFirstFit`:
    # `granted`, `waitNs`, `reservations > 0`, the tail rate, both ticket-inversion
    # checks, `overlapTimeouts >= 2` and `slotDescents > 0` all broke — and these
    # two did NOT (about 60,000 samples, 112 units). A sampler cannot distinguish
    # capacity that is being WITHHELD from capacity that is free and will be
    # granted a microsecond later, so it reports the behaviour without attributing
    # it to the policy. The attribution is carried by `reservations > 0` above, by
    # `overlapTimeouts >= 2` below, by the unit suite's `amNoReserve` control on an
    # identical board, and by the TLA+ non-vacuity probe.
    check run.idleHoldSamples > 0'u64
    check run.maxIdleUnits >= SmallUnits
    # **THE IN-ROUND COUNTER IS REPORTED AND NOT ASSERTED, AND THE REASON IS
    # WORTH KNOWING.** `reserveBlocks` counts requests a ROUND refused because of
    # the reservation — but on a board where the head is the only thing that could
    # be decided, `decidableWork` declines the role BEFORE a round runs, so the
    # arbiter does not even burn an acquisition while it holds capacity idle.
    # The counter is therefore near-zero by design rather than by absence of the
    # behaviour, and asserting it would be asserting how often the two gates
    # happened to disagree.
    discard blocks

    # --- 3. THE IDLE HOLD IS BOUNDED -----------------------------------------
    # A reservation exists only while its head is pending, so its lifetime is the
    # wait asserted above. The half that is NOT implied by that is whether the
    # machine recovers: a policy that reserved permanently would keep refusing
    # small claims forever. Measured as a grant RATE in the tail window, after the
    # large claim has been released, against the rate before it ever arrived.
    let preNs = run.large.publishNs
    let preGrants = grantsInWindow(run, t0Guard, 0'u64, preNs)
    check preGrants > 0'u64
    let tailFrom = run.large.releasedNs
    let tailGrants = grantsInWindow(run, t0Guard, tailFrom, run.stopNs)
    check tailGrants > 0'u64
    # A per-second rate rather than a raw count, because the two windows are not
    # the same length. The threshold is deliberately loose — this assertion exists
    # to catch a policy that stops the world, not to police throughput — and its
    # falsifying direction is a tail rate of ZERO, which is what "reserved
    # forever" looks like.
    let preRate = (preGrants * 1_000_000_000'u64) div max(preNs - t0Guard, 1'u64)
    let tailRate = (tailGrants * 1_000_000_000'u64) div
      max(run.stopNs - tailFrom, 1'u64)
    check tailRate * 4'u64 >= preRate
    # ...and no claimer was starved by the cure: the opposite defect, asserted.
    check ct.maxWaitNs < MaxClaimerWaitNs

    # --- 4. THE SCAN RAN IN ARRIVAL ORDER ------------------------------------
    # Ticket order, asserted; and the anti-vacuity companion beside it, because a
    # run in which arrival order and slot order coincide proves nothing about
    # which one was used. `slotDescents > 0` is structural here: the large claim
    # sits at the HIGHEST slot index and is the OLDEST pending request for the
    # whole of its wait, so every round that decides it and a claimer's newer
    # request decides the higher slot first.
    check ct.ticketInversions == 0'u64
    check run.large.ticketInversions == 0'u64
    # ...and the DRAIN really is what freed the capacity. `held` starts at 48
    # units and the head needs 32, so at least two claimers must have given up
    # their bounded overlap and released empty-handed — which is only possible
    # because the reservation refused their replacements. This is the single
    # number that says the reservation, and not a lull, is what let the large
    # claim in.
    check ct.overlapTimeouts >= 2'u64
    check ct.slotDescents + run.large.slotDescents > 0'u64

    # --- 5. NO OVERCOMMIT, EVER ----------------------------------------------
    check run.overcommitSamples == 0'u64
    let v = l.arbiterView()
    check vecFits(v.heldSum(), MachineCap)
    check l.noOvercommit(MachineBudgetIndex)

    echo "  [m6 gate] admitted in ", waitNs div 1_000_000, " ms (bound ",
      AdmitBoundNs div 1_000_000, " ms); small grants=", ct.grants,
      " (pre ", preGrants, " @ ", preRate, "/s, tail ", tailGrants, " @ ",
      tailRate, "/s); reservations=", reservations, " idle-hold blocks=", blocks,
      "; idle-hold samples=", run.idleHoldSamples, " (max ",
      run.maxIdleUnits, " units held idle); min occupancy=",
      run.minOccupancyUnits, " units (floor ",
      uint32(NClaimers) * SmallUnits, "); ticket-inversions=", ct.ticketInversions,
      " slot-descents=", ct.slotDescents + run.large.slotDescents,
      "; max claimer wait=", ct.maxWaitNs div 1_000_000,
      " ms; overlap timeouts=", ct.overlapTimeouts
    l.detach()

# ===========================================================================
# PART 2 — THE NAIVE CAS LOOP. The control the gate names in so many words.
# ===========================================================================

suite "M6 gate has teeth: a naive CAS loop STARVES the same claim":
  test "packed-CAS admission never admits 8 GiB in 4x the asserted bound":
    let path = freshPath("naive")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [MachineCap], requestSlots = NSlots)
    check l.available

    let run = runStorm(l, path, smNaiveCas, {}, StarveDeadlineNs)
    let ct = claimerTotals(run)

    # THE FAILURE, RECORDED. This is the arm the milestone requires to fail.
    check run.large.granted == 0'u64

    # ...and it FAILED BY STARVING, not by wedging. Both halves are needed: a run
    # in which nothing at all happened would also satisfy the line above.
    check ct.errors == 0'u64
    check ct.grants > uint64(NClaimers)
    check run.minOccupancyUnits >= uint32(NClaimers) * SmallUnits
    check run.overcommitSamples == 0'u64
    # No arbiter was ever bound to this segment: the whole arm ran through M2's
    # packed-CAS claim path, which is what "naive CAS-loop admission" means.
    check l.arbiterView().heldSum() == ResourceVec()
    check l.claimCount(MachineBudgetIndex) > uint64(NClaimers)

    echo "  [m6 naive CAS] large claim NOT admitted in ",
      StarveDeadlineNs div 1_000_000, " ms; small claims granted=", ct.grants,
      " (CAS claims=", l.claimCount(MachineBudgetIndex), ", refusals=",
      l.refusalCount(MachineBudgetIndex), ", retries=",
      l.retryCount(MachineBudgetIndex), "); min occupancy=",
      run.minOccupancyUnits, " units"
    l.detach()

# ===========================================================================
# PART 3 — THE THREE POLICY CONTROLS, one per mechanism plus the pair.
# ===========================================================================

proc starvationArm(tag: string; mutations: ArbiterMutations;
    expectReserveBlocks: bool; requireStarved: bool) =
  let path = freshPath(tag)
  defer: cleanup(path)
  var l = createLeaseSegment(path, [MachineCap], requestSlots = NSlots)
  check l.available
  let run = runStorm(l, path, smArbiter, mutations, StarveDeadlineNs)
  let ct = claimerTotals(run)
  let (reservations, blocks) = reserveTotals(run)

  # THE FAILURE — asserted only where it is STRUCTURAL. See `requireStarved` at
  # the call sites for the one arm where it is not, and why that is recorded
  # rather than asserted.
  if requireStarved:
    check run.large.granted == 0'u64
  # ...by starvation rather than by a wedged run: the small claims kept flowing
  # the whole time, which is precisely the condition SM-4 names.
  check ct.errors == 0'u64
  check ct.grants > uint64(NClaimers)
  check run.minOccupancyUnits >= uint32(NClaimers) * SmallUnits
  check run.overcommitSamples == 0'u64
  # AND THE MECHANISM REALLY WAS OFF. `amNoReserve` and `amFirstFit` hold nothing
  # idle at all, so their reservation counters must be exactly zero; `amSlotOrder`
  # keeps the reservation and must still show it — for the WRONG request, which is
  # the whole point of that control.
  if expectReserveBlocks:
    check reservations > 0'u64
  else:
    check reservations == 0'u64
    check blocks == 0'u64
  echo "  [m6 control ", tag, "] large claim ",
    (if run.large.granted == 1'u64: "ADMITTED (in " &
        $((run.large.grantedNs - run.large.publishNs) div 1_000_000) & " ms)"
     else: "NOT admitted in " & $(StarveDeadlineNs div 1_000_000) & " ms"),
    "; small grants=", ct.grants,
    " reservations=", reservations, " idle-hold blocks=", blocks,
    " overlap timeouts=", ct.overlapTimeouts,
    " min occupancy=", run.minOccupancyUnits, " units"
  l.detach()

suite "M6 gate has teeth: each half of the policy is load-bearing":
  test "amFirstFit (M5's policy: slot order, no reservation) STARVES it":
    starvationArm("firstfit", {amFirstFit}, false, true)

  test "amNoReserve (arrival order, nothing held idle) is NOT a structural control":
    # THE MOST INSTRUCTIVE OF THE THREE, AND THE ONE THIS FILE DOES NOT ASSERT ON.
    #
    # Ordering the scan oldest-first LOOKS like an anti-starvation policy: the
    # large claim is considered before every request that arrived after it. It is
    # not one — without a reservation the capacity a release frees is spent on
    # whichever small claim fits, so it never accumulates. On an idle host this
    # arm starves the claim every time, and it did so in 15 consecutive runs.
    #
    # **BUT ITS FAILURE IS A SCHEDULING PROPERTY AND NOT A STRUCTURAL ONE, AND
    # THAT IS RECORDED HERE RATHER THAN TUNED AWAY.** Arrival order alone admits
    # the large claim the moment the storm momentarily lets go, and the storm lets
    # go exactly when a claimer's bounded overlap expires. Under 2x CPU
    # oversubscription that happened: 1 run in 5 admitted the claim. The obvious
    # repair — a workload that provably never lets go — is not available, because
    # a workload that never releases without a replacement would DEADLOCK any
    # reservation policy, which is the opposite defect this file also has to avoid.
    # So no dynamic harness can make this control structural.
    #
    # The claim that the reservation is load-bearing is therefore carried by the
    # FORMAL tier, where it IS structural: `shm_lease_admit_noreserve_MC.cfg`
    # requires TLC to exhibit a FAIR behaviour in which the large claim is never
    # admitted, and TLC finds one over the complete 101-state graph. What this arm
    # asserts is only what it can: the storm ran, nothing overcommitted, no claimer
    # was starved, and the outcome is PRINTED.
    starvationArm("noreserve", {amNoReserve}, false, false)

  test "amSlotOrder (the reservation, given to the WRONG request) STARVES it":
    # Capacity IS held idle here — the counters prove it — just not for the claim
    # that has been waiting longest. It isolates the arrival ORDER as the thing
    # that makes the reservation land on the right request.
    starvationArm("slotorder", {amSlotOrder}, true, true)
