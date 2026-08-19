## **M7 — RECLAMATION (SM-6), and the pid-reuse negative test the gate names.**
##
## MOCKS: none. Every process here is a real forked process, every death is a real
## `SIGKILL`, every anchor is read out of a real shared segment, and every liveness
## probe is a real `kill(pid, 0)` + `sysctl`/`/proc` start-time read. The ONE thing
## that is constructed rather than waited for is the pid-reuse ANCHOR — see the
## comment on that suite, which states exactly what is constructed, why a natural
## reuse is unreachable in a test, and why the constructed state is not weaker.
##
## WHAT THIS FILE PROVES, AND IN BOTH DIRECTIONS. SM-6 is not one property, it is
## two, and this campaign has already watched one bound produce its own opposite
## defect (M5's epoch bound produced a deadlock; M6's reservation could trivially
## produce underutilization). Reclamation's mirror image is RECLAIMING A LIVE
## HOLDER, so every assertion below is paired:
##
##   * a dead client's reservation IS reclaimed — and the same board with no
##     reclamation is measured still holding it, which is the leak;
##   * a live client's reservation is NEVER reclaimed — and the same board with
##     `rmTimeoutOnly` (the anchor check dropped) IS reclaimed out from under it,
##     which is what makes the first assertion mean something;
##   * a pid reused by a NEW process on the SAME boot does not make a live
##     reservation reclaimable, AND does not make a dead one look live — and
##     `rmIgnoreStartTime` breaks the second half, which is the exact reason the
##     start-time field exists;
##   * a slot caught INSIDE a two-step write is not judged — and `rmNoGrace` (the
##     grace dropped, the anchor left on) yanks it out from under a live
##     registrant on the FIRST sighting, which is the half of the rule the anchor
##     structurally cannot cover.

import std/[os, posix, times, unittest]
import shm_lease

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}

var tmpCounter = 0
proc freshPath(tag: string): string =
  inc tmpCounter
  getTempDir() / ("shmlease-rc-" & tag & "-" & $getpid() & "-" & $tmpCounter & ".seg")

proc cleanup(path: string) =
  try: removeFile(path)
  except CatchableError: discard

const
  Cap = vec(8, 64, 8, 100)
  ChildWant = vec(2, 8, 2, 20)
  ParentWant = vec(1, 4, 1, 10)

proc waitForState(v: ArbiterView; slot: int; st: RequestState;
    sec: float = 10.0): bool =
  ## Poll a slot's state out of the segment. Used instead of a pipe because the
  ## state word IS the handshake the protocol already defines, and adding a second
  ## channel would let the test and the protocol disagree about who is ready.
  let deadline = epochTime() + sec
  while epochTime() < deadline:
    if stateOf(v.stateAt(slot)) == st: return true
    sleep(1)
  false

proc grantPending(c: var ArbiterClient; rounds = 200): bool =
  ## Drive rounds until nothing is grantable any more.
  var r: CombineRound
  for _ in 0 ..< rounds:
    if c.tryCombine(r) != cbCommitted: return true
  false

# ---------------------------------------------------------------------------
# 1. A client killed while holding a reservation has it reclaimed.
# ---------------------------------------------------------------------------

suite "M7 SM-6: a dead client's reservation is reclaimed":
  test "SIGKILL while holding a grant leaks capacity until a pass reclaims it":
    let path = freshPath("dead")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [Cap], requestSlots = 4)
    check l.available
    var p = l.arbiterClient(0)
    check p.registerSlot(0)
    let v = p.view
    check v.reclaimEpoch() == 0'u64      # a fresh segment has reclaimed nothing

    let pid = fork()
    if pid == 0:
      var l2 = attachLeaseSegment(path)
      var c = l2.arbiterClient(1)
      doAssert c.registerSlot(1)
      doAssert c.publishRequest(ChildWant) == psPublished
      # The PARENT runs the round; this child only waits for its answer, so the
      # moment it dies it is a pure HOLDER of capacity and nothing else.
      for _ in 0 ..< 5000:
        if c.view.answerArrived(1): break
        sleep(1)
      doAssert c.collectAnswer() == ansGranted
      discard kill(getpid(), SIGKILL)     # <-- the real kill, holding the grant
      cExit(9)                            # unreachable
    check pid > 0

    check waitForState(v, 1, rqPending)
    check p.grantPending()
    check waitForState(v, 1, rqHolding)
    var st: cint
    check waitpid(pid, st, 0) == pid
    check WIFSIGNALED(st)
    check WTERMSIG(st) == SIGKILL

    # THE LEAK, MEASURED RATHER THAN ASSERTED AWAY. With the holder gone and no
    # reclamation, its grant is still an effective ledger entry, so `heldSum` still
    # counts it and every subsequent action sees a smaller machine. This is the
    # state SM-6 exists to forbid, and it is the counterfactual that makes the
    # reclaim assertions below mean something.
    check v.heldSum() == ChildWant
    check v.budgetCache() == Cap - ChildWant
    check ledgerDec(v.ledgerAt(1)) == ldGrant

    var rc = newReclaimer(v, graceNs = 0)
    # The FIRST pass only starts the clock: a slot is never judged on its first
    # sighting, which is what stops a reaper from acting inside a two-step write.
    let first = rc.reclaimPass()
    check first.reclaimed == 0
    check first.action[1] == saGrace
    check v.heldSum() == ChildWant

    let rep = rc.reclaimPass()
    check rep.reclaimed == 1
    check rep.action[1] == saReclaimed
    check rep.verdict[1] == avOwnerGone     # WHY, not merely THAT
    check rep.freed == ChildWant
    check rep.epoch == 1'u64

    # THE CAPACITY IS BACK, on both the authority and the cache.
    check v.heldSum() == ResourceVec()
    check v.budgetCache() == Cap
    check ledgerDec(v.ledgerAt(1)) == ldReleased
    check l.remainingVec(0) == Cap
    check l.packedRemaining(0) == l.packedCapacity(0)
    check l.noOvercommitAnywhere()

    # ...AND THE SLOT IS REUSABLE, which is the other half of not leaking: a slot
    # that is free of capacity but permanently occupied leaks admission instead.
    check stateOf(v.stateAt(1)) == rqFree
    check v.slotOwnerPid(1) == 0'u64
    var q = l.arbiterClient(1)
    check q.registerSlot(1)
    check q.publishRequest(ChildWant) == psPublished

    # IDEMPOTENT: a further pass over the same board reclaims nothing and does not
    # move the epoch. (Slot 1 is now owned by a LIVE client — this process.)
    var rc2 = newReclaimer(v, graceNs = 0)
    discard rc2.reclaimPass()
    let again = rc2.reclaimPass()
    check again.reclaimed == 0
    check again.action[1] == saLive
    check v.reclaimEpoch() == 1'u64
    l.detach()

# ---------------------------------------------------------------------------
# 2. A LIVE holder is never reclaimed — and the mutation that reclaims it.
# ---------------------------------------------------------------------------

suite "M7 SM-6: reclamation must never touch a live holder":
  test "a live holder survives every pass; dropping the anchor check reclaims it":
    let path = freshPath("live")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [Cap], requestSlots = 4)
    check l.available
    var p = l.arbiterClient(0)
    check p.registerSlot(0)
    let v = p.view

    # A LIVE child that takes a grant and then simply sits there — which is what a
    # real client does while it runs the action it was admitted for, and is
    # precisely the state a timeout-only reaper cannot distinguish from a corpse.
    let pid = fork()
    if pid == 0:
      var l2 = attachLeaseSegment(path)
      var c = l2.arbiterClient(1)
      doAssert c.registerSlot(1)
      doAssert c.publishRequest(ChildWant) == psPublished
      for _ in 0 ..< 5000:
        if c.view.answerArrived(1): break
        sleep(1)
      doAssert c.collectAnswer() == ansGranted
      sleep(3000)                          # holding, alive, and doing nothing
      cExit(0)
    check pid > 0

    check waitForState(v, 1, rqPending)
    check p.grantPending()
    check waitForState(v, 1, rqHolding)

    # THE SHIPPING RECLAIMER, run repeatedly across a window far longer than its
    # own grace. It must decline every time, and say why.
    var rc = newReclaimer(v, graceNs = 20_000_000'i64)
    for _ in 0 ..< 40:
      let rep = rc.reclaimPass()
      check rep.reclaimed == 0
      check rep.action[1] == saLive
      check rep.verdict[1] == avLive
      sleep(5)
    check rc.stats.liveSkipped >= 40'u64   # it was ASKED, and it said no
    check v.heldSum() == ChildWant
    check v.reclaimEpoch() == 0'u64

    # THE MIRROR IMAGE, AND THE CONTROL THAT GIVES THE ABOVE TEETH. `rmTimeoutOnly`
    # is constraint 4's anchor half removed — the bounded timeout alone. On the
    # IDENTICAL board, with the holder still alive and still using the memory, it
    # reclaims the grant: capacity that is genuinely in use is handed back to the
    # pool, which is the overcommit this component exists to prevent.
    var bad = newReclaimer(v, graceNs = 0, mutations = {rmTimeoutOnly})
    discard bad.reclaimPass()
    let harm = bad.reclaimPass()
    # It reclaims BOTH occupied slots — the live child's grant AND this process's
    # own registered slot — because "the words have not changed for a while" is
    # true of every client that is getting on with its work. That is the whole
    # failure mode in one number.
    check harm.reclaimed == 2
    check harm.action[1] == saReclaimed
    check harm.verdict[1] == avLive        # it KNEW, and reclaimed anyway
    check harm.action[0] == saReclaimed
    check v.heldSum() == ResourceVec()     # <-- the live holder's capacity, gone

    var st: cint
    check waitpid(pid, st, 0) == pid
    l.detach()

# ---------------------------------------------------------------------------
# 3. PID REUSE — the gate's negative test, in both directions.
# ---------------------------------------------------------------------------

suite "M7: pid reuse does not make a live reservation reclaimable":
  test "same pid, new process, same boot: the live slot survives, the stale one goes":
    ## WHAT IS CONSTRUCTED AND WHAT IS REAL, stated before the code because the
    ## honesty of this test is the whole point of it.
    ##
    ## REAL: a live child process, its real pid, its real start time, a real
    ## `kill(pid, 0)`, a real second real start time (this process's own), and two
    ## real grants in a real segment.
    ##
    ## CONSTRUCTED: which of the two start times slot 2's anchor records. A
    ## NATURAL pid reuse is not reachable inside a test — macOS allocates pids
    ## sequentially and wraps at ~99k, so provoking one would mean forking the
    ## entire pid space — and it is not needed, because the reclaimer's whole input
    ## is `(boot, pid, start)` plus what the OS says about `pid` right now. After a
    ## natural reuse those inputs are: boot matches, the pid EXISTS, and the
    ## recorded start time is some other process's. That is exactly the state
    ## below, with a real start time in every field. There is nothing for the
    ## reclaimer to tell apart.
    let path = freshPath("pidreuse")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [Cap], requestSlots = 4)
    check l.available
    var p = l.arbiterClient(0)
    check p.registerSlot(0)
    let v = p.view

    let pid = fork()
    if pid == 0:
      var l2 = attachLeaseSegment(path)
      var c = l2.arbiterClient(1)
      doAssert c.registerSlot(1)
      doAssert c.publishRequest(ChildWant) == psPublished
      for _ in 0 ..< 5000:
        if c.view.answerArrived(1): break
        sleep(1)
      doAssert c.collectAnswer() == ansGranted
      sleep(4000)
      cExit(0)
    check pid > 0
    check waitForState(v, 1, rqPending)
    check p.grantPending()
    check waitForState(v, 1, rqHolding)

    # Slot 2 takes a real grant of its own, and then its anchor is rewritten to
    # "pid P, started at a time P did not start at" — the corpse whose pid the live
    # child now carries.
    var q = l.arbiterClient(2)
    check q.registerSlot(2)
    check q.publishRequest(ParentWant) == psPublished
    check p.grantPending()
    check q.collectAnswer() == ansGranted
    check v.heldSum() == ChildWant + ParentWant

    let livePid = uint64(pid)
    let liveStart = processStartTime(pid)
    let otherStart = processStartTime(int(getpid()))   # a REAL start time...
    check liveStart != 0'u64
    check otherStart != 0'u64
    check liveStart != otherStart                      # ...of a DIFFERENT process
    check v.slotOwnerPid(1) == livePid
    check v.slotOwnerStart(1) == liveStart
    v.writeSlotAnchor(2, livePid, otherStart)

    # THE VERDICTS, REPORTED RATHER THAN COLLAPSED. Both slots name the same LIVE
    # pid on the same boot; only the start time separates them, and it is the only
    # thing that can.
    check anchorVerdict(v.boot, livePid, liveStart) == avLive
    check anchorVerdict(v.boot, livePid, otherStart) == avPidReused

    var rc = newReclaimer(v, graceNs = 0)
    discard rc.reclaimPass()
    let rep = rc.reclaimPass()

    # DIRECTION 1 — the live reservation is NOT reclaimed, even though its pid is
    # the pid the stale record names. This is the gate's clause, and a reaper that
    # keyed on "pid P was seen dead" would fail it.
    check rep.action[1] == saLive
    check rep.verdict[1] == avLive
    check stateOf(v.stateAt(1)) == rqHolding
    check ledgerDec(v.ledgerAt(1)) == ldGrant

    # DIRECTION 2 — the stale reservation IS reclaimed, and the verdict says which
    # check fired.
    check rep.action[2] == saReclaimed
    check rep.verdict[2] == avPidReused
    check rep.freed == ParentWant
    check v.heldSum() == ChildWant                     # exactly the live holder's
    check v.budgetCache() == Cap - ChildWant

    # THE MUTATION, AND IT IS WHY THE START-TIME FIELD EXISTS AT ALL. Judged on
    # boot + pid only, the corpse's record reads as LIVE — the pid does exist —
    # and its capacity is never given back.
    var l3 = createLeaseSegment(freshPath("pidreuse2"), [Cap], requestSlots = 4)
    check l3.available
    defer:
      let p3 = l3.path
      l3.detach()
      cleanup(p3)
    var r3 = l3.arbiterClient(0)
    check r3.registerSlot(0)
    check r3.publishRequest(ParentWant) == psPublished
    check r3.grantPending()
    check r3.collectAnswer() == ansGranted
    let v3 = r3.view
    v3.writeSlotAnchor(0, livePid, otherStart)
    check v3.heldSum() == ParentWant

    var blind = newReclaimer(v3, graceNs = 0, mutations = {rmIgnoreStartTime})
    discard blind.reclaimPass()
    let leaked = blind.reclaimPass()
    check leaked.reclaimed == 0
    check leaked.action[0] == saLive
    check leaked.verdict[0] == avLive          # WRONG, and only start time knows
    check v3.heldSum() == ParentWant           # <-- the leak SM-6 forbids

    # ...while the shipping reclaimer, on that same board, gives it back.
    var good = newReclaimer(v3, graceNs = 0)
    discard good.reclaimPass()
    let fixed = good.reclaimPass()
    check fixed.reclaimed == 1
    check fixed.verdict[0] == avPidReused
    check v3.heldSum() == ResourceVec()

    var st: cint
    check waitpid(pid, st, 0) == pid
    l.detach()

# ---------------------------------------------------------------------------
# 4. An abandoned PENDING request is reclaimed too — it is not capacity, it is
#    the admission ORDER, and a dead reservation head would block it forever.
# ---------------------------------------------------------------------------

suite "M7 SM-5: a dead client's PENDING request does not wedge the scan":
  test "a request published by a process that then dies is reclaimed":
    let path = freshPath("pending")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [Cap], requestSlots = 4)
    check l.available
    var p = l.arbiterClient(0)
    check p.registerSlot(0)
    let v = p.view

    # The survivor takes its grant first, so the machine is no longer idle.
    check p.publishRequest(ParentWant) == psPublished
    check p.grantPending()
    check p.collectAnswer() == ansGranted
    check v.heldSum() == ParentWant                  # free is now (7, 60, 7, 90)

    # The dead client then asks for MORE than is free but LESS than the machine
    # has in total, so under M6's policy it is not refusable and becomes the
    # RESERVATION HEAD — capacity held idle for a process that will never collect.
    # That is the shape SM-5 is about: not corruption, but admission stopped by a
    # corpse.
    let pid = fork()
    if pid == 0:
      var l2 = attachLeaseSegment(path)
      var c = l2.arbiterClient(1)
      doAssert c.registerSlot(1)
      doAssert c.publishRequest(vec(8, 60, 7, 90)) == psPublished
      discard kill(getpid(), SIGKILL)
      cExit(9)
    check pid > 0
    var st: cint
    check waitpid(pid, st, 0) == pid
    check WIFSIGNALED(st)
    check WTERMSIG(st) == SIGKILL
    check waitForState(v, 1, rqPending)

    # A live client's small request now sits BEHIND the dead head. It FITS what is
    # genuinely free, and it is refused anyway — correctly, by the anti-starvation
    # policy, which has no way to know the head is a corpse.
    var q = l.arbiterClient(2)
    check q.registerSlot(2)
    check q.publishRequest(ParentWant) == psPublished
    check not v.decidableWork()            # <-- ADMISSION IS STOPPED
    var round: CombineRound
    for _ in 0 ..< 20:
      discard q.tryCombine(round)
      sleep(1)
    check not v.answerArrived(2)

    var rc = newReclaimer(v, graceNs = 0)
    discard rc.reclaimPass()
    let rep = rc.reclaimPass()
    check rep.action[1] == saReclaimed
    check rep.verdict[1] == avOwnerGone
    check rep.freed == ResourceVec()        # it held no capacity, only the order
    check stateOf(v.stateAt(1)) == rqFree

    # ...and admission restarts immediately afterwards.
    check v.decidableWork()
    var round2: CombineRound
    check q.tryCombine(round2) == cbCommitted
    check round2.reserveSlot == -1
    check q.collectAnswer() == ansGranted
    check v.heldSum() == ParentWant + ParentWant
    l.detach()

# ---------------------------------------------------------------------------
# 5. THE GRACE — the OTHER half of the shipping rule, and the one the anchor
#    structurally cannot cover.
# ---------------------------------------------------------------------------

suite "M7: the grace is what stops a pass judging a two-step write":
  test "a slot mid-registration survives every pass; rmNoGrace yanks it on the first":
    ## WHY THIS NEEDS ITS OWN TEST RATHER THAN RIDING ON THE ANCHOR ONES. The
    ## shipping rule is "the anchor is NOT `avLive` **AND** the words have been
    ## unchanged for a bounded grace", and suites 1-3 above exercise only the
    ## anchor half: in every one of them the grace is set to zero so it is out of
    ## the way. `rmNoGrace` was declared as the grace's required-to-fail control
    ## and nothing ran it, which left the grace half — half of the safety rule —
    ## asserted by prose alone.
    ##
    ## **THE ANCHOR CANNOT COVER THIS WINDOW, AND THAT IS THE WHOLE POINT.**
    ## `registerSlot` CASes the state word to `rqIdle` and THEN stores pid and
    ## start time (`arbiter.nim`), so between those two instructions the slot is
    ## OCCUPIED with an anchor of zero — which `anchorVerdict` reads as
    ## `avNoOwner`, not `avLive`. The anchor half therefore does not decline; it
    ## has nothing to go on. The only thing standing between a live registrant and
    ## a reaper is the grace.
    ##
    ## WHAT IS CONSTRUCTED, AND WHY IT IS THE SAME STATE. The window is two
    ## instructions wide and there is deliberately no schedule hook inside it (a
    ## new `SchedulePoint` would be a seam in the hot registration path, and the
    ## kill-injection gate loops over that enumeration), so the test writes the
    ## anchor back to zero with `writeSlotAnchor` — the same test-support writer
    ## the pid-reuse suite uses — immediately after a REAL `registerSlot` by a
    ## REAL live process. The resulting words are byte-for-byte what registration
    ## passes through: state `rqIdle`, pid 0, start 0. There is nothing for the
    ## reclaimer to tell apart, and the registrant really is alive.
    let path = freshPath("grace")
    defer: cleanup(path)
    var l = createLeaseSegment(path, [Cap], requestSlots = 4)
    check l.available
    var p = l.arbiterClient(0)
    check p.registerSlot(0)                  # the reaper's own slot: a live control
    let v = p.view

    var w = l.arbiterClient(1)
    check w.registerSlot(1)                  # a REAL registration by a LIVE process
    v.writeSlotAnchor(1, 0, 0)               # ...rewound INTO its two-step window
    check stateOf(v.stateAt(1)) == rqIdle
    check v.slotOwnerPid(1) == 0'u64
    check anchorVerdict(v.boot, 0, 0) == avNoOwner   # the anchor has NOTHING to say

    # THE SHIPPING RECLAIMER, at its SHIPPING grace — not the zero the suites above
    # use. It must decline on the first sighting (nothing has been seen before) AND
    # on the second (the words are unchanged but the grace has not elapsed: two
    # back-to-back passes over four slots are microseconds apart and the default
    # grace is 50 ms).
    var rc = newReclaimer(v, graceNs = DefaultReclaimGraceNs)
    check rc.graceNs == 50_000_000'i64
    let a = rc.reclaimPass()
    check a.reclaimed == 0
    check a.action[1] == saGrace
    check a.verdict[1] == avNoOwner          # judged gone, and NOT acted on
    let b = rc.reclaimPass()
    check b.reclaimed == 0
    check b.action[1] == saGrace             # <-- the SECOND sighting, still held
    check rc.stats.graceSkipped >= 2'u64     # it was ASKED twice, and said no twice
    check stateOf(v.stateAt(1)) == rqIdle    # the live registrant still owns it
    check v.reclaimEpoch() == 0'u64

    # ...AND THE GRACE HANDS OVER TO THE ANCHOR RATHER THAN MERELY DELAYING. The
    # registrant completes the two-step write — these are `registerSlot`'s next two
    # stores, nothing more — and from then on the slot is declined by the ANCHOR,
    # so waiting out the grace changes nothing.
    v.writeSlotAnchor(1, uint64(getpid()), processStartTime(int(getpid())))
    let c = rc.reclaimPass()
    check c.action[1] == saLive
    check c.verdict[1] == avLive
    sleep(80)                                # well past the 50 ms grace
    let d = rc.reclaimPass()
    check d.action[1] == saLive
    check d.reclaimed == 0
    check stateOf(v.stateAt(1)) == rqIdle

    # THE MUTATION, AND IT IS THE CONTROL THE MILESTONE, BOTH READMEs AND THE
    # VERIFICATION RECORD ALL CITE. Identical board, identical grace value, one
    # live registrant rewound into the identical window — and `rmNoGrace` acts on
    # the FIRST observation.
    var w2 = l.arbiterClient(2)
    check w2.registerSlot(2)
    v.writeSlotAnchor(2, 0, 0)
    check stateOf(v.stateAt(2)) == rqIdle

    var bad = newReclaimer(v, graceNs = DefaultReclaimGraceNs,
      mutations = {rmNoGrace})
    let harm = bad.reclaimPass()             # <-- the FIRST pass, and it acts
    check harm.reclaimed == 1
    check harm.action[2] == saReclaimed
    check harm.verdict[2] == avNoOwner       # it knew only "no owner recorded"
    check stateOf(v.stateAt(2)) == rqFree    # the LIVE registrant's slot, yanked
    check v.reclaimEpoch() == 1'u64
    # The two slots whose registration is COMPLETE are untouched, so this is the
    # grace failing and not the anchor: the mutation is scoped to one half.
    check harm.action[0] == saLive
    check harm.action[1] == saLive

    # THE DAMAGE, MEASURED. A slot yanked back to `rqFree` is re-registerable, so
    # a second live client takes the slot the first one believes it owns — and the
    # first one then publishes into it, locking the real owner out. Two live
    # clients, one slot: the state M5's per-slot serialisation exists to forbid.
    var other = l.arbiterClient(2)
    check other.registerSlot(2)
    check w2.publishRequest(ParentWant) == psPublished
    check other.publishRequest(ParentWant) == psNotIdle
    l.detach()
