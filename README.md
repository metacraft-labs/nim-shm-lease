# nim-shm-lease

A shared-memory, lock-free, file-backed **multi-dimensional reservation** for Nim:
CPU slots, coarse memory units, process count and IO weight packed into **one
64-bit word**, claimed and released with a single CAS.

Sibling to [`nim-shm-queue`](../nim-shm-queue) (MPSC ring) and
[`nim-shm-gset`](../nim-shm-gset) (grow-only set). This is the POC library of the
*RunQuota Observation Store & Shared-Memory Transport* campaign —
`reprobuild-specs/RunQuota-Observation-Store.milestones.org`, phase 1 — and its
design authority is
`reprobuild-specs/RunQuota-Shared-Memory-Transport.md`.

## Status: M2 only

M2 is the spec's *"§1 the fit check and claim are the easy part"*, and nothing
more. Read the scope honestly before building on it:

| Campaign milestone | What it adds | Here? |
|---|---|---|
| **M2** | packed-budget multi-dimensional reservation, no overcommit, position independence | **yes** |
| M3 | futex-class blocking (`futex` / `os_sync_wait_on_address`) | no |
| M4 | observation ring (built on `nim-shm-queue`) | no |
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

| Platform | Status | Note |
|---|---|---|
| Linux (x86-64, aarch64) | supported | `boot_id` from `/proc/sys/kernel/random/boot_id`; process start time is field 22 of `/proc/<pid>/stat` |
| macOS 11+ (arm64, x86-64) | supported | process start time via `sysctl(KERN_PROC/KERN_PROC_PID)` → `kp_proc.p_starttime`; boot identity derived from pid 1's start time |
| Windows | **not supported** — no-op arm | Deliberate, and inherited from the campaign: the shared-memory transport's Windows *wake* path needs named kernel objects because `WaitOnAddress` is documented as within-process only. The M2 reservation itself would port, but shipping it without M3's wake path would be a half-capability, so Windows reports unavailable and the gap is recorded here rather than silently omitted. |

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

## Test & benchmark

```bash
just test      # unit + the multi-process M2 gate + deterministic interleavings
just bench     # POC-local claim/release cost (the socket comparison is M1/M8)
just soak 20   # the same gate harness, 20x the rounds per child
just lint      # nim check over the library and every test
```

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

Apache-2.0.
