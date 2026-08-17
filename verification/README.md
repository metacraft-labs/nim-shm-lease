# nim-shm-lease — formal / weak-memory verification tier (campaign milestone MV1)

This directory is the **formal** verification tier for the multi-process,
file-backed lease structures in `../src/shm_lease.nim`,
`../src/shm_lease/packed.nim` and `../src/shm_lease/waitword.nim`. It is the
complement to the *dynamic* verification in `../tests` (77 tests: the M2
differing-base claim gate, the M3 block/wake gate, the M4 ring gate,
deterministic schedule-hook interleavings, mutation-tested assertions), and it
exists because those tests **sample** the schedule space and cannot exhaust it.

Its sibling is `../../nim-shm-gset/verification/`, and this README deliberately
follows that one's conventions: a table of what actually **RAN** with state
counts and depths, and an explicit section on the **coverage boundaries** of the
RUN items.

**Why these structures need it more than the G-Set does.** `nim-shm-gset`'s
safety argument is that it has no per-element mutable value and no atomic
read-modify-write, so the lost-update race class does not exist for it. The lease
budget word is the opposite: it is *all* read-modify-write, and its correctness
rests on a per-field fit test whose failure mode is a silent borrow into a
*different* dimension. The wait protocol adds a release/acquire pairing on which
lost-wakeup freedom depends. Neither is amenable to exhaustive dynamic testing.

## What is RUNNABLE on this host (and was RUN)

Host: macOS / Darwin 25.5 (macOS 26.5.1), arm64, 16 KiB pages, 2026-08-17.
Tool: `tlaplus-1.7.4` (TLC 2.19) via `nix run nixpkgs#tlaplus`. Wired as
`just verify-tla` and `just verify-tla-negative`.

### The shipped protocols — every invariant HOLDS

| Model | Config | Distinct states | Depth | Result |
|---|---|---:|---:|---|
| CLAIM protocol, 3 processes over 2 budget words | `shm_lease_claim_MC.cfg` | **450,639** (1,274,374 generated) | **82** | **RAN — green.** 12 invariants + `Termination` |
| CLAIM protocol, the enforced claim order vs. a descending list | `shm_lease_claim_ord_MC.cfg` | **128** | **35** | **RAN — green.** Same 12 + `Termination` |
| CLAIM protocol, the per-field fit test on the borrow workload | `shm_lease_claim_borrow_fit_MC.cfg` | **214** | **22** | **RAN — green.** Same 12 + `Termination` |
| CLAIM protocol, order rule dropped, safety only | `shm_lease_claim_ord_nocheck_safety_MC.cfg` | **7,349** | **66** | **RAN — green.** 10 invariants + `Termination` |
| WAIT protocol, 2 per-waiter slots, 3 grants, 1 spurious wake | `shm_lease_wait_MC.cfg` | **21,542** (57,610 generated) | **43** | **RAN — green.** 7 invariants + `AllServed` |
| WAIT protocol, with a seq-cst fence after the value bump | `shm_lease_wait_tso_fence_MC.cfg` | **23,141** | **46** | **RAN — green.** Same 7 + `AllServed` |

`shm_lease_claim_ord_MC`'s 128 states are small **for a stated reason, and the
reason is checked**: its whole point is that one of its two processes names its
words *descending*, so `claimWords` refuses it with `csOutOfOrder` and that
process never holds anything. Only one process does work. That the refusal really
fires is not assumed — `shm_lease_claim_ord_MC_probe.cfg` requires TLC to violate
`ProbeOutOfOrderReached`, and it does.

### The negative controls — every one of these MUST report a violation

A green model that cannot fail proves nothing, so each row below is *required* to
fail and `just verify-tla-negative` fails the recipe if one of them passes. The
state count is what was explored **before TLC stopped**; these are not complete
state-graph searches.

| Kind | Config | Required violation | Explored | Depth |
|---|---|---|---:|---:|
| non-vacuity | `shm_lease_claim_MC_probe.cfg` | `ProbeAllReached` | 16,373 | 26 |
| non-vacuity | `shm_lease_claim_ord_MC_probe.cfg` | `ProbeOutOfOrderReached` | 9 | 5 |
| MUTATION | `shm_lease_claim_ord_nocheck_MC.cfg` | `NoHoldCycle` | 79 | 11 (trace) |
| MUTATION | `shm_lease_claim_borrow_MC.cfg` | `NoBorrow` | 73 | 11 |
| non-vacuity | `shm_lease_wait_MC_probe.cfg` | `ProbeAllReached` | 18,156 | 32 |
| MUTATION | `shm_lease_wait_order_MC.cfg` | `GrantPayloadCoherent` | 51 | 8 |
| **FINDING** | `shm_lease_wait_overwrite_MC.cfg` | `GrantPayloadCoherent` | 1,086 | 15 |
| **FINDING** | `shm_lease_wait_tso_MC.cfg` | `NoLostWakeup` | 10,740 | 25 |

The two **non-vacuity probes** are the load-bearing ones, because they are what
make the green runs above mean something. Each asserts the *negation* of "all the
interesting behaviours have happened", so TLC's counterexample is a single
behaviour in which they all did:

- claim: a claim was **refused**, a partial claim was **rolled back**, a CAS was
  **lost** to a competing process, and a multi-word claim was **granted**;
- wait: the waiter took its **zero-syscall fast path**, **genuinely slept**, was
  saved by its **userspace re-check**, was saved by the **kernel's
  compare-and-park**, was woken by a **real wake syscall**, and **survived a
  spurious wakeup** — while the waker took **both** its zero-syscall fast path
  and its syscall path, and hit the **pre-park window** where its wake syscall
  found nobody inside the kernel.

The `shm_lease_claim_borrow_MC` mutation was additionally re-run with each
invariant alone, because TLC reports only the first: `NoBorrow`,
`NoOvercommit` **and** `ConservationExact` each fail on it independently.

**A NOTE FOR WHOEVER RE-RUNS THIS.** The *green* runs' state counts and depths are
**exact and reproducible** — a complete breadth-first search of a finite state
graph is deterministic, and 450,639 / 128 / 214 / 7,349 / 21,542 / 23,141 come back
identical every time.

The *violating* runs' numbers are **NOT** — and that applies to **both** numeric
columns, not only to *Explored*. TLC stops at the first counterexample, so it
aborts **mid-BFS**; with `-workers 4` which worker reaches the violation first
varies, and that changes both how much of the graph had been explored and how
deep the search had got when it stopped. Observed across re-runs:

- *Explored* moves by a few percent: 16,373 vs 16,373; 79 vs 81; 73 vs 75;
  18,156 vs 18,233; 51 vs 47; 1,086 vs 1,160; 10,740 vs 10,702.
- *Depth* moves too, for exactly the same reason:
  `shm_lease_claim_ord_nocheck_MC` reported **13 on one run and 14 on another**,
  and `shm_lease_wait_order_MC` reported **7** where **8** is recorded above.

**So for the eight violating rows the only invariant thing is the NAMED
INVARIANT** — which invariant TLC reports, and nothing else. That is precisely
what `just verify-tla-negative` asserts, and it was confirmed for all eight. A
verifier who sees a different *Explored* count, or a different *Depth*, has not
found a discrepancy. A verifier who sees a different *invariant* named, or no
violation at all, has.

**Depth convention, and the one row that departs from it.** Every *Depth* cell in
both tables above is TLC's own "depth of the complete state graph search", which
for the green rows is exact. The single exception is
`shm_lease_claim_ord_nocheck_MC`, marked `11 (trace)`: because its reported search
depth was not reproducible (13 and 14, above) that row records instead the
**length of the counterexample trace, 11 states**, which *was* stable across four
runs at both `-workers 4` and `-workers 1`. The same 11-state figure is what the
prose below and the milestone record cite for this counterexample. An independent
re-run confirmed the 11 states over six more runs and widened the observed spread
of the *reported search depth* to **13 at `-workers 4` and 11 at `-workers 1`** —
at one worker the BFS is deterministic and stops exactly at the violating level,
so there the reported depth and the trace length coincide.

### Three things that look like failures and are not

**A `just verify` that seems to hang is `nix shell`, not TLC.** Every recipe pulls
TLC with `nix shell nixpkgs#tlaplus`, which re-resolves the `nixpkgs` registry
entry over the network. When `channels.nixos.org` is rate-limiting (503/429) those
retries can stall the run for **ten minutes or more with no output at all**, which
looks exactly like a model blowing up. Fail fast to the cached registry instead:

```bash
export NIX_CONFIG=$'download-attempts = 1\nconnect-timeout = 3'
```

**And a slow `just verify` is not a symptom either.** The wall time is dominated by
fourteen separate `nix shell` + JVM + SANY-parse startups, not by model checking:
TLC's own reported times for the six green models are 39 s + 00 s + 00 s + 01 s +
01 s + 01 s — 42 s of actual model checking — while end-to-end `just verify` was
recorded at 64 s when the tier was written and measured **6 min 44 s** on an
independent re-run of the same models with identical state counts. Only the state
counts are reproducible; the clock is not.

**`herd7 -version` prints the wrong `Rev:`.** It reports a `git rev-parse` taken in
its build directory, and `get-herd7.sh` builds into `litmus/herd7-opam/` — *inside
this repository* — so the sha it prints is **nim-shm-lease's HEAD**, not
herdtools7's. That is a build-stamp artifact and not a sign of a fake binary; the
`7.58` is real. If you want to satisfy yourself that herd7 is computing verdicts
rather than replaying them, add an `MFENCE` to a copy of
`grant-bump-vs-waiters-x86.litmus` (it must flip to `Never`), drop the `MFENCE`
from a copy of the `-FENCED` form (it must flip to `Sometimes`), and downgrade
`STLR`/`LDAR` to `STR`/`LDR` in a copy of the aarch64 form (it must flip to
`Sometimes`, which is also what makes the ARMv8 "Never" a *result* rather than a
default).

## Coverage boundaries of the RUN items (read this)

- **TLC explores sequentially-consistent interleavings.** It does **NOT** model
  ARMv8 or x86-TSO reordering. Everything above is a property of the *protocol*
  given correct memory ordering. Whether the shipped `ATOMIC_ACQUIRE` /
  `ATOMIC_RELEASE` / `ATOMIC_SEQ_CST` annotations *deliver* that ordering on a
  given architecture is a different question, it is the question the litmus tier
  exists for, and **the litmus tier DID run** — see below, and note that it found
  one of the annotations insufficient. In particular the
  payload/value release-acquire pairing is *assumed* to work in the wait model:
  what that model checks is the **protocol order** (the payload is written before
  the bump at all), which is a different property from the pairing being
  sufficient.

- **The one exception is deliberate and explicit, and herd7 has now confirmed
  it.** `shm_lease_wait.tla` has an optional **one-pair store buffer**
  (`AllowStoreLoadReorder`) that models x86-TSO store-load reordering *for the
  publisher's release-store-then-seq-cst-load pair only*. On its own it could only
  show a window was **reachable under a hand-built approximation** — it is not a
  validated memory model and it could not have pronounced on what x86-TSO or ARMv8
  actually permit. `litmus/grant-bump-vs-waiters-x86.litmus` since ran the same
  shape under herd7's x86-TSO model and returned **Allowed**, and the aarch64 form
  returned **Forbidden**, so the abstraction turned out to agree with the real
  model on the case it was built for. **That agreement is a result, not a
  licence**: the abstraction still must not be quoted for any other pair, and any
  future use of it needs its own litmus test.

- **Sanitizers cannot cover this at all, and that is structural.** TSAN, DRD and
  helgrind shadow by **virtual address**, while every process in this design maps
  the segment at its **own** base — the real multi-process shape, which
  `../tests` deliberately forces with `MAP_FIXED`. They therefore cannot observe
  the cross-mapping ordering. This is the same argument M3's verification already
  accepted for excluding `just test-sanitizers`, and it applies here too. (On this
  host the point is moot anyway: the TSAN binary dies with SIGSEGV and the ASan
  binary hangs in `dyld`.)

- **Two packed fields of radix 4, not four of radix 65536.** The borrow hazard is
  a property of two *adjacent* fields and two adjacent fields exhibit it; four
  would only multiply the state space. `Base` and `Dims` are constants, so a
  reviewer can widen either.

- **Each process holds one reservation at a time.** The real API lets a process
  hold several concurrently, and *that* regime can produce a waits-for cycle even
  with every individual claim ascending: hold word 1, then claim word 0, while
  another process holds word 0 and claims word 1. The spec's ordering argument is
  about a single claim and is checked as such. The cross-transaction regime is
  **not modelled**, and the reason it is not urgent is the same reason the cycle
  is harmless below — a refused claim gives everything back.

- **One grantor.** M5's migrating combiner role, where several processes publish
  grants, is **MV2** and is deliberately out of scope. So are M6 and M7.

- **`Rounds = 2`, three processes, two words, one spurious wakeup.** These are
  bounds, not proofs of unboundedness. The models are parameterised so a reviewer
  can raise them; the claim model at `Rounds = 2` is already 39 s of wall time on
  16 cores.

## What the invariants establish

### CLAIM (`shm_lease_claim.tla`) — MV1 gate item (a)

| Invariant | Establishes |
|---|---|
| `ConservationExact` | **No lost update.** At *every* state and in *every* dimension, `remaining` plus the sum of what every process currently holds equals `capacity`. Two claimants committing decrements computed from the same read would leave `remaining` too high for the set of holders, and this catches it. This is the invariant the step-wise CAS exists to put at risk. |
| `NoOvercommit` | **No overcommit in any dimension**, stated over the *holders* rather than over the word, so it is independent of `remaining` looking plausible. |
| `NoBorrow` | No field of `remaining` ever exceeds the same field of `capacity` — the spec's "a memory over-claim can present as CPU-slot corruption". |
| `NonNegative` | The packed word never underflows. |
| `AllOrNothing` | Between transactions a process holds **nothing**, whether its last claim was granted, refused, or rolled back. |
| `QuiescentRestore`, `ReleasedEqualsClaimed` | **Conservation: total released == total claimed.** Releasing everything restores every word bit-for-bit. |
| `CounterIdentityAtQuiescence` | The accounting identity `claimedUnits - releasedUnits == capacity - remaining`, asserted **only at quiescence** — because the counters are bumped in a *separate step* after the CAS, exactly as the code does it. That the identity is *not* an always-invariant is the spec's warning that "a consumer MUST NOT derive correctness from counters", turned into a checked statement. |
| `NoOverReleaseRefusal` | A process releasing what it holds is never refused by `releaseWord`'s over-release guard. |
| `AscendingHold` | The local form of the ordering rule: everything a claimant holds has a strictly smaller index than the word it is reaching for. |
| `NoHoldCycle` | **Deadlock freedom, and this is the one that was prose.** No cycle in the waits-for relation is reachable. The edge relation is deliberately *generous* — an edge whenever `p` wants a word `q` holds any capacity in, not only when `q`'s holding is what makes `p` refuse — so acyclicity here is stronger than the argument the spec needs. |
| `Termination` (liveness) | No process is ever permanently stuck, by a cycle or by losing its CAS forever. Checked under weak fairness per process. |

### WAIT (`shm_lease_wait.tla`) — MV1 gate item (b)

| Invariant | Establishes |
|---|---|
| `NoLostWakeup` | **No lost wakeup**, stated so it cannot false-positive: the waiter is asleep, no wake is pending for it, the grantor has *finished* so no further wake will be issued, every buffered store has drained, and the word it parked on **has already moved**. Only a spurious wakeup could rescue it, and no platform guarantees one. |
| `WakesLEGrants` | **SM-3, wakes ≤ grants.** No wake amplification. |
| `WakeImpliesGrant` | A waiter leaves the wait **only** because its own word moved forward — never merely because it was woken. Wake-then-retry, which the spec calls a defect rather than an alternative, violates this. |
| `GrantPayloadCoherent` | **The grant-then-wake publish order.** A waiter that observes value *v* reads the payload published *for v*, never the previous grant's. |
| `WaiterCountSane`, `NoWakeWhileUnregistered` | A parked waiter is always counted, which is what makes the waker's `wkNoWaiters` fast path sound. |
| `AllServed` (liveness) | Every published grant is eventually collected **without relying on a spurious wakeup** — `SpuriousWake` is deliberately given **no** fairness, because no platform guarantees one and no protocol may depend on one. |

## The deadlock argument, and what these runs actually show

The spec says: *"Because every claimant takes words ascending, the waits-for
relation is a strict order and no cycle is constructible — that is the entire
deadlock argument."* Running the workload the argument excludes, both ways,
sharpens that into two separate statements:

1. **The ordering rule is what makes the hold graph acyclic — checked.** With
   `EnforceOrder = TRUE` (`csOutOfOrder` shipped), `NoHoldCycle` and
   `AscendingHold` hold. With it dropped, `NoHoldCycle` is **violated by an
   11-state counterexample trace**: p1 holds word 0 and wants word 1 while p2
   holds word 1 and wants word 0. (11 is the *trace length*, which is stable
   across runs; TLC's reported search depth for this run is **not** reproducible —
   13 and 14 were both observed — see the re-run note above.) The cycle really is
   constructible the moment the rule goes, so the rule is load-bearing and not
   stylistic.

2. **The ordering rule is NOT what prevents a deadlock — the rollback is.** On the
   same mutation, with `NoHoldCycle` removed from the invariant list
   (`shm_lease_claim_ord_nocheck_safety_MC.cfg`), **everything else still holds,
   including `Termination`**: 7,349 states, depth 66, green. Dropping the ordering
   rule costs the acyclicity of the hold graph and *nothing else*. A claim never
   parks (SM-8) and a refused claim gives back every word it took, so a cycle
   resolves into mutual refusal rather than into a wedge.

That distinction is worth keeping. The spec's sentence is true about cycles and
is easy to misread as "the ascending order is what stops admission deadlocking".
What stops admission deadlocking is that admission is non-blocking and
all-or-nothing; the ascending order is what stops the *cycle*, which matters
because M5's queue-and-grant path will make holding-and-waiting real.

## FINDINGS — two, and they are the most valuable output of this tier

### Finding 1 (contract defect, real, reproducible on this host)

**`publishGrant` has an unstated precondition: at most one outstanding grant per
slot. Violating it silently loses a grant, and the waiter cannot tell.**

`shm_lease_wait_overwrite_MC.cfg` drops the precondition and TLC violates
`GrantPayloadCoherent` at depth 15. The trace: grant *v* is published to a slot;
before its waiter has read the payload, grant *v+1* is published to the same
slot; `payload` is a **single word** and `value` is a **plain counter**, so the
second write overwrites the first and the waiter — which observed value *v* — reads
grant *v+1*'s payload while re-arming on *v*. It will then wait again, see value
*v+1*, and read the same payload a second time. **One grant is delivered twice and
one is never delivered at all.**

Nothing in `waitword.nim`'s API, its docstrings, or
`RunQuota-Shared-Memory-Structures.md` §"Grant-then-wake ordering" states this
precondition.

**Why this is not yet a live bug — and note that the real reason STRENGTHENS the
finding rather than weakening it.** The precondition is **already violated
in-tree**: `tests/test_shm_lease_wait_multiprocess.nim:257` calls
`publishGrant(ProgressSlot, uint64(parks))` *inside the waiter loop, on every
kernel return, with nothing waiting to consume it* — so the "at most one
outstanding grant per slot" rule is broken on essentially every iteration. It is
harmless **there, and only there**, because of a property of that slot's one
consumer: `awaitProgress` (`:418`) polls `slotPayload(ProgressSlot) >= atLeast`,
a **monotone level rather than a per-grant message**, and never touches that
slot's wait word at all — so an intermediate value that gets overwritten is
simply unobservable. Every site that *does* treat a payload as a **distinct
grant** happens to publish one at a time: `benchmarks/bench_wait.nim` is a
strictly alternating ping-pong, and `src/shm_lease/obsring.nim:625` uses
`bumpAndWake`, which carries no payload at all.

So the accurate statement is not "nobody violates the precondition" — somebody
already does — but "the one violating call site is safe by an **undocumented
property of its consumer**". That is a weaker foundation than a stated
precondition, and it is a second reason to write the precondition down.

It is also not exploitable by a waiter — but it is a **direct constraint on
M5's arbiter**, whose MV2 gate already lists "no double grant" as a property to
prove. Two remedies exist and MV2 should pick one deliberately: have the arbiter
grant only to a slot whose previous grant is provably consumed (what
`OneOutstandingPerSlot = TRUE` models, and what the shipped runs above assume), or
couple the payload to the value so a stale pair is detectable.

### Finding 2 (the `:first_target:` ordering claim — the docstring is wrong)

**`waitOn`'s stated justification for its lost-wakeup freedom does not hold, and
the model shows the window is not excluded by the protocol.**

The docstring says: *"Sequential consistency on both accesses gives a single total
order in which at least one of the two must observe the other."* But the
publisher's two accesses are **not** both seq-cst — `publishValue` performs an
`ATOMIC_RELEASE` store of `value`, and only the load of `waiters` in `wakeAll` is
seq-cst. So the SC argument does not apply to that pair, which is exactly what
MV1's `:first_target:` suspects.

Under the explicit one-pair store-buffer abstraction
(`shm_lease_wait_tso_MC.cfg`), TLC violates `NoLostWakeup` at depth 25 — and with
deadlock checking left on it reports **`Deadlock reached`** at depth 24, because
the wedged state has no successor at all. The counterexample is exactly the
sequence the code's own comment says cannot happen:

1. the publisher issues the release store of `value` (buffered, not yet visible);
2. the publisher's seq-cst load of `waiters` reads **0** and it **skips the wake
   syscall**;
3. the waiter increments `waiters` to 1;
4. the waiter's re-check loads `value` and sees the **old** value, because the
   publisher's store is still in the buffer;
5. the waiter parks; the **kernel's compare-and-park also reads the old value**
   and puts it to sleep;
6. the store drains. `value` has moved, a grant is outstanding, and nobody will
   ever wake it.

**The remedy is already used elsewhere in this same library.**
`shm_lease_wait_tso_fence_MC.cfg` adds a seq-cst fence between the bump and the
load of `waiters` — the Dekker pairing `src/shm_lease/obsring.nim` **already
applies** to its structurally identical idle-token / `tail - head` pair, with an
explicit `atomicThreadFence(ATOMIC_SEQ_CST)` on both sides "rather than relying on
whatever ordering a particular CAS mapping happens to emit on ARM64" (M4's
`:result:`). With the fence, the model is green: 23,141 states, depth 46. So the
library contains both the pattern and its fix, applied inconsistently.

**HERD7 SETTLED IT, so this is no longer a modelling argument.** The TLA+ result
alone would only have shown the window is *not excluded by the protocol*, leaving
the architecture to decide. herd7 was built from source (see the litmus section)
and asked directly:

| | C11 | x86-TSO | ARMv8 |
|---|---|---|---|
| shipped: `release` store of `value`, then seq-cst load of `waiters` | **Allowed** | **Allowed** | **Forbidden** |
| remedy: seq-cst store, or `MFENCE` between the pair | **Forbidden** | **Forbidden** | (already forbidden) |

**The precise, defensible statement.** The shipped code is **correct on ARMv8**,
which is the only architecture it has ever run on, because `STLR;LDAR` is RCsc and
the LDAR cannot be hoisted above the STLR. It is **not correct on x86-TSO**, where
the lost wakeup is architecturally permitted, nor under C11, where it is permitted
outright. And `waitOn`'s docstring gives the wrong reason for the correctness it
does have: it appeals to sequential consistency over a pair in which one access is
only `ATOMIC_RELEASE`, so the argument it makes is unavailable on every one of the
three models.

**What to do about it is not MV1's call**, and MV1 deliberately does not change
the code: this milestone is a verification tier, and a one-word memory-order change
on the wake path wants its own commit, its own gate re-run and its own record.
What MV1 hands over is (a) the defect, (b) two remedies each confirmed Forbidden by
herd7, and (c) the observation that `src/shm_lease/obsring.nim` **already applies**
one of them to a structurally identical pair — so the fix is a consistency change
within the library rather than a new technique. The Linux arm (MP1) is where the
x86 exposure becomes real; the docstring is wrong **today** on every platform and
is the more urgent half.

## The litmus tier (MV1 gate item (c)) — RAN

**herd7 is not in nixpkgs on aarch64-darwin.** Re-probed 2026-08-17, confirming
MV1's `:tooling:` record — `herdtools7`, `herdtools`, `herd7`, `litmus7`, `diy`,
`ocamlPackages.herdtools7` and `genmc` all fail to resolve. So `:tooling:`'s
route 1 was taken: **herdtools7 7.58 was built from source through opam against
the nixpkgs OCaml**, and `litmus/get-herd7.sh` is the recipe that worked, with
the two non-obvious steps recorded (`--packages=ocaml-system` to reuse the
nixpkgs OCaml instead of compiling one; `nix-shell -p` rather than `nix shell`,
so GMP's headers and pkg-config file are real build inputs). It took about
20 minutes including three failed attempts.

Wired as `just verify-litmus`. **`litmus/run-litmus.sh` CHECKS EVERY VERDICT** and
fails if any test does not produce the required one — necessary because four of
these tests are required to be **Allowed**, and a runner that only knew how to
report "Never" would have silently converted its own controls into passes.

| Test | Model | Required | **RAN** |
|---|---|---|---|
| `grant-payload-publish` | C11 | Never | **Never** |
| `grant-payload-publish-aarch64` | AArch64 | Never | **Never** |
| `grant-payload-publish-RELAXED-control` | C11 | **Sometimes** | **Sometimes** |
| `grant-payload-publish-aarch64-RELAXED-control` | AArch64 | **Sometimes** | **Sometimes** |
| `grant-payload-publish-x86-RELAXED-control` | x86-TSO | Never | **Never** |
| `header-magic-publish` | C11 | Never | **Never** |
| `header-magic-publish-aarch64` | AArch64 | Never | **Never** |
| `budget-cas-atomicity` | C11 | Never | **Never** |
| `grant-bump-vs-waiters` | C11 | **Sometimes** | **Sometimes** |
| `grant-bump-vs-waiters-x86` | x86-TSO | **Sometimes** | **Sometimes** |
| `grant-bump-vs-waiters-aarch64` | AArch64 | Never | **Never** |
| `grant-bump-vs-waiters-SEQCST-fix` | C11 | Never | **Never** |
| `grant-bump-vs-waiters-x86-FENCED` | x86-TSO | Never | **Never** |

### The controls are the point, and one of them is a lesson

`grant-payload-publish` is Forbidden and its **relaxed control is Allowed**, so
the "Never" is bought by the release/acquire annotations rather than coming free.

The three-way payload control is worth reading on its own, because it states the
trap this whole tier exists for as three verdicts instead of as a warning. The
*same* relaxed message-passing code is:

- **Allowed (buggy) on ARMv8** — `grant-payload-publish-aarch64-RELAXED-control`
- **Forbidden (invisible) on x86-TSO** — `grant-payload-publish-x86-RELAXED-control`

So downgrading those orders is **undetectable by any amount of x86 testing** and
unsound on the architecture this library actually ships on. That is why the
release/acquire pair in `publishGrant` is load-bearing, and why dynamic evidence
gathered on one architecture is not evidence about another.

### `:first_target:` — SETTLED

MV1 said: *"A herd7 litmus test for exactly this store-load pair, run under both
TSO and ARM8 models, settles it in an afternoon and is the natural first artifact
of this tier."* It did. The verdicts:

| | C11 | x86-TSO | ARMv8 |
|---|---|---|---|
| shipped: `release` store of `value`, then seq-cst load of `waiters` | **Allowed** | **Allowed** | **Forbidden** |
| remedy: seq-cst store / `MFENCE` between the pair | **Forbidden** | **Forbidden** | (already forbidden) |

**The suspicion in `:first_target:` was correct, and it is now a measurement.**
The code is safe on ARMv8 — but for the reason `:first_target:` guessed (`STLR;LDAR`
is RCsc, so the LDAR cannot be hoisted above the STLR), **not** for the reason its
docstring gives. On x86-TSO the lost wakeup is **architecturally permitted**, and
under C11 it is permitted outright. See "Finding 2" below.

## Also NOT run here

- **GenMC / Nidhugg / CDSChecker (gate item (e))** — `genmc` is absent from
  nixpkgs entirely, and unlike herdtools7 it is not an opam package, so the route
  that worked for herd7 does not exist for it. **Deferred to MP1.**
- **The standalone C11 core (gate item (d), optional)** — not written. Its two
  possible consumers on this host are GenMC (absent, above) and TSAN, and TSAN
  does not run here at all: the TSAN binary dies with SIGSEGV before `main` and
  the ASan binary hangs in `dyld`, reproduced under M3 and unchanged. A C11 core
  that nothing on this host can check would have been an artifact whose only
  status could be "authored, unrun" — and with the litmus tier now actually
  running, the ordering questions it would have carried are answered by herd7 at
  the level of the memory model rather than by a program nobody can check. MP1 is
  the place for it, together with GenMC.
- **valgrind DRD / helgrind, rr chaos** — the sibling runs these; `valgrind` does
  not work on modern macOS arm64 and `rr` is Linux-only.

## Files

- `tla/shm_lease_claim.tla` — the claim protocol: packed word as a real packed
  integer, three-step CAS (read / test / CAS), descending rollback and release,
  counters bumped in a separate step. Constants `PerFieldFit` and `EnforceOrder`
  select the shipped rule or its mutation.
- `tla/shm_lease_claim_MC.{tla,cfg}` — 3 processes, 2 words, the shipped rules.
  `_MC_probe.cfg` is the non-vacuity companion.
- `tla/shm_lease_claim_ord_MC.tla` + 4 cfgs — the deadlock argument, run both
  ways: enforced (green), the refusal actually firing (probe), the cycle reachable
  without it (violation), and everything-but-acyclicity still holding (green).
- `tla/shm_lease_claim_borrow_MC.tla` + 2 cfgs — the per-field fit test, run both
  ways on one word with two processes.
- `tla/shm_lease_wait.tla` — the wait protocol: kernel compare-and-park as its own
  step, a wake that only wakes an actually-parked waiter, unfair spurious wakeups,
  and the optional one-pair store buffer. Constants `PayloadFirst`,
  `AllowStoreLoadReorder`, `FenceAfterBump`, `OneOutstandingPerSlot`.
- `tla/shm_lease_wait_MC.tla` + 6 cfgs — shipped, non-vacuity probe, publish-order
  mutation, the grant-overwrite finding, the TSO finding, and the fence remedy.

Fourteen configurations in total: **6 green** and **8 required to fail**, which is
the whole set `just verify` runs.
- `litmus/*.litmus` — 13 herd7 tests across the C11, x86-TSO and AArch64 models:
  the grant-payload publish pair and its relaxed controls on all three models, the
  publish-before-write pair, RMW atomicity, and the `:first_target:` store-load
  pair with two confirmed remedies.
- `litmus/run-litmus.sh` — runs them and **checks every verdict**, including the
  four that must be *Allowed*.
- `litmus/get-herd7.sh` — builds herdtools7 7.58 through opam where nixpkgs has no
  package for it, which is the case on aarch64-darwin.
