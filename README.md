# nim-shm-lease

A shared-memory, lock-free, file-backed **multi-dimensional reservation** for Nim:
CPU slots, coarse memory units, process count and IO weight packed into **one
64-bit word**, claimed and released with a single CAS.

Sibling to [`nim-shm-queue`](../nim-shm-queue) (MPSC ring) and
[`nim-shm-gset`](../nim-shm-gset) (grow-only set) — and, since M4, a **consumer** of
`nim-shm-queue`: the observation ring rides its Layer 1 rather than growing a second
copy of the same MPSC protocol, so the sibling checkout must be present to build
`shm_lease/obsring` (`config.nims`, the `Justfile` and the nimble task each thread
`--path:../nim-shm-queue/src` when the directory exists). This is the POC library of the
*RunQuota Observation Store & Shared-Memory Transport* campaign —
`reprobuild-specs/RunQuota-Observation-Store.milestones.org`, phase 1 — and its
design authority is
`reprobuild-specs/RunQuota-Shared-Memory-Transport.md`.

## Status: M2 + M3 + M4

M2 is the spec's *"§1 the fit check and claim are the easy part"*; M3 is
*"Waiting Without Spinning"*; M4 is *"The Observation Ring"*. Nothing beyond those
three. Read the scope honestly before building on it:

| Campaign milestone | What it adds | Here? |
|---|---|---|
| **M2** | packed-budget multi-dimensional reservation, no overcommit, position independence | **yes** |
| **M3** | futex-class cross-process blocking (`futex` / `os_sync_wait_on_address`), per-waiter wait slots | **yes** |
| **M4** | observation ring: bounded MPSC, counted drops, non-polling consumer (rides `nim-shm-queue`'s Layer 1) | **yes** |
| M5 | flat-combining arbiter, per-waiter grant slots, grant-then-wake | no |
| M6 | anti-starvation (bounded wait for large claims) | no |
| M7 | kill injection, steal protocol, reservation reclamation | no |
| M8 | preemption study and go/no-go verdict | no |

The single most important thing this library is **not**: an admission *policy*.
The design spec's §2 is explicit that a pure CAS loop admits whoever arrives first
and happens to fit, which **starves large claims** — a link action needing 8 GiB
can lose indefinitely to a stream of 512 MiB compiles, and RunQuota exists
precisely to keep memory-heavy actions schedulable. That is SM-4, it is M6's gate,
and it is not solved here. What is here is the correct, overcommit-free substrate a
policy is built on.

## The packed budget word

Four 16-bit fields, little end first:

| bits | dimension | ceiling |
|---|---|---|
| 0–15 | CPU slots | 65535 slots |
| 16–31 | memory, in 64 MiB units | 65535 × 64 MiB = 4095 GiB (~4 TiB) |
| 32–47 | process count | 65535 processes |
| 48–63 | IO weight | 65535 weight units |

4 × 16 = 64 exactly. Every ceiling is orders of magnitude past any real build host,
so **64-bit CAS is sufficient and no 128-bit CAS (`cmpxchg16b` / `CASP`) is used**
— the spec permits one but conditions it on the packing being "genuinely too
tight", and it is not. The triggers to revisit are a fifth dimension or a memory
ceiling above 4 TiB, at which point the cheaper fix is a 256 MiB unit (16 TiB in
the same 16 bits) before reaching for a wider CAS.

Coarsening memory to whole units is what buys that headroom; `memUnitsForBytes`
rounds **up**, because rounding down would under-reserve and under-reserving memory
is the OOM the component exists to prevent.

**Borrow safety is why the fit test is not optional.** A packed subtraction is
field-wise only while every field difference is non-negative; one underflowing
field borrows from the field above and corrupts a *different* dimension. So the
claim is: read → `fitsPacked` per dimension → CAS the decremented value → retry.
`tests/test_shm_lease.nim` demonstrates the corruption directly, and
`tests/test_shm_lease_multiprocess.nim` runs the whole multi-process gate with the
fit test removed and asserts the invariant checker catches it.

## Multi-word budgets and the fixed claim order

Per-machine and per-pool budgets get their own words:

* word `0` (`MachineBudgetIndex`) — the per-machine budget;
* word `1 + p` (`poolBudgetIndex(p)`) — pool `p`'s budget.

**Claim order is ascending word index; rollback and release are descending.** Since
every claimant takes words in strictly ascending index order, the waits-for relation
is a strict order and no cycle is constructible. This is *enforced*, not documented:
`claimWords` returns `csOutOfOrder` for a non-ascending index list rather than
sorting it, because silently reordering would hide a caller that had built an order
this library cannot see. A claim is all-or-nothing — a refusal on a later word rolls
the earlier words back exactly, leaving no trace in the accounting.

## Engineering playbook (inherited)

Per the design spec's *"The engineering playbook does transfer"*:

- **File-backed `mmap(MAP_SHARED)`** — the segment survives producer death and `exec`.
- **Position independence (SM-7)** — only offsets, counts, and packed *values* live
  in the segment; never an absolute pointer. `attachLeaseSegment(path, wantBase)`
  maps at a caller-chosen base (`MAP_FIXED`) so this is provable rather than
  asserted; `storedPointerCheck` is a second, heuristic line of defence.
- **Publish-before-write** — a segment is fully written, its magic release-stored
  last, and only then `rename`d into its final name. The final name never names a
  half-initialised segment.
- **Anchoring: boot id + owner pid + owner process START TIME.** Start time is what
  defeats pid reuse. Reclamation is M7, but the fields and the predicate that
  consults them (`anchorVerdict` → `avPidReused`) are here from M2, because the spec
  says this discipline cannot be retrofitted.
- **Deterministic schedule hooks** — `-d:shmLeaseScheduleHooks`, mirroring
  `-d:shmGSetScheduleHooks`, at *every* budget CAS, release CAS, rollback CAS,
  anchor publish, magic publish and rename site. Compile-time no-op otherwise.
- **Portable no-op arm** — compiles everywhere; `shmLeaseSupported == false` off
  Linux/macOS, where every operation reports unavailable.

## Capability record

### The reservation (M2)

| Platform | Status | Note |
|---|---|---|
| Linux (x86-64, aarch64) | supported | `boot_id` from `/proc/sys/kernel/random/boot_id`; process start time is field 22 of `/proc/<pid>/stat` |
| macOS 11+ (arm64, x86-64) | supported | process start time via `sysctl(KERN_PROC/KERN_PROC_PID)` → `kp_proc.p_starttime`; boot identity derived from pid 1's start time |
| Windows | **not supported** — no-op arm | Deliberate, and inherited from the campaign: the shared-memory transport's Windows *wake* path needs named kernel objects because `WaitOnAddress` is documented as within-process only. The M2 reservation itself would port, but shipping it without M3's wake path would be a half-capability, so Windows reports unavailable and the gap is recorded here rather than silently omitted. |

### The blocking wrapper (M3)

| Platform | Primitive | Minimum version | Cross-process | Note |
|---|---|---|---|---|
| Linux (x86-64, aarch64) | `futex(FUTEX_WAIT / FUTEX_WAKE)` **without** `FUTEX_PRIVATE_FLAG` | any | ✓ | A shared futex keys on the underlying **inode + offset**, not the virtual address, which is what lets a file-backed segment mapped at a different base in every process still block correctly. **UNEXERCISED: never run on Linux.** |
| macOS (arm64, x86-64) | `os_sync_wait_on_address` / `os_sync_wake_by_address_any` / `..._all` with `OS_SYNC_*_SHARED` | **14.4** | ✓ | The symbols are **weak-imported and NULL-checked at run time**, so a binary built against a 14.4 SDK still launches on an older macOS and `waitWordAvailable()` simply returns false there. The minimum version is recorded in `WaitWordMinMacOsVersion` and asserted by the suite. |
| Windows | — | — | **✗** | **OUT OF SCOPE, recorded not omitted.** `WaitOnAddress` is documented as working only within a process; a cross-process wake needs named kernel objects (a per-waiter named event or semaphore). Note the asymmetry for whoever takes it up: the *fast path* (no wait) still costs zero syscalls on Windows, and only the **wake** needs the named object. |

`waitWordAvailable()` is the runtime gate and `WaitWordBackend` names the primitive
actually selected, so a caller can report what it got rather than assume.

**On macOS, a wait word must be on a page this process has already touched.**
`os_sync_wait_on_address` returns `EFAULT` for an address whose page has not yet
been faulted in — even though the mapping is valid and an ordinary load from it
succeeds. That is exactly the state a forked child is in after a fresh `MAP_FIXED`
of the segment, so a park issued before any access fails instantly instead of
blocking, which reads as "the primitive does not work". `waitOn` therefore
prefaults, and `tests/test_shm_lease_waitword.nim` exhibits both halves on two
separate fresh mappings — one untouched (`EFAULT`), one whose only access is the
prefault (blocks and times out cleanly). Reproduced on Darwin 25.5 / arm64.

### The observation ring (M4)

A **third**, independent segment (format version 1), so a ring-format change cannot
destabilise admission. It rides [`nim-shm-queue`](../nim-shm-queue)'s Layer 1
through its `EmbeddedRing` view — ticket-CAS append, release-store publish,
single-consumer drain, atomic **signalled** drop counter — rather than growing a
second copy of the MPSC protocol, and adds the segment, the consumer wait word and
the completeness accounting on top.

| Platform | Status | Note |
|---|---|---|
| Linux (x86-64, aarch64) | supported | inherits `shm_queue`'s POSIX arm and M3's `futex` wake path. **UNEXERCISED: never run on Linux.** |
| macOS 14.4+ (arm64, x86-64) | supported, and the only platform it has been RUN on | the consumer parks with `os_sync_wait_on_address`; below 14.4 `awaitRecord` reports `owrUnavailable` and a caller degrades |
| Windows | **not supported** — no-op arm | `createObsRing` returns unavailable; `publish` returns `oprUnavailable`. Recorded, not omitted. |

The rules it enforces, each measured rather than asserted:

- **Publishing never blocks, never fsyncs, never fails an execution.** A full ring
  DROPS and bumps the counter; the block-on-full policy the substrate offers is
  deliberately not used, because blocking a monitored process to preserve an
  advisory record inverts the priority the component exists to enforce.
- **Publishing adds no round trip.** No reply, no acknowledgement, no handle.
- **Drops are counted and SURFACED.** `windowCompleteness` turns the counter into a
  verdict, so a truncated window can never be recorded as complete.
- **The consumer never polls.** `awaitRecord` parks on the wait word; a quiet ring
  costs zero wakeups.
- **Producers signal only on the empty-to-non-empty transition** — and exactly ONE
  producer per transition, because the consumer publishes an *idle token* before it
  sleeps and a producer must CAS that token from 1 to 0 to be the signaller. A
  producer's own `tail - head` snapshot would be a lost wakeup: the consumer can
  drain and park in the window between the snapshot and the append.

**The ring is usable with no daemon attached.** `publish` never consults consumer
liveness — that would put a `kill(2)` probe on the hot path — so with nobody
draining a client simply fills the ring and then drops, every drop counted. A
client that wants the standalone fallback asks `consumerVerdict` out of band.

**Page size is a host property, and it bit us.** `MAP_FIXED` needs a page-aligned
address; pages are 4 KiB on x86-64 Linux and Intel macOS but **16 KiB on Apple
Silicon**. Striding the position-independence probe bases by the segment size
(4 KiB) silently failed with `EINVAL` for every child whose index was not a
multiple of 4 — reproduced on Darwin 25.5 / arm64. The test now asks
`sysconf(_SC_PAGESIZE)`.

## API sketch

```nim
import shm_lease

# OWNER: word 0 is the machine budget, words 1.. are pool budgets.
var l = createLeaseSegment(path, [
  vec(cpuSlots = 16, memUnits = memUnitsForBytes(64'u64 * 1024 * 1024 * 1024).uint32,
      procs = 64, ioWeight = 1000),          # machine
  vec(8, 256, 32, 500),                       # pool 0
])

# CLIENT: attach and claim. Non-blocking — granted or not, never parks the caller.
var c = attachLeaseSegment(l.path)
var r: Reservation
case c.claim(vec(4, 128, 1, 100), r, poolIndex = 0)
of csGranted: discard        # ... run the action ...
of csRefused: discard        # run something else instead (SM-8)
else: discard                # unavailable / invalid — degrade

discard c.release(r)         # exact inverse; over-release is REFUSED, not silent

# Observability + the invariant.
echo c.remainingVec(MachineBudgetIndex), " of ", c.capacityVec(MachineBudgetIndex)
doAssert c.noOvercommitAnywhere()
```

Blocking (M3) lives in its own segment of per-waiter slots — a shared wait word
would reintroduce the thundering herd by construction:

```nim
# OWNER: one wait slot per waiter.
var w = createWaitSegment(waitPath, slots = 64)

# WAITER: remember what you saw, then block until it changes, RE-VALIDATING after
# every wake (spurious wakeups are guaranteed by every primitive underneath).
var c = attachWaitSegment(waitPath)
let seen = c.slotValue(mySlot)
if c.awaitGrant(mySlot, seen) == wrNotEqual:
  let grant = c.slotPayload(mySlot)      # published BEFORE the word was bumped

# WAKER: assign first, then wake — never wake-then-retry.
discard w.publishGrant(mySlot, grantValue)

# --- M4: the observation ring -------------------------------------------------

# DAEMON: create the ring, register, then drain WITHOUT polling.
var ring = createObsRing("/tmp/runquota.obs", capacity = 4096, maxRecordLen = 256)
ring.registerConsumer()
var buf: array[256, byte]
var n = 0
while running:
  if ring.awaitRecord(timeoutNs = 1_000_000_000) == owrReady:   # parks; no polling
    while ring.drainOne(buf, n) == odrGot:
      handle(buf, n)

# CLIENT: one append, no reply, no way to fail the execution being observed.
var client = attachObsRing("/tmp/runquota.obs")
let before = client.droppedCount()
case client.publish(record)          # never blocks, never fsyncs
of oprPublished: discard
of oprDropped:   discard             # counted, and surfaced below
of oprOversize, oprUnavailable: discard

# ...and the window can never be presented as complete if it lost anything.
if client.windowCompleteness(before) == ccTruncated:
  markCaptureIncomplete()
```

## Test & benchmark

```bash
just test           # unit + the M2, M3 and M4 gates + deterministic interleavings
just bench          # POC-local claim/release, wait/wake and per-observation cost
                    # (M1/M8 own the real socket comparison)
just soak 20        # the M2 gate harness, 20x the rounds per child
just test-syscalls  # EXTERNAL syscall counting for SM-2 (strace / dtruss)
just lint           # nim check over the library and every test
```

`just test-syscalls` is **not** part of `test`: on macOS `dtrace`/`dtruss` need
root *and* a SIP configuration that permits DTrace, and refuse on a stock host.
The suite's own SM-2 assertions therefore use the kernel's per-task syscall
counter (`task_info` / `TASK_EVENTS_INFO`), which is exact, needs no privileges,
and is calibrated in-suite before it is trusted. On Linux there is no cheap
in-process equivalent, so `strace -c` is the only route there and the in-suite
SM-2 assertions announce themselves as skipped rather than passing vacuously.

`nimble test` runs the same three files, but only once the repo has a commit
(nimble derives the package version from the VCS revision), so `just` is the
blessed runner during development — the same convention as `nim-shm-gset`.

`just test-sanitizers` exists but is **not** part of `test` and has **not** been
made to run on macOS/arm64: both arms build, then the TSAN binary dies with SIGSEGV
and the ASan binary hangs in `dyld` before `main`. Reproduced on Darwin 25.5 /
arm64, not diagnosed, and not claimed as passing anywhere — run it on x86-64 Linux.
Note also that TSAN/DRD shadow state by *virtual address* while every process maps
the segment at its own base, so they structurally cannot observe the cross-mapping
ordering; that is what the multi-process gate covers.

### What the gate proves

`tests/test_shm_lease_multiprocess.nim` forks N real processes against one shared
packed budget, **each mapping the segment at a deliberately different virtual
base**, and asserts:

1. **No overcommit ever observed** — N+1 independent observers sample every budget
   word and assert `remaining[d] <= capacity[d]`, which catches an under-flowing
   claim and an over-release alike. Three anti-vacuity assertions (refusals
   non-zero, CAS retries non-zero, minimum observed CPU remaining ≤ 1) rule out "no
   overcommit because nothing was ever tight", and a **negative control** re-runs
   the same harness with the fit test removed and requires the checker to fire.
2. **No lost update** — the shared counters must equal the sum of what each process
   independently believes it did, and, counter-independently, the budget deficit at
   quiescence must equal the *exact* sum of the reservations the children
   deliberately still hold.
3. **Total released == total claimed** — releasing the still-held reservations
   restores `remaining == capacity` bit-for-bit on every word, and one further
   release is refused.
4. **Position independence (SM-7)** — the parent reserves one `PROT_NONE` region
   before forking, so child `i` maps at `region + i * pageAlignedStride` and the
   bases are pairwise distinct *by construction*, not by luck. Two forked children
   both calling `mmap(nil, ...)` would very likely land at the same address and
   prove nothing.

**Contention is structural, not incidental.** The `retryCount > 0` assertion above
is load-bearing — without it, "0 overcommit violations" is also the expected result
of a gate in which no two claims ever raced — so the harness must *guarantee* the
race rather than hope for it. Two pipe gates do that:

1. **Start barrier** — each child announces "attached" and blocks; the parent
   releases them all with one `close` (a broadcast) only after all N announcements.
2. **Stop gate** — after its *first* round each child announces "I am inside the
   loop", and no child may *leave* the loop until the parent closes the stop pipe,
   which it does only after all N announcements. So at the instant the parent holds
   all N, every child is provably inside the loop and none can exit. The parent
   records that instant and the gate asserts it lies inside every child's
   `[startNs, endNs]`, plus pairwise interval intersection.

Both gates are needed. A start barrier alone was measured and found insufficient:
releasing six blocked readers spreads their wakeups over ~1 ms, the same order as a
child's entire release-mode run, so 23% of runs still contained a non-overlapping
pair. Timing cannot be fixed with more timing. Before either gate existed, observed
CAS retries ranged from 135,689 down to **zero** (~4% of release runs). After:
120/120 clean runs on a host at load average 104–120, minimum 69,282 retries.

The invariant-sample count is **derived, not observed** — the parent samples a fixed
budget and each child samples `roundsDone + (claims − heldCount) + 1` times, an
identity the gate asserts. An earlier unbounded parent spin-sampler made the figure
a measure of machine load (7.2M vs 19.3M on the same soak), which is not something
that can be quoted.

Proves **SM-7** and **partial SM-5**. Not proven here: **SM-6** (no leaked
capacity) — this test deliberately exhibits the leak, since the children exit while
still holding reservations and the parent has to give that capacity back by hand.
Reclaiming it automatically is M7.

### What the M3 gate proves

`tests/test_shm_lease_wait_multiprocess.nim` reuses M2's harness shape — one
`PROT_NONE` region reserved *before* the fork, `sysconf(_SC_PAGESIZE)` stride,
`MAP_FIXED` per child, pipe start barrier, report pipe drained before reaping —
and asserts, in five phases:

1. **A waiter blocks and another process wakes it, at differing virtual bases.**
   The child parks at its `MAP_FIXED` base; the parent publishes and wakes through
   its own, different, mapping. The parent observes the waiter count from its
   mapping while the child is inside the kernel. This is simultaneously SM-7 for
   the wait word and the direct assertion of the keying rule (inode + offset on
   Linux, `OS_SYNC_*_SHARED` on macOS) rather than an assumption about it.
2. **Spurious wakeups are tolerated.** The parent injects forced wakes with the
   value *unchanged* — exactly the event every one of these primitives is
   permitted to manufacture — and the child must re-validate and re-park rather
   than report a grant that does not exist. Delivery is *confirmed* through a
   shared-memory progress counter and re-issued if lost, because a waiter is
   registered a few instructions before it is actually in the kernel and a wake in
   that window is legitimately lost.
3. **SM-1: a blocked waiter consumes no measurable CPU** over a multi-second
   block — with a **spinning child running the same window as the negative
   control**, required to *exceed* the same limit. Measured on Darwin 25.5 /
   arm64: 35–51 µs of CPU over a 3.0 s block, against 3.01 s for the spinner —
   a ratio of 59,000–86,000x, with the limit set at 20 ms.
4. **SM-2: the uncontended fast path costs zero syscalls**, measured in the child
   at its `MAP_FIXED` base with the kernel's own counter: 200,000 fast-path waits
   → **0** syscalls, 200,000 no-waiter wakes → **0**, control of 200 forced wakes
   → **200**.
5. **The cross-process scope is load-bearing.** Two children park under an
   identical schedule, one with the cross-process scope and one with the
   process-local one (`FUTEX_*_PRIVATE` / `OS_SYNC_WAIT_ON_ADDRESS_NONE`). The
   shared waiter is woken in ~311 ms; the process-local waiter is *not* woken and
   sits out its full 1.5 s timeout.

Every one of those was **mutation-tested** — removing the fast paths turns 0/0
syscalls into 200,000/200,000; making `waitOn` return without parking turns the
blocked child's 51 µs into 3.72 s of CPU; collapsing the process-local scope onto
the shared one makes the keying control return in 303 ms instead of timing out;
removing the prefault turns a clean timeout into `EFAULT`.

Proves **SM-1** and **SM-2**. Not proven here: SM-3 (no wake amplification), SM-4
(bounded wait for large claims), SM-6 (no leaked capacity) and SM-8, which belong
to M5/M6/M7 and are not attempted.

### Fast-path cost (M3)

POC-local, Darwin 25.5 / arm64, one release run — read the variance warning in
`benchmarks/bench_wait.nim` before quoting any of it:

| operation | cost | syscalls |
|---|---|---|
| uncontended wait (word already differs) | ~2.2 ns | **0** over 5,000,000 ops |
| uncontended wake (nobody parked) | ~2.4 ns | **0** over 5,000,000 ops |
| forced wake syscall (the fast path bypassed) | ~430 ns | 1 per op |
| park + wake round trip between two threads | ~5.8 µs | slow path, for scale |

The middle two rows are the point: skipping the wake syscall when the word records
no waiter is ~177x cheaper than issuing it, and that is the case a naive
implementation gets wrong on *every* release.

### What the M4 gate proves

`tests/test_shm_lease_obs_multiprocess.nim` forks real producer and consumer
processes at **deliberately differing virtual bases** and asserts, in five phases:

1. **Saturation** — 4 producers hammer a 256-slot ring while the parent drains it,
   THROTTLED. `delivered + dropped == produced` holds exactly, no record is torn,
   each producer's records arrive in order, and the drop count has a **derived lower
   bound** (`produced - capacity - drained`) so "drops happened" is arithmetic
   rather than luck. Overlap is structural — M2's start barrier plus stop gate — and
   is asserted BEFORE the drop assertions, so a regression names the cause.
2. **OS-1, the perturbation measurement** — each child times the same synthetic work
   with no observation, with a ring append, with an append into a SATURATED ring
   (the drop path), with a one-way `write(2)` per observation, and with a socket
   ROUND TRIP per observation. All within one process, in CPU time, with the
   baseline re-measured inside every repetition and each arm estimated as the MEDIAN
   of the paired per-repetition differences over 210 repetitions.

   The bound is **bounded and small, not "indistinguishable"** — observing is
   reproducibly measurable, and a bar demanding indistinguishability is both
   unachievable and an invitation to a meaningless tolerance. The threshold is
   anchored to a noise floor the phase MEASURES on every run: a sixth `paNull` arm
   runs the baseline loop with nothing added, through the identical estimator, and
   whatever it reports is the finest difference the instrument can resolve. Two
   things must then hold before any arm is judged — the floor is small, and **no arm
   reads meaningfully faster than the baseline**, which is physically impossible
   since every arm is the baseline plus an observation. The ring arms must stay under
   the tolerance and **both IPC arms must exceed it**; a tolerance only one side can
   fail is not a measurement.

   The estimator is PAIRED: the overhead is computed inside each repetition against
   the baseline measured a few hundred microseconds away, and the result is the
   MEDIAN of the paired differences over 210 repetitions. The two properties that
   make the phase survive a loaded host are this paired median and the SHORT
   MEASUREMENT LOOPS (200 rounds x 210 repetitions rather than 10000 x 2) — and which
   two was settled by REVERTING each candidate individually: reverting to few long
   loops fails 12 of 12 runs at 4x oversubscription, and reverting to best-over-phase
   against best-over-phase fails 5 of 8 runs even idle. The measurement-order rotation and the CPU-time clock are kept but are
   NOT load-bearing — reverting either still passes 8/8 at 8x oversubscription.

   Measured idle and under 2x and 4x CPU oversubscription (32 and 64 spinners on 16
   cores), on release AND on the unoptimised build `just test` uses. Floor: exactly
   0 per mille in all 156 samples. Ring: 3..5 per mille release, 14..17 debug;
   saturated/drop path 0..1 and 4..5. One-way `write(2)`: 161..235. Socket round
   trip: 357..376. Against a 50 per mille (5.0%) tolerance — ~2.9x above the worst
   ring reading over both builds and ~3.2x below the weakest falsifying control.
   12/12 release gate runs passed at each of the three load levels, and 8/8 debug
   runs idle and at 4x.
3. **The idle gate** — a consumer blocks on a quiet ring for a multi-second window
   and must come back having entered the kernel exactly ONCE (zero wakeups) and
   burned no measurable CPU, while a POLLING control on the same ring burns
   thousands of syscalls and must exceed the same limits.
4. **The signalling gate** — with a consumer parked and a burst that keeps the ring
   non-empty throughout, the producer's own KERNEL syscall count over the burst must
   be exactly 1, against a `publishForcedSignal` control that pays one per append.
5. **No daemon attached** — a child publishes into a ring nobody registered against
   or drains: no failure, no block, every record accepted or counted.

Proves **OS-1**, **OS-2**, **SM-1 (consumer side)** and **SM-2**. Not proven here:
OS-3..OS-8 (the store, not the transport), SM-3/SM-4/SM-6, and anything about
producer death mid-publish — kill injection is M7.

### Per-observation cost (M4)

POC-local, Darwin 25.5 / arm64, ranges across several release runs — read the
variance warning in `benchmarks/bench_obsring.nim` before quoting any of it:

| operation | cost | syscalls |
|---|---|---|
| append, ring has room (one producer) | ~14-34 ns | **0** |
| append, ring FULL — the counted-drop path | ~4-11 ns | **0** |
| append that SIGNALS (the transition) | ~443-892 ns | 1 |
| drain, consumer side | ~10-16 ns | **0** |
| one-way `write(2)` of the same record | ~383-402 ns | 1 |
| socket round trip (send + ack) | ~850-915 ns | 4 |

The third row against the first is the whole argument for signalling only on the
empty-to-non-empty transition: a transition costs ~26-31x a plain append, so a
design that signalled on every append would pay it every time.

**Known cost, measured and not hidden:** with several processes appending to ONE
ring as fast as they can, the ticket-CAS cache line becomes the bottleneck and the
per-append cost rises from ~26-32 ns (one producer) to ~190-255 ns (three) and
~800-955 ns (six) — `benchmarks/probe_obs_contention.nim`, run by `just bench`, eight
invocations on this host. Read the variance warning literally: in the two invocations
taken while the host was busy the SINGLE-producer arm alone read 125-194 ns, so the
contention ratios are only meaningful between arms measured in the same invocation. That rate is far beyond anything an execution stream can
generate — one observation per *execution*, not per microsecond — so it bounds the
substrate rather than the design, and reducing it is what M5's flat combining is
for. The M4 gate reports it and deliberately does not assert on it.

Apache-2.0.
