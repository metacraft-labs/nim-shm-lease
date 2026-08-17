# nim-shm-lease — formal / weak-memory verification tier (campaign milestones MV1 + MV2)

This directory is the **formal** verification tier for the multi-process,
file-backed lease structures in `../src/shm_lease.nim`,
`../src/shm_lease/packed.nim` and `../src/shm_lease/waitword.nim`. It is the
complement to the *dynamic* verification in `../tests` (77 tests: the M2
differing-base claim gate, the M3 block/wake gate, the M4 ring gate,
deterministic schedule-hook interleavings, mutation-tested assertions), and it
exists because those tests **sample** the schedule space and cannot exhaust it.

**MV2 is a different kind of entry and it is worth naming the difference.** MV1
modelled code that had already shipped. `tla/shm_lease_combine.tla` models the
M5 flat-combining arbiter **before M5 exists**, so it is not a description of
anything in `../src` — it is a *constraint on what M5 may be written as*. Four of
its results (Findings 3 to 6 below) are layout and algorithm requirements that
would each have been expensive to discover from a running implementation, and one
of them — that the commit and the role transfer must be resolved by a single CAS
on a single word — is not expressible as a patch at all once the words are in
use.

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
| **MV2** COMBINER, 2 processes, death at every step of a round | `shm_lease_combine_MC.cfg` | **2,600** | **38** | **RAN — green.** 11 invariants + `AllSettled` |
| **MV2** COMBINER, the FALSE-POSITIVE STEAL: descheduled, stolen from, resumed | `shm_lease_combine_stall_MC.cfg` | **10,352** | **43** | **RAN — green.** Same 11 + `AllSettled` |
| **MV2** COMBINER, TWO faults, so the *recovering* round may also be abandoned | `shm_lease_combine_f2_MC.cfg` | **79,487** | **51** | **RAN — green.** Same 11 + `AllSettled` |
| **MV2** COMBINER, safety under an arbitrarily wrong steal detector | `shm_lease_combine_live_MC.cfg` | **1,325,806** | **55** | **RAN — green.** 10 invariants, safety only (see below) |
| **MV2** COMBINER, Finding 4's mutation vs. every NON-GHOST invariant | `shm_lease_combine_unfenced_damage_MC.cfg` | **339,869** | **54** | **RAN — green.** 9 invariants + `AllSettled`. This one is green **on purpose** — see Finding 4 |

**The last row is a green run on a MUTATION, and that is deliberate.**
`shm_lease_combine_unfenced_damage_MC.cfg` runs Finding 4's `CommitFencedByRole
= FALSE` — the same constants as the required-to-fail
`shm_lease_combine_unfenced_MC.cfg` — against every invariant stated over **real
state** rather than over the `eres`/`edisc` ghosts. Its greenness is the
*boundary* of Finding 4: the mutation breaks the gate's exactly-once resolution
clause and does **not** break any damage clause, and the finding is written at
that precision. See Finding 4.

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
| **MV2** non-vacuity | `shm_lease_combine_MC_probe.cfg` | `ProbeAllReached` | 37,755 | 29 |
| **MV2** non-vacuity | `shm_lease_combine_resume_probe.cfg` | `ProbeResumeReached` | 374 | 12 |
| **MV2** non-vacuity | `shm_lease_combine_pub_probe.cfg` | `ProbeDiedMidPublish` | 727 | 14 |
| **MV2** MUTATION | `shm_lease_combine_nosteal_MC.cfg` | **`Deadlock reached`** | 71 | 7 |
| **MV2** MUTATION | `shm_lease_combine_counter_MC.cfg` | `NoDoubleGrant` | 8,672 | 30 |
| **MV2** MUTATION | `shm_lease_combine_noserial_MC.cfg` | `NoDoubleGrant` | 16,537 | 32 |
| **MV2** MUTATION | `shm_lease_combine_fit_MC.cfg` | `NoOvercommit` | 427 | 13 |
| **MV2 FINDING** | `shm_lease_combine_budget_MC.cfg` | `BudgetExact` | 6,310 | 27 |
| **MV2 FINDING** | `shm_lease_combine_unfenced_MC.cfg` | `NeverBoth` | 669 | 14 (13-state trace) |
| **MV2 FINDING** | `shm_lease_combine_livelock_MC.cfg` | `EpochBoundNotBinding` | 1,491 | 11 |

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

**So for the eighteen violating rows the only invariant thing is the NAMED
INVARIANT** — which invariant TLC reports, and nothing else. That is precisely
what `just verify-tla-negative` asserts, and it was confirmed for all eighteen. A
verifier who sees a different *Explored* count, or a different *Depth*, has not
found a discrepancy. A verifier who sees a different *invariant* named, or no
violation at all, has. The MV2 rows drift for the same reason and by the same
sort of margin — `shm_lease_combine_MC_probe` was observed at 37,755, 38,647 and
39,489 explored across three runs — while every one of the ten named invariants
came back identical every time.

**One MV2 negative row moved for a reason that is NOT drift, and it is recorded
here so nobody mistakes it for one.** `shm_lease_combine_unfenced_MC` was
originally tabled at 466 explored / depth 13. The model has since been corrected
so that `CommitFencedByRole = FALSE` toggles the acquirer's discard **read**
along with the commit **write** (see Finding 4), which changes the reachable
ghost states and therefore the graph. It still violates `NeverBoth`, now with a
**13-state counterexample trace** at a reported search depth of **14**, and the
trace is a materially better one — the violation is now witnessed in real state
rather than by a mislabelled ghost.

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
the separate `nix shell` + JVM + SANY-parse startup each configuration pays, not
by model checking: TLC's own reported times for MV1's six green models are
39 s + 00 s + 00 s + 01 s + 01 s + 01 s — 42 s of actual model checking — while
end-to-end `just verify` was recorded at 64 s when the tier was written and
measured **6 min 44 s** on an independent re-run of the same models with
identical state counts. MV2 added five green models and ten negatives for about
26 s more of actual checking (the 1.3-million-state detector run is 10 s of it
and the 340-thousand-state Finding 4 damage run 11 s); `just verify-tla`
measured **1 min 18 s** end to end, `just verify-tla-negative` **26 s**, and the
whole `just verify` — twenty-nine TLC configurations plus sixteen herd7 tests —
**1 min 44 s**, which is *faster* than MV1's independently re-measured 6 min 44 s
for a third as many models. That is the point about the clock: it is measuring
`nix shell` and JVM startup and the state of `channels.nixos.org`, not the
checking. Only the state counts are reproducible.

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

- **One grantor — in the WAIT model only.** M5's migrating combiner role, where
  several processes publish grants, is **MV2** and is modelled separately in
  `tla/shm_lease_combine.tla`. The two models **compose rather than overlap**:
  MV2 says *which* grant is published and *how many times*, MV1 says the waiter
  cannot sleep through it. MV2 does **not** re-model the kernel's
  compare-and-park, the pre-park window, spurious wakeups or the waker's fast
  path — it keeps only the two-step payload-then-value publication, because that
  is the only part of the wait protocol its invariants depend on.

### Coverage boundaries specific to MV2

- **Two processes, capacity 2, one budget dimension.** Two is the minimum that
  makes the role *migrate*, and therefore the minimum at which a steal exists at
  all. One dimension is deliberate: the packed-borrow hazard is MV1's ground
  (`NoBorrow`) and re-modelling it here would multiply the graph to re-prove a
  property already proved. What MV2 is about is *whose* arithmetic runs and
  whether it survives a death.

- **At most two faults.** `MaxFaults` bounds deaths *and* stalls together. At
  one, a single round is abandoned in a single way. At two — `*_f2_MC.cfg`,
  79,487 states — the round that *recovers* a dead combiner's work may itself be
  abandoned, which is what reaches nested failure and what forced the recovery
  step to be written as a stateless idempotent sweep of the ledger rather than
  as "recover the previous epoch" (that formulation does not compose: a stealer
  that dies while recovering leaves two epochs to recover, and the next stealer
  would have to know how many). **Three faults are not run**, and with two
  processes a third fault can only re-kill an already-dead process or add a
  second stall to the same round, so what it would add is graph rather than
  protocol. That is an argument, not a proof; `MaxFaults` is a constant.

- **`MaxEpochs = 5`, and the bound is CHECKED rather than assumed.**
  `EpochBoundNotBinding` (`role.epoch < MaxEpochs`) is an invariant of every
  green configuration, so if those runs are green the bound was never reached
  and excluded nothing from them. The one configuration where it *is* binding is
  `shm_lease_combine_live_MC.cfg`, and there it is binding for a reason that is
  itself a finding (Finding 5) rather than an artefact.

- **One request per process per behaviour.** A slot is never reused for a second
  request, so **requeue-after-refusal is not modelled**. That is a real
  exclusion: M6's anti-starvation gate needs a refused request to *stay* queued
  and be re-decided in a later round, and MV2 does not check that it can.
  Nothing in the protocol precludes it — a requeue is a fresh proposal into a
  slot whose entry is stamped with an older epoch, which the raise pass already
  handles — but "does not preclude" is weaker than "checked", and M6 should
  extend the model rather than assume this sentence.

- **Reclamation is out of scope.** A dead process's granted capacity stays taken
  here. That leak is SM-6 and M7; modelling it would confuse "the combine
  conserved capacity" with "the owner gave it back".

- **The steal detector is an ORACLE, not a timeout.** `Steal` is enabled when the
  role holder is not currently runnable, and — under `StealFromLive` — even when
  it is. So the model never assumes the detector is *accurate*; it assumes only
  that one *exists*. Bounding the timeout, and the boot-id + pid + start-time
  anchor check that feeds it, are M7's.

- **`Die` is enabled at every program counter at which a request is
  outstanding — which is not quite "every program counter", and the difference
  is worth stating.** `Die(p)` requires `pc[p] # "idle"` **and**
  `alive[p] = "live"`, so there are two exclusions. `idle` is excluded and it is
  immaterial: nothing is published there, the process holds nothing, and killing
  it is indistinguishable from its never having run. `stalled` is excluded from
  `Die` *directly*, but "descheduled and then killed" is still reachable as
  `Stall` → `Resume` → `Die` — at the cost of **two** faults. So that sequence is
  reachable only where the fault budget allows two, which is the three
  configurations `shm_lease_combine_MC_probe.cfg`, `shm_lease_combine_f2_MC.cfg`
  and `shm_lease_combine_unfenced_damage_MC.cfg`; **no `MaxFaults = 1`
  configuration can reach it.**
  Everything in between is covered: death at each of the seven combiner program
  counters, death *between* the payload store and the value bump (separately
  probed by `*_pub_probe.cfg`), and death while a waiter is mid-collection.

- **Cross-slot misdelivery is not representable.** Slots are addressed by their
  owner, so "a waiter receives a grant meant for another **waiter**" cannot occur
  by construction and `GrantCoherent` is not about that reading. The other
  reading of the gate's clause — a waiter receiving a grant meant for another
  **request** — is representable, is what `GrantCoherent` checks, and has two
  failing configurations.

- **The atomisation, enumerated — because an earlier version of this paragraph
  disclosed it falsely, and a false disclosure is worse than none.** Each
  shared-word *write* is one TLA+ step, which is exactly what the hardware gives
  for an aligned `u64`, so injecting death *between* steps really is death at
  every point. But a guard and its write are in the **same** step, and it is
  **not** true — as this section previously claimed — that "the model does not
  atomise across two words anywhere", nor that "every such pair is a CAS on a
  single word". Only **two** actions are single-word guard-and-write: `CCommit`
  (fenced branch), which tests `role = [me, e, FALSE]` and writes `[me, e, TRUE]`,
  and `CRelease`. **Eight read a shared word other than the one they write:**

  | Action | Reads | Writes | Why the atomisation is defensible — *stated, not checked* |
  |---|---|---|---|
  | `SeqRepair` | `role` (commit bit + epoch), `cseq` | `cseq` | **Monotone idempotent repair.** The value written is an epoch the role word says committed, and the write is a max-store. A race writes the same value twice; a stale read of `cseq` can only be *lower* than the truth, and `cseq` never moves backwards, so a stale repair is a no-op rather than a regression. |
  | `CSeq` | `role`, `cseq` | `cseq` | Same operation as `SeqRepair`, by construction — the round runs the public repair rather than a private variant. Same argument. |
  | `TryRole` / `Steal` (`TakeRole`) | `role`, `cseq`, `reqst`, `wire` | `role` | **The write IS the CAS on the word the guard reads.** `role` is read and CAS'd with that exact expected value, so an interfering acquisition invalidates it. The other three reads are advisory: `WorkPending` (`reqst`, `wire`) is a liveness heuristic — reading it stale costs a wasted round or a missed acquisition, never correctness — and `~SeqNeedsRepair` (`cseq`) is safe by monotonicity, since `cseq` only rises and a risen `cseq` only makes the guard *more* satisfied. |
  | `CRaiseOne` | `res[q]`, `cseq` | `res[q]` | **Epoch-stamped CAS.** The expected value carries `res[q].epoch`; any interfering writer had to acquire the role, which bumps the epoch and restamps, so the CAS fails rather than corrupts. The `cseq` read is *frozen* (below). |
  | `CDecide` | the **entire ledger** (`res`), `cseq` | `res[q]`, and `budget` too under `BudgetIsCache = FALSE` | **Epoch-stamped CAS on the entry, frozen `cseq` for the fit test.** This is the weakest of the eight and the one M5 must be written against most carefully: a real combiner reads N ledger words in a loop, not in one step. What makes the loop stable is that the entries it sums are either effective (stamped `≤ cseq`, and `cseq` is frozen) or this round's own proposals — and any process that could change either had to take the role, which fences this combiner out of its own subsequent CAS. **Under `BudgetIsCache = FALSE` this step writes two shared words in one step**, which is precisely the shape Finding 6 says must not exist. |
  | `CRefresh` | the **entire ledger**, `cseq` | `budget` | **The written word is a self-healing cache.** No correctness property is stated over `budget` outside quiescence (`BudgetExact` is guarded by `Quiet`); `NoOvercommit` and `GrantedEqualsTaken` are stated over the ledger. A torn recomputation is corrected by the next combiner's, and by construction there is one before the next quiescent state. |
  | `CPubPayload` | `res[q]`, `cseq` | `wire[q]` (payload) | **Epoch-stamped read into a slot only its round may publish.** The payload written is tagged with the entry's epoch, so a stale publisher writes a *stale tag* rather than an untagged word, and `GrantCoherent` is exactly the check that a stale tag is caught. |
  | `CPubValue` | `wire[q]` (payload tag) | `wire[q].val` (wait word) | **The tag it reads is necessarily the value it wrote.** Under the shipped rules an effective, uncollected entry cannot be restamped (`SerialisePerSlot`) and a republication of the same entry writes the same tag (`IdempotentPublish`), so the re-read cannot observe a different round's tag. A real publisher carries the value in a register instead; under the *mutations* the model's re-read is the more forgiving of the two, which only makes those mutations harder to fail and so does not manufacture their violations. |

  **The two class arguments the table leans on.** *Epoch stamps:* every mutation
  of `role` and of `res[q]` is a CAS whose expected value carries an epoch, and
  every acquisition — clean or stolen — increments that epoch, so an interfering
  writer necessarily invalidates the expected value and the stale write **fails**
  rather than corrupting. *Frozen `cseq`:* `cseq` advances only in `SeqRepair`
  and `CSeq`, both guarded by `SeqNeedsRepair`, which requires the role word's
  commit flag — and a round in flight cleared that flag in its own `TakeRole`. So
  for the whole of a live, unstolen round `cseq` cannot move, and every read of
  it inside the raise and scan passes sees one value. If the round *is* stolen,
  the epoch-stamp argument takes over.

  **None of this is checked.** These are arguments about what an M5
  implementation would have to do to make each atomised step faithful; TLC checks
  the atomised model, not the arguments. Four further actions — `CRaiseDone`,
  `CScanDone`, `CPubDone`, `CAbort` — read shared state and write only `pc`,
  which is process-local, so they are pure reads and are not in the table; a
  stale read there causes a spurious loop iteration, which is why `CAbort` exists
  at all. **Any M5 step that reads its guard from one word and writes another
  without one of the arguments above is outside what was checked**, which is the
  general form of Finding 4.

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

### COMBINER (`shm_lease_combine.tla`) — the MV2 gate, modelled before M5 exists

The protocol the model pins, in the two words the layout already reserves:

- **Role word** (`LhOffReserved2`, offset 96) = `[owner, epoch, committed]`, one
  u64, CAS-mutated. The epoch increases on **every** acquisition, clean or
  stolen. The commit flag lives **inside** this word, which is one of the two
  ways to satisfy Finding 4's requirement that the commit and the role transfer
  be resolved by a single CAS on a single word — see Finding 4.
- **Combine sequence** (`LhOffReserved3`, offset 104) = the highest **committed**
  epoch, monotone. A ledger entry is *effective* iff its stamp is `<= cseq`, so
  this one word is both the durable answer to "was this round applied" and the
  switch that makes a whole round take effect at once.
- **Per-slot ledger entry** = `[epoch, dec, amt]`, one u64, and **every** mutation
  of it is a CAS whose expected value carries an epoch.
- **Budget word** = a *cache* of `Capacity − Σ effective grants`, recomputed and
  never incrementally mutated — see Finding 6.
- **Published value** = the round's **epoch**, not a counter bump, which is what
  makes republication after a steal idempotent.

| Invariant | Establishes |
|---|---|
| `NoDoubleGrant` | **No request is granted twice.** The gate's headline property and the one MV1 handed over unresolved. It has **two** failing configurations because it needs **two** independent mechanisms — see Finding 3. |
| `GrantCoherent` | **No waiter receives a grant meant for another request.** A waiter that observes value *v* reads the payload published *for v*. MV1's `GrantPayloadCoherent` restated for an arbiter that publishes repeatedly into per-waiter slots. |
| `NoOvercommit` | **No capacity conjured**, stated over the *committed ledger* rather than over the budget word, so it does not depend on that word looking plausible. |
| `NonNegative` | The budget word never underflows. |
| `BudgetExact` | **No capacity conjured or destroyed across a combine.** At every quiescent state — role free, no round in flight — the budget word equals exactly what the committed ledger says is left. A round that was half-applied and then discarded must leave **no** trace. This is the invariant Finding 6 breaks. |
| `GrantedEqualsTaken` | **What is granted is exactly what was taken from the budget.** Every grant a waiter believes it holds is a committed ledger entry of exactly that amount, so no waiter proceeds on a grant the budget never paid for. |
| `NeverBoth` | **A stealer either completes or discards a half-applied round — never both.** A round marked discarded has no effective decision; a round marked completed has committed; and no epoch is ever both. This is the invariant Finding 4 breaks — and it is stated over the `eres`/`edisc` ghosts, so read Finding 4 for what a violation of it does and does not entail. |
| `StealResolvesExactlyOnce` | The **never neither** half: at quiescence, no epoch that decided anything is left unresolved. |
| `NoDiscardOfCollected` | **No lost request**, safety half: an outcome a waiter has already collected and is acting on is never erased from the ledger behind it. |
| `EpochBoundNotBinding` | **`MaxEpochs` excluded nothing**, checked rather than asserted — see the bounds section. It is also what detects unbounded role churn, which is Finding 5. |
| `AllSettled` (liveness) | **No lost request, and no deadlock when the role holder vanishes.** Every published request is eventually granted or refused *and the answer reaches its waiter*, no matter where the combiner died. Dead processes are excused; nobody else is. |

**Two of these have only one failing configuration each, and one has none.**
`StealResolvesExactlyOnce` survives all ten mutations: they break "never both",
not "never neither", and `NeverBoth` is where that pair's teeth are. Recording
that is better than inventing a mutation to manufacture a failure for it.
`shm_lease_combine_noserial_MC` was additionally re-run with each invariant
alone, because TLC reports only the first: `NoDoubleGrant` (32-state trace),
`GrantCoherent` (29), `NoDiscardOfCollected` (20) **and** `GrantedEqualsTaken`
(20) each fail on it independently, and they do **not** witness the same thing —
see Finding 3's table, which had this wrong in an earlier draft. Meanwhile
`shm_lease_combine_counter_MC` fails `NoDoubleGrant` and `GrantCoherent` only —
which is itself the evidence that the two mutations break *different* things.

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

## FINDINGS — six, and they are the most valuable output of this tier

Findings 1 and 2 are MV1's, about code that had already shipped. Findings 3, 4,
5 and 6 are MV2's, about code that **does not exist yet** — which is the whole
argument for modelling before implementing, so it is worth being concrete about
what each would have cost to find later.

**This numbering is the only one, and every cross-reference in
`tla/*.tla`, `tla/*.cfg` and the milestone record uses it.** An earlier draft
carried a second, *local* MV2 numbering in the model and two of its configs — in
which "FINDING 1" meant the budget word and "FINDING 2" meant the commit flag —
while citing this file, where 1 and 2 are MV1's. Those citations resolved to the
wrong findings and have been reconciled.


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
in-tree**: `tests/test_shm_lease_wait_multiprocess.nim:266` calls
`publishGrant(ProgressSlot, uint64(parks))` *inside the waiter loop, on every
kernel return, with nothing waiting to consume it* — so the "at most one
outstanding grant per slot" rule is broken on essentially every iteration. It is
harmless **there, and only there**, because of a property of that slot's one
consumer: `awaitProgress` (`:427`) polls `slotPayload(ProgressSlot) >= atLeast`,
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
prove. MV1 posed two remedies and asked MV2 to pick one: have the arbiter grant
only to a slot whose previous grant is provably consumed (what
`OneOutstandingPerSlot = TRUE` models, and what the shipped runs above assume), or
couple the payload to the value so a stale pair is detectable.

> **ANSWERED BY MV2, AND THE ANSWER IS "BOTH".** The either/or was the wrong
> shape. The two remedies close **different** failure modes, each has its own
> required-to-fail configuration, and neither covers for the other. See
> **Finding 3** below.

### Finding 2 (the `:first_target:` ordering claim — the docstring is wrong)

> **RESOLVED 2026-08-18, in a commit separate from this tier.** `wakeAll` and
> `wakeOne` now execute `fullFence()` — `atomicThreadFence(ATOMIC_SEQ_CST)` —
> immediately before loading `waiters`, and `waitOn`'s docstring now names that
> fence as the reason instead of appealing to a sequential consistency it does not
> have. The waiter side deliberately got **no** fence; its seq-cst RMW already
> orders that side, and `grant-bump-vs-waiters-WAITER-FENCE-ONLY-control.litmus`
> shows a waiter-side fence would have fixed nothing. Three new litmus tests pin
> the shipped fenced pair under C11, x86-TSO and AArch64 (all required
> **Forbidden**), and the two tests below that report **Allowed** are kept beside
> them so the Forbidden verdicts are bought by the fence rather than free.
> The models cannot detect a source regression — that is
> `tests/check-fence-shape.sh`'s job, wired into `just test`; see the litmus table
> below. Measured cost on the wake fast path: 2.42 → 2.44
> ns/op (arm64; `dmb ish`), with SM-2 still at **zero syscalls**. Everything in
> this section describes the code **as MV1 found it**.

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

### Finding 3 (MV2) — "serialise per slot" vs "carry a sequence number" is a FALSE CHOICE, and M5 needs both

MV1 left this open and MV2's gate promised to settle it. It is settled, and the
answer is not either of the two options as posed.

**The two mechanisms fail on different questions.**

| | The question it answers | Its failing configuration | What breaks without it |
|---|---|---|---|
| **Serialise per slot** — never decide a request whose previous outcome is committed and not yet superseded | *"May I grant into this slot?"* | `shm_lease_combine_noserial_MC.cfg`, `NoDoubleGrant` at depth 32 | A request that has **already been collected** is re-decided and granted a second time. The payload is **one word**; no stamp recovers a word that has been overwritten. A sequence number makes the loss **detectable**, not survivable. |
| **Carry the round sequence in the published value** — publish the epoch, not `val + 1` | *"Did the corpse already publish this?"* | `shm_lease_combine_counter_MC.cfg`, `NoDoubleGrant` at depth 30 | A stealer completing a committed round cannot tell whether the dead combiner already published, republishes, and the counter bumps twice. Serialisation cannot help: the slot **is** serialised, and the grant is still delivered twice. |

**Which witness belongs to which damage, because an earlier draft of that first
row got it wrong.** Dropping serialisation damages a slot in two ways and they
are *not* witnessed by the same invariant:

- **Re-grant of an already-collected request** — the waiter reads its grant, the
  next round re-decides the slot and grants it again, and one request is
  answered twice. **This** is what `NoDoubleGrant` witnesses, at a 32-state
  trace, and it is the only one of the two that is literally a double grant.
- **Overwrite of an uncollected first grant** — a second grant lands in a slot
  whose waiter has observed the value but not yet read the payload. This
  **cannot** violate `NoDoubleGrant`: a waiter that never read the first
  collects exactly once. It is witnessed by **`GrantCoherent`** (29-state trace:
  the waiter observed value *v* and reads a payload tagged for a later round),
  and the erasure behind a waiter that is already acting on its outcome is
  witnessed by `NoDiscardOfCollected` and `GrantedEqualsTaken` (20 states each).

Both are consequences of serialisation being absent and both are reasons to keep
it; the substance of "serialise is separately required" is unaffected. What was
wrong was only the name of the invariant that catches the second one.

So the shipped model runs with `SerialisePerSlot = TRUE` **and**
`IdempotentPublish = TRUE`, and each mutation is the proof that the other
mechanism does not cover for it. Note that the second is a **change to
`publishGrant`'s contract**, not merely to its callers: `wire.val := wire.val + 1`
is what the code does today, and it is the reason MV1's precondition exists at
all. Publishing the round's epoch instead makes republication a no-op — the
waiter's word does not move, so there is no second wake and no second collection
— which is what turns crash recovery from "did I already do this?" into a
question nobody has to ask.

**The concrete instruction to M5.** The wait slot's `value` field is already
documented as "a grant sequence" (`RunQuota-Shared-Memory-Structures.md`, wait
slot offset 0). Make it one: publish the **combine epoch**, and make the payload
carry the same epoch as its tag. Then keep the per-slot serialisation rule
anyway, and state it as a precondition rather than leaving it to be inferred.

### Finding 4 (MV2) — the commit and the role transfer MUST be resolved by ONE CAS on ONE word, and that is a LAYOUT constraint rather than an algorithm choice

**This is the most valuable single output of MV2, because it is the one that is
not expressible as a patch once the words are in use. It is also the one whose
first write-up claimed more than the evidence carried, so it is stated below at
the precision the evidence actually supports, with the boundary marked.**

The natural reading of the reserved layout — `LhOffReserved2` is "the combiner
role word", `LhOffReserved3` is "the combine sequence" — invites an
implementation in which the role word is a lock and the commit is a monotone
store on the sequence word. That is what `CommitFencedByRole = FALSE` models, and
it is not a strawman: it is what an implementer would write from that sentence
alone.

**The mutation models that design faithfully, and getting that right was the
whole of the evidence.** Deleting the commit *write* while leaving the acquirer's
discard predicate *reading* `role.committed` would model neither design: with
nothing ever setting the bit, it is FALSE in every reachable state, so **every**
acquisition over a decided round — including one that committed perfectly
cleanly — gets labelled "discarded", and the counterexample is a *mislabelling*
rather than a protocol defect. So the read is toggled together with the write:
`PrevRoundUnresolved` becomes `role.epoch > cseq`, which is the test the
alternative design gives an implementer, needs no commit bit, and is what they
would write.

**Under that faithful mutation, `shm_lease_combine_unfenced_MC.cfg` still
violates `NeverBoth` — 13-state counterexample trace, and the witness is in real
state, not in the ghost:**

1. p1 holds the role at epoch 1, has granted itself 2 of the capacity, and
   **stalls at `cCommit`** with `cseq = 0`.
2. p2 steals the role at epoch 2 and, seeing `role.epoch (1) > cseq (0)`,
   **discards round 1**.
3. p1 **resumes** and executes its commit: `cseq := 1`.
4. `res[p1] = [epoch 1, grant, 2]` and `cseq = 1`, so **p1's grant — an entry of
   a round the stealer declared discarded — is now EFFECTIVE.** The round is half
   applied and half thrown away: both, where the gate demands exactly one.

**The necessary condition, stated exactly.** The fix is structural, not
algorithmic, but it is **not** specifically that `LhOffReserved2` carries the
flag:

> **The commit and the role transfer must be resolved by a single CAS on a single
> word.** Either reserved word can play that part. Putting the commit flag inside
> the role word (what the shipped model does) makes the acquisition CAS the same
> CAS that invalidates the previous owner's commit, so a stolen-from combiner's
> `CAS(role, [me, e, FALSE] → [me, e, TRUE])` simply fails. Making the *sequence*
> word carry the role transfer would serve equally. What must not exist is a
> design in which the role moves in one word and the commit lands in another,
> because then nothing the steal touched is anything the commit reads.

`LhOffReserved2` is a `u64` and has ample room for an owner tag, an epoch and a
flag, which is why that is the assignment modelled. Discovering the constraint
after the field layout ships would mean a format-version bump on the lease
segment; discovering it now costs a paragraph.

#### What this finding does NOT establish — checked, not assumed

`NeverBoth` and `StealResolvesExactlyOnce` are stated over the `eres`/`edisc`
ghosts, and the gate clause they discharge ("a stealer either completes or
discards a half-applied round, exactly once") is a clause about *resolution*. So
the obvious next question is whether the half-applied round goes on to damage
anything, and the answer is **no**, at the strongest fault budget any green run
here uses:

`shm_lease_combine_unfenced_damage_MC.cfg` runs the **same mutation, same
constants, two faults** against every NON-ghost invariant — `TypeOK`,
`EpochBoundNotBinding`, `NoDoubleGrant`, `GrantCoherent`, `NoOvercommit`,
`NonNegative`, `BudgetExact`, `GrantedEqualsTaken`, `NoDiscardOfCollected` —
plus `AllSettled`, and it is **green: 339,869 distinct states, depth 54**. No
capacity is conjured or destroyed, no request is granted twice, no waiter reads
an incoherent payload, nothing is stranded.

**Why the damage is absorbed.** Two shipped mechanisms cover for the unfenced
commit. The raise guard `RaiseNeeded` is re-evaluated **per step** against the
*current* ledger and `cseq`, not against a snapshot taken when the pass began, so
an entry that becomes effective in the middle of a stealer's raise pass stops
being raised from that step onward. And `SerialisePerSlot` refuses to re-decide
an effective entry at all. Between them, the resurrected commit's entry is left
alone rather than half-cleared.

**So the honest form of this finding is materially weaker than "half applied,
half discarded" reads.** What the mutation breaks is the gate's *exactly-once
resolution* clause — a stealer that believes it discarded a round can be
contradicted afterwards, so no process can rely on its own discard decision, and
"was this round applied" stops being decidable from the two words. What it does
**not** break, in this model at these bounds, is any damage clause. That is
still a reason to require the single-word resolution — a protocol whose recovery
decisions can be silently reversed is not one to build M7's reclamation on, and
the absorption depends on two *other* mechanisms holding — but the requirement is
"resolution must be decidable", not "otherwise the ledger corrupts".

### Finding 5 (MV2) — an unsound steal detector costs LIVENESS, not SAFETY, and that division of labour is worth knowing before M7 tunes the timeout

Two configurations run **identical constants** with `StealFromLive = TRUE`, which
lets the timeout fire on a combiner that is *running* — a fully arbitrary,
maximally wrong detector:

- `shm_lease_combine_live_MC.cfg` explores **1,325,806 states to depth 55** and
  **every safety invariant holds**. The epoch stamps fence a wrongly stolen-from
  combiner out of every mutation, so a bad timeout cannot corrupt anything.
- `shm_lease_combine_livelock_MC.cfg` violates `EpochBoundNotBinding`: two live
  processes steal the role from each other **without bound**, and the epoch
  counter runs away.

The pair is the statement, and it is a useful one: **the epoch stamps buy safety,
and the anchor check (boot id + pid + start time) plus the bounded timeout buy
progress.** M7 can therefore choose its timeout by measurement rather than having
to prove it never fires early — an early fire costs a wasted round, never
correctness — but it must not omit the anchor check on the grounds that the
protocol tolerates false positives, because tolerating them is precisely what it
does *not* do for liveness.

### Finding 6 (MV2) — an incrementally decremented budget word cannot be made crash-safe by a sequence number, because the decrement and the stamp are TWO WORDS

**This one was previously left as an unwritten finding**: the negative table
labelled it "MV2 FINDING", the model and its config called it one, and two
cross-references cited it as a finding, but there was no entry for it here and
the milestone record demoted it to a next-steps bullet. It is a finding, on the
same footing as 3, 4 and 5 — a constraint on M5 discovered before M5 exists — and
this is its entry.

**The mutation is the obvious implementation, and the one M2's claim path already
uses.** `BudgetIsCache = FALSE` makes the budget word authoritative: each grant
decrements it as its own step and there is no recompute. That is exactly how
`claimWords` works today on the packed budget, so it is the design an M5 author
would inherit rather than invent.

`shm_lease_combine_budget_MC.cfg` violates **`BudgetExact`** — the invariant that
says at every quiescent state the budget word equals exactly what the committed
ledger says is left. The counterexample is a 26-state trace:

1. p1 takes the role at epoch 1 and begins its raise pass.
2. p1 is **descheduled**; p2 steals the role at epoch 2.
3. p1 **resumes** and, before it notices the steal, completes a decision — which
   under this mutation **decrements the budget word** as a separate step.
4. p1 then discovers it no longer owns the role and **aborts**.
5. p2 raises p1's entry away, so p1's *grant* is discarded — but **the decrement
   is not**, because it landed in a different word from the stamp that discarded
   it. p2 runs its round to completion and releases.
6. At quiescence the budget word is short by p1's amount. **That capacity is
   withheld from every subsequent action for the lifetime of the segment.**

**A sequence number cannot fix this, and that is the point.** The stamp that
makes "was this round applied" decidable lives in the ledger entry; the
subtraction lives in the budget word; no CAS spans the two. Whatever the stamp
says, the arithmetic has already happened, and a discard cannot un-happen it —
undoing it would need a second write that a crash can equally well land between.

**The fix is not a bigger stamp; it is to stop treating the budget word as an
accumulator.** Derive it from the stamped per-slot ledger:
`budget = Capacity − Σ effective grants`, recomputed rather than mutated. Then
"was this applied" is a property of a **single atomic word** — the entry's stamp
— and re-application is a *recompute*, which is idempotent, rather than a second
subtraction, which is not. That is what `CRefresh` does in the shipped model, and
why a process that dies inside `CRefresh` costs nothing: the next combiner
recomputes.

Note how this interacts with Finding 4: both are instances of the same rule, that
a decision and the word that records it must not be separable. Finding 4 is that
rule applied to the *role transfer*; Finding 6 is it applied to the *arithmetic*.

### Two deadlocks the model found in its own first drafts, kept because they are the protocol's real shape

Neither is a defect in a design anyone wrote down — both are places where the
obvious recovery predicate is wrong — and both were found by TLC in under a
second, which is the argument for MV2 in miniature.

1. **Testing the ledger for "is there work to do" deadlocks in 157 states.** A
   combiner that died having *decided* every request but *committed* none leaves
   a state in which no survivor sees work, so nobody steals and every request is
   stranded. An uncommitted decision is not progress.
2. **Testing the payload deadlocks in 711 states.** A combiner that died
   *between* the payload store and the value bump leaves a slot whose payload is
   written and whose waiter has been told nothing.

The sound test is the **value word** — and the reason is worth stating as a rule,
because it is not obvious and it is easy to get wrong in a recovery loop: *the
recovery predicate and the waiter's wake predicate must be the same predicate.*
The value word is what the waiter waits on, so it is the only thing whose
movement means "answered". `shm_lease_combine_pub_probe.cfg` is required to
violate `ProbeDiedMidPublish`, so the fixed model demonstrably still reaches the
state that broke it.

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
fails if any test does not produce the required one — necessary because five of
these sixteen tests are required to be **Allowed**, and a runner that only knew how to
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
| `grant-bump-vs-waiters-FENCED-fix` † | C11 | Never | **Never** |
| `grant-bump-vs-waiters-aarch64-FENCED` † | AArch64 | Never | **Never** |
| `grant-bump-vs-waiters-WAITER-FENCE-ONLY-control` † | C11 | **Sometimes** | **Sometimes** |

† Added 2026-08-18 with the fix for Finding 2. The three `-FENCED*` rows
(`-FENCED-fix`, `-x86-FENCED`, `-aarch64-FENCED`) pin the pair the source now
**compiles to**: release store of `value`, `fullFence()` in `wakeAll` / `wakeOne`,
seq-cst load of `waiters`, waiter unfenced.

**They are NOT a regression barrier over `src/`, and an earlier version of this
paragraph said they were.** A `.litmus` file is a standalone program: herd7's
verdict is a deterministic function of that file alone, so *no* edit to the Nim
source can move it. Deleting `fullFence()` from `waitword.nim` and re-running
leaves all sixteen verdicts unchanged and `just verify-litmus` green — checked by
doing exactly that on 2026-08-18. What these rows pin is the **intended shape**,
and keeping the source in step with the models is a **review obligation** at this
tier, not an automated one.

The automated one lives in `tests/check-fence-shape.sh`, run by `just
test-fence-shape` as part of **`just test`** (not `just verify` — see that script's
header for why). It compiles a driver that calls both `wakeAll` and `wakeOne`,
disassembles them, and requires a full-fence instruction (`dmb ish` on arm64,
`mfence` / a `lock`-prefixed op on x86-64) to precede the load of `waiters`, with
no earlier load of it. It was proven to fail against four mutations: the fence
deleted from both procs, deleted from `wakeAll` only, **moved to after the load**
(the relocation a source grep cannot see), and weakened from `ATOMIC_SEQ_CST` to
`ATOMIC_ACQUIRE`. On an architecture it has no instruction profile for it prints a
banner and exits non-zero rather than passing.

The `WAITER-FENCE-ONLY` control is what licenses the shipped
**asymmetry**: obsring fences both sides of its Dekker pair, so the question
"should `waitOn` get a fence too?" had to be answered rather than assumed, and the
answer is that a waiter-side fence with an unfenced publisher leaves the lost
wakeup **reachable** — the waiter's seq-cst RMW already orders its own side, and
the reordering that loses the wakeup is the publisher's.

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
- `tla/shm_lease_combine.tla` — **MV2**, and the only model here of code that does
  not exist yet: the flat-combining arbiter. Role acquisition, the combine round,
  per-waiter grant publication, role release, and the STEAL path — with `Die`
  enabled at **every program counter at which a request is outstanding** (every
  one except `idle`; see the bounds section for the two exclusions), and
  `Stall`/`Resume` modelling a descheduled combiner resurrected onto a round it
  no longer owns. Constants `IdempotentPublish`, `BudgetIsCache`,
  `SerialisePerSlot`, `AllowSteal`, `StealFromLive`, `AllowStall`,
  `CommitFencedByRole`, `CountOwnProposals` select the shipped protocol or one of
  seven mutations. `CommitFencedByRole` toggles the acquirer's discard **read**
  together with the commit **write**, so that `FALSE` models the alternative
  design rather than a half-deleted version of the shipped one.
- `tla/shm_lease_combine_MC.tla` + 15 cfgs — 5 green (death; the false-positive
  steal; two faults; safety under an arbitrarily wrong detector; and Finding 4's
  mutation against every non-ghost invariant), 3 non-vacuity probes, and 7
  mutations, three of which are Findings 4, 5 and 6 above.

Twenty-nine configurations in total: **11 green** and **18 required to fail**,
which is the whole set `just verify` runs.
- `litmus/*.litmus` — 16 herd7 tests across the C11, x86-TSO and AArch64 models:
  the grant-payload publish pair and its relaxed controls on all three models, the
  publish-before-write pair, RMW atomicity, the `:first_target:` store-load pair
  (both remedies), and — added with the fix — the three tests that pin the SHIPPED
  fenced pair on all three models plus the waiter-fence-only control.
  (13 of these are MV1's own; the last three landed with the Finding 2 fix.)
- `litmus/run-litmus.sh` — runs them and **checks every verdict**, including the
  five that must be *Allowed*.
- `litmus/get-herd7.sh` — builds herdtools7 7.58 through opam where nixpkgs has no
  package for it, which is the case on aarch64-darwin.
