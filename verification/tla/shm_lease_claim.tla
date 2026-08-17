------------------------------ MODULE shm_lease_claim ------------------------------
(***************************************************************************)
(* THE CLAIM PROTOCOL of `nim-shm-lease` (`src/shm_lease.nim`:              *)
(* `claimWord`, `releaseWord`, `claimWords`, `releaseWords`), modelled at   *)
(* the granularity the races actually live at.                             *)
(*                                                                         *)
(* The contract being modelled is                                          *)
(* `reprobuild-specs/RunQuota-Shared-Memory-Structures.md`                  *)
(* SS"The claim algorithm", SS"Word indices and the claim order" and         *)
(* SS"Packed reservation encoding".                                         *)
(*                                                                         *)
(* WHAT IS MODELLED FAITHFULLY -- read this before trusting any result.     *)
(*                                                                         *)
(*  1. THE BUDGET WORD IS A PACKED INTEGER, not a vector of independent     *)
(*     counters. `rem[w]` is ONE natural number and a dimension is read out *)
(*     of it arithmetically (`Field(w, i) == (w \div Base^i) % Base`), so    *)
(*     the BORROW hazard the spec calls "load-bearing, not defensive" is    *)
(*     representable: with the per-field fit test replaced by a whole-word  *)
(*     comparison, a subtraction really does borrow from the field above    *)
(*     and really does corrupt a DIFFERENT dimension. That mutation is a    *)
(*     shipped configuration (`shm_lease_claim_borrow_MC`) and TLC is       *)
(*     REQUIRED to report a violation for it.                              *)
(*                                                                         *)
(*  2. THE CAS IS STEP-WISE, in three separate steps: READ the word         *)
(*     (`cRead`), TEST the fit against what was read (`cTest`), then CAS    *)
(*     against the value that was read (`cCas`). Every other process may    *)
(*     interleave at each boundary, so a STALE FIT DECISION is a reachable  *)
(*     state and the CAS is the only thing that rejects it. Making the      *)
(*     fit-test-and-CAS one atomic step would have modelled a mutex rather  *)
(*     than this code, and would have made the lost-update class            *)
(*     unreachable by construction. Release and rollback are step-wise for  *)
(*     the same reason.                                                     *)
(*                                                                         *)
(*  3. THE OBSERVABILITY COUNTERS MOVE IN A SEPARATE STEP FROM THE CAS      *)
(*     (`cCount`, `rbCount`, `relCount`), because in the code they are      *)
(*     bumped AFTER the CAS that changed `remaining`. So the accounting      *)
(*     identity `claimedUnits - releasedUnits == capacity - remaining` is   *)
(*     deliberately NOT an always-invariant here -- it is asserted only at  *)
(*     quiescence (`CounterIdentityAtQuiescence`). That is exactly the      *)
(*     spec's warning that "a consumer MUST NOT derive correctness from     *)
(*     counters", turned into a checked statement rather than a caveat.     *)
(*                                                                         *)
(* WHAT IS ABSTRACTED, AND WHY IT IS SOUND ENOUGH:                          *)
(*                                                                         *)
(*  - TLC EXPLORES SEQUENTIALLY-CONSISTENT INTERLEAVINGS ONLY. It does NOT  *)
(*    model ARMv8 or x86-TSO reordering. Everything proved here is a        *)
(*    property of the PROTOCOL given correct memory ordering; whether the   *)
(*    acquire/release annotations in `claimWord` are sufficient is the      *)
(*    litmus tier's question, not this model's. See verification/README.md. *)
(*                                                                         *)
(*  - TWO PACKED FIELDS OF RADIX `Base` rather than four of radix 65536.    *)
(*    The borrow hazard is a property of two ADJACENT fields, and two       *)
(*    adjacent fields exhibit it; four would only multiply the state space. *)
(*    `Dims` and `Base` are constants, so a reviewer can widen either.      *)
(*                                                                         *)
(*  - EACH PROCESS RUNS ONE CLAIM TRANSACTION AT A TIME and releases it     *)
(*    before starting the next. The real API lets a process hold several    *)
(*    reservations at once; see verification/README.md SS"Coverage           *)
(*    boundaries" for what that leaves unmodelled about the hold graph.     *)
(*                                                                         *)
(*  - A CLAIM NEVER PARKS (SM-8), so "deadlock" in this protocol cannot     *)
(*    mean "blocked on a lock". The two statements checked instead are      *)
(*    `NoHoldCycle` (the waits-for relation the spec's deadlock argument    *)
(*    appeals to is acyclic) and `Termination` (every process finishes).    *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
  Procs,          \* the claimant processes
  Words,          \* budget word indices; word 0 is `MachineBudgetIndex`
  Base,           \* radix of one packed field (65536 in the code)
  Dims,           \* number of packed fields (4 in the code)
  Capacity,       \* [Words -> Nat] packed capacity, immutable after publish
  Want,           \* [Procs -> Nat] the packed vector each process claims
  WordList,       \* [Procs -> Seq(Words)] the words each claim names, in order
  Rounds,         \* how many claim transactions each process performs
  PerFieldFit,    \* TRUE = shipped `fitsPacked`; FALSE = MUTATION (whole word)
  EnforceOrder    \* TRUE = shipped `csOutOfOrder` refusal; FALSE = MUTATION

NoWord == -1

Fields == 0 .. (Dims - 1)

RECURSIVE Pow(_, _)
Pow(b, n) == IF n = 0 THEN 1 ELSE b * Pow(b, n - 1)

MaxWord == Pow(Base, Dims) - 1

Field(w, i) == (w \div Pow(Base, i)) % Base
  (*************************************************************************)
  (* Read dimension `i` out of a packed word. `%` is TLA+'s modulus, which  *)
  (* is non-negative for a positive divisor, so this stays in 0..Base-1     *)
  (* even for a negative `w` -- an underflowed word is therefore caught by  *)
  (* `NonNegative`, not silently hidden by this operator.                   *)
  (*************************************************************************)

Fits(avail, want) ==
  (*************************************************************************)
  (* `fitsPacked` (src/shm_lease/packed.nim). The shipped form is the       *)
  (* PER-FIELD comparison. `PerFieldFit = FALSE` is the mutation the spec   *)
  (* warns about: a whole-word comparison, which passes while a field       *)
  (* underflows and borrows from the dimension above it.                    *)
  (*************************************************************************)
  IF PerFieldFit
  THEN \A i \in Fields : Field(want, i) <= Field(avail, i)
  ELSE want <= avail

PackedSub(avail, want) == avail - want   \* precondition: Fits(avail, want)
PackedAdd(cur, give) == cur + give

Ascending(s) == \A i \in 1 .. (Len(s) - 1) : s[i] < s[i + 1]

RECURSIVE SumSet(_, _)
SumSet(S, f) ==
  IF S = {} THEN 0
  ELSE LET x == CHOOSE y \in S : TRUE IN f[x] + SumSet(S \ {x}, f)

VARIABLES
  rem,        \* [Words -> Int]  the shared `remaining` word: THE CAS target
  pc,         \* [Procs -> STRING] per-process program counter
  k,          \* [Procs -> Nat] cursor into WordList[p] during the ascending claim
  rb,         \* [Procs -> Nat] cursor during the DESCENDING rollback / release
  taken,      \* [Procs -> Nat] how many words the in-flight claim has taken
  held,       \* [Procs -> SUBSET Words] words this process currently holds
  rd,         \* [Procs -> Int] the value read, i.e. the CAS's expected operand
  round,      \* [Procs -> Nat] completed transactions
  claimed,    \* [Words -> [Fields -> Nat]] `claimedUnits`, bumped AFTER the CAS
  released,   \* [Words -> [Fields -> Nat]] `releasedUnits`, bumped AFTER the CAS
  probe       \* behaviour flags, for the non-vacuity configuration

vars == <<rem, pc, k, rb, taken, held, rd, round, claimed, released, probe>>

ZeroUnits == [w \in Words |-> [i \in Fields |-> 0]]

Init ==
  /\ rem = Capacity
  /\ pc = [p \in Procs |-> "start"]
  /\ k = [p \in Procs |-> 1]
  /\ rb = [p \in Procs |-> 0]
  /\ taken = [p \in Procs |-> 0]
  /\ held = [p \in Procs |-> {}]
  /\ rd = [p \in Procs |-> 0]
  /\ round = [p \in Procs |-> 0]
  /\ claimed = ZeroUnits
  /\ released = ZeroUnits
  /\ probe = [refusal |-> FALSE, rollback |-> FALSE, casLoss |-> FALSE,
              grant |-> FALSE, outOfOrder |-> FALSE, overRelease |-> FALSE]

(***************************************************************************)
(* `claimWords`: validate the order, then claim ASCENDING.                  *)
(***************************************************************************)

StartDone(p) ==
  /\ pc[p] = "start"
  /\ round[p] >= Rounds
  /\ pc' = [pc EXCEPT ![p] = "done"]
  /\ UNCHANGED <<rem, k, rb, taken, held, rd, round, claimed, released, probe>>

StartOutOfOrder(p) ==
  (*************************************************************************)
  (* The enforced fixed claim order: a non-ascending index list returns     *)
  (* `csOutOfOrder` and TAKES NOTHING. It is not silently sorted.           *)
  (*************************************************************************)
  /\ pc[p] = "start"
  /\ round[p] < Rounds
  /\ EnforceOrder
  /\ ~Ascending(WordList[p])
  /\ round' = [round EXCEPT ![p] = round[p] + 1]
  /\ probe' = [probe EXCEPT !.outOfOrder = TRUE]
  /\ UNCHANGED <<rem, pc, k, rb, taken, held, rd, claimed, released>>

StartClaim(p) ==
  /\ pc[p] = "start"
  /\ round[p] < Rounds
  /\ ~(EnforceOrder /\ ~Ascending(WordList[p]))
  /\ pc' = [pc EXCEPT ![p] = "cRead"]
  /\ k' = [k EXCEPT ![p] = 1]
  /\ taken' = [taken EXCEPT ![p] = 0]
  /\ UNCHANGED <<rem, rb, held, rd, round, claimed, released, probe>>

CRead(p) ==
  \* `var cur = loadU64Acquire(...)` -- and the re-read after a lost CAS.
  /\ pc[p] = "cRead"
  /\ rd' = [rd EXCEPT ![p] = rem[WordList[p][k[p]]]]
  /\ pc' = [pc EXCEPT ![p] = "cTest"]
  /\ UNCHANGED <<rem, k, rb, taken, held, round, claimed, released, probe>>

CTestFit(p) ==
  \* `if not fitsPacked(cur, want)` -- taken NOT, so proceed to the CAS. The
  \* decision is made on `rd[p]`, which other processes may already have
  \* invalidated; that staleness is the point of the separate step.
  /\ pc[p] = "cTest"
  /\ Fits(rd[p], Want[p])
  /\ pc' = [pc EXCEPT ![p] = "cCas"]
  /\ UNCHANGED <<rem, k, rb, taken, held, rd, round, claimed, released, probe>>

CTestRefuseClean(p) ==
  \* Refused on the FIRST word: nothing is held, so `csRefused` immediately.
  /\ pc[p] = "cTest"
  /\ ~Fits(rd[p], Want[p])
  /\ taken[p] = 0
  /\ pc' = [pc EXCEPT ![p] = "start"]
  /\ round' = [round EXCEPT ![p] = round[p] + 1]
  /\ probe' = [probe EXCEPT !.refusal = TRUE]
  /\ UNCHANGED <<rem, k, rb, taken, held, rd, claimed, released>>

CTestRefuseRollback(p) ==
  \* Refused on a LATER word: the already-claimed words are given back in
  \* DESCENDING order, the mirror image of the acquisition.
  /\ pc[p] = "cTest"
  /\ ~Fits(rd[p], Want[p])
  /\ taken[p] > 0
  /\ pc' = [pc EXCEPT ![p] = "rbRead"]
  /\ rb' = [rb EXCEPT ![p] = taken[p]]
  /\ probe' = [probe EXCEPT !.refusal = TRUE]
  /\ UNCHANGED <<rem, k, taken, held, rd, round, claimed, released>>

CCasWin(p) ==
  \* The CAS succeeds only against the value that was READ. This is the whole
  \* lost-update guard: a stale `rd[p]` cannot be committed.
  /\ pc[p] = "cCas"
  /\ LET w == WordList[p][k[p]] IN
     /\ rem[w] = rd[p]
     /\ rem' = [rem EXCEPT ![w] = PackedSub(rd[p], Want[p])]
     /\ held' = [held EXCEPT ![p] = held[p] \cup {w}]
     /\ taken' = [taken EXCEPT ![p] = taken[p] + 1]
     /\ pc' = [pc EXCEPT ![p] = "cCount"]
  /\ UNCHANGED <<k, rb, rd, round, claimed, released, probe>>

CCasLose(p) ==
  \* Contention: re-read and re-evaluate the fit against what is ACTUALLY there.
  /\ pc[p] = "cCas"
  /\ rem[WordList[p][k[p]]] # rd[p]
  /\ pc' = [pc EXCEPT ![p] = "cRead"]
  /\ probe' = [probe EXCEPT !.casLoss = TRUE]
  /\ UNCHANGED <<rem, k, rb, taken, held, rd, round, claimed, released>>

CCountLast(p) ==
  \* Counters bumped after the CAS; this was the last word, so the claim is
  \* granted and the process HOLDS every word until it releases.
  /\ pc[p] = "cCount"
  /\ k[p] = Len(WordList[p])
  /\ LET w == WordList[p][k[p]] IN
     claimed' = [claimed EXCEPT ![w] =
                   [i \in Fields |-> claimed[w][i] + Field(Want[p], i)]]
  /\ pc' = [pc EXCEPT ![p] = "relRead"]
  /\ rb' = [rb EXCEPT ![p] = Len(WordList[p])]
  /\ probe' = [probe EXCEPT !.grant = TRUE]
  /\ UNCHANGED <<rem, k, taken, held, rd, round, released>>

CCountMore(p) ==
  /\ pc[p] = "cCount"
  /\ k[p] < Len(WordList[p])
  /\ LET w == WordList[p][k[p]] IN
     claimed' = [claimed EXCEPT ![w] =
                   [i \in Fields |-> claimed[w][i] + Field(Want[p], i)]]
  /\ pc' = [pc EXCEPT ![p] = "cRead"]
  /\ k' = [k EXCEPT ![p] = k[p] + 1]
  /\ UNCHANGED <<rem, rb, taken, held, rd, round, released, probe>>

(***************************************************************************)
(* Rollback of a partial claim: DESCENDING, and it undoes the claim         *)
(* accounting rather than counting a release (`isRollback = true`).         *)
(***************************************************************************)

RbRead(p) ==
  /\ pc[p] = "rbRead"
  /\ rd' = [rd EXCEPT ![p] = rem[WordList[p][rb[p]]]]
  /\ pc' = [pc EXCEPT ![p] = "rbCas"]
  /\ UNCHANGED <<rem, k, rb, taken, held, round, claimed, released, probe>>

OverReleaseGuardHolds(w, cur, give) ==
  \* `releaseWord`'s two guards, evaluated on the value that was read.
  /\ Fits(Capacity[w], cur)
  /\ Fits(PackedSub(Capacity[w], cur), give)

RbGuardFires(p) ==
  \* The over-release guard refusing during a process's OWN rollback would mean
  \* the accounting had already been corrupted. `NoOverReleaseRefusal` asserts
  \* this action is never enabled; it exists so that a violation is NAMED.
  /\ pc[p] = "rbCas"
  /\ LET w == WordList[p][rb[p]] IN
     /\ ~OverReleaseGuardHolds(w, rd[p], Want[p])
     /\ IF rb[p] = 1
        THEN /\ pc' = [pc EXCEPT ![p] = "start"]
             /\ round' = [round EXCEPT ![p] = round[p] + 1]
             /\ rb' = rb
        ELSE /\ pc' = [pc EXCEPT ![p] = "rbRead"]
             /\ rb' = [rb EXCEPT ![p] = rb[p] - 1]
             /\ round' = round
  /\ probe' = [probe EXCEPT !.overRelease = TRUE]
  /\ UNCHANGED <<rem, k, taken, held, rd, claimed, released>>

RbCasWin(p) ==
  /\ pc[p] = "rbCas"
  /\ LET w == WordList[p][rb[p]] IN
     /\ OverReleaseGuardHolds(w, rd[p], Want[p])
     /\ rem[w] = rd[p]
     /\ rem' = [rem EXCEPT ![w] = PackedAdd(rd[p], Want[p])]
     /\ held' = [held EXCEPT ![p] = held[p] \ {w}]
     /\ pc' = [pc EXCEPT ![p] = "rbCount"]
  /\ UNCHANGED <<k, rb, taken, rd, round, claimed, released, probe>>

RbCasLose(p) ==
  /\ pc[p] = "rbCas"
  /\ OverReleaseGuardHolds(WordList[p][rb[p]], rd[p], Want[p])
  /\ rem[WordList[p][rb[p]]] # rd[p]
  /\ pc' = [pc EXCEPT ![p] = "rbRead"]
  /\ probe' = [probe EXCEPT !.casLoss = TRUE]
  /\ UNCHANGED <<rem, k, rb, taken, held, rd, round, claimed, released>>

RbCount(p) ==
  \* A rolled-back word had no net effect, so the CLAIM accounting is undone
  \* rather than a release being counted.
  /\ pc[p] = "rbCount"
  /\ LET w == WordList[p][rb[p]] IN
     claimed' = [claimed EXCEPT ![w] =
                   [i \in Fields |-> claimed[w][i] - Field(Want[p], i)]]
  /\ probe' = [probe EXCEPT !.rollback = TRUE]
  /\ IF rb[p] = 1
     THEN /\ pc' = [pc EXCEPT ![p] = "start"]
          /\ round' = [round EXCEPT ![p] = round[p] + 1]
          /\ taken' = [taken EXCEPT ![p] = 0]
          /\ rb' = rb
     ELSE /\ pc' = [pc EXCEPT ![p] = "rbRead"]
          /\ rb' = [rb EXCEPT ![p] = rb[p] - 1]
          /\ round' = round
          /\ taken' = taken
  /\ UNCHANGED <<rem, k, held, rd, released>>

(***************************************************************************)
(* `release` / `releaseWords`: DESCENDING, the mirror image of the claim.   *)
(***************************************************************************)

RelRead(p) ==
  /\ pc[p] = "relRead"
  /\ rd' = [rd EXCEPT ![p] = rem[WordList[p][rb[p]]]]
  /\ pc' = [pc EXCEPT ![p] = "relCas"]
  /\ UNCHANGED <<rem, k, rb, taken, held, round, claimed, released, probe>>

RelGuardFires(p) ==
  /\ pc[p] = "relCas"
  /\ LET w == WordList[p][rb[p]] IN
     /\ ~OverReleaseGuardHolds(w, rd[p], Want[p])
     /\ IF rb[p] = 1
        THEN /\ pc' = [pc EXCEPT ![p] = "start"]
             /\ round' = [round EXCEPT ![p] = round[p] + 1]
             /\ rb' = rb
        ELSE /\ pc' = [pc EXCEPT ![p] = "relRead"]
             /\ rb' = [rb EXCEPT ![p] = rb[p] - 1]
             /\ round' = round
  /\ probe' = [probe EXCEPT !.overRelease = TRUE]
  /\ UNCHANGED <<rem, k, taken, held, rd, claimed, released>>

RelCasWin(p) ==
  /\ pc[p] = "relCas"
  /\ LET w == WordList[p][rb[p]] IN
     /\ OverReleaseGuardHolds(w, rd[p], Want[p])
     /\ rem[w] = rd[p]
     /\ rem' = [rem EXCEPT ![w] = PackedAdd(rd[p], Want[p])]
     /\ held' = [held EXCEPT ![p] = held[p] \ {w}]
     /\ pc' = [pc EXCEPT ![p] = "relCount"]
  /\ UNCHANGED <<k, rb, taken, rd, round, claimed, released, probe>>

RelCasLose(p) ==
  /\ pc[p] = "relCas"
  /\ OverReleaseGuardHolds(WordList[p][rb[p]], rd[p], Want[p])
  /\ rem[WordList[p][rb[p]]] # rd[p]
  /\ pc' = [pc EXCEPT ![p] = "relRead"]
  /\ probe' = [probe EXCEPT !.casLoss = TRUE]
  /\ UNCHANGED <<rem, k, rb, taken, held, rd, round, claimed, released>>

RelCount(p) ==
  /\ pc[p] = "relCount"
  /\ LET w == WordList[p][rb[p]] IN
     released' = [released EXCEPT ![w] =
                    [i \in Fields |-> released[w][i] + Field(Want[p], i)]]
  /\ IF rb[p] = 1
     THEN /\ pc' = [pc EXCEPT ![p] = "start"]
          /\ round' = [round EXCEPT ![p] = round[p] + 1]
          /\ taken' = [taken EXCEPT ![p] = 0]
          /\ rb' = rb
     ELSE /\ pc' = [pc EXCEPT ![p] = "relRead"]
          /\ rb' = [rb EXCEPT ![p] = rb[p] - 1]
          /\ round' = round
          /\ taken' = taken
  /\ UNCHANGED <<rem, k, held, rd, claimed, probe>>

Step(p) ==
  \/ StartDone(p) \/ StartOutOfOrder(p) \/ StartClaim(p)
  \/ CRead(p) \/ CTestFit(p) \/ CTestRefuseClean(p) \/ CTestRefuseRollback(p)
  \/ CCasWin(p) \/ CCasLose(p) \/ CCountLast(p) \/ CCountMore(p)
  \/ RbRead(p) \/ RbGuardFires(p) \/ RbCasWin(p) \/ RbCasLose(p) \/ RbCount(p)
  \/ RelRead(p) \/ RelGuardFires(p) \/ RelCasWin(p) \/ RelCasLose(p) \/ RelCount(p)

AllDone == \A p \in Procs : pc[p] = "done"

Terminating == AllDone /\ UNCHANGED vars
  (*************************************************************************)
  (* An explicit stutter at quiescence, so that TLC's deadlock check stays  *)
  (* MEANINGFUL: any OTHER state with no successor is a real wedge and is   *)
  (* reported as a deadlock rather than being drowned out by the normal     *)
  (* end of the workload.                                                  *)
  (*************************************************************************)

Next == (\E p \in Procs : Step(p)) \/ Terminating

Fairness == \A p \in Procs : WF_vars(Step(p))

Spec == Init /\ [][Next]_vars /\ Fairness

(***************************************************************************)
(* INVARIANTS                                                              *)
(***************************************************************************)

TypeOK ==
  /\ rem \in [Words -> (0 - MaxWord) .. MaxWord]
  /\ pc \in [Procs -> {"start", "cRead", "cTest", "cCas", "cCount",
                       "rbRead", "rbCas", "rbCount",
                       "relRead", "relCas", "relCount", "done"}]
  /\ k \in [Procs -> 1 .. 8]
  /\ rb \in [Procs -> 0 .. 8]
  /\ taken \in [Procs -> 0 .. 8]
  /\ held \in [Procs -> SUBSET Words]
  /\ round \in [Procs -> 0 .. Rounds]

NonNegative == \A w \in Words : rem[w] >= 0
  \* An underflowed packed word. Cannot happen under the per-field fit test.

NoBorrow == \A w \in Words : \A i \in Fields :
              Field(rem[w], i) <= Field(Capacity[w], i)
  (*************************************************************************)
  (* THE BORROW INVARIANT. A field of `remaining` may never exceed the same *)
  (* field of `capacity`. Under the whole-word fit mutation a subtraction   *)
  (* borrows and this fails on a dimension the claimant never asked for --  *)
  (* the spec's "a memory over-claim can present as CPU-slot corruption".   *)
  (*************************************************************************)

HeldUnits(w, i) ==
  SumSet({p \in Procs : w \in held[p]}, [p \in Procs |-> Field(Want[p], i)])

NoOvercommit == \A w \in Words : \A i \in Fields :
                  HeldUnits(w, i) <= Field(Capacity[w], i)
  (*************************************************************************)
  (* NO OVERCOMMIT IN ANY DIMENSION. The sum of what every process actually *)
  (* holds, per dimension, never exceeds capacity. Stated over the HOLDERS  *)
  (* rather than over the word, so it is independent of `rem` being         *)
  (* correct -- a corrupted `rem` that let two processes hold more than     *)
  (* capacity is caught here even if `rem` itself looks plausible.          *)
  (*************************************************************************)

ConservationExact == \A w \in Words : \A i \in Fields :
                       Field(rem[w], i) + HeldUnits(w, i) = Field(Capacity[w], i)
  (*************************************************************************)
  (* NO LOST UPDATE, stated exactly: at EVERY state, in EVERY dimension,    *)
  (* the word plus what is held equals capacity. A lost update -- two       *)
  (* claimants committing decrements computed from the same read -- leaves  *)
  (* `rem` too HIGH for the set of holders and is caught here. This is the  *)
  (* invariant the step-wise CAS exists to put at risk.                     *)
  (*************************************************************************)

AllOrNothing == \A p \in Procs :
                  pc[p] \in {"start", "done"} => held[p] = {}
  \* A claim is all-or-nothing: between transactions a process holds nothing,
  \* whether its last transaction was granted, refused, or rolled back.

QuiescentRestore == AllDone => \A w \in Words : rem[w] = Capacity[w]
  \* Total released == total claimed: releasing everything restores the word.

ReleasedEqualsClaimed ==
  AllDone => \A w \in Words : \A i \in Fields : claimed[w][i] = released[w][i]

CounterIdentityAtQuiescence ==
  AllDone => \A w \in Words : \A i \in Fields :
               claimed[w][i] - released[w][i]
                 = Field(Capacity[w], i) - Field(rem[w], i)
  \* The accounting identity the code claims. Asserted ONLY at quiescence,
  \* because the counters are bumped in a step after the CAS -- see the header.

NoOverReleaseRefusal == ~probe.overRelease
  \* A process releasing what it holds is never refused by the over-release
  \* guard. If this fails, the guard is either wrong or the accounting is.

(***************************************************************************)
(* DEADLOCK FREEDOM -- the part of the spec that was only prose.            *)
(*                                                                         *)
(* SS"Word indices and the claim order": "Because every claimant takes words *)
(* ascending, the waits-for relation is a strict order and no cycle is     *)
(* constructible -- that is the entire deadlock argument."                  *)
(*                                                                         *)
(* `Wanting(p)` is the word `p` is currently trying to take; `held[q]` is   *)
(* what `q` currently holds. The edge relation is deliberately GENEROUS --  *)
(* it draws an edge whenever `p` wants a word `q` holds ANY capacity in,    *)
(* not only when `q`'s holding is what makes `p` refuse -- so acyclicity    *)
(* here is a stronger statement than the one the spec needs.                *)
(***************************************************************************)

Wanting(p) == IF pc[p] \in {"cRead", "cTest", "cCas"}
              THEN WordList[p][k[p]]
              ELSE NoWord
  (*************************************************************************)
  (* `cCount` is deliberately EXCLUDED: by then the word has already been   *)
  (* taken (the CAS succeeded), so the process holds it rather than wants   *)
  (* it. Including it would make `AscendingHold` read `w < w` and fail on   *)
  (* every successful claim -- which is how this operator was first written  *)
  (* and how TLC caught it.                                                 *)
  (*************************************************************************)

AscendingHold == \A p \in Procs :
                   Wanting(p) # NoWord =>
                     \A a \in held[p] : a < Wanting(p)
  \* The LOCAL form of the ordering rule: everything a claimant already holds
  \* has a strictly smaller index than the word it is reaching for.

WaitsFor == {e \in Procs \X Procs :
               /\ e[1] # e[2]
               /\ Wanting(e[1]) # NoWord
               /\ Wanting(e[1]) \in held[e[2]]}

Closure(R) ==
  LET n == Cardinality(Procs)
      f[m \in 0 .. n] ==
        IF m = 0 THEN R
        ELSE f[m - 1] \cup
             {e \in Procs \X Procs :
                \E z \in Procs : <<e[1], z>> \in f[m - 1]
                                 /\ <<z, e[2]>> \in f[m - 1]}
  IN f[n]

NoHoldCycle == \A p \in Procs : <<p, p>> \notin Closure(WaitsFor)
  (*************************************************************************)
  (* THE DEADLOCK-FREEDOM INVARIANT. No cycle in the waits-for relation is  *)
  (* reachable. Its teeth are demonstrated by `shm_lease_claim_ord_MC` with *)
  (* `EnforceOrder = FALSE`, where one process names its words DESCENDING   *)
  (* and TLC reports a violation -- the cycle really is constructible once  *)
  (* the ordering rule is dropped, and `csOutOfOrder` really is what        *)
  (* excludes it.                                                          *)
  (*************************************************************************)

Termination == <>AllDone
  (*************************************************************************)
  (* The liveness half: no process is ever permanently stuck, whether by a  *)
  (* deadlock or by losing its CAS forever. Checked under weak fairness on  *)
  (* each process's own steps.                                             *)
  (*************************************************************************)

(***************************************************************************)
(* NON-VACUITY. A green run over a workload that never reaches the          *)
(* interesting states proves nothing, so this NEGATION is checked as an     *)
(* invariant in `*_probe.cfg` and TLC is REQUIRED to violate it: the        *)
(* counterexample is a single behaviour in which a refusal, a rollback, a   *)
(* LOST CAS and a granted multi-word claim have all occurred.               *)
(***************************************************************************)

ProbeAllReached ==
  ~(probe.refusal /\ probe.rollback /\ probe.casLoss /\ probe.grant)

ProbeOutOfOrderReached == ~probe.outOfOrder
  \* Only meaningful in the configurations whose workload contains a
  \* non-ascending list; violated there, trivially true elsewhere.

================================================================================
