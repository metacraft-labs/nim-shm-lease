## **M7 — THE KILL-INJECTION GATE: SIGKILL at every schedule hook.**
## Built with `-d:shmLeaseScheduleHooks --threads:on`.
##
## MOCKS: none, and the word deserves care in a file about killing things. The
## schedule hooks are not mocks — they do not replace any behaviour, they pause or
## (here) TERMINATE the real code at a real CAS, publish, role-transfer or
## reclamation site. The kill is `kill(getpid(), SIGKILL)`: uncatchable, unblockable,
## no unwinding, no atexit, no flush, no destructor. A process killed that way stops
## between two machine instructions, which is the only faithful model of a crash.
## Everything asserted afterwards is read out of the real shared segment by real
## surviving processes.
##
## ===========================================================================
## WHAT THE GATE ASKS FOR, AND HOW EACH CLAUSE IS ESTABLISHED
## ===========================================================================
##
## > SIGKILL at every schedule hook, including mid-combine while holding the
## > arbiter role. Asserts admission always recovers within a bounded time, the
## > structure is never corrupted, and no capacity is permanently leaked.
##
## **"AT EVERY HOOK" IS ESTABLISHED BY MEASUREMENT, NOT BY A LIST.** The suite
## loops over `SchedulePoint` — the compiler's own enumeration, so a point added
## later is covered automatically — and for each one forks a victim armed to die
## the first time that point is reached. The parent then requires the victim to
## have died BY SIGKILL, which only the hook can have caused: a victim that never
## reached the point exits with a distinguishable status instead, and the test
## FAILS on it. So "every hook was killed at" is a fact each child proved about
## itself, not a claim about the workload.
##
## **THE VICTIM ALWAYS HOLDS CAPACITY WHEN IT DIES.** It is granted its reservation
## BEFORE the hook is armed, by a round the parent runs, so whichever point it dies
## at it dies holding a real grant on the shared board. Without that the leak
## clause would be vacuous for every point outside the combine path.
##
## **AND IT IS USUALLY HOLDING THE ROLE.** After collecting its grant it drives
## combine rounds for a request the parent published, so the role-transfer,
## ledger, commit, sequence, budget-refresh, publication and role-release points
## are all reached mid-round with the role held. The dedicated suite at the bottom
## pins the hardest of those — death at the commit CAS — and measures what
## recovery costs there.

import std/[monotimes, os, posix, strutils, times, unittest]
import shm_lease

static: doAssert scheduleHooksEnabled, "expected -d:shmLeaseScheduleHooks"

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}

const
  RcNotReached = 7'i32
    ## The victim ran its whole workload without ever reaching the armed point.
  Cap = vec(8, 64, 8, 100)
  VictimWant = vec(2, 8, 2, 20)
  SurvivorWant = vec(1, 4, 1, 10)

  RecoverBoundNs = 1_000_000_000'i64
    ## THE ASSERTED RECOVERY BOUND, and it is DERIVED rather than chosen.
    ##
    ## The worst case is a victim killed while holding the role. A survivor then
    ## has to notice. `mayStealRole` establishes a baseline on its FIRST sighting
    ## of an unchanged role word and can fire the anchor probe one
    ## `anchorProbeAfterNs` later; the probe reads the dead owner's own slot
    ## anchor, gets a verdict that is not `avLive`, and steals immediately. So the
    ## mechanism's own figure is
    ##
    ##     2 x DefaultAnchorProbeAfterNs (60 ms)   -- baseline, then the probe
    ##   + one park slice (ParkNs, 20 ms)          -- the survivor's bounded wait
    ##   + one round                               -- bounded and syscall-free
    ##
    ## i.e. of the order of 80 ms, and the timeout half (250 ms) is never reached
    ## because the anchor fires first. The assertion is set at 1 s — roughly 12x —
    ## for the same reason M6's was set at 8x its measured figure: an assertion has
    ## to be robust on a loaded host rather than tight, and what gives it teeth is
    ## the control, not the margin. The control is in the last suite: with the
    ## anchor half disabled, the SAME kill takes at least the timeout.
  ParkNs = 20_000_000'i64

var tmpCounter = 0
proc freshPath(tag: string): string =
  inc tmpCounter
  getTempDir() / ("shmlease-k-" & tag & "-" & $getpid() & "-" & $tmpCounter & ".seg")

proc cleanup(path: string) =
  try: removeFile(path)
  except CatchableError: discard
  try:
    for _, p in walkDir(parentDir(path)):
      if extractFilename(p).startsWith(extractFilename(path) & ".tmp."):
        removeFile(p)
  except CatchableError: discard

proc nowNs(): int64 {.inline.} = getMonoTime().ticks

proc waitForState(v: ArbiterView; slot: int; st: RequestState;
    sec: float = 20.0): bool =
  let deadline = epochTime() + sec
  while epochTime() < deadline:
    if stateOf(v.stateAt(slot)) == st: return true
    sleep(1)
  false

# ---------------------------------------------------------------------------
# THE KILL HOOK
# ---------------------------------------------------------------------------

var
  gKillPoint: SchedulePoint
  gArmed = false
  gReached = false

proc killHook(p: SchedulePoint) {.gcsafe, raises: [].} =
  ## Die AT the point, not near it. `SIGKILL` to self is delivered before the
  ## `kill` syscall returns and cannot be caught, blocked or ignored, so no further
  ## instruction of the victim's own code runs — which is what makes this a crash
  ## rather than an early return.
  {.cast(gcsafe).}:
    if gArmed and p == gKillPoint:
      gReached = true
      discard kill(getpid(), SIGKILL)

# ---------------------------------------------------------------------------
# THE VICTIM'S LOCAL WORKLOAD — the same one-cycle sweep `test_shm_lease_hooks`
# uses for its coverage assertion, extended with M7's reclamation pass, so every
# point outside the shared board's combine path is reachable too.
# ---------------------------------------------------------------------------

proc runLocalCycle(tag: string) =
  ## Reaches every non-arbiter seam: the create/publish/rename sites, the budget
  ## CAS and its release and rollback, the wait/wake sites, the observation ring's
  ## four, and reclamation's two.
  let lp = freshPath(tag & "-l")
  var l = createLeaseSegment(lp, [vec(8, 8, 8, 8), vec(1, 1, 1, 1)])
  if not l.available: return
  var r: Reservation
  discard l.claim(vec(2, 2, 2, 2), r)
  discard l.release(r)
  discard l.claim(vec(2, 2, 2, 2), r, poolIndex = 0)   # refused -> rollback
  l.detach()
  cleanup(lp)

  let wp = freshPath(tag & "-w")
  var ws = createWaitSegment(wp, 4)
  if ws.available:
    let woff = ws.slotOffset(0)
    prefaultWaitWord(ws.base, woff)
    discard waitOn(ws.base, woff, ws.slotValue(0), timeoutNs = 3_000_000'i64)
    discard ws.publishGrant(0, 1'u64)
    discard wakeRaw(ws.base, woff)
    ws.detach()
  cleanup(wp)

  let op = freshPath(tag & "-o")
  var obs = createObsRing(op, 8, 32)
  if obs.available:
    var orec: array[32, byte]
    discard obs.publish(orec)
    discard obs.publishForcedSignal(orec)
    var obuf: array[32, byte]
    var on = 0
    while obs.drainOne(obuf, on) == odrGot: discard
    discard obs.awaitRecord(timeoutNs = 3_000_000'i64)
    obs.detach()
  cleanup(op)

  # RECLAMATION's two seams. The slot is given a null anchor, which is the state a
  # client that died between `registerSlot`'s state CAS and its anchor stores
  # leaves — `avNoOwner`, judged gone — and two passes with a zero grace then
  # reclaim it.
  let rp = freshPath(tag & "-r")
  var rl = createLeaseSegment(rp, [vec(8, 8, 8, 8)], requestSlots = 2)
  if rl.available:
    var rcl = rl.arbiterClient(0)
    if rcl.registerSlot(0) and rcl.publishRequest(vec(1, 1, 1, 1)) == psPublished:
      var rr: CombineRound
      discard rcl.tryCombine(rr)
      discard rcl.collectAnswer()
      rcl.view.writeSlotAnchor(0, 0, 0)
      var rec = newReclaimer(rcl.view, graceNs = 0)
      discard rec.reclaimPass()
      discard rec.reclaimPass()
    rl.detach()
  cleanup(rp)

# ---------------------------------------------------------------------------
# THE GATE
# ---------------------------------------------------------------------------

type RunOutcome = object
  died: bool            ## killed by SIGKILL at the armed point
  reached: bool
  recoverNs: int64      ## from reaping the victim to the survivor's answer
  reclaimNs: int64
  freed: ResourceVec
  verdict: AnchorVerdict

proc runVictim(point: SchedulePoint; path: string): RunOutcome =
  ## One iteration: a shared board, a survivor, and a victim that dies at `point`
  ## while holding a grant and (for every point in the combine path) the role.
  var l = createLeaseSegment(path, [Cap], requestSlots = 4)
  doAssert l.available
  var p = l.arbiterClient(0)
  doAssert p.registerSlot(0)
  let v = p.view

  let pid = fork()
  if pid == 0:
    var l2 = attachLeaseSegment(path)
    var c = l2.arbiterClient(1)
    if not c.registerSlot(1): cExit(RcNotReached.cint)
    if c.publishRequest(VictimWant) != psPublished: cExit(RcNotReached.cint)
    # Wait for the PARENT's round to grant it. Nothing here is hooked, so the
    # victim cannot die before it is holding capacity.
    for _ in 0 ..< 20000:
      if c.view.answerArrived(1): break
      sleep(1)
    if c.collectAnswer() != ansGranted: cExit(RcNotReached.cint)
    # Wait for the survivor's request to appear, so the victim's rounds have real
    # work and reach the whole of the combine path.
    for _ in 0 ..< 20000:
      if stateOf(c.view.stateAt(0)) == rqPending: break
      sleep(1)
    setScheduleHook(killHook)
    gKillPoint = point
    gArmed = true
    var rr: CombineRound
    for _ in 0 ..< 8:
      discard c.tryCombine(rr)
      if c.view.answerArrived(0): break
    runLocalCycle("victim")
    setScheduleHook(nil)
    cExit(RcNotReached.cint)               # the point was never reached
  doAssert pid > 0

  doAssert waitForState(v, 1, rqPending)
  var g: CombineRound
  doAssert p.tryCombine(g) == cbCommitted   # grant the victim its reservation
  doAssert waitForState(v, 1, rqHolding)
  doAssert v.heldSum() == VictimWant
  doAssert p.publishRequest(SurvivorWant) == psPublished

  var st: cint
  doAssert waitpid(pid, st, 0) == pid
  let reaped = nowNs()
  result.died = WIFSIGNALED(st) and WTERMSIG(st) == SIGKILL
  result.reached = result.died
  if not result.died:
    doAssert WIFEXITED(st)
    doAssert WEXITSTATUS(st) == RcNotReached.cint

  # (b) ADMISSION RECOVERS. The survivor drives its own rounds with the SHIPPED
  #     steal constants; when the victim died holding the role this is where the
  #     anchor probe fires and the steal happens.
  var r: CombineRound
  var answered = false
  let deadline = epochTime() + 20.0
  while epochTime() < deadline:
    discard p.combineUntilAnswered(r, ParkNs)
    if v.answerArrived(0) or stateOf(v.stateAt(0)) == rqHolding:
      answered = true
      break
  result.recoverNs = nowNs() - reaped
  doAssert answered, "admission did not recover after a kill at " & $point
  if stateOf(v.stateAt(0)) == rqPending:
    doAssert p.collectAnswer() == ansGranted

  # (c) NO CAPACITY PERMANENTLY LEAKED. Until a pass runs, the dead victim's grant
  #     is still effective and still counted — that is the leak, and it is what the
  #     reclaimer is for.
  let t1 = nowNs()
  var rc = newReclaimer(v, graceNs = 0)
  discard rc.reclaimPass()
  let rep = rc.reclaimUntilQuiet()
  result.reclaimNs = nowNs() - t1
  result.freed = rep.freed
  result.verdict = rep.verdict[1]

  # The survivor gives its own grant back, and the board must be bit-for-bit the
  # board the segment was created with.
  doAssert p.releaseGrant()
  doAssert v.heldSum() == ResourceVec()
  doAssert v.budgetCache() == Cap
  doAssert l.packedRemaining(0) == l.packedCapacity(0)
  doAssert l.noOvercommitAnywhere()
  doAssert l.storedPointerCheck()
  l.detach()

suite "M7 gate: SIGKILL at EVERY schedule hook":
  test "every hook is reached and killed at, and admission recovers each time":
    var worstRecover = 0'i64
    var worstPoint = low(SchedulePoint)
    var killed = 0
    var leaks = 0
    for point in SchedulePoint:
      let path = freshPath("gate-" & $ord(point))
      let o = runVictim(point, path)
      cleanup(path)
      # COVERAGE, PROVEN BY THE VICTIM ITSELF: it can only have been SIGKILLed by
      # the hook, because nothing else in this suite sends one.
      check o.died
      if o.died: inc killed
      # BOUNDED RECOVERY.
      check o.recoverNs <= RecoverBoundNs
      if o.recoverNs > worstRecover:
        worstRecover = o.recoverNs
        worstPoint = point
      # NO LEAK: the victim died holding `VictimWant` at every point, so every
      # iteration's reclamation must hand back exactly that.
      check o.freed == VictimWant
      check o.verdict == avOwnerGone
      if o.freed != VictimWant: inc leaks
    check killed == ord(high(SchedulePoint)) + 1
    check leaks == 0
    echo "  [M7] killed at ", killed, " of ", ord(high(SchedulePoint)) + 1,
      " hook points; worst recovery ", worstRecover div 1_000_000, " ms at ",
      worstPoint

# ---------------------------------------------------------------------------
# THE HARDEST POINT, PINNED — and the control that says what makes it fast.
# ---------------------------------------------------------------------------

proc killAtCommitAndRecover(anchorNs, stealNs: int64): int64 =
  ## Kill a combiner AT ITS COMMIT CAS — holding the role, uncommitted, with a
  ## survivor's request decided in its ledger and about to be discarded — and
  ## return how long the survivor took to recover, in nanoseconds.
  let path = freshPath("commit")
  defer: cleanup(path)
  var l = createLeaseSegment(path, [Cap], requestSlots = 4)
  doAssert l.available
  var p = l.arbiterClient(0)
  doAssert p.registerSlot(0)
  p.anchorProbeAfterNs = anchorNs
  p.stealAfterNs = stealNs
  let v = p.view

  let pid = fork()
  if pid == 0:
    var l2 = attachLeaseSegment(path)
    var c = l2.arbiterClient(1)
    doAssert c.registerSlot(1)
    doAssert c.publishRequest(VictimWant) == psPublished
    for _ in 0 ..< 20000:
      if c.view.answerArrived(1): break
      sleep(1)
    doAssert c.collectAnswer() == ansGranted
    for _ in 0 ..< 20000:
      if stateOf(c.view.stateAt(0)) == rqPending: break
      sleep(1)
    setScheduleHook(killHook)
    gKillPoint = slpBeforeCommitCas
    gArmed = true
    var rr: CombineRound
    discard c.tryCombine(rr)
    cExit(RcNotReached.cint)
  doAssert pid > 0

  doAssert waitForState(v, 1, rqPending)
  var g: CombineRound
  doAssert p.tryCombine(g) == cbCommitted
  doAssert waitForState(v, 1, rqHolding)
  doAssert p.publishRequest(SurvivorWant) == psPublished

  var st: cint
  doAssert waitpid(pid, st, 0) == pid
  doAssert WIFSIGNALED(st) and WTERMSIG(st) == SIGKILL
  let reaped = nowNs()

  # THE STRANDED STATE, SPELLED OUT: the role is held by a slot whose owner is
  # gone, at an uncommitted epoch, with the survivor's answer decided but not
  # effective. Nothing but the steal path can move it.
  let role = v.roleSnapshot()
  doAssert roleOwner(role) == 1'u16
  doAssert not roleCommitted(role)
  doAssert v.ownerAnchorVerdict(1) == avOwnerGone

  var r: CombineRound
  let deadline = epochTime() + 20.0
  var ok = false
  while epochTime() < deadline:
    discard p.combineUntilAnswered(r, ParkNs)
    if v.answerArrived(0) or stateOf(v.stateAt(0)) == rqHolding:
      ok = true
      break
  result = nowNs() - reaped
  doAssert ok, "no recovery from a kill at the commit CAS"
  doAssert p.stats.steals >= 1'u64
  if stateOf(v.stateAt(0)) == rqPending:
    doAssert p.collectAnswer() == ansGranted
  doAssert v.heldSum() == VictimWant + SurvivorWant
  doAssert l.noOvercommitAnywhere()
  l.detach()

suite "M7: killed mid-combine while holding the role":
  test "the ANCHOR half is what bounds the recovery, and the control shows it":
    # THE SHIPPED CONSTANTS. The anchor probe fires long before the 250 ms steal
    # timeout, so recovery costs the probe interval and not the timeout.
    let fast = killAtCommitAndRecover(DefaultAnchorProbeAfterNs,
      DefaultStealAfterNs)
    check fast <= RecoverBoundNs

    # THE CONTROL: constraint 4's anchor half disabled by pushing its interval
    # beyond the timeout, so only the bounded timeout can fire. The SAME kill then
    # costs at least the timeout — which is the measurement that says the anchor
    # check is load-bearing rather than decorative, and it is exactly what MV2
    # warns about (`shm_lease_combine_livelock_MC.cfg`: dropping the anchor costs
    # LIVENESS, never safety).
    let slow = killAtCommitAndRecover(10_000_000_000'i64, DefaultStealAfterNs)
    check slow >= DefaultStealAfterNs
    check slow <= 20 * DefaultStealAfterNs
    check fast * 2 < slow
    echo "  [M7] recovery from a kill at the commit CAS: anchor ",
      fast div 1_000_000, " ms, timeout-only control ", slow div 1_000_000, " ms"

# ---------------------------------------------------------------------------
# A RECLAIMER KILLED MID-PASS
# ---------------------------------------------------------------------------

proc killedReclaimer(point: SchedulePoint; path: string): tuple[
    heldAfterKill: ResourceVec; stateAfterKill: RequestState] =
  ## Set a board up with ONE dead owner holding a grant, then kill a REAPER at
  ## `point` and report the half-state it left.
  var l = createLeaseSegment(path, [Cap], requestSlots = 4)
  doAssert l.available
  var p = l.arbiterClient(0)
  doAssert p.registerSlot(0)
  let v = p.view

  let holder = fork()
  if holder == 0:
    var l2 = attachLeaseSegment(path)
    var c = l2.arbiterClient(1)
    doAssert c.registerSlot(1)
    doAssert c.publishRequest(VictimWant) == psPublished
    for _ in 0 ..< 20000:
      if c.view.answerArrived(1): break
      sleep(1)
    doAssert c.collectAnswer() == ansGranted
    discard kill(getpid(), SIGKILL)
    cExit(9)
  doAssert holder > 0
  doAssert waitForState(v, 1, rqPending)
  var g: CombineRound
  doAssert p.tryCombine(g) == cbCommitted
  doAssert waitForState(v, 1, rqHolding)
  var st: cint
  doAssert waitpid(holder, st, 0) == holder
  doAssert v.heldSum() == VictimWant

  let reaper = fork()
  if reaper == 0:
    var l3 = attachLeaseSegment(path)
    var c3 = l3.arbiterClient(2)
    var rc = newReclaimer(c3.view, graceNs = 0)
    discard rc.reclaimPass()          # unhooked: this pass only starts the clock
    setScheduleHook(killHook)
    gKillPoint = point
    gArmed = true
    discard rc.reclaimPass()
    cExit(RcNotReached.cint)
  doAssert reaper > 0
  doAssert waitpid(reaper, st, 0) == reaper
  doAssert WIFSIGNALED(st) and WTERMSIG(st) == SIGKILL

  result.heldAfterKill = v.heldSum()
  result.stateAfterKill = stateOf(v.stateAt(1))

  # WHATEVER HALF-STATE IT LEFT, THE NEXT PASS FINISHES IT.
  var rc2 = newReclaimer(v, graceNs = 0)
  discard rc2.reclaimPass()
  discard rc2.reclaimUntilQuiet()
  doAssert v.heldSum() == ResourceVec()
  doAssert stateOf(v.stateAt(1)) == rqFree
  doAssert v.budgetCache() == Cap
  doAssert l.packedRemaining(0) == l.packedCapacity(0)
  var q = l.arbiterClient(1)
  doAssert q.registerSlot(1)          # the slot really is reusable
  l.detach()

suite "M7: the reclaimer is itself crash-safe":
  test "killed before the ledger CAS, the capacity is still held and is recovered":
    let path = freshPath("rk1")
    defer: cleanup(path)
    let o = killedReclaimer(slpBeforeReclaimCas, path)
    # Nothing moved: the reaper died before the one CAS that gives capacity back.
    check o.heldAfterKill == VictimWant
    check o.stateAfterKill == rqHolding

  test "killed after the ledger CAS, the capacity is already back and the slot is finished":
    let path = freshPath("rk2")
    defer: cleanup(path)
    let o = killedReclaimer(slpBeforeReclaimEpoch, path)
    # THE CAPACITY IS BACK THE INSTANT THE CAS LANDS — everything after it is
    # tidying, and a reaper that dies in the middle of the tidying leaves a slot
    # that holds nothing and is not yet reusable.
    check o.heldAfterKill == ResourceVec()
    check o.stateAfterKill == rqHolding

# ---------------------------------------------------------------------------
# M4'S DEBT: a producer killed between its ticket and its publish.
# ---------------------------------------------------------------------------

suite "M7 / M4 debt: a producer killed mid-publish":
  test "no corruption, no torn record — and the wedge is DECLARED, not silent":
    ## WHAT THIS SETTLES AND WHAT IT DOES NOT. The transport spec requires that a
    ## producer killed mid-publish "MUST NOT corrupt the ring or strand a partially
    ## written record", and records the requirement as unmet. This test establishes
    ## the first half and MEASURES the second rather than fixing it:
    ##
    ##   * every record published before the kill is delivered, intact and in
    ##     order, and no torn record is ever returned — that is the release-store
    ##     publication protocol, and it survives a real SIGKILL;
    ##   * the drain then STOPS at the dead producer's ticket, exactly as M4
    ##     recorded, and every record behind it is undeliverable;
    ##   * and a window containing it is now `ccTruncated` instead of passing as
    ##     complete, because the stall detector reports it. The drop counter cannot
    ##     see this loss — nothing was dropped and the ring is not full — so
    ##     without the detector the window presents as authoritative.
    ##
    ## The REPAIR is not here, and it is DEFERRED rather than impossible: skipping
    ## the stuck ticket is safe only if its producer can never write again, and a
    ## ticket's owner is not recorded anywhere — the reservation and the
    ## publication are both inside `nim-shm-queue`'s `pushBlob`, which has no owner
    ## field and no seam between them. This layer therefore has the bounded timeout
    ## and not the anchor, and M5's finding is precisely that those two halves buy
    ## different things. A per-ticket owner side table COULD be carried by this
    ## layer — `reserveTicketWithoutPublish` shows the ticket CAS is reachable from
    ## here — but it would be a second copy of a reservation protocol the sibling
    ## library owns, against `obsring`'s single-MPSC-implementation invariant, and
    ## changing that library's slot format was out of M7's scope. The reasons are
    ## scope and ownership; see `obsring.nim`'s stranded-ticket section.
    let path = freshPath("obs-kill")
    defer: cleanup(path)
    var ring = createObsRing(path, 16, 32)
    check ring.available

    var rec: array[32, byte]
    for i in 0 ..< 3:
      rec[0] = byte(100 + i)
      check ring.publish(rec) == oprPublished
    let dropsBefore = ring.droppedCount()

    let pid = fork()
    if pid == 0:
      var r2 = attachObsRing(path)
      doAssert r2.available
      # The exact state a producer killed between its ticket CAS and its
      # release-store leaves. The KILL is real; only the placement is arranged,
      # because the two steps live inside `nim-shm-queue` with no seam between.
      doAssert r2.reserveTicketWithoutPublish()
      discard kill(getpid(), SIGKILL)
      cExit(9)
    check pid > 0
    var st: cint
    check waitpid(pid, st, 0) == pid
    check WIFSIGNALED(st)
    check WTERMSIG(st) == SIGKILL

    # Two more records land BEHIND the stranded ticket, published normally.
    for i in 0 ..< 2:
      rec[0] = byte(200 + i)
      check ring.publish(rec) == oprPublished

    # NO CORRUPTION: the three records published before the kill come out intact,
    # in order, and nothing else does.
    var buf: array[32, byte]
    var n = 0
    var got: seq[int] = @[]
    while ring.drainOne(buf, n) == odrGot:
      check n == 32
      got.add int(buf[0])
    check got == @[100, 101, 102]

    # THE STALL, DETECTED. The head ticket is unpublished with records reserved
    # behind it, and the head has not moved.
    check ring.pendingCount() == 3'u64        # the corpse's ticket + two behind it
    check not ring.headSlotReady()
    check ring.droppedCount() == dropsBefore  # the drop counter cannot see this
    check ring.windowCompleteness(dropsBefore) == ccComplete   # ...and so lies

    var det = newDrainStallDetector(thresholdNs = 20_000_000'i64)
    let t0 = nowNs()
    check det.drainStallVerdict(ring, t0) == dsPendingFresh    # first sighting
    check det.drainStallVerdict(ring, t0 + 1_000_000) == dsPendingFresh
    check det.drainStallVerdict(ring, t0 + 30_000_000) == dsStalled
    check det.stalls == 1'u64
    check ring.windowCompleteness(dropsBefore, drainStalled = true) == ccTruncated

    # THE CONTROL — a healthy ring is never reported as stalled, however long the
    # detector looks at it. Without this the verdict above could be "the detector
    # says stalled" rather than "the ring is stalled".
    let hpath = freshPath("obs-ok")
    defer: cleanup(hpath)
    var healthy = createObsRing(hpath, 16, 32)
    check healthy.available
    check healthy.publish(rec) == oprPublished
    var det2 = newDrainStallDetector(thresholdNs = 20_000_000'i64)
    check det2.drainStallVerdict(healthy, t0) == dsFlowing
    check det2.drainStallVerdict(healthy, t0 + 10_000_000_000'i64) == dsFlowing
    check healthy.headSlotReady()
    check det2.stalls == 0'u64
    healthy.detach()
    ring.detach()
