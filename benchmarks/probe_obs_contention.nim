## THE SHARED-RING CONTENTION PROBE: what N processes appending to ONE ring cost
## each other on the ticket-CAS cache line.
##
## Why this exists as a committed file rather than as a number in a record. M4's
## gate REPORTS the shared-ring cost and deliberately does NOT assert on it (the
## figure is bimodal on how closely the children's measured arms happen to align,
## and a load-bearing assertion must not rest on that). The milestone record
## nonetheless quoted a 1/3/6-producer figure taken from a standalone probe that was
## never committed — i.e. a number nobody could regenerate. This file is that probe,
## kept, so the figure is reproducible instead of remembered.
##
## WHAT IT MEASURES. For each producer count, N real processes append a fixed number
## of records to ONE shared ring as fast as they can, with NOTHING between appends
## and nobody draining. The ring is sized so it can hold every record, so no arm
## silently switches to the cheap counted-drop path — that is checked, not assumed.
## The reported figure is nanoseconds per append as seen BY A PRODUCER.
##
## WHAT IT DOES NOT MEASURE, and this is the point of the number rather than a
## caveat: no execution stream can generate appends at this rate. RunQuota's
## observation is one record per EXECUTION, not one per microsecond. So this bounds
## THE SUBSTRATE under a load the design does not produce, and reducing it is what
## M5's flat combining is for. It is not a cost anyone pays today.
##
## HOW THE PROCESSES ARE MADE SIMULTANEOUS. Children are forked, then block on a
## barrier pipe; the parent releases every one of them with a single `close`. Without
## that, N children started in a loop are partly serial and the contention being
## measured is diluted by however long the fork loop took.
##
## THE MAPPING IS PREFAULTED BEFORE THE FORK, so the children inherit page-table
## entries for a segment that is already resident and the timed loop is not
## measuring first-touch paging over tens of megabytes (~40 ns per append of pure
## fault cost, which was one of the three harness defects M4's phase B had to fix).
##
## READ THE VARIANCE BEFORE QUOTING ANYTHING. Like every other benchmark in this
## repo the figures move run to run on a loaded host, and the contended ones move
## MORE than the uncontended ones because they depend on how the scheduler places
## the producers across P and E cores. Quote a range over several runs, never a
## point value.
##
##   SHM_LEASE_OBS_CONTENTION_ITERS   appends per producer   (default 50000)
##   SHM_LEASE_OBS_CONTENTION_REPS    repetitions per config (default 3)

import std/[os, posix, strutils]
import shm_lease/[obsring, waitword]

const
  RecLen = 48
  ProducerCounts = [1, 3, 6]

proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}

type
  ChildReport = object
    elapsedNs: uint64
    published: uint64
    dropped: uint64

proc nowNs(): uint64 =
  var ts: Timespec
  discard clock_gettime(CLOCK_MONOTONIC, ts)
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

proc fmt2(x: float): string = formatFloat(x, ffDecimal, 2)

when not obsRingSupported:
  echo "obsring unavailable on this platform (portable no-op arm) — nothing to measure"
else:
  let iters = envInt("SHM_LEASE_OBS_CONTENTION_ITERS", 50_000)
  let reps = envInt("SHM_LEASE_OBS_CONTENTION_REPS", 3)
  var rec: array[RecLen, byte]
  for i in 0 ..< RecLen: rec[i] = byte(i)

  proc runOne(producers, iters: int): seq[float] =
    ## One repetition at one producer count. Returns each producer's own
    ## nanoseconds-per-append; the caller summarises. Returns an empty seq if the
    ## run could not be set up or a producer dropped, so a broken run reports
    ## nothing rather than a plausible wrong number.
    let path = getTempDir() /
      ("shmlease-obscontention-" & $getpid() & "-" & $producers & ".seg")
    # Capacity holds EVERY record every producer will publish, so no arm can fall
    # onto the counted-drop path (4 ns) and flatter the result. `droppedCount` is
    # checked below as well: sized-not-to-drop is a claim, not a guarantee. The ring
    # masks tickets, so the capacity must be a POWER OF TWO — rounded up, never down.
    var capacity = 1
    while capacity < producers * iters: capacity = capacity * 2
    if capacity > MaxObsCapacity:
      echo "  (", producers, " x ", iters, " records exceeds the ", MaxObsCapacity,
        "-slot maximum — lower SHM_LEASE_OBS_CONTENTION_ITERS; skipped)"
      return @[]
    var ring = createObsRing(path, capacity, RecLen)
    if not ring.available:
      echo "  (could not create a ", capacity, "-slot ring — skipped)"
      return @[]
    defer:
      ring.detach()
      try: removeFile(path)
      except CatchableError: discard

    # PREFAULT before the fork: the children inherit these page-table entries.
    block:
      let ps = pageSize()
      var off = 0
      while off < ring.size:
        ring.base[off] = ring.base[off]
        off += ps

    var barrier, results: array[0..1, cint]
    if pipe(barrier) != 0: return @[]
    if pipe(results) != 0:
      discard close(barrier[0]); discard close(barrier[1]); return @[]

    var pids = newSeq[Pid](producers)
    for k in 0 ..< producers:
      let pid = fork()
      if pid == 0:
        discard close(barrier[1])
        discard close(results[0])
        # Block until the parent releases everyone at once: `read` returns 0 (EOF)
        # when the last write end closes.
        var b: byte
        discard read(barrier[0], addr b, 1)
        var rep = ChildReport()
        let t0 = nowNs()
        for _ in 0 ..< iters:
          case ring.publish(rec)
          of oprPublished: inc rep.published
          of oprDropped: inc rep.dropped
          else: discard
        rep.elapsedNs = nowNs() - t0
        discard writeFull(results[1], addr rep, sizeof(rep))
        cExit(0)
      pids[k] = pid

    discard close(barrier[1])          # RELEASE: every child leaves `read` here.
    discard close(results[1])
    var perProducer: seq[float] = @[]
    var bad = false
    for _ in 0 ..< producers:
      var rep: ChildReport
      if not readFull(results[0], addr rep, sizeof(rep)):
        bad = true; break
      if rep.dropped != 0 or rep.published != uint64(iters): bad = true
      perProducer.add(float(rep.elapsedNs) / float(iters))
    discard close(results[0])
    discard close(barrier[0])
    for pid in pids:
      var st: cint
      discard waitpid(pid, st, 0)
    if bad or ring.droppedCount() != 0: return @[]
    perProducer

  echo "probe_obs_contention: ", iters, " appends per producer, ", reps,
    " repetitions per configuration, one SHARED ring, nobody draining"
  # A probe that measured NOTHING must not exit 0. Rejecting a contaminated run
  # is the right behaviour, but `just bench` reads the exit code, so a silent
  # refusal would go green while reporting no number at all — the same false-green
  # shape as a `tee` pipeline without `pipefail`, which this repo already had once.
  var anyConfigUnusable = false
  for producers in ProducerCounts:
    # DISCARDED WARM-UP REPETITION, the same convention M4's phase B uses: a child
    # that has just come off a blocking read pays the frequency ramp, a cold i-cache
    # and a cold branch predictor on its first timed loop. That is a real cost of
    # starting a process and it is not the cost of an append — measured at 115
    # ns/append against 28 for the very first single-producer repetition.
    discard runOne(producers, iters)
    var perRepMean: seq[float] = @[]
    var lo = 0.0
    var hi = 0.0
    for r in 0 ..< reps:
      let samples = runOne(producers, iters)
      if samples.len == 0:
        echo "  producers=", producers, "  rep ", r, ": RUN REJECTED (setup failed, ",
          "or a producer dropped — the ring must never fill in this probe)"
        continue
      var sum = 0.0
      for s in samples:
        sum += s
        if lo == 0.0 or s < lo: lo = s
        if s > hi: hi = s
      perRepMean.add(sum / float(samples.len))
    if perRepMean.len == 0:
      echo "  producers=", producers, ": no usable repetition"
      anyConfigUnusable = true
      continue
    var best = perRepMean[0]
    var worst = perRepMean[0]
    for m in perRepMean:
      if m < best: best = m
      if m > worst: worst = m
    echo "  producers=", producers, "  ", fmt2(best), "-", fmt2(worst),
      " ns/append (mean per producer, range over ", perRepMean.len,
      " repetitions; individual producers ", fmt2(lo), "-", fmt2(hi), ")"

  if anyConfigUnusable:
    echo "probe_obs_contention: FAILED — at least one configuration produced no ",
      "usable repetition, so this probe measured nothing"
    quit(1)
