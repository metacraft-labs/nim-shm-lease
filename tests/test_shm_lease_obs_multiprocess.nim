## THE M4 GATE — the observation ring under real multi-process saturation, with a
## real non-polling consumer, at DELIBERATELY DIFFERING virtual bases.
##
## `RunQuota-Observation-Store.milestones.org` ** M4 :gate:
##   "Saturation test: producers append faster than the consumer drains; asserts
##    every record is either delivered intact or counted as a drop (delivered +
##    dropped == produced, no torn records), and that the producing process's wall
##    time is statistically indistinguishable from a no-observation control. Idle
##    test: a quiet ring costs ZERO consumer wakeups over a multi-second window.
##    Signalling test: producers signal only on the empty-to-non-empty transition,
##    asserted by counting wake syscalls under a sustained non-empty ring."
##   :proves: OS-1, OS-2, SM-1 (consumer side), SM-2
##
## MOCKS: none, and none are possible. The properties under test are that SEPARATE
## PROCESSES appending through THEIR OWN virtual mappings lose nothing silently, and
## that a process asleep in the kernel is woken by another process and by nothing
## else. Threads would not test the first (one address space is exactly what must
## not be relied on) and a fake clock or fake counter would test the fake. So: real
## `fork`, real file-backed `mmap(MAP_SHARED)`, real `MAP_FIXED` at real distinct
## addresses, the kernel's own syscall counter, and the kernel's own `getrusage`.
##
## THE FIVE PHASES, AND WHAT MAKES EACH ASSERTION ABLE TO FAIL:
##
## PHASE A — SATURATION. `P` producer children hammer a small ring while the parent
##   drains it, THROTTLED so the producers genuinely outrun it. Contention and
##   overflow are STRUCTURAL, not incidental — M2's two-gate harness is reused
##   (a start barrier plus a stop gate, so at the instant the parent holds every
##   child's "I am inside the loop" announcement, every child provably IS inside it
##   and none may leave) and the drop count has a DERIVED LOWER BOUND: with capacity
##   `C`, a consumer that drains at most `D` records during production, and `N`
##   records produced, at least `N - C - D` must be dropped. So "drops happened" is
##   arithmetic, not luck. The overlap assertions come FIRST so a regression names
##   the cause (serial execution) rather than only the symptom.
##
## PHASE B — OS-1, THE PERTURBATION MEASUREMENT. Each child times the SAME synthetic
##   workload six ways IN ITS OWN PROCESS — with no observation at all, with an
##   observation appended to its OWN ring, to a ring SHARED by every child, and to a
##   SATURATED ring (so the drop path is what is measured), then with one bare
##   `write(2)` per observation and with a socket ROUND TRIP per observation. The two
##   IPC arms are the FALSIFIABLE CONTROLS: they must EXCEED the same tolerance the
##   ring arms must stay inside, and both are honest LOWER BOUNDS on any IPC-based
##   observation — a socket completion report costs strictly more than one syscall.
##
##   THE ESTIMATOR IS THE HARD PART OF THIS PHASE, and getting it wrong is not
##   visible in the result: an earlier version passed 12/12 on an idle host and
##   failed 12 of 15 runs under 2x-4x CPU oversubscription, reporting a 4.6 ns code
##   path as +288% and, in 9 of 30 loaded samples, reporting NEGATIVE overhead for
##   arms that do strictly more work than the control. TWO properties fix that, and
##   which two was established by REVERTING each candidate INDIVIDUALLY and re-running
##   the gate, not by reasoning about which explanation sounded right:
##
##     * MANY SHORT MEASUREMENT LOOPS RATHER THAN FEW LONG ONES — 200 rounds x 210
##       repetitions, not 10000 rounds x 2. A long loop straddles DVFS transitions and
##       P/E core migration, and on this hardware an efficiency core burns roughly
##       twice the CPU for identical work, which contaminates a CPU-time measurement
##       as surely as preemption contaminates a wall-clock one. REVERTED: 0 of 12 runs
##       pass at 4x oversubscription, with the measured floor moving to -48..+54 per
##       mille.
##     * A PAIRED COMPARISON COMBINED BY THE MEDIAN. The overhead is computed INSIDE
##       each repetition, against a baseline measured microseconds away. Best-over-
##       phase against best-over-phase lets whichever quantity caught the faster clock
##       window set the result. REVERTED: 3 of 8 runs pass even on an IDLE host, with
##       the 4.6 ns drop path reading up to +93 per mille.
##
##   TWO FURTHER PROPERTIES ARE KEPT AND ARE NOT LOAD-BEARING, and recording that is
##   the point rather than an aside: the CPU-time clock (see `timed`) and the
##   measurement-order rotation. Each was reverted individually and the gate still
##   passed — wall time 6/6 idle, 20/20 at 4x and 8/8 at 8x with the floor still 0;
##   fixed order 6/6 idle, 12/12 at 4x, 8/8 at 8x. They stay because CPU time is the
##   semantically right instrument for a question about CPU cost and both are cheap,
##   but a reader must not infer that either is what makes this phase survive a loaded
##   host.
##
##   AND THE PHASE MEASURES ITS OWN FLOOR. A sixth arm, `paNull`, runs the baseline
##   loop with NOTHING added through the identical estimator; what it reports is
##   control-vs-control, i.e. the finest difference this instrument can resolve on
##   this machine on this run. Every threshold is anchored to that reading, and two
##   sanity assertions run BEFORE any arm is judged: the floor must be small, and no
##   arm may read meaningfully FASTER than the baseline it is structurally built on.
##   A result that cannot physically happen must fail loudly rather than pass
##   silently, which is what the old `medOwn < limit` did with every negative sample.
##
## PHASE C — SM-1 (CONSUMER SIDE) AND THE IDLE GATE. A consumer child blocks on a
##   quiet ring for a multi-second window; a second child POLLS the same ring, which
##   is the implementation this design exists to remove. The blocked child must come
##   back having entered the kernel exactly ONCE — i.e. ZERO wakeups over the whole
##   window — and having burned no measurable CPU; the poller must exceed the same
##   limits. A threshold nothing can fail is not a measurement.
##
## PHASE D — SM-2 AND THE SIGNALLING RULE. A consumer child parks; the parent then
##   appends a long burst that keeps the ring non-empty throughout, and counts its
##   OWN kernel syscalls. Exactly ONE — the empty-to-non-empty transition — against
##   a control arm running the naive "signal on every append", which the transport
##   spec names as the thing that "would restore the syscall this design removes".
##
## PHASE E — NO DAEMON ATTACHED. A child at its own base publishes into a ring
##   nobody drains and nobody has ever registered against: no failure, no block, and
##   every record either accepted or counted.
##
## HARNESS SHAPE IS M2's AND M3's, DELIBERATELY REUSED rather than re-derived. One
## `PROT_NONE` region reserved BEFORE the fork, so child `i` maps at
## `region + i * pageAlignedStride` and the bases are pairwise distinct BY
## CONSTRUCTION — two forked children both calling `mmap(nil, ...)` would very likely
## land at the SAME address and prove nothing. The stride comes from
## `sysconf(_SC_PAGESIZE)`, never from a hard-coded 4096 (16 KiB on Apple Silicon —
## the hazard M2 hit, carried forward through M3's and M4's `:notes:`). A start
## barrier over a pipe releases every child with one `close`, and the report pipe is
## DRAINED BEFORE the children are reaped, because reaping first is the pipe
## deadlock M2 found for real.

import std/[algorithm, os, posix, strutils, unittest]
import shm_lease/[obsring, waitword, syscount, anchor]

# ---------------------------------------------------------------------------
# geometry, thresholds, and the knobs
# ---------------------------------------------------------------------------

const
  RecLen = 48
    ## One observation. Small on purpose: the ring's cost must be dominated by the
    ## coordination, not by the `memcpy`, or the perturbation measurement would be
    ## measuring `memcpy` rather than the transport.

  # --- phase A ---
  SatCapacity = 256
    ## Deliberately far smaller than the burst, so overflow is arithmetic.
  DefaultProducers = 4
  DefaultRounds = 20_000
  ThrottledDrain = 4_000
    ## The most the consumer may drain WHILE the producers run. Together with the
    ## capacity this is what turns "the producers outran the consumer" into a
    ## derived lower bound on the drop count instead of a hope.

  # --- phase B ---
  PerturbCapacity = 262_144
    ## Big enough that NEITHER a per-child ring (`PerturbReps x PerturbRounds`
    ## appends) nor the shared one (3 children x the same) ever fills. A ring that
    ## filled part way through an arm would silently switch that arm onto the much
    ## cheaper drop path and flatter the measurement. This is not left to arithmetic
    ## the reader has to redo: the phase asserts the capacity covers the configured
    ## knobs BEFORE forking, and asserts `droppedCount() == 0` on every measured ring
    ## AFTERWARDS, so a knob sweep cannot silently invalidate the arm.
  PerturbRounds = 200
    ## Iterations per timed loop: ~480 us of work. SHORT ON PURPOSE, and this is the
    ## knob that most decides whether the phase is load-robust. The shorter a loop
    ## is, the less likely it is to straddle a DVFS transition or a migration onto an
    ## efficiency core — and on this hardware an efficiency core burns roughly twice
    ## the CPU for the same work, so a straddled loop is the dominant contaminant of
    ## a CPU-time measurement. Short loops also buy a LOT of them: the budget goes
    ## into `PerturbReps` instead. The floor on how short is quantisation, and the
    ## thread CPU clock's ~83 ns is under 0.2 per mille of 480 us.
  PerturbReps = 210
    ## HOW MANY TIMES THE WHOLE ARM CYCLE IS REPEATED, with each arm's estimate being
    ## the MEDIAN OF THE PAIRED PER-REPETITION DIFFERENCES (see the estimator comment
    ## in the perturbation child). This is what replaces the old single ABBA sweep,
    ## and it is the second half of the fix for a phase that failed 12 of 15 runs
    ## under load. Two samples (all ABBA gave) do not converge on anything: they leave
    ## the baseline pinned at the two positions in the sequence where it is least
    ## representative, which is how arms doing strictly more work came to report
    ## NEGATIVE overhead. Many short repetitions each carry their OWN adjacent
    ## baseline instead, so the achieved-clock drift that produced those readings
    ## cancels inside the pair rather than having to be averaged away. A WHOLE
    ## MULTIPLE of `PerturbSlots`, so the order rotation below balances exactly
    ## rather than approximately.
  PerturbWorkIters = 3000
    ## The synthetic unit of "real work" each iteration does — about 2.4 us here,
    ## and STILL orders of magnitude smaller than any real execution, so the regime
    ## is deliberately harsher on the transport than the deployment will be. Sized
    ## from measurement so both margins are real: at this size an append is well
    ## under 1% of the unit and one IPC call is 20-40% of it, so the ring arms clear
    ## the tolerance by an order of magnitude and the control arms exceed it by 3x or
    ## more. Making the unit much larger would push the CONTROLS under the tolerance
    ## too, and a control that cannot fail proves nothing.
  PerturbLimitPermille = 50
    ## THE TOLERANCE, in PER MILLE of the no-observation baseline: 5.0%. Per mille,
    ## not percent, because the quantities it sits between differ by a factor of ten
    ## and integer percent cannot express the lower one at all.
    ##
    ## DERIVED FROM THIS HOST'S OWN MEASUREMENTS, and the phase re-measures the floor
    ## it is anchored to on every single run rather than trusting this comment.
    ## Darwin 25.5 / arm64, 16 cores, 3 children per run, taken IDLE and under 2x and
    ## 4x CPU OVERSUBSCRIPTION (32 and 64 spinners on 16 cores; the gate's own wall
    ## time grew 4.4 s -> 5.5 s -> 8.4 s, so the load really did bite), and taken on
    ## BOTH BUILDS, because `just test` runs this gate UNOPTIMISED while the stability
    ## runs are release. min .. max with the median in brackets, in per mille:
    ##
    ##                                          RELEASE (n=108)    DEBUG (n=48)
    ##   noise floor (`paNull`, ctl vs ctl)       0 ..   0  [0]     0 ..   0  [0]
    ##   ring, own per-process ring               3 ..   5  [3]    14 ..  17  [15]
    ##   ring, SATURATED / counted-drop path      0 ..   1  [0]     4 ..   5  [4]
    ##   ring, SHARED by all three (not asserted) 4 ..  16  [5]    14 ..  30  [21]
    ##   one-way `write(2)` per observation     161 .. 228 [164]  164 .. 235 [168]
    ##   socket round trip per observation      358 .. 376 [364]  357 .. 373 [366]
    ##
    ## The ring arm and the IPC arms are a factor of ten apart even on the worse of
    ## the two builds, and the tolerance goes between them with the margin split
    ## about evenly: 50 is ~2.9x the WORST ring reading over BOTH builds and all three
    ## load levels, and ~3.2x below the WEAKEST falsifying control. So an
    ## implementation costing more than ~3x what this one costs FAILS, and the
    ## assertion still cannot be satisfied by an IPC-shaped transport. Checked by
    ## mutation rather than by argument: giving the ring arm ten appends per
    ## observation instead of one takes it to ~69 per mille and fails this threshold,
    ## and adding a single `write(2)` per observation takes it to ~174.
    ##
    ## WHY NOT TIGHTER: the unoptimised build reads 14-17 and the phase must not fail
    ## because a verifier ran `just test` rather than a release binary, or because
    ## their host differs a little from this one. WHY NOT LOOSER: the 120 this
    ## replaces would have passed an implementation perturbing the producer by 11%,
    ## i.e. ~7x this one, and a threshold nothing realistic can violate is not a
    ## measurement.
    ##
    ## Calibrated FROM BOTH SIDES, as M3's CPU limit is: the ring arms must stay
    ## under it AND both IPC control arms must EXCEED it. A tolerance only one side
    ## can fail is not a measurement.
    ##
    ## WHAT THIS IS NOT: it is NOT a claim that observing is INDISTINGUISHABLE from
    ## not observing. It is not — the ring arm reads 3-5 per mille (release) against
    ## a floor that measured EXACTLY 0 in every one of 156 samples, which is about as
    ## distinguishable as a measurement gets — and a bar demanding indistinguishability
    ## would be unachievable, which is precisely what invited the tolerance this
    ## replaces. The claim is that the perturbation is BOUNDED AND SMALL, and it is
    ## falsifiable in both directions.
  NoiseFloorLimitPermille = 8
    ## THE RESOLUTION THIS PHASE REQUIRES OF ITS OWN INSTRUMENT: 0.8%. One constant,
    ## used twice, and both uses are falsifiable.
    ##
    ## (a) THE INSTRUMENT MUST DEMONSTRATE IT, every run, before any arm is judged.
    ## `paNull` — the baseline loop with nothing added, through the identical
    ## estimator — must read within this of the baseline. If it does not, the machine
    ## moved under the measurement and no arm's figure means anything however good it
    ## looks, so the phase fails naming the CAUSE rather than the symptom. Measured
    ## here over 156 samples, both builds, idle and under 2x/4x oversubscription:
    ## EXACTLY 0, every sample, so this bound is never approached — but it is what stands between a
    ## reported number and a believed one when it is.
    ##
    ## (b) IT IS ALSO THE ONLY ALLOWANCE FOR A NEGATIVE READING. Every arm is
    ## structurally the baseline plus an observation, so no arm can honestly measure
    ## FASTER than the baseline; but the cheapest arm (the counted-drop path, ~4.6 ns
    ## against a 2.4 us work unit, i.e. ~2 per mille) sits near the instrument's
    ## resolution and could read slightly under it. Readings inside the resolution
    ## the phase just demanded of itself are unresolvable and allowed; anything below
    ## that is contamination and must FAIL. For scale, the wall-clock estimator this
    ## replaces produced negative readings of 19, 31 and 89 per mille — every one of
    ## them caught by this bound, and every one of them passed SILENTLY by the old
    ## `medOwn < limit` assertion, which any negative number satisfies.

  # --- phase C ---
  DefaultIdleSeconds = 3
  IdleCpuLimitNs = 20_000_000'u64
    ## 20 ms of CPU over a multi-second idle block — under 1% of one core. The same
    ## limit M3 used for the waiter side, applied here to the CONSUMER side, and
    ## again asserted against a control that must EXCEED it.
  PollIntervalMs = 1
    ## The polling control's interval. One millisecond is a generous poller; a real
    ## one would be faster and burn more.

  # --- phase D ---
  SignalCapacity = 65536
  SignalBurst = 20_000

  # --- phase E ---
  NoDaemonCapacity = 64
  NoDaemonRounds = 512

type
  PerturbArm = enum
    ## Phase B's measured arms, IN THE ORDER THE CHILD RUNS THEM WITHIN EACH
    ## REPETITION. Every one of them is the baseline's work loop plus (at most) one
    ## observation per iteration, so no arm can do LESS work than the baseline and
    ## no arm can honestly measure faster than it.
    paNull       ## NOTHING added — the baseline measured a second time. THE FLOOR.
    paOwn        ## an append to THIS PROCESS'S OWN ring — the asserted arm
    paShared     ## an append to the ring all three children share — reported only
    paFull       ## an append to a SATURATED ring, i.e. the counted-drop path
    paWrite      ## one-way `write(2)` of the record — falsifiable IPC control
    paRtrip      ## socketpair round trip — falsifiable IPC control

const
  PerturbSlots = ord(high(PerturbArm)) + 2
    ## One slot per measurement in a repetition: the baseline plus every arm. The
    ## cycle is ROTATED by one slot each repetition so every measurement occupies
    ## every position equally often — see the child's loop for why that matters.

type
  ChildRole = enum
    crProducer        ## phase A: hammer the ring
    crPerturb         ## phase B: time the same work with and without observing
    crBlockConsumer   ## phase C: park on a quiet ring
    crPollConsumer    ## phase C: POLL the same quiet ring — the prohibited design
    crSignalConsumer  ## phase D: park once so the parent can count its own signals
    crNoDaemon        ## phase E: publish with nobody attached at all

  ChildReport = object
    ## Reported over a pipe, never through the segment: a mapped base is an ADDRESS,
    ## and writing an address into shared memory is precisely the position-
    ## independence violation this harness exists to rule out.
    ok: uint64
    childId: uint64
    role: uint32
    base: uint64
    published: uint64
    dropped: uint64
    rounds: uint64
    startNs: uint64
    endNs: uint64
    wallNs: uint64
    cpuNs: uint64
    parks: uint64
    waitRc: uint32
    syscalls: uint64
    ctlNs: uint64
      ## Phase B's BASELINE: the synthetic work with no observation, as the MEDIAN
      ## over `PerturbReps` repetitions interleaved with the arms. Reported for scale
      ## only — no threshold reads it, because a ratio of two separately-summarised
      ## timings is exactly the estimator this phase had to stop using.
    armPp100k: array[PerturbArm, int64]
      ## Each arm's overhead over the baseline in PARTS PER 100000, computed PER
      ## REPETITION against the baseline measured alongside it and then taken as the
      ## MEDIAN across repetitions. `paNull` is the baseline loop with nothing added,
      ## carried through the identical estimator, so `armPp100k[paNull]` is a
      ## control-vs-control reading — the noise floor, measured every run rather than
      ## assumed.
    workAcc: uint64

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
proc quitChild(code: cint) {.noreturn.} = cExit(code)

var tmpCounter = 0
proc freshPath(tag: string): string =
  inc tmpCounter
  getTempDir() / ("shmlease-m4-" & tag & "-" & $getpid() & "-" & $tmpCounter & ".seg")

proc cleanup(path: string) =
  try: removeFile(path)
  except CatchableError: discard

proc nowNs(): uint64 =
  var ts: Timespec
  discard clock_gettime(CLOCK_MONOTONIC, ts)
  uint64(ts.tv_sec) * 1_000_000_000'u64 + uint64(ts.tv_nsec)

proc selfCpuNs(): uint64 =
  ## This process's own CPU, user + system, as the KERNEL accounts it. Self-reported
  ## per child rather than taken from `RUSAGE_CHILDREN`, because a phase runs several
  ## children at once and an aggregate would not say which one burned the core.
  var ru: Rusage
  if getrusage(RUSAGE_SELF, addr ru) != 0: return 0
  uint64(ru.ru_utime.tv_sec) * 1_000_000_000'u64 +
    uint64(ru.ru_utime.tv_usec) * 1_000'u64 +
    uint64(ru.ru_stime.tv_sec) * 1_000_000_000'u64 +
    uint64(ru.ru_stime.tv_usec) * 1_000'u64

var CLOCK_THREAD_CPUTIME {.importc: "CLOCK_THREAD_CPUTIME_ID",
    header: "<time.h>".}: ClockId

proc selfThreadCpuNs(): uint64 =
  ## THIS THREAD's own CPU time, at the finest resolution the platform offers.
  ##
  ## Phase B times with this rather than with `selfCpuNs` above because it is the
  ## finer clock, NOT because CPU time is what rescued the phase (see `timed`: the
  ## wall-clock revert still passes 8/8 at 8x). `getrusage` quantises to 1 us on this
  ## host; this clock quantises to ~83 ns, twelve times finer, at ~97 ns a call. That
  ## buys the thing phase B's estimator does depend on: loops SHORT enough to fit
  ## inside a single frequency/core regime (a few hundred microseconds) with
  ## quantisation still well under a per mille, and therefore HUNDREDS of paired
  ## repetitions instead of a handful. Long loops straddle DVFS transitions and P/E
  ## core migrations, and a straddled loop is the dominant contaminant of a CPU-time
  ## measurement on this hardware — a thread displaced onto an efficiency core burns
  ## roughly twice the CPU for the same work.
  ##
  ## Thread rather than process CPU because the child is single-threaded and a
  ## thread clock cannot pick up anything else the process happens to be doing.
  var ts: Timespec
  if clock_gettime(CLOCK_THREAD_CPUTIME, ts) != 0: return 0
  uint64(ts.tv_sec) * 1_000_000_000'u64 + uint64(ts.tv_nsec)

proc envInt(name: string; dflt: int): int =
  result = dflt
  try:
    let raw = getEnv(name)
    if raw.len > 0: result = max(1, parseInt(raw.strip()))
  except CatchableError: discard

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

# --- the record, self-describing so a torn one cannot pass -------------------

proc mkRec(producer, seqNo: uint32): array[RecLen, byte] =
  result[0] = byte(producer and 0xFF)
  result[1] = byte((producer shr 8) and 0xFF)
  result[2] = byte(seqNo and 0xFF)
  result[3] = byte((seqNo shr 8) and 0xFF)
  result[4] = byte((seqNo shr 16) and 0xFF)
  result[5] = byte((seqNo shr 24) and 0xFF)
  for i in 6 ..< RecLen - 2:
    result[i] = byte((producer * 31 + seqNo * 17 + uint32(i)) and 0xFF)
  var sum: uint16 = 0
  for i in 0 ..< RecLen - 2: sum = sum + uint16(result[i])
  result[RecLen - 2] = byte(sum and 0xFF)
  result[RecLen - 1] = byte((sum shr 8) and 0xFF)

proc recProducer(buf: openArray[byte]): uint32 =
  uint32(buf[0]) or (uint32(buf[1]) shl 8)

proc recSeq(buf: openArray[byte]): uint32 =
  uint32(buf[2]) or (uint32(buf[3]) shl 8) or (uint32(buf[4]) shl 16) or
    (uint32(buf[5]) shl 24)

proc recIntact(buf: openArray[byte]; n: int): bool =
  ## A record is INTACT iff it has the right length, its filler matches what its own
  ## (producer, seq) header says it should be, and its checksum agrees. A record
  ## assembled from two different writers' bytes fails all three.
  if n != RecLen: return false
  let p = recProducer(buf)
  let s = recSeq(buf)
  for i in 6 ..< RecLen - 2:
    if buf[i] != byte((p * 31 + s * 17 + uint32(i)) and 0xFF): return false
  var sum: uint16 = 0
  for i in 0 ..< RecLen - 2: sum = sum + uint16(buf[i])
  buf[RecLen - 2] == byte(sum and 0xFF) and buf[RecLen - 1] == byte((sum shr 8) and 0xFF)

# --- the synthetic workload (phase B) ---------------------------------------

proc doWork(acc: var uint64; iters: int) {.inline.} =
  ## Pure userspace arithmetic standing in for "the execution being observed". It
  ## must not be optimisable away, hence the accumulator the child reports back.
  for i in 0 ..< iters:
    acc = acc * 6364136223846793005'u64 + uint64(i) + 1442695040888963407'u64

# ---------------------------------------------------------------------------
# the child
# ---------------------------------------------------------------------------

proc warmRing(r: ObsRing) =
  ## Touch one byte on every page of the mapping, so a later timed loop is not
  ## measuring first-touch page faults. A read-modify-write rather than a load, so
  ## the page is faulted in WRITABLE — the same reason `prefaultWaitWord` uses an
  ## atomic RMW.
  if not r.available: return
  let ps = pageSize()
  var off = 0
  while off < r.size:
    r.base[off] = r.base[off]
    off += ps

var gPerturbReps = PerturbReps
  ## Phase B's repetition count; set in the parent BEFORE the fork and inherited,
  ## the same way the ring paths are. `SHM_LEASE_OBS_PERTURB_REPS` overrides it.
var gSecondPath: string      ## phase B's SATURATED ring; inherited across `fork`
var gOwnPaths: seq[string]   ## phase B's PER-CHILD rings; likewise inherited

proc childMain(childId: int; role: ChildRole; path: string; wantBase: pointer;
    readyW, goR, stopR, insideW, pipeW: cint; rounds: int;
    windowNs: int64) {.noreturn.} =
  var rep = ChildReport(childId: uint64(childId), role: uint32(ord(role)),
    base: cast[uint64](wantBase))

  # Attach at the base the PARENT chose for this child, over the region it reserved
  # before forking. Every participant observes the same segment through a different
  # virtual address, which is what makes the wake and the ring arithmetic prove
  # something about position independence rather than about one lucky layout.
  var ring = attachObsRing(path, wantBase)
  if not ring.available:
    discard writeFull(pipeW, addr rep, sizeof(rep)); quitChild(11)
  if cast[uint](ring.mappedBase()) != cast[uint](wantBase):
    discard writeFull(pipeW, addr rep, sizeof(rep)); quitChild(12)

  var full, own: ObsRing
  if role == crPerturb:
    full = attachObsRing(gSecondPath)     # its own base; only its FULLNESS matters
    own = attachObsRing(gOwnPaths[childId])
    if not full.available or not own.available:
      discard writeFull(pipeW, addr rep, sizeof(rep)); quitChild(13)
    # WARM ALL THREE MAPPINGS. Without this the timed loops measure first-touch
    # paging of a freshly created multi-megabyte segment rather than the transport:
    # roughly 40 ns per append of pure page-fault cost at this geometry, which is
    # several times the append itself. Faulting a segment in is a real, one-off
    # start-up cost of any mmap design and it belongs in the record, not in the
    # steady-state per-observation figure this phase compares.
    warmRing(ring)
    warmRing(own)
    warmRing(full)

  # START BARRIER (M2's shape): announce "attached", then block until the parent has
  # every child's announcement and releases them all with one `close`.
  var one: byte = 1
  if not writeFull(readyW, addr one, 1):
    discard writeFull(pipeW, addr rep, sizeof(rep)); quitChild(14)
  discard close(readyW)
  var goByte: byte
  discard read(goR, addr goByte, 1)      # 0 at EOF: the broadcast release
  discard close(goR)

  let cpu0 = selfCpuNs()
  let sys0 = unixSyscallCount()
  let t0 = nowNs()
  rep.startNs = t0

  case role
  of crProducer:
    # THE STOP GATE (M2's second gate, and it is load-bearing): after its FIRST
    # append the child announces "I am inside the loop", and it may not LEAVE the
    # loop until the parent closes the stop pipe. So at the instant the parent holds
    # every announcement, every child provably IS inside the hammering loop and none
    # can exit — simultaneity becomes a fact the harness witnessed rather than a
    # probability. A hard cap keeps the child terminating if the parent dies.
    # The stop-gate probe must never BLOCK the hammering loop, so the child reads it
    # non-blockingly: EAGAIN means "still gated", 0 (EOF) means "released".
    discard fcntl(stopR, F_SETFL, fcntl(stopR, F_GETFL, 0) or O_NONBLOCK)
    var published, dropped, done = 0
    let maxRounds = rounds * 8
    var stopped = false
    while done < maxRounds:
      case ring.publish(mkRec(uint32(childId), uint32(done)))
      of oprPublished: inc published
      of oprDropped: inc dropped
      else: discard writeFull(pipeW, addr rep, sizeof(rep)); quitChild(15)
      inc done
      if done == 1:
        # "I am INSIDE the loop." The parent collects one of these per child before
        # it records the simultaneity witness, so at that instant every child is
        # provably hammering — and none may leave until the stop gate opens.
        var b: byte = 1
        discard writeFull(insideW, addr b, 1)
        discard close(insideW)
      if not stopped and (done and 0xFF) == 0:
        var probe: byte
        if read(stopR, addr probe, 1) == 0: stopped = true   # EOF: gate released
      if done >= rounds and stopped: break
    rep.published = uint64(published)
    rep.dropped = uint64(dropped)
    rep.rounds = uint64(done)

  of crPerturb:
    # EVERY ARM MEASURED IN THIS PROCESS, INTERLEAVED WITH ITS OWN BASELINE, AND
    # ESTIMATED AS THE MEDIAN OF THE PAIRED PER-REPETITION DIFFERENCES. Comparing two
    # different children would measure the scheduler as much as the code, so the
    # comparison is always between loops in ONE process. Beyond that, TWO properties
    # are what make this estimator survive a loaded host — the phase failed 12 of 15
    # runs under 2x-4x CPU oversubscription without them, and each was confirmed
    # load-bearing by REVERTING IT INDIVIDUALLY and re-running the gate:
    #
    #   * SHORT MEASUREMENT LOOPS, MANY OF THEM (see `PerturbRounds` /
    #     `PerturbReps`). A long loop straddles DVFS transitions and P/E core
    #     migration; on this host a thread displaced onto an efficiency core burns
    #     roughly twice the CPU for the same work. Reverted to few long loops: 0 of 12
    #     runs pass at 4x, floor -48..+54 per mille.
    #   * THE COMPARISON IS PAIRED AND COMBINED BY THE MEDIAN (see below). Reverted to
    #     best-over-phase against best-over-phase: 3 of 8 runs pass even IDLE.
    #
    # The baseline is therefore RE-MEASURED INSIDE EVERY REPETITION, adjacent to the
    # arms it is compared against, instead of running once at each END of a single
    # ABBA sweep, where it could not escape the start and end transients.
    #
    # And `paNull` — the baseline loop, added to the cycle as a SIXTH ARM and put
    # through the identical estimator — measures what this instrument's floor
    # actually is, on this machine, on this run. Every threshold in the phase is
    # anchored to that reading rather than to a number in a comment.
    var acc = 1'u64
    # ONE pre-built record, used by EVERY arm. Building it inside the timed loop
    # would put the test's own 48-byte checksum loop into the ring arms and not into
    # the control arms, which is a difference in the harness rather than in the
    # transport — and at this work size it was worth 40-100 ns an iteration, i.e.
    # most of what the arm was reporting.
    var rec = mkRec(uint32(childId), 0)
    var reply: array[1, byte]
    # The two perturbing controls' plumbing, opened OUTSIDE the timed loops so the
    # setup cost is not what is being measured.
    let devNull = open("/dev/null".cstring, O_WRONLY)
    var sv: array[2, cint]
    if devNull < 0 or socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0:
      discard writeFull(pipeW, addr rep, sizeof(rep)); quitChild(17)

    template timed(body: untyped): uint64 =
      # CPU TIME, NOT WALL TIME — AND THIS CHANGE IS NOT WHAT MADE PHASE B
      # TRUSTWORTHY, THOUGH AN EARLIER VERSION OF THIS COMMENT CLAIMED IT WAS.
      # Preemption inflates WALL time and leaves CPU time alone, so a CPU clock is
      # the semantically right instrument for a question about CPU cost, and the
      # finer THREAD clock is what makes the short loops affordable (see
      # `selfThreadCpuNs`). But it is NOT load-bearing: reverting `timed` to a
      # wall-clock `nowNs()` and re-running the whole gate passed 6/6 idle, 20/20 at
      # 4x oversubscription and 8/8 at 8x, with the measured floor still 0. What the
      # original wall-clock phase actually lacked was the SHORT LOOPS and the PAIRED
      # MEDIAN below; those two, reverted individually, fail the gate immediately.
      # Keep the diagnosis and the cause apart: this clock explains the symptom
      # ("preemption inflates wall time") and was for a while believed to be the fix,
      # and the belief survived a day precisely because nobody reverted it.
      # Phase C counts CPU the same way through `getrusage`.
      let s = selfThreadCpuNs()
      body
      selfThreadCpuNs() - s

    template armRun(observe: untyped): uint64 =
      ## The baseline's work loop PLUS `observe` once per iteration. The baseline
      ## itself is this template with an empty `observe`, so every arm is
      ## STRUCTURALLY the baseline plus work — which is what makes a negative
      ## reading a statement about the instrument rather than about the transport.
      timed:
        for i in 0 ..< rounds:
          doWork(acc, PerturbWorkIters)
          observe

    template ctlRun(): uint64 =
      ## THE BASELINE, and it is literally `armRun` with an EMPTY observation — the
      ## same loop, the same timing path, the same code shape. Writing it as its own
      ## loop would reintroduce exactly the class of harness difference that made an
      ## earlier version of this phase report the test's own checksum as transport
      ## cost.
      armRun:
        discard

    # DISCARDED WARM-UP. The child has just come off the start barrier, i.e. off a
    # blocking read, so the very first timed loop pays the frequency ramp, a cold
    # i-cache and a cold branch predictor. That transient is a real cost of starting
    # a process and it is not the cost of an observation.
    discard ctlRun()

    # PAIRED WITHIN EVERY REPETITION, AND THE ESTIMATE IS THE MEDIAN OF THE PAIRED
    # DIFFERENCES. This, not the arm loops, is where phase B's trustworthiness comes
    # from, and every part of it was forced by a measurement that lied:
    #
    #   * PAIRED. The overhead is computed INSIDE each repetition, arm against the
    #     baseline measured a few hundred microseconds away, and only then combined
    #     across repetitions. Comparing an arm's best over the whole phase against
    #     the baseline's best over the whole phase does NOT work on this hardware:
    #     the achieved clock varies by several percent over the phase's lifetime, and
    #     whichever of the two happened to catch the faster window sets the result.
    #     That produced a 4.6 ns code path reading as +9.1%, and baselines "faster"
    #     than arms built out of them.
    #   * THE ORDER IS ROTATED by one slot per repetition, so each of the seven
    #     measurements occupies each position equally often. THIS IS TIDINESS, NOT A
    #     FIX, and the record used to say otherwise: the claim was that a fixed order
    #     left the baseline immediately after the socket arm's syscalls where it read
    #     "up to 3.6% high". That was MEASURED and is FALSE — running all seven slots
    #     with an IDENTICAL empty baseline in fixed order puts position dependence at
    #     0.0-0.1 per mille, idle and under 4x load, and with the pre-fix long loops
    #     too. Reverting the rotation passes the gate 6/6 idle, 12/12 at 4x and 8/8 at
    #     8x. It stays because it is free and because it removes the question, not
    #     because anything here depends on it.
    #   * THE MEDIAN, not the mean and not the minimum. The mean is at the mercy of
    #     one preempted repetition. The minimum is BIASED: it selects the luckiest
    #     sample of each quantity independently, which is exactly the coupling the
    #     pairing exists to remove.
    #
    # `PerturbReps` is a whole multiple of `PerturbSlots`, so the rotation balances
    # exactly rather than statistically.
    doAssert gPerturbReps mod PerturbSlots == 0
    var perRep: array[PerturbArm, seq[int64]]
    for a in PerturbArm: perRep[a] = newSeqOfCap[int64](gPerturbReps)
    var ctlSamples = newSeqOfCap[uint64](gPerturbReps)

    for it in 0 ..< gPerturbReps:
      var repCtl = 0'u64
      var repArm: array[PerturbArm, uint64]
      for slot in 0 ..< PerturbSlots:
        case (it + slot) mod PerturbSlots
        of 0:
          # THE BASELINE: the synthetic work and nothing else.
          repCtl = ctlRun()
        of 1:
          # THE FLOOR: the baseline loop AGAIN, with nothing added, carried through
          # the identical estimator as a full arm. What this reports against the
          # baseline is the smallest difference the instrument can honestly resolve,
          # and the phase's thresholds are anchored to it.
          repArm[paNull] = armRun:
            discard
        of 2:
          # THIS PROCESS'S OWN ring — the per-observation cost of the transport with
          # no cross-process sharing, which is the arm the tolerance is asserted on.
          repArm[paOwn] = armRun:
            discard own.publish(rec)
        of 3:
          # The SHARED ring every child is appending to at the same time. REPORTED,
          # not asserted — see the phase's assertions for why.
          repArm[paShared] = armRun:
            discard ring.publish(rec)
        of 4:
          # The SATURATED ring: every append here takes the counted-drop path.
          repArm[paFull] = armRun:
            discard full.publish(rec)
        of 5:
          # ONE-WAY SEND: the cheapest conceivable IPC delivery of an observation —
          # one `write` of the record, to a sink that does nothing with it. No peer,
          # no reply, no scheduling. A strict LOWER BOUND on a socket append.
          repArm[paWrite] = armRun:
            discard write(devNull, addr rec[0], RecLen)
        else:
          # THE ROUND TRIP the transport spec forbids: "Publishing MUST NOT add a
          # round trip. An observation is a one-way append with no reply." Modelled
          # at its floor — the four syscalls of send/receive/ack/receive over a real
          # socketpair, with the daemon's own work and its scheduling latency
          # EXCLUDED, so a real completion report costs strictly more than this.
          repArm[paRtrip] = armRun:
            discard write(sv[0], addr rec[0], RecLen)
            discard read(sv[1], addr rec[0], RecLen)
            discard write(sv[1], addr reply[0], 1)
            discard read(sv[0], addr reply[0], 1)
      if repCtl == 0: continue
      ctlSamples.add repCtl
      for a in PerturbArm:
        # In PARTS PER 100000, not per mille: the effect being resolved is a couple
        # of per mille and integer division at per-mille granularity would quantise
        # most of it away before the median ever sees it.
        perRep[a].add (int64(repArm[a]) - int64(repCtl)) * 100_000 div int64(repCtl)

    var arms: array[PerturbArm, int64]
    for a in PerturbArm:
      sort(perRep[a])
      arms[a] = perRep[a][perRep[a].len div 2]
    sort(ctlSamples)

    rep.ctlNs = ctlSamples[ctlSamples.len div 2]
    rep.armPp100k = arms
    rep.workAcc = acc
    rep.rounds = uint64(rounds)
    rep.published = uint64(gPerturbReps * rounds)  # appends per ring arm
    discard close(devNull)
    discard close(sv[0])
    discard close(sv[1])
    own.detach()
    full.detach()

  of crBlockConsumer:
    # The non-polling consumer, doing exactly what an idle daemon does. `parks`
    # counts KERNEL ENTRIES, so `parks == 1` means it slept once and returned once:
    # ZERO wakeups over the whole quiet window.
    ring.registerConsumer()
    var parks = 0
    let rc = ring.awaitRecord(timeoutNs = windowNs * 8, parks = addr parks)
    rep.parks = uint64(parks)
    rep.waitRc = uint32(ord(rc))

  of crPollConsumer:
    # THE PROHIBITED DESIGN, as the negative control. A 1 ms poll on a quiet ring is
    # what "the consumer MUST NOT poll" is about: it burns a timer syscall per
    # interval forever, on a machine that has nothing to report.
    var polls = 0'u64
    let capNs = uint64(windowNs) * 8
    while ring.pendingCount() == 0:
      sleep(PollIntervalMs)
      inc polls
      if nowNs() - t0 > capNs: break
    rep.parks = polls
    rep.waitRc = uint32(ord(owrReady))

  of crSignalConsumer:
    # Park ONCE so the parent has a genuine idle consumer to signal, then HOLD
    # without draining and without re-parking, so the ring stays non-empty for the
    # rest of the parent's burst and the parent's syscall count is attributable to
    # the empty-to-non-empty transition and to nothing else.
    ring.registerConsumer()
    var parks = 0
    let rc = ring.awaitRecord(timeoutNs = windowNs * 8, parks = addr parks)
    rep.parks = uint64(parks)
    rep.waitRc = uint32(ord(rc))
    var b: byte
    discard read(stopR, addr b, 1)     # hold until the parent has finished counting

  of crNoDaemon:
    # Nobody has ever registered as a consumer and nobody is draining. Publishing
    # must still work, must not block, and must not fail — OS-4's "a missing daemon
    # MUST NOT be reported as an error" at the transport level.
    var published, dropped = 0
    for i in 0 ..< rounds:
      case ring.publish(mkRec(uint32(childId), uint32(i)))
      of oprPublished: inc published
      of oprDropped: inc dropped
      else: discard writeFull(pipeW, addr rep, sizeof(rep)); quitChild(16)
    rep.published = uint64(published)
    rep.dropped = uint64(dropped)
    rep.rounds = uint64(rounds)

  rep.endNs = nowNs()
  rep.wallNs = rep.endNs - t0
  rep.cpuNs = selfCpuNs() - cpu0
  rep.syscalls = unixSyscallCount() - sys0
  rep.ok = 1
  if not writeFull(pipeW, addr rep, sizeof(rep)): quitChild(4)
  quitChild(0)

# ---------------------------------------------------------------------------
# the harness
# ---------------------------------------------------------------------------

type Phase = object
  region: pointer
  regionSize: int
  pids: seq[Pid]
  reportR: cint
  stopW: cint
  insideR: cint
  nChildren: int

proc startPhase(ring: ObsRing; path: string; roles: openArray[ChildRole];
    rounds: int; windowNs: int64): Phase =
  ## Reserve one `PROT_NONE` region BEFORE forking, give child `i` the base
  ## `region + i * stride`, fork, and release every child with a single `close` once
  ## all of them have announced that they attached.
  let n = roles.len
  # `MAP_FIXED` needs a PAGE-ALIGNED address and the page size is a HOST property —
  # 16 KiB on Apple Silicon, 4 KiB elsewhere. M2 strode by the segment size and got
  # a silent `EINVAL` for most children; ask, do not assume.
  let ps = pageSize()
  doAssert ps > 0
  let stride = ((ring.size + ps - 1) div ps) * ps
  result.regionSize = stride * (n + 1)
  result.region = mmap(nil, result.regionSize, PROT_NONE,
    MAP_PRIVATE or MAP_ANONYMOUS, cint(-1), 0)
  doAssert result.region != MAP_FAILED, "could not reserve the MAP_FIXED probe region"
  doAssert cast[uint](ring.mappedBase()) < cast[uint](result.region) or
    cast[uint](ring.mappedBase()) >= cast[uint](result.region) + uint(result.regionSize),
    "the parent's mapping unexpectedly landed inside the probe region"
  result.nChildren = n

  var fds: array[0..1, cint]        # child reports -> parent
  var readyFds: array[0..1, cint]   # child "attached" -> parent
  var goFds: array[0..1, cint]      # parent broadcast release -> children
  var stopFds: array[0..1, cint]    # parent stop gate -> children (EOF releases)
  var insideFds: array[0..1, cint]  # child "I am inside the loop" -> parent
  doAssert pipe(fds) == 0
  doAssert pipe(readyFds) == 0
  doAssert pipe(goFds) == 0
  doAssert pipe(stopFds) == 0
  doAssert pipe(insideFds) == 0

  for i in 0 ..< n:
    let childBase = cast[pointer](cast[uint](result.region) + uint(i * stride))
    let pid = fork()
    if pid == 0:
      discard close(fds[0])
      discard close(readyFds[0])
      discard close(insideFds[0])
      discard close(goFds[1])      # the child must not hold the gate's write end,
      discard close(stopFds[1])    # or it would never observe EOF on the release
      childMain(i, roles[i], path, childBase, readyFds[1], goFds[0], stopFds[0],
        insideFds[1], fds[1], rounds, windowNs)
    doAssert pid > 0
    result.pids.add pid
  discard close(fds[1])
  discard close(readyFds[1])
  discard close(insideFds[1])
  discard close(goFds[0])
  discard close(stopFds[0])

  for i in 0 ..< n:
    var b: byte
    doAssert readFull(readyFds[0], addr b, 1),
      "child " & $i & " never reached the start barrier"
  discard close(readyFds[0])
  discard close(goFds[1])          # BROADCAST: every child starts now
  result.reportR = fds[0]
  result.stopW = stopFds[1]
  result.insideR = insideFds[0]

proc awaitAllInside(p: var Phase): uint64 =
  ## Block until EVERY child has announced that it is inside its loop, then return
  ## the instant that became true. GATE 2 of M2's harness: no child may LEAVE the
  ## loop until `releaseStop`, so at the returned instant every child is provably
  ## inside it. Simultaneity is a fact the harness witnessed, not a probability —
  ## a start barrier ALONE was measured (in M2) to leave 23% of runs with a
  ## non-overlapping pair, because releasing N blocked readers spreads their wakeups
  ## over roughly the time a whole child run takes.
  for i in 0 ..< p.nChildren:
    var b: byte
    doAssert readFull(p.insideR, addr b, 1),
      "child " & $i & " never announced that it was inside the loop"
  discard close(p.insideR)
  p.insideR = -1
  nowNs()

proc releaseStop(p: var Phase) =
  ## Close the stop gate's write end: EOF releases every child that is waiting on
  ## it. Idempotent-ish — the caller calls it once.
  if p.stopW >= 0:
    discard close(p.stopW)
    p.stopW = -1

proc finishPhase(p: var Phase): seq[ChildReport] =
  ## DRAIN THE REPORT PIPE BEFORE REAPING. Reaping first is the classic pipe
  ## deadlock, and M2's harness hit it for real — the parent sat in `waitpid` while a
  ## child sat in `write`. Draining first removes the dependency on pipe capacity
  ## rather than staying just under whatever it happens to be.
  for i in 0 ..< p.nChildren:
    var rep: ChildReport
    doAssert readFull(p.reportR, addr rep, sizeof(rep)),
      "short read of child report " & $i
    result.add rep
  discard close(p.reportR)
  if p.stopW >= 0:
    discard close(p.stopW)
    p.stopW = -1
  if p.insideR >= 0:
    discard close(p.insideR)
    p.insideR = -1
  for k in 0 ..< p.pids.len:
    var st: cint
    doAssert waitpid(p.pids[k], st, 0) == p.pids[k]
    doAssert WIFEXITED(st) and WEXITSTATUS(st) == 0,
      "child " & $k & " did not exit cleanly (exited=" & $WIFEXITED(st) &
      " status=" & $WEXITSTATUS(st) & ")"
  discard munmap(p.region, p.regionSize)

proc fmtPm(pm: int): string =
  ## Per mille rendered as a percentage with one decimal, for the human reader.
  ## PER MILLE is the unit every phase B threshold is stated in, because the two
  ## quantities the tolerance sits between differ by a factor of ten and integer
  ## percent cannot express the lower one at all — it rounds a real 4-per-mille
  ## reading to "0%", which is exactly how a contaminated estimator hides in a log.
  ## A NEGATIVE value means an arm — which runs the baseline's loop PLUS an
  ## observation, i.e. strictly more work — measured FASTER than the baseline. That
  ## is a statement about the instrument, not about the transport, and phase B
  ## asserts against it rather than merely printing it.
  let a = abs(pm)
  (if pm < 0: "-" else: "") & $(a div 10) & "." & $(a mod 10) & "%"

# ===========================================================================

when not obsRingSupported:
  suite "M4 gate: portable no-op arm":
    test "the observation ring reports unavailable rather than failing to build":
      var r = createObsRing("unused", 8, 64)
      check not r.available

else:
 suite "M4 gate: the observation ring under real multi-process load":

  test "A. saturation: delivered + dropped == produced, and nothing is torn":
    let path = freshPath("sat")
    defer: cleanup(path)
    var ring = createObsRing(path, SatCapacity, RecLen)
    check ring.available
    ring.registerConsumer()

    # THE TORN-RECORD DETECTOR'S OWN CONTROL. "torn == 0" below is worth nothing
    # from a checker that cannot say no, so before using it: an intact record passes,
    # a record with ONE flipped byte fails, one truncated by a byte fails, and one
    # whose header says it belongs to a different producer fails.
    block:
      var good = mkRec(3, 77)
      check recIntact(good, RecLen)
      var bad = good
      bad[20] = bad[20] xor 0x01
      check not recIntact(bad, RecLen)
      check not recIntact(good, RecLen - 1)
      var relabelled = good
      relabelled[0] = relabelled[0] xor 0x01     # same bytes, different producer id
      check not recIntact(relabelled, RecLen)

    let producers = envInt("SHM_LEASE_OBS_PRODUCERS", DefaultProducers)
    let rounds = envInt("SHM_LEASE_OBS_ROUNDS", DefaultRounds)
    var roles: seq[ChildRole] = @[]
    for _ in 0 ..< producers: roles.add crProducer
    var ph = startPhase(ring, path, roles, rounds, 0)

    # GATE 2: every child is now provably inside its hammering loop, and none may
    # leave until `releaseStop`. Everything the parent does between here and that
    # call is CONCURRENT WITH ALL OF THEM by construction rather than by scheduling
    # luck — which is what makes "the producers appended faster than the consumer
    # drained" a statement about this run rather than a hope about it.
    let allRunningNs = ph.awaitAllInside()

    var buf: array[RecLen, byte]
    var n = 0
    var delivered = 0
    var torn = 0
    var lastSeq: seq[int64] = newSeq[int64](producers)
    for i in 0 ..< producers: lastSeq[i] = -1
    var perProducer: seq[int] = newSeq[int](producers)

    proc take(): bool =
      if ring.drainOne(buf, n) != odrGot: return false
      inc delivered
      if not recIntact(buf, n):
        inc torn
        return true
      let p = int(recProducer(buf))
      let s = int64(recSeq(buf))
      if p >= 0 and p < producers:
        # A ticket ring delivers one producer's records IN ORDER; a duplicate or a
        # reordering would mean a slot was read twice or a ticket was reused.
        if s <= lastSeq[p]: inc torn
        lastSeq[p] = s
        inc perProducer[p]
      else:
        inc torn
      true

    # THE THROTTLE. The consumer takes at most `ThrottledDrain` records while every
    # producer is provably still hammering. That cap is what turns "drops happened"
    # into arithmetic: with capacity C and D records taken out, at most C + D of the
    # N produced can have survived.
    let drainDeadline = nowNs() + 10_000_000_000'u64
    while delivered < ThrottledDrain and nowNs() < drainDeadline:
      discard take()                  # `false` just means the producers are behind
    let deliveredDuringRun = delivered

    # Release the stop gate and let every child finish its rounds.
    ph.releaseStop()
    let reps = finishPhase(ph)
    check reps.len == producers

    # Drain to empty, so `delivered + dropped == produced` can hold EXACTLY rather
    # than modulo whatever was still resident.
    while take(): discard
    check ring.pendingCount() == 0'u64

    var produced = 0'u64
    var childPublished = 0'u64
    var childDropped = 0'u64
    for r in reps:
      check r.ok == 1
      produced += r.rounds
      childPublished += r.published
      childDropped += r.dropped
      check r.rounds >= uint64(rounds)
      check r.rounds < uint64(rounds * 8)     # the hard cap was never the exit path

    # --- BASES ARE PAIRWISE DISTINCT, BY CONSTRUCTION ----------------------
    for i in 0 ..< reps.len:
      check reps[i].base != cast[uint64](ring.mappedBase())
      for j in i + 1 ..< reps.len:
        check reps[i].base != reps[j].base

    # --- OVERLAP FIRST, so a regression names the CAUSE --------------------
    # If the children ran serially, "drops happened" would still be true and the
    # identity would still hold, and the gate would be measuring nothing. These are
    # asserted BEFORE the drop assertions for exactly that reason. The witness is
    # the stronger of the two forms: the instant the parent held every "I am inside
    # the loop" announcement lies inside EVERY child's [start, end] interval, and
    # `CLOCK_MONOTONIC` is cross-process comparable on one host (M2 confirmed that
    # empirically with an injected stagger rather than assuming it).
    var overlapLo = reps[0].startNs
    var overlapHi = reps[0].endNs
    for r in reps:
      check r.startNs <= allRunningNs
      check r.endNs >= allRunningNs
      overlapLo = max(overlapLo, r.startNs)
      overlapHi = min(overlapHi, r.endNs)
    check overlapHi > overlapLo
    for i in 0 ..< reps.len:
      for j in i + 1 ..< reps.len:
        check reps[j].startNs < reps[i].endNs
        check reps[i].startNs < reps[j].endNs

    # --- OS-2: THE IDENTITY ------------------------------------------------
    check childPublished + childDropped == produced
    check ring.acceptedCount() == childPublished
    check ring.droppedCount() == childDropped
    check uint64(delivered) + ring.droppedCount() == produced   # <-- the gate's identity

    # --- DROPS ARE STRUCTURAL, NOT INCIDENTAL ------------------------------
    # Derived, not hoped for: at most `capacity` records can be resident and at most
    # `delivered` have been taken out, so everything else MUST have been dropped.
    let lowerBound = int64(produced) - int64(SatCapacity) - int64(delivered)
    check int64(ring.droppedCount()) >= lowerBound
    check ring.droppedCount() > 0'u64
    check ring.windowCompleteness(0) == ccTruncated   # <-- and it SAYS it lost some

    # --- NO TORN RECORDS ---------------------------------------------------
    check torn == 0
    check delivered > 0
    for p in 0 ..< producers:
      check perProducer[p] > 0        # every producer's records reached the consumer

    echo "  [A] ", producers, " producers x ", rounds, " rounds at distinct bases: ",
      "produced=", produced, " accepted=", ring.acceptedCount(),
      " dropped=", ring.droppedCount(), " delivered=", delivered,
      " (", deliveredDuringRun, " while they ran)  torn=", torn,
      "  identity delivered+dropped==produced: ",
      uint64(delivered) + ring.droppedCount() == produced,
      "  drop lower bound=", lowerBound,
      "  all-children overlap window=", (overlapHi - overlapLo) div 1000, "us"
    ring.detach()

  test "B. OS-1: observing does not perturb the process being observed":
    let openPath = freshPath("perturb-shared")
    let fullPath = freshPath("perturb-full")
    defer: cleanup(openPath)
    defer: cleanup(fullPath)
    var openRing = createObsRing(openPath, PerturbCapacity, RecLen)
    var fullRing = createObsRing(fullPath, 8, RecLen)
    check openRing.available
    check fullRing.available
    gSecondPath = fullPath
    # A PER-CHILD ring as well as the shared one. The two are different questions
    # and conflating them is what made the first version of this phase bimodal: the
    # per-child ring measures what an observation COSTS, while the shared ring also
    # measures what N processes contending on ONE ticket-CAS cache line costs. Both
    # are reported; only the first is asserted, and the phase says why.
    gOwnPaths = @[]
    var ownRings: seq[ObsRing] = @[]
    for i in 0 ..< 3:
      let p = freshPath("perturb-own" & $i)
      gOwnPaths.add p
      var orr = createObsRing(p, PerturbCapacity, RecLen)
      check orr.available
      ownRings.add orr
    defer:
      for i in 0 ..< ownRings.len:
        ownRings[i].detach()
        cleanup(gOwnPaths[i])
    # SATURATE the second ring before forking, so every append in that arm takes the
    # DROP path. "A full ring must not slow the producer down" is the half of OS-1
    # that a happy-path benchmark never measures.
    for i in 0'u32 ..< 64'u32:
      discard fullRing.publish(mkRec(99, i))
    check fullRing.droppedCount() > 0'u64

    let rounds = envInt("SHM_LEASE_OBS_PERTURB_ROUNDS", PerturbRounds)
    gPerturbReps = envInt("SHM_LEASE_OBS_PERTURB_REPS", PerturbReps)
    var roles: seq[ChildRole] = @[crPerturb, crPerturb, crPerturb]
    # THE MEASURED RINGS MUST NEVER FILL, and that is checked rather than left to
    # arithmetic in a comment. A ring that filled part way through an arm would put
    # the rest of that arm on the much cheaper DROP path and flatter the result —
    # and the knobs above are swept by whoever verifies this milestone, so the
    # invariant has to survive a sweep. Checked here for the shared ring (all three
    # children append to it) and re-checked from the counters afterwards.
    check gPerturbReps * rounds * roles.len <= PerturbCapacity

    var ph = startPhase(openRing, openPath, roles, rounds, 0)
    ph.releaseStop()
    let reps = finishPhase(ph)
    check reps.len == roles.len

    proc armPermille(r: ChildReport; a: PerturbArm): int =
      ## The child already did the pairing; the parent only rescales parts-per-100000
      ## to the per mille the thresholds are stated in, rounding away from zero so a
      ## small negative stays visibly negative.
      let v = r.armPp100k[a]
      int((if v < 0: v - 50 else: v + 50) div 100)

    var armPm: array[PerturbArm, seq[int]]
    var shCostNs: seq[int] = @[]
    var totalAppends = 0'u64
    for r in reps:
      check r.ok == 1
      check r.workAcc != 0'u64             # the workload was not optimised away
      check r.ctlNs > 0'u64
      totalAppends += r.published
      for a in PerturbArm:
        armPm[a].add armPermille(r, a)
      shCostNs.add int(r.armPp100k[paShared] * int64(r.ctlNs) div 100_000 div int64(r.rounds))
      echo "  [B] child ", r.childId, " base=0x", toHex(r.base),
        "  ctl=", r.ctlNs div 1000, "us cpu (median of ", gPerturbReps, " reps)",
        "  FLOOR(ctl vs ctl)=", fmtPm(armPermille(r, paNull)),
        "  ring(own)=", fmtPm(armPermille(r, paOwn)),
        "  ring(FULL/dropping)=", fmtPm(armPermille(r, paFull)),
        "  ring(SHARED by all 3)=", fmtPm(armPermille(r, paShared)),
        "  one-way write=", fmtPm(armPermille(r, paWrite)),
        "  socket round trip=", fmtPm(armPermille(r, paRtrip))
    for a in PerturbArm: sort(armPm[a])
    sort(shCostNs)
    proc med(xs: seq[int]): int = xs[xs.len div 2]
    let medNull = med(armPm[paNull])
    let medOwn = med(armPm[paOwn])
    let medFull = med(armPm[paFull])
    let medShared = med(armPm[paShared])
    let medWrite = med(armPm[paWrite])
    let medRtrip = med(armPm[paRtrip])
    # The floor is the WORST reading of the null arm, in either direction: the
    # instrument gets no credit for a lucky child.
    var worstFloor = 0
    for pm in armPm[paNull]: worstFloor = max(worstFloor, abs(pm))

    # --- THE MEASURED RINGS TOOK THE APPEND PATH, NOT THE DROP PATH ---------
    # `openRing` is the shared arm and the `own` rings are the asserted arm; if
    # either had filled, the arm would have measured a cheap counted drop instead of
    # an append and the result would be flattering and wrong.
    check openRing.droppedCount() == 0'u64
    check openRing.acceptedCount() == totalAppends
    for i in 0 ..< ownRings.len:
      check ownRings[i].droppedCount() == 0'u64
      check ownRings[i].acceptedCount() == reps[0].published

    # --- THE INSTRUMENT CHECKS ITSELF FIRST ---------------------------------
    # These come BEFORE the OS-1 assertions on purpose, so a run on a machine that
    # drifted under the measurement names the CAUSE (the estimator is contaminated)
    # rather than only the symptom (some arm read an implausible number). This is
    # the ordering phase A already uses for its overlap assertions.
    #
    # (1) THE CONTROL AGREES WITH ITSELF. `paNull` is the baseline loop run a second
    # time, with nothing added, through the IDENTICAL paired-median estimator.
    # Whatever it reports is what this instrument can resolve on this machine on this
    # run — the NOISE FLOOR, measured rather than assumed. If it is large, the
    # machine moved under the measurement and no arm's figure means anything, however
    # good it looks, so this must fail before any arm is judged.
    check worstFloor <= NoiseFloorLimitPermille
    # (2) NOTHING MAY MEASURE MEANINGFULLY FASTER THAN THE CONTROL. Every arm is
    # structurally the control's loop plus an observation, so every arm does strictly
    # more work and cannot honestly be faster. Readings inside the resolution the
    # phase demands of itself — the same `NoiseFloorLimitPermille` asserted just
    # above, and demonstrated just above by `paNull` — are unresolvable and allowed;
    # anything below that is proof the estimator is measuring something other than
    # the code. The wall-clock version of this phase produced 9 negative readings in
    # 30 loaded samples and PASSED EVERY ONE OF THEM SILENTLY, because
    # `medOwn < limit` is satisfied by any negative number. A result that cannot
    # physically happen must fail loudly.
    for a in PerturbArm:
      check armPm[a][0] >= -NoiseFloorLimitPermille

    # --- OS-1 --------------------------------------------------------------
    # Both asserted arms are PER-PROCESS, and so are both control arms, so the
    # comparison is like for like: one process's observation against one process's
    # IPC call. The `full` arm is the one the gate's wording is really about — under
    # saturation, when every append is a counted drop, the producer must not slow
    # down at all.
    #
    # BOUNDED AND SMALL, not "indistinguishable". The ring's cost IS distinguishable
    # from zero — `worstFloor` is exactly what establishes that — and pretending
    # otherwise is what invited a tolerance sitting 20x above the floor.
    check medOwn < PerturbLimitPermille
    check medFull < PerturbLimitPermille  # the DROP path is just as cheap
    # --- and the controls that give the tolerance teeth ---------------------
    # BOTH IPC arms must EXCEED the same tolerance the ring arms stay inside.
    # Without them, `medOwn < limit` could be passing because the limit is
    # unfalsifiable rather than because appending is cheap. Both are LOWER BOUNDS on
    # the socket transport this ring replaces: the first is a bare one-way send with
    # no peer at all, the second the round trip the spec explicitly forbids, with
    # the daemon's own work and scheduling excluded.
    check medWrite > PerturbLimitPermille
    check medRtrip > PerturbLimitPermille
    check medRtrip > medOwn * 4
    # ...and the tolerance stays ANCHORED TO THE MEASURED FLOOR from below: a
    # threshold that creeps down towards what the instrument can resolve stops
    # measuring the transport and starts measuring the machine, which is the failure
    # this whole revision exists to remove. The anchor from ABOVE is not a constant
    # at all — it is the two IPC control arms immediately above, which a tolerance
    # loose enough to be unfalsifiable would no longer be exceeded by.
    check PerturbLimitPermille >= max(worstFloor, 1) * 3
    echo "  [B] NOISE FLOOR measured BY THIS RUN (paNull: the control loop through ",
      "the identical estimator, worst of ", armPm[paNull].len, " children): ",
      fmtPm(worstFloor), " (median ", fmtPm(medNull), ") -- nothing finer than ",
      "this is resolvable, and the tolerance is anchored to it"
    echo "  [B] median CPU overhead vs a no-observation control: ring(own) ",
      fmtPm(medOwn), ", ring(full/dropping) ", fmtPm(medFull),
      ", one-way write per observation ", fmtPm(medWrite),
      ", socket round trip per observation ", fmtPm(medRtrip),
      "  (tolerance ", fmtPm(PerturbLimitPermille), "; the ring arms must stay " &
      "UNDER it and both IPC arms must EXCEED it)"

    # --- REPORTED, NOT ASSERTED: the shared-ring contention cost ------------
    # Three processes appending to ONE ring contend on the ticket-CAS cache line, and
    # the per-observation cost rises by an order of magnitude. This is a REAL property
    # of the substrate, it is measured here rather than hidden, and it is deliberately
    # NOT the basis of an assertion: the figure depends on how closely the children's
    # arms happen to align, which made an earlier version of this phase bimodal (2% in
    # one run, 26% in the next). A load-bearing assertion must not rest on that. The
    # rate that produces it is also far beyond anything an execution stream can
    # generate — one observation per EXECUTION, not per microsecond — so it bounds the
    # substrate, not the design. See the milestone record; reducing it is what M5's
    # flat combining is for.
    echo "  [B] REPORTED (not asserted): the SAME ring shared by all 3 producers ",
      "costs ", fmtPm(medShared), " -- i.e. ~", shCostNs[shCostNs.len div 2],
      " ns per observation against ~",
      int(reps[0].armPp100k[paOwn] * int64(reps[0].ctlNs) div 100_000 div
        int64(reps[0].rounds)),
      " ns on a per-process ring. Cross-process CAS contention on one cache line, ",
      "at an append rate no execution stream can reach."
    fullRing.detach()
    openRing.detach()

  test "C. SM-1: a quiet ring costs ZERO consumer wakeups and no CPU":
    let path = freshPath("idle")
    defer: cleanup(path)
    var ring = createObsRing(path, 64, RecLen)
    check ring.available
    let secs = envInt("SHM_LEASE_OBS_IDLE_SECONDS", DefaultIdleSeconds)
    let windowNs = int64(secs) * 1_000_000_000'i64

    var ph = startPhase(ring, path, [crBlockConsumer, crPollConsumer], 0, windowNs)
    ph.releaseStop()

    # Wait for the consumer to be genuinely parked. Its IDLE TOKEN, observed from the
    # PARENT's mapping, is the cross-process fact the signalling rule is built on.
    var parked = false
    for _ in 0 ..< 10_000:
      if ring.consumerIdle(): parked = true; break
      sleep(1)
    check parked

    let t0 = nowNs()
    sleep(secs * 1000)          # THE QUIET WINDOW: nothing is published
    let heldNs = nowNs() - t0
    # End the window for both children with one record.
    check ring.publish(mkRec(1, 1)) == oprPublished

    let reps = finishPhase(ph)
    check reps.len == 2
    var blocked, polled: ChildReport
    for r in reps:
      if r.role == uint32(ord(crBlockConsumer)): blocked = r else: polled = r
    check blocked.ok == 1
    check polled.ok == 1
    check blocked.base != polled.base
    check blocked.base != cast[uint64](ring.mappedBase())

    # Both really did cover the window...
    check blocked.wallNs >= uint64(heldNs) * 9 div 10
    check polled.wallNs >= uint64(heldNs) * 9 div 10
    check blocked.waitRc == uint32(ord(owrReady))
    # ...and the blocked one came back PROMPTLY once the record was published, rather
    # than sitting out its own (much longer) timeout. Without this upper bound, a
    # consumer that is never signalled at all still satisfies every assertion below
    # — it burns no CPU precisely because nothing ever wakes it — and "zero wakeups"
    # would be passing for the wrong reason.
    check blocked.wallNs < uint64(heldNs) + 2_000_000_000'u64

    # --- THE IDLE GATE: ZERO wakeups ---------------------------------------
    # `parks` counts KERNEL ENTRIES. Exactly one means the consumer slept once and
    # returned once — on the record that ended the window. Anything above one is a
    # wakeup during the quiet window, which is what this gate forbids.
    check blocked.parks == 1'u64
    # --- SM-1, consumer side -----------------------------------------------
    check blocked.cpuNs < IdleCpuLimitNs
    check blocked.cpuNs * 100 < uint64(heldNs)     # under 1% of the window
    # --- and the control that gives both limits teeth -----------------------
    check polled.parks > 100'u64                   # it really polled
    check polled.cpuNs > blocked.cpuNs             # and it really cost more
    if syscallCountAvailable():
      # The number that matters: an idle blocking consumer enters the kernel a
      # handful of times over MULTIPLE SECONDS, while a 1 ms poller enters it
      # thousands of times to discover nothing each time.
      check blocked.syscalls <= 8'u64
      check polled.syscalls > 500'u64
      check polled.syscalls > blocked.syscalls * 50
    echo "  [C] quiet window ", heldNs div 1_000_000, "ms: BLOCKING consumer ",
      blocked.parks, " kernel entr(y/ies), ", blocked.syscalls, " syscalls, ",
      blocked.cpuNs div 1000, "us CPU  |  POLLING control ", polled.parks,
      " polls, ", polled.syscalls, " syscalls, ", polled.cpuNs div 1_000_000,
      "ms CPU  (limit ", IdleCpuLimitNs div 1_000_000, "ms)"
    ring.detach()

  test "D. SM-2: a sustained non-empty ring is signalled exactly ONCE":
    let path = freshPath("signal")
    let ctlPath = freshPath("signal-ctl")
    defer: cleanup(path)
    defer: cleanup(ctlPath)
    var ring = createObsRing(path, SignalCapacity, RecLen)
    var ctl = createObsRing(ctlPath, SignalCapacity, RecLen)
    check ring.available
    check ctl.available

    var ph = startPhase(ring, path, [crSignalConsumer], 0, 5_000_000_000'i64)
    var parked = false
    for _ in 0 ..< 10_000:
      if ring.consumerIdle(): parked = true; break
      sleep(1)
    check parked

    if not syscallCountAvailable():
      echo "  [D] SKIPPED: no in-process kernel syscall counter on this platform. " &
        "SM-2 must be measured externally here — run `just test-syscalls`."
      check true
      for _ in 0 ..< SignalBurst: discard ring.publish(mkRec(1, 1))
      ph.releaseStop()
      discard finishPhase(ph)
    else:
      # THE BURST. Nobody drains, so the ring is non-empty from the first append to
      # the last: there is exactly ONE empty-to-non-empty transition in it.
      let a0 = unixSyscallCount()
      for i in 0'u32 ..< uint32(SignalBurst):
        discard ring.publish(mkRec(1, i))
      let realDelta = unixSyscallCount() - a0

      # THE CONTROL: the naive implementation that signals on every append. Same
      # burst, same ring geometry, no consumer needed — an unconditional wake is a
      # syscall whether or not anybody is listening, which is precisely why the
      # transport spec calls it out.
      let b0 = unixSyscallCount()
      for i in 0'u32 ..< uint32(SignalBurst):
        discard ctl.publishForcedSignal(mkRec(1, i))
      let ctlDelta = unixSyscallCount() - b0

      ph.releaseStop()
      let reps = finishPhase(ph)
      check reps.len == 1
      let r = reps[0]
      check r.ok == 1
      check r.base != cast[uint64](ring.mappedBase())
      check r.waitRc == uint32(ord(owrReady))     # it was woken, cross-process
      check r.parks == 1'u64                      # exactly one kernel entry

      check ring.signalCount() == 1'u64           # <-- one transition, one signal
      check realDelta == 1'u64                    # <-- and exactly one syscall
      check ctl.signalCount() == uint64(SignalBurst)
      check ctlDelta >= uint64(SignalBurst)       # <-- the control moves the counter
      echo "  [D] ", SignalBurst, " appends into a sustained non-empty ring with a ",
        "parked consumer at base 0x", toHex(r.base), ": ", realDelta,
        " wake syscall(s), ", ring.signalCount(), " signal(s); the signal-always ",
        "control: ", ctlDelta, " syscalls, ", ctl.signalCount(), " signals"
    ctl.detach()
    ring.detach()

  test "E. the ring is usable with NO daemon attached, at another base":
    let path = freshPath("nodaemon")
    defer: cleanup(path)
    var ring = createObsRing(path, NoDaemonCapacity, RecLen)
    check ring.available
    # Nobody registers, nobody drains — the standalone case a client must survive.
    check ring.consumerVerdict() == avNoOwner

    var ph = startPhase(ring, path, [crNoDaemon], NoDaemonRounds, 0)
    ph.releaseStop()
    let reps = finishPhase(ph)
    check reps.len == 1
    let r = reps[0]
    check r.ok == 1                     # never `oprUnavailable`, never an error
    check r.base != cast[uint64](ring.mappedBase())
    check r.rounds == uint64(NoDaemonRounds)
    check r.published + r.dropped == uint64(NoDaemonRounds)
    check r.published == uint64(NoDaemonCapacity)
    check r.dropped == uint64(NoDaemonRounds - NoDaemonCapacity)
    check ring.droppedCount() == r.dropped
    check ring.windowCompleteness(0) == ccTruncated
    # NEVER BLOCKED: a block-on-full ring with no consumer would have hung the child
    # forever, and the phase would never have completed at all.
    check r.wallNs < 5_000_000_000'u64
    echo "  [E] no daemon, child at base 0x", toHex(r.base), ": ", r.rounds,
      " appends -> ", r.published, " published, ", r.dropped,
      " counted drops, in ", r.wallNs div 1000, "us; completeness=",
      ring.windowCompleteness(0)
    ring.detach()
