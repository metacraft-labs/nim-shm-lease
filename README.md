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
_RunQuota Observation Store & Shared-Memory Transport_ campaign —
`reprobuild-specs/RunQuota-Observation-Store.milestones.org`, phase 1 — and its
design authority is
`reprobuild-specs/RunQuota-Shared-Memory-Transport.md`.

## Status: M2 + M3 + M4 + M5 + M6 + M7

M2 is the spec's _"§1 the fit check and claim are the easy part"_; M3 is
_"Waiting Without Spinning"_; M4 is _"The Observation Ring"_; M5 is
_"§3 flat combining puts the policy in shared memory"_; M6 is the anti-starvation
_policy_ that section exists for; M7 is _"§4 structural crash safety"_ and
_"§5 reservation reclamation"_. Nothing beyond those six. Read the scope honestly
before building on it:

| Campaign milestone | What it adds                                                                                          | Here?   |
| ------------------ | ----------------------------------------------------------------------------------------------------- | ------- |
| **M2**             | packed-budget multi-dimensional reservation, no overcommit, position independence                     | **yes** |
| **M3**             | futex-class cross-process blocking (`futex` / `os_sync_wait_on_address`), per-waiter wait slots       | **yes** |
| **M4**             | observation ring: bounded MPSC, counted drops, non-polling consumer (rides `nim-shm-queue`'s Layer 1) | **yes** |
| **M5**             | flat-combining arbiter: a migrating role, per-waiter grant slots, grant-then-wake                     | **yes** |
| **M6**             | anti-starvation policy: arrival-order scan, one reservation head, bounded wait for large claims       | **yes** |
| **M7**             | kill injection at every hook, reservation reclamation, pid-reuse safety                               | **yes** |
| M8                 | preemption study and go/no-go verdict                                                                 | no      |

M5 added the arbiter — a global view, taken by whichever client holds the migrating
role — so the policy had somewhere to live. M6 put a policy in it, and it is two
rules: the scan runs in **arrival order**, and the first request a round cannot
grant becomes that round's single **reservation head**, whose want is withheld from
every request decided after it. That is capacity held idle for a pending large
claim instead of spent on a small one that arrived later, which is what the design
spec's §2 asks for and what first fit in slot order could not do.

What that buys, measured: an 8 GiB claim admitted in 100–111 ms while six processes
hold or demand 512 MiB each continuously — against four other admission policies,
including the naive packed-CAS loop, which never admit it at all. What it does not
buy: optimal packing. Admission is **online**, so the achievable goals are bounded
waiting and no overcommit, and nothing more than that is claimed.

M7 closed the thing this library most conspicuously was not. Real processes are
now SIGKILLed at **every** schedule hook — the loop is over the `SchedulePoint`
enumeration itself, so a seam added later is covered without editing the test — and
each victim dies holding a real grant and, in the combine path, the role.
Admission recovers in a **measured 41–47 ms** against a derived 1 s bound, the
structure is intact, and the dead client's capacity comes back exactly. What made
it fast is measured rather than asserted: with the anchor half of the steal
detector disabled the same kill costs **261–267 ms**, the bounded timeout.

What is still **not** crash-safe: capacity taken through M2's `claimWords` path.
That reservation is a process-local handle with no shared owner record, so a client
killed there leaks irrecoverably. It is not the admission path — the arbiter is,
and mixing the two on one budget word is already forbidden — but it is a real
boundary and it is stated rather than left to be found.

## The packed budget word

Four 16-bit fields, little end first:

| bits  | dimension               | ceiling                            |
| ----- | ----------------------- | ---------------------------------- |
| 0–15  | CPU slots               | 65535 slots                        |
| 16–31 | memory, in 64 MiB units | 65535 × 64 MiB = 4095 GiB (~4 TiB) |
| 32–47 | process count           | 65535 processes                    |
| 48–63 | IO weight               | 65535 weight units                 |

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
field borrows from the field above and corrupts a _different_ dimension. So the
claim is: read → `fitsPacked` per dimension → CAS the decremented value → retry.
`tests/test_shm_lease.nim` demonstrates the corruption directly, and
`tests/test_shm_lease_multiprocess.nim` runs the whole multi-process gate with the
fit test removed and asserts the invariant checker catches it.

## Multi-word budgets and the fixed claim order

Per-machine and per-pool budgets get their own words:

- word `0` (`MachineBudgetIndex`) — the per-machine budget;
- word `1 + p` (`poolBudgetIndex(p)`) — pool `p`'s budget.

**Claim order is ascending word index; rollback and release are descending.** Since
every claimant takes words in strictly ascending index order, the waits-for relation
is a strict order and no cycle is constructible. This is _enforced_, not documented:
`claimWords` returns `csOutOfOrder` for a non-ascending index list rather than
sorting it, because silently reordering would hide a caller that had built an order
this library cannot see. A claim is all-or-nothing — a refusal on a later word rolls
the earlier words back exactly, leaving no trace in the accounting.

## Engineering playbook (inherited)

Per the design spec's _"The engineering playbook does transfer"_:

- **File-backed `mmap(MAP_SHARED)`** — the segment survives producer death and `exec`.
- **Position independence (SM-7)** — only offsets, counts, and packed _values_ live
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
  `-d:shmGSetScheduleHooks`, at _every_ budget CAS, release CAS, rollback CAS,
  anchor publish, magic publish and rename site. Compile-time no-op otherwise.
- **Portable no-op arm** — compiles everywhere; `shmLeaseSupported == false` off
  Linux/macOS, where every operation reports unavailable.

## Capability record

### The reservation (M2)

| Platform                  | Status                        | Note                                                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------- | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Linux (x86-64, aarch64)   | supported                     | `boot_id` from `/proc/sys/kernel/random/boot_id`; process start time is field 22 of `/proc/<pid>/stat`                                                                                                                                                                                                                                                                                     |
| macOS 11+ (arm64, x86-64) | supported                     | process start time via `sysctl(KERN_PROC/KERN_PROC_PID)` → `kp_proc.p_starttime`; boot identity derived from pid 1's start time                                                                                                                                                                                                                                                            |
| Windows                   | **not supported** — no-op arm | Deliberate, and inherited from the campaign: the shared-memory transport's Windows _wake_ path needs named kernel objects because `WaitOnAddress` is documented as within-process only. The M2 reservation itself would port, but shipping it without M3's wake path would be a half-capability, so Windows reports unavailable and the gap is recorded here rather than silently omitted. |

### The blocking wrapper (M3)

| Platform                | Primitive                                                                                     | Minimum version | Cross-process | Note                                                                                                                                                                                                                                                                                                                                                       |
| ----------------------- | --------------------------------------------------------------------------------------------- | --------------- | ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Linux (x86-64, aarch64) | `futex(FUTEX_WAIT / FUTEX_WAKE)` **without** `FUTEX_PRIVATE_FLAG`                             | any             | ✓             | A shared futex keys on the underlying **inode + offset**, not the virtual address, which is what lets a file-backed segment mapped at a different base in every process still block correctly. **UNEXERCISED: never run on Linux.**                                                                                                                        |
| macOS (arm64, x86-64)   | `os_sync_wait_on_address` / `os_sync_wake_by_address_any` / `..._all` with `OS_SYNC_*_SHARED` | **14.4**        | ✓             | The symbols are **weak-imported and NULL-checked at run time**, so a binary built against a 14.4 SDK still launches on an older macOS and `waitWordAvailable()` simply returns false there. The minimum version is recorded in `WaitWordMinMacOsVersion` and asserted by the suite.                                                                        |
| Windows                 | —                                                                                             | —               | **✗**         | **OUT OF SCOPE, recorded not omitted.** `WaitOnAddress` is documented as working only within a process; a cross-process wake needs named kernel objects (a per-waiter named event or semaphore). Note the asymmetry for whoever takes it up: the _fast path_ (no wait) still costs zero syscalls on Windows, and only the **wake** needs the named object. |

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

| Platform                    | Status                                              | Note                                                                                                                       |
| --------------------------- | --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Linux (x86-64, aarch64)     | supported                                           | inherits `shm_queue`'s POSIX arm and M3's `futex` wake path. **UNEXERCISED: never run on Linux.**                          |
| macOS 14.4+ (arm64, x86-64) | supported, and the only platform it has been RUN on | the consumer parks with `os_sync_wait_on_address`; below 14.4 `awaitRecord` reports `owrUnavailable` and a caller degrades |
| Windows                     | **not supported** — no-op arm                       | `createObsRing` returns unavailable; `publish` returns `oprUnavailable`. Recorded, not omitted.                            |

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
  producer per transition, because the consumer publishes an _idle token_ before it
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

### The flat-combining arbiter (M5)

The serialization point **stops being a process boundary and becomes a migrating
role**. Clients publish requests into per-client slots in the lease segment;
whichever client finds the role free claims it, decides _every_ pending request
with a full global view, publishes the outcomes into per-waiter slots and wakes
only the waiters it granted, then releases the role. A client that does not get the
role neither spins nor parks inside the attempt (SM-8).

**This protocol was modelled before it was written.** `verification/tla/
shm_lease_combine.tla` (campaign milestone MV2) is a TLA+ model of exactly this
arbiter — death at every program counter, plus the false-positive steal a
kill-injection suite cannot reach — and it produced four constraints, each with a
configuration that fails without it. All four are in the code, and each has a
negative control in `tests/test_shm_lease_arbiter.nim` that switches it off and
requires the damage to appear:

| Constraint                                                              | Where it lives                                                                                                                    | What breaks without it                                                                                                                                    |
| ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Commit and role transfer resolve in ONE CAS on ONE word**             | the role word is `[epoch, ownerSlot, committed]` at lease-header offset 96; the commit is `CAS(role, [me,e,false] → [me,e,true])` | a stolen-from combiner commits a round the stealer discarded (`..._unfenced_MC.cfg`, `NeverBoth`, 13-state trace)                                         |
| **The budget word is a CACHE of the stamped ledger, never decremented** | `refreshBudgetCache` recomputes `capacity − Σ effective grants`; no decision reads the word                                       | a discard between a decrement and its stamp destroys capacity permanently (`..._budget_MC.cfg`, `BudgetExact`, 26 states)                                 |
| **Per-slot serialisation AND the epoch in the published value**         | the raise pass never restamps an effective entry; the published value is the combine **epoch**, not `value + 1`                   | a collected request granted twice; a stealer republishing a dead combiner's answer (`..._noserial_MC.cfg` and `..._counter_MC.cfg`, both `NoDoubleGrant`) |
| **The steal detector needs the anchor check AND a bounded timeout**     | `mayStealRole`: boot+pid+start-time verdict fires immediately, the timeout covers a live-but-stalled holder                       | an unsound detector costs **liveness**, not safety — unbounded role churn (`..._livelock_MC.cfg`)                                                         |

Two further rules the model insisted on: _the recovery predicate and the waiter's
wake predicate must be the same predicate_ — both are the **value word**, since
testing the ledger or the payload deadlocks the model — and a combine round must be
bounded, allocation-free and syscall-free, which is measured at **zero syscalls**
against a forced-syscall control.

M3's `publishGrant` carried a documented precondition — _at most one outstanding
grant per slot_ — that it could not enforce. M5 satisfies it **by construction**:
`publishRequest` refuses a slot whose ledger entry is an outstanding grant, so a
second grant cannot be published because a second request cannot exist.

**Two places M5 leaves the model, stated because they are not checked anywhere.** A
request that does not fit is left **pending** rather than refused — which is what
makes a waiter exist at all, and is what M6's bounded-waiting property is about. That
also means "there is work" stays true for an unfittable request, so the arbiter
declines to take the role unless something pending can actually be granted,
permanently refused, **or published**, and a round whose scan stamped nothing
publishes what is outstanding and then hands the role back uncommitted; otherwise
the epoch churns without bound, which the model forbids.

**That "or published" is not a detail, and the first version of this gate did not
have it — it deadlocked.** The admission gate reads the effective ledger, and an
argument that it therefore cannot hide work is only true of an _uncommitted_ round.
A combiner that commits and then dies before its publish loop leaves entries that
_are_ effective and _are_ counted as held, so the slot's own grant makes the slot's
own request stop fitting and the gate answers "nothing to do" about precisely the
work that needs doing. Republishing a dead combiner's answer is the _designed_
recovery — it is why the published value carries the combine epoch — and both the
gate and the empty-round exit have to let it happen. What is actually true of the
predicate is narrower: a "no" means every pending slot either already has its
answer on the value word or wants capacity another slot's effective grant holds,
and both are states only an event outside the round — a release, or a publication —
can leave. `tests/test_shm_lease_hooks.nim` kills a real combiner at the
`slpBeforeGrantPublish` seam and requires the survivor to recover.

And `releaseGrant` has no counterpart in MV2 at all, since the model never gives
capacity back (reclamation is M7's ground). It is more than unmodelled: it is a
**writer outside the epoch fence**. Every other ledger mutation is a CAS whose
expected value carries an epoch that a role acquisition has already invalidated;
the release CAS carries the entry's _old_ epoch and succeeds whoever holds the
role. It is safe because a release can only move `grant → released` and so only
ever _decreases_ the effective sum, because a released entry cannot be raised back
into a live grant, and because `want` is rewritten only after the decision has been
cleared — none of which is model-checked. See `src/shm_lease/arbiter.nim`'s
docstring for the argument in full.

### Reservation reclamation and kill injection (M7)

**SM-5 and SM-6 are separate invariants, and the arbiter already satisfied the
first.** A death never deadlocks admission and never corrupts the structure: the
epoch fence discards a half-applied round, the steal detector recovers the role,
and republication delivers a committed-but-unpublished answer. None of that gives
the **capacity** back. A dead client's grant is still an effective ledger entry, so
`heldVec` still counts it and the machine is permanently smaller — admission stays
correct and becomes progressively useless. That is SM-6.

**The per-reservation owner anchor already existed, by construction.** A grant
lives in exactly one slot's ledger entry, `publishRequest` refuses a slot whose
entry is still an outstanding grant, and the slot carries `ownerPid` +
`ownerStartTime` written by `registerSlot`. So at most one grant exists per slot and
the slot's anchor _is_ that reservation's anchor. M7 adds the reader, not the field
— which is why M2 wrote the fields.

The rule, and both ways to get it wrong:

> A slot is reclaimed when its owner's anchor is **not** `avLive` **and** the slot's
> words have been unchanged for a bounded grace.

| half           | what it buys                               | mutation            | damage                                                 |
| -------------- | ------------------------------------------ | ------------------- | ------------------------------------------------------ |
| the **anchor** | safety — a live holder is never touched    | `rmTimeoutOnly`     | reclaims a **live** grant: real overcommit             |
| the **grace**  | it is never judged inside a two-step write | `rmNoGrace`         | reclaims a slot mid-registration                       |
| **start time** | pid reuse is a _different_ process         | `rmIgnoreStartTime` | a corpse reads as live: the capacity is leaked forever |

All three mutations are exercised in `tests/test_shm_lease_reclaim.nim`, each on a
board where the shipping reclaimer is required to do the right thing first.

Note the division of labour is the **reverse** of the steal detector's, and the
reversal matters. For a steal the epoch fence buys safety and the anchor buys
progress, so an early fire costs a wasted round; for reclamation there is no fence,
the anchor _is_ the safety, and an early fire costs an overcommit. That is why
`rmTimeoutOnly` is a required-to-fail control rather than a tuning option.

`LhOffReserved1` — the header word M2 reserved with the note "M7: reclamation
epoch" — is now a monotone change counter of reclaimed slots, so "has anything been
reclaimed since I last looked" is decidable by a reader that never saw the pass. No
offset moved, no field changed size, and the format version did not move.

**Reclamation deliberately does not write the role word.** A dead role holder is
recovered by the steal detector, which is modelled, epoch-fenced and already proven
by M5. A second writer of the role word outside the acquire/commit CAS discipline is
precisely the shape MV2's Finding 4 rules out.

**The pid-reuse test is the one the gate names, and it runs in both directions.** A
live child's slot and a stale slot naming _the same live pid_ differ only in the
recorded start time; the shipping reclaimer leaves the first alone (`avLive`) and
reclaims the second (`avPidReused`), and `rmIgnoreStartTime` on the same board reads
the corpse as live and leaks it. What is constructed is only _which_ of two **real**
start times the stale anchor records — a natural pid reuse is unreachable in a test
(macOS allocates pids sequentially and wraps at ~99k) and is not needed, because
after a natural reuse the reclaimer's inputs are exactly those.

**The observation ring's mid-publish kill (M4's debt), settled honestly.** A real
SIGKILL between a producer's ticket reservation and its release-store publish
corrupts nothing and tears no record — every record published before it is delivered
intact and in order. It does still **stall** the in-order drain at that ticket, as
M4 recorded. What M7 changes is that the stall is now _declared_: a stall detector
reports it and the window becomes `ccTruncated` instead of passing as complete
because the drop counter — which cannot see this kind of loss — never moved. The
**repair** is not here and cannot be at this layer: skipping the stuck ticket is
safe only if its producer can never write again, and a ticket has no owner anywhere
— the reservation and the publication are both inside `nim-shm-queue`'s `pushBlob`,
which has no owner field and no seam between them. This layer therefore has the
bounded timeout and not the anchor, and M5's finding is exactly that those two
halves buy different things.

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

# --- M5: the flat-combining arbiter -------------------------------------------

# OWNER: a lease segment WITH request slots is what makes the arbiter available.
var l = createLeaseSegment(path, [vec(64, 512, 64, 1000)], requestSlots = 32)

# CLIENT: take a slot (this writes the anchor the steal detector consults) and
# publish a request. Publishing never blocks and never enters the kernel.
var c = l.arbiterClient(mySlot)
doAssert c.registerSlot(mySlot)
doAssert c.publishRequest(vec(4, 16, 1, 10)) == psPublished

# ...then drive: try to BE the arbiter, and park with a bounded timeout if
# somebody else already is. Whoever runs the round decides every pending request
# with a global view and wakes only the waiters it granted.
var round: CombineRound
while true:
  case c.combineUntilAnswered(round, parkNs = 20_000_000)
  of ansGranted: break                 # the capacity is now HELD by this slot
  of ansRefused: raise newException(ValueError, "cannot ever fit")
  else: discard                        # not answered yet; go round again

runTheAction()
doAssert c.releaseGrant()              # one CAS; the next round redistributes it
```

```nim
# --- M7: reclamation ----------------------------------------------------------

# A REAPER (the daemon, or any client willing to pay for it out of band — never
# from inside a round, which must stay syscall-free). One `kill(pid, 0)` per
# OCCUPIED slot; live holders are counted and left alone.
var reaper = newReclaimer(lease.arbiterView())
let rep = reaper.reclaimPass()
echo rep.reclaimed, " slots reclaimed, ", rep.freed, " capacity returned"
for i in 0 ..< view.slotCount:
  if rep.action[i] == saReclaimed:
    echo "slot ", i, " reclaimed because ", rep.verdict[i]   # avOwnerGone / avPidReused / ...

# A CONSUMER of the observation ring can now tell a stalled drain from a quiet one.
var det = newDrainStallDetector()
if det.drainStallVerdict(ring, getMonoTime().ticks) == dsStalled:
  discard ring.windowCompleteness(dropsAtStart, drainStalled = true)   # ccTruncated
```

## Test & benchmark

```bash
just test           # unit + the M2..M7 gates + deterministic interleavings + kill injection
just bench          # POC-local claim/release, wait/wake and per-observation cost
                    # (M1/M8 own the real socket comparison)
just soak 20        # the M2 gate harness, 20x the rounds per child
just test-syscalls  # EXTERNAL syscall counting for SM-2 (strace / dtruss)
just lint           # nim check over the library and every test
just verify         # the FORMAL tier: TLA+/TLC models + herd7 litmus tests
```

`just test-syscalls` is **not** part of `test`: on macOS `dtrace`/`dtruss` need
root _and_ a SIP configuration that permits DTrace, and refuse on a stock host.
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
Note also that TSAN/DRD shadow state by _virtual address_ while every process maps
the segment at its own base, so they structurally cannot observe the cross-mapping
ordering; that is what the multi-process gate covers.

### The formal tier — `just verify`

`verification/` holds what the dynamic suite structurally cannot reach. The suite
above **samples** the schedule space; a lock-free budget word whose correctness
rests on a per-field fit test, and a wait protocol whose lost-wakeup freedom rests
on a release/acquire pairing, are not amenable to exhaustive dynamic testing on one
architecture.

```bash
just verify           # everything below
just verify-tla       # TLA+/TLC: the CLAIM and WAIT protocols, all invariants
just verify-tla-negative   # the mutations and non-vacuity probes, which MUST fail
just verify-litmus    # herd7 under the C11, x86-TSO and AArch64 memory models
```

`verification/README.md` is the record: state counts and depths for every model,
what each invariant establishes, the coverage boundaries, and the findings — among
them **two** that paid for the tier before any code existed:
`publishGrant` has an unstated one-outstanding-grant-per-slot precondition whose
violation silently loses a grant, and `waitOn`'s docstring justifies its
lost-wakeup freedom with an argument that does not hold, for a window herd7 reports
as **Allowed on x86-TSO** and **Forbidden on ARMv8**. Read it before changing any
memory order in `waitword.nim`.

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
   quiescence must equal the _exact_ sum of the reservations the children
   deliberately still hold.
3. **Total released == total claimed** — releasing the still-held reservations
   restores `remaining == capacity` bit-for-bit on every word, and one further
   release is refused.
4. **Position independence (SM-7)** — the parent reserves one `PROT_NONE` region
   before forking, so child `i` maps at `region + i * pageAlignedStride` and the
   bases are pairwise distinct _by construction_, not by luck. Two forked children
   both calling `mmap(nil, ...)` would very likely land at the same address and
   prove nothing.

**Contention is structural, not incidental.** The `retryCount > 0` assertion above
is load-bearing — without it, "0 overcommit violations" is also the expected result
of a gate in which no two claims ever raced — so the harness must _guarantee_ the
race rather than hope for it. Two pipe gates do that:

1. **Start barrier** — each child announces "attached" and blocks; the parent
   releases them all with one `close` (a broadcast) only after all N announcements.
2. **Stop gate** — after its _first_ round each child announces "I am inside the
   loop", and no child may _leave_ the loop until the parent closes the stop pipe,
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
`PROT_NONE` region reserved _before_ the fork, `sysconf(_SC_PAGESIZE)` stride,
`MAP_FIXED` per child, pipe start barrier, report pipe drained before reaping —
and asserts, in five phases:

1. **A waiter blocks and another process wakes it, at differing virtual bases.**
   The child parks at its `MAP_FIXED` base; the parent publishes and wakes through
   its own, different, mapping. The parent observes the waiter count from its
   mapping while the child is inside the kernel. This is simultaneously SM-7 for
   the wait word and the direct assertion of the keying rule (inode + offset on
   Linux, `OS_SYNC_*_SHARED` on macOS) rather than an assumption about it.
2. **Spurious wakeups are tolerated.** The parent injects forced wakes with the
   value _unchanged_ — exactly the event every one of these primitives is
   permitted to manufacture — and the child must re-validate and re-park rather
   than report a grant that does not exist. Delivery is _confirmed_ through a
   shared-memory progress counter and re-issued if lost, because a waiter is
   registered a few instructions before it is actually in the kernel and a wake in
   that window is legitimately lost.
3. **SM-1: a blocked waiter consumes no measurable CPU** over a multi-second
   block — with a **spinning child running the same window as the negative
   control**, required to _exceed_ the same limit. Measured on Darwin 25.5 /
   arm64: 35–51 µs of CPU over a 3.0 s block, against 3.01 s for the spinner —
   a ratio of 59,000–86,000x, with the limit set at 20 ms.
4. **SM-2: the uncontended fast path costs zero syscalls**, measured in the child
   at its `MAP_FIXED` base with the kernel's own counter: 200,000 fast-path waits
   → **0** syscalls, 200,000 no-waiter wakes → **0**, control of 200 forced wakes
   → **200**.
5. **The cross-process scope is load-bearing.** Two children park under an
   identical schedule, one with the cross-process scope and one with the
   process-local one (`FUTEX_*_PRIVATE` / `OS_SYNC_WAIT_ON_ADDRESS_NONE`). The
   shared waiter is woken in ~311 ms; the process-local waiter is _not_ woken and
   sits out its full 1.5 s timeout.

Every one of those was **mutation-tested** — removing the fast paths turns 0/0
syscalls into 200,000/200,000; making `waitOn` return without parking turns the
blocked child's 51 µs into 3.72 s of CPU; collapsing the process-local scope onto
the shared one makes the keying control return in 303 ms instead of timing out;
removing the prefault turns a clean timeout into `EFAULT`.

Proves **SM-1** and **SM-2**. Not proven by the M3 gate: SM-3 (no wake
amplification), SM-4 (bounded wait for large claims), SM-6 (no leaked capacity) and
SM-8 — SM-3 and SM-8 are M5's and SM-4 is M6's, all proven by the gates below;
SM-6 remains M7's and is not attempted.

### What the M5 gate proves

`tests/test_shm_lease_arbiter_multiprocess.nim`, six real processes at deliberately
differing virtual bases, one run:

1. **The role really migrates, and it is structural.** Every child owns the role
   before the measured workload starts — it keeps a request outstanding and races
   for the role until it has committed a round — so the epoch-ordered owner
   sequence contains all six and has at least five changes of owner. Typical run:
   41 rounds, **6 distinct owners, 22 owner changes**. The assertion is made
   **before** the clauses that depend on it, so a regression names the cause. The
   teeth: the identical workload with a single permitted combiner yields exactly
   **one** owner and zero changes. \*How many attempts found the role busy or lost
   the acquisition CAS is reported but **not asserted\*** — those count races lost
   to this host's scheduler, they ranged 0–280 and 0–19 over 40 runs, and an
   earlier version of this gate asserted their sum was positive and flaked on it.
2. **(a) Wakes ≤ grants**, and the release scenario is controlled: the parent holds
   nearly the whole budget, four children publish requests that cannot fit and
   **park in the kernel**, the parent waits until every one of them has actually
   parked, and only then releases and runs ONE round. That round grants four and
   wakes exactly four — `wakes == grants`, with real wake syscalls. This is SM-3.
3. **(b) No waiter is ever woken without its grant**, asserted on both sides of the
   wake and in terms of what _this code_ guarantees rather than what the kernel
   happens to do. Publisher: `wakeCalls ≤ answersPublished` — every wake is issued
   in the same straight-line block as the value CAS it announces, so it cannot
   precede its answer. Waiter: of the parks this protocol really woke (the ones
   that returned with the wait word **moved**), the number that failed to find a
   complete, coherent payload is **zero**. A park that returns with the wait word
   unchanged is a _spurious wakeup_, which the wait primitive is allowed to deliver
   and which this suite tolerates elsewhere; it is counted and printed, not
   asserted away.
4. **(c) Every decision is identical to a single-threaded reference.** Each
   committed round records the held-set it scanned and every decision it took;
   the parent merges the logs by epoch — the commit CAS totally orders them — and
   replays them through a reference admission function that keeps its **own**
   arithmetic. It shares `ResourceVec`, `unpackVec` and saturating subtraction —
   the vocabulary the log is written in — but re-derives the _policy_ rather than
   calling the arbiter's fit test, which is what makes agreement a cross-check.
   It checks that no slot is held that the reference never granted, that the two
   held sums agree, and that every decision matches. Typical run: **92 decisions,
   57 grants, 35 left pending, 0 mismatches**, and the same agreement in the
   single-combiner run — so packing quality is provably unchanged by making the
   arbiter migrate. Its **boundary**: a release is inferred from a slot's absence
   from the round's held-set, so an _under_-counting held-set is absorbed and never
   reported. Clause (c) proves decision identity _given_ the round's held-set, and
   validates that set's amount but not its membership in the under-counting
   direction; over-counting is caught, as a phantom hold.

The gate's own teeth are a deliberately blind fit test (MV2's
`CountOwnProposals = FALSE`) driven through four real parked waiters: it grants 12
CPU slots out of 8, and the reference replay reports exactly the two decisions it
would not have taken.

Proves **SM-3** and partial **SM-4** (the arbiter exists and decides with a global
view; _bounded waiting for large claims_ is the M6 gate below). Not proven here:
SM-5/SM-6 — no process is killed and nothing is reclaimed, which is M7.

### What the M6 gate proves

`tests/test_shm_lease_starvation.nim`, seven real processes at deliberately
differing virtual bases. Capacity 10 GiB; six claimers each holding or demanding
512 MiB **at every instant** — they publish the next request while still holding
the current grant, so occupancy never dips, and the parent samples the minimum and
asserts it. `10 GiB − 3 GiB = 7 GiB < 8 GiB`, so a first-fit round cannot admit the
large claim in any schedule; a `static: doAssert` refuses to let those four numbers
be tuned into a gate that passes for free.

1. **The 8 GiB claim is admitted in 100–111 ms** against an asserted 1000 ms bound:
   20/20 release runs and 15/15 unoptimised runs on an idle host (100–102 ms), and
   8/8 release runs under 2× CPU oversubscription (100–111 ms).
2. **Capacity was held idle, observed from outside the arbiter:** the parent saw
   40,000–460,000 states in which the head was waiting, a small claim was waiting,
   and up to 8 GiB of free capacity was not being given out. That sampler is
   corroboration and not the discriminator — it still reads tens of thousands under
   `amFirstFit`, because it cannot tell capacity being withheld from capacity about
   to be granted. `reservations > 0` and `overlapTimeouts >= 2` are the assertions
   that read zero under that mutation.
3. **The idle hold is bounded** — it lasts exactly as long as the wait above — and
   small-claim throughput **recovers**: ~29,000/s before the large claim arrives and
   ~29,000/s in the 300 ms after it is released.
4. **The scan really ran in arrival order**, with rounds that decided a higher slot
   before a lower one so that arrival order demonstrably differed from slot order.
5. **The same harness FAILS for other policies**, which is the milestone's own
   requirement: the naive packed-CAS loop, M5's slot-ordered first fit, and a
   reservation handed to the wrong request all fail to admit the claim in 4000 ms
   while granting 130,000 small claims in the meantime.

The bounded overlap is load-bearing in both directions: with it removed (the
claimer holds until its replacement arrives, without limit) the shipping arm
**deadlocks** — the large claim is never admitted, the tail grant rate is zero and
every claimer blows its own 3 s deadline. That is the opposite defect, and the
"throughput recovers" assertion is what catches it.

Proves **SM-4**. Its honest gap is recorded in the test: _arrival order without a
reservation_ is not a structural control — it starves the claim on an idle host and
admitted it in 1 of 5 runs under load — so the reservation's necessity is carried by
the formal tier, where TLC exhibits a fair behaviour in which it never gets in.

### What the M7 gate proves

`tests/test_shm_lease_kill_injection.nim` (real forks, real `SIGKILL`) and
`tests/test_shm_lease_reclaim.nim`.

1. **Every schedule hook was killed at, and each victim proved it about itself.**
   The loop is over `SchedulePoint`, and the parent requires `WIFSIGNALED` +
   `SIGKILL` — a victim that never reached its point exits with a distinguishable
   status and the test fails on it. 31 of 31 points, in every run.
2. **The victim always died holding capacity.** It is granted its reservation by a
   round the parent runs _before_ the hook is armed, so the no-leak clause is never
   vacuous, and it then drives rounds for a request the parent published, so the
   role-transfer, ledger, commit, sequence, budget-refresh, publication and
   role-release points are all reached mid-round with the role held.
3. **Admission recovered within a derived bound, every time.** Worst observed
   recovery **44–47 ms** against an asserted 1000 ms. The bound is
   `2 × anchorProbeAfterNs (60 ms) + one park slice (20 ms) + one round`, i.e. of
   the order of 80 ms; the 250 ms steal timeout is never reached because the anchor
   fires first.
4. **…and the anchor half is what makes it fast, measured against a control.** The
   same kill at `slpBeforeCommitCas` with the anchor probe pushed beyond the
   timeout takes **261–267 ms** — the timeout, as designed. `fast × 2 < slow` is
   asserted, so "the anchor is load-bearing" is a measurement rather than a comment.
5. **No capacity permanently leaked.** After each kill the reaper hands back
   _exactly_ the victim's vector with verdict `avOwnerGone`, the survivor releases
   its own grant, and `remaining == capacity` **bit-for-bit** with
   `noOvercommitAnywhere` and the stored-pointer audit clean.
6. **A live holder is never reclaimed**, over 40 passes across a window far longer
   than the grace — and `rmTimeoutOnly` on the identical board reclaims _both_
   occupied slots, which is the failure direction stated as a number.
7. **Pid reuse breaks neither direction** (above), with `rmIgnoreStartTime` leaking
   the corpse's capacity on the same board.
8. **The reaper is itself crash-safe.** Killed before its ledger CAS the capacity is
   still held; killed after it the capacity is already back and the slot is not yet
   reusable; the next pass finishes either state and the slot re-registers.
9. **A dead client's _pending_ request does not wedge the scan.** A corpse at the
   head of the arrival order holds capacity idle for nobody — `decidableWork` reads
   false and a live small claim behind it is refused — and reclamation restarts
   admission in the same round.

Run counts: **22 clean runs of the kill gate** — 10 release-idle, 6 under 2× CPU
oversubscription (32 spinners on 16 cores), 6 unoptimised — and 14 of the
reclamation suite, no flake. Proves **SM-5** and **SM-6**.

The formal half is `verification/tla/shm_lease_reclaim.tla`, which is the model M6
recorded as owed: the reservation and the combine role **together**, with death and
reclamation. Its three required-to-fail mutations are the three ways this could have
been got wrong — no reaper (the capacity leaks and the large claim never fits
again), no steal (a combiner that died mid-round while a reservation stood wedges
admission for everybody), and a reaper that fires on a live holder (real overcommit,
while the ledger-side invariant a naive implementation would check stays happily
true).

### Fast-path cost (M3)

POC-local, Darwin 25.5 / arm64, one release run — read the variance warning in
`benchmarks/bench_wait.nim` before quoting any of it:

| operation                                    | cost    | syscalls                 |
| -------------------------------------------- | ------- | ------------------------ |
| uncontended wait (word already differs)      | ~2.2 ns | **0** over 5,000,000 ops |
| uncontended wake (nobody parked)             | ~2.4 ns | **0** over 5,000,000 ops |
| forced wake syscall (the fast path bypassed) | ~430 ns | 1 per op                 |
| park + wake round trip between two threads   | ~5.8 µs | slow path, for scale     |

The middle two rows are the point: skipping the wake syscall when the word records
no waiter is ~177x cheaper than issuing it, and that is the case a naive
implementation gets wrong on _every_ release.

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

| operation                                 | cost        | syscalls |
| ----------------------------------------- | ----------- | -------- |
| append, ring has room (one producer)      | ~14-34 ns   | **0**    |
| append, ring FULL — the counted-drop path | ~4-11 ns    | **0**    |
| append that SIGNALS (the transition)      | ~443-892 ns | 1        |
| drain, consumer side                      | ~10-16 ns   | **0**    |
| one-way `write(2)` of the same record     | ~383-402 ns | 1        |
| socket round trip (send + ack)            | ~850-915 ns | 4        |

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
generate — one observation per _execution_, not per microsecond — so it bounds the
substrate rather than the design, and reducing it is what M5's flat combining is
for. The M4 gate reports it and deliberately does not assert on it.

Apache-2.0.
