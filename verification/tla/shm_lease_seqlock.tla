----------------------------- MODULE shm_lease_seqlock -----------------------------
(***************************************************************************)
(* THE PUBLISHED AGGREGATE TABLE'S PER-ENTRY SEQLOCK, MODELLED BEFORE M13b  *)
(* WRITES IT.                                                              *)
(*                                                                         *)
(* The contract being modelled is                                          *)
(* `reprobuild-specs/RunQuota-Shared-Memory-Structures.md`                  *)
(* SS"Structures Not Yet Built", the published-aggregate-table entry, and    *)
(* `reprobuild-specs/RunQuota-Shared-Memory-Transport.md` SS1b.             *)
(*                                                                         *)
(* The spec gives the structure in four lines -- "Seqlock per entry, not a   *)
(* global one[...] Even-odd counter, release-store to publish, reader        *)
(* retries on an odd or changed count" -- and this module is what those four *)
(* lines have to mean if they are to hold. Like `shm_lease_combine.tla` and *)
(* unlike `shm_lease_claim.tla`, IT DESCRIBES NOTHING IN `../src`: it is a   *)
(* CONSTRAINT ON WHAT M13b MAY BE WRITTEN AS.                               *)
(*                                                                         *)
(* THE PROTOCOL.                                                            *)
(*                                                                         *)
(*   writer (runquotad, the only one):     reader (any client):             *)
(*     seq <- seq + 1        (odd)           s1 <- seq                      *)
(*     data[1] <- round                      if odd(s1): retry              *)
(*     ...                                   snap[1] <- data[1]             *)
(*     data[n] <- round                      ...                            *)
(*     seq <- seq + 1        (even)          snap[n] <- data[n]             *)
(*                                           s2 <- seq                      *)
(*                                           if s2 /= s1: retry             *)
(*                                           accept snap                    *)
(*                                                                         *)
(* WHAT IS MODELLED FAITHFULLY:                                             *)
(*                                                                         *)
(*  1. EVERY PAYLOAD WORD IS ITS OWN STEP, on both sides. A seqlock whose    *)
(*     payload is one word has no tearing to prevent, so a model that       *)
(*     stored and loaded the payload atomically would make `NoTornRead`     *)
(*     unfalsifiable. `PayloadWords` is at least 2 in every configuration    *)
(*     and `shm_lease_seqlock_torn_probe.cfg` REQUIRES TLC to exhibit a      *)
(*     reader whose RAW snapshot is torn before validation -- that probe is  *)
(*     what makes the green runs mean anything.                             *)
(*                                                                         *)
(*  2. ROUND `k` STORES `k` INTO EVERY WORD, so "this snapshot is some       *)
(*     single writer round's complete payload" is a checkable equality      *)
(*     rather than a paraphrase. `NoTornRead` is the gate's sentence,       *)
(*     transcribed.                                                         *)
(*                                                                         *)
(*  3. THE WRITER NEVER READS READER STATE. No writer action's guard        *)
(*     mentions any reader variable, and that is checked two ways rather    *)
(*     than asserted: `WriterAlwaysEnabled` (an `ENABLED` invariant, at      *)
(*     every reachable state) and a configuration that gives readers NO      *)
(*     FAIRNESS AT ALL and still requires `WriterFinishes`. The mutation     *)
(*     `WriterWaitsForReaders` introduces exactly the coupling those two     *)
(*     forbid, and is required to break the second.                        *)
(*                                                                         *)
(*  4. THE READER'S RETRY BUDGET IS NOT MODELLED AS A BUDGET. The spec says *)
(*     an exhausted retry budget falls back to the socket, which is a       *)
(*     LIVENESS convenience, not a safety mechanism; modelling it would     *)
(*     have let a reader escape the very interleaving the model is about.   *)
(*     Here the reader retries until it succeeds, and `ReaderTerminates`    *)
(*     is the statement that it does not have to retry forever. NO RETRY    *)
(*     COUNTER IS CARRIED: a counter would multiply the state graph by its  *)
(*     range to record something the `rprobe` ghost already records as a    *)
(*     reachability question, which is the only form in which this tier     *)
(*     needs it. M13b's own gate asserts a non-zero retry counter at        *)
(*     RUNTIME, and that is the right instrument for it.                    *)
(*                                                                         *)
(* WHAT IS ABSTRACTED, AND THE HONEST NAME FOR THE MUTATIONS:               *)
(*                                                                         *)
(*  - TLC EXPLORES SEQUENTIALLY-CONSISTENT INTERLEAVINGS. `WriterOrdered`,  *)
(*    `ReaderOrdered` and `ReaderChecksParity` are PROTOCOL-ORDER           *)
(*    mutations, exactly like `PayloadFirst` in `shm_lease_wait.tla`: they  *)
(*    reorder or delete a STEP, they do not simulate a memory model.        *)
(*    `ReaderOrdered = FALSE` lets the second seq load fire early, which is *)
(*    what a hoisted load LOOKS like from the protocol's side -- it is not   *)
(*    evidence that any compiler or architecture will hoist it. THAT        *)
(*    question is herd7's and is answered by                                *)
(*    `litmus/seqlock-recheck-vs-payload*.litmus`. Nothing in this module   *)
(*    substitutes for the litmus tier, and this module deliberately does    *)
(*    NOT carry `shm_lease_wait.tla`'s one-pair store-buffer abstraction:   *)
(*    that abstraction was built and validated for ONE pair and must not be *)
(*    quoted for another.                                                   *)
(*                                                                         *)
(*  - ONE ENTRY. The spec's "seqlock per entry, not a global one, so a      *)
(*    writer updating one key never stalls a reader of another" is a claim  *)
(*    about INDEPENDENCE of entries; with a per-entry counter it is         *)
(*    structural, and modelling two entries would multiply the graph to     *)
(*    re-derive it. What IS modelled is the stronger local statement: the   *)
(*    writer of THIS entry never stalls a reader of THIS entry either.      *)
(*                                                                         *)
(*  - NO HASH TABLE, NO EVICTION, NO ABSENT KEY. Open addressing, the       *)
(*    recency/frequency eviction and the miss path are M13b's and are       *)
(*    orthogonal to the ordering question: a miss is answered before the    *)
(*    seqlock is entered. But AN ENTRY EVICTED AND REBOUND TO A DIFFERENT   *)
(*    KEY UNDER A READER IS A DIFFERENT HAZARD FROM TEARING AND IS NOT      *)
(*    COVERED BY ANYTHING HERE: the reader would return a COHERENT payload  *)
(*    belonging to ANOTHER KEY, and `NoTornRead` is green on that behaviour *)
(*    because nothing tore. See verification/README.md, Finding 8, which    *)
(*    gives the two remedies M13b must choose between.                      *)
(*                                                                         *)
(*  - CROSS-MAPPING IS OUT OF SCOPE BY DESIGN. That the daemon and each     *)
(*    client map the segment at DIFFERENT virtual bases is SM-7's property  *)
(*    and is gated by EXECUTION, not by model -- the same split M3 used.     *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
  Readers,               \* the reading client processes
  PayloadWords,          \* words in one table entry; MUST be >= 2 to see a tear
  NumRounds,             \* how many updates the single writer publishes
  WriterOrdered,         \* TRUE = shipped; FALSE = MUTATION, bump-to-even first
  ReaderChecksParity,    \* TRUE = shipped; FALSE = MUTATION, odd seq accepted
  ReaderRechecks,        \* TRUE = shipped; FALSE = MUTATION, the retry removed
  ReaderOrdered,         \* TRUE = shipped; FALSE = MUTATION, second load hoisted
  WriterWaitsForReaders, \* FALSE = shipped; TRUE = MUTATION, writer blocks
  SeqModulus             \* 0 = the counter never wraps; k > 0 = it wraps at k

Words == 1 .. PayloadWords

NextSeq(v) == IF SeqModulus = 0 THEN v + 1 ELSE (v + 1) % SeqModulus
  (*************************************************************************)
  (* THE COUNTER'S WIDTH, WHICH THE STRUCTURES SPEC DOES NOT GIVE.          *)
  (* `SeqModulus = 0` is the unbounded counter every green configuration     *)
  (* here runs, and it is an ASSUMPTION rather than a fact about any         *)
  (* implementation: a real counter is 32 or 64 bits wide, and if it is      *)
  (* packed into a header field it may be far narrower.                      *)
  (* `shm_lease_seqlock_wrap_MC.cfg` runs the same protocol on a counter     *)
  (* that wraps and is REQUIRED to violate `NoTornRead`. `SeqModulus` MUST   *)
  (* be EVEN, or the even-odd discipline is destroyed by the wrap itself     *)
  (* rather than by the ABA this is about.                                   *)
  (*************************************************************************)

SeqBound == IF SeqModulus = 0 THEN 2 * NumRounds ELSE SeqModulus - 1

RoundPayload(k) == [i \in Words |-> k]
  \* Round k writes k into every word, so a complete payload is a constant
  \* function and "some single round's complete payload" is an equality.

IsEven(n) == n % 2 = 0
IsOdd(n)  == n % 2 = 1

VARIABLES
  seq,        \* the entry's sequence counter; ODD means a round is in flight
  data,       \* [Words -> Nat] the entry's payload, one word per index
  wround,     \* Nat, the round the writer is publishing (1 .. NumRounds)
  wi,         \* Nat, the writer's cursor over the payload words
  pcW,        \* STRING, writer program counter
  pcR,        \* [Readers -> STRING]
  s1,         \* [Readers -> Nat] the first seq load
  s2,         \* [Readers -> Nat] the second seq load
  s2taken,    \* [Readers -> BOOLEAN] the second load has already happened
  snap,       \* [Readers -> [Words -> Nat]] the in-progress snapshot
  ri,         \* [Readers -> Nat] the reader's cursor over the payload words
  res,        \* [Readers -> [Words -> Nat]] the snapshot the reader ACCEPTED
  acc,        \* [Readers -> BOOLEAN] this reader accepted a snapshot
  rprobe      \* ghost, non-vacuity only

wvars == <<seq, data, wround, wi, pcW>>
rvars == <<pcR, s1, s2, s2taken, snap, ri, res, acc>>
vars  == <<seq, data, wround, wi, pcW, pcR, s1, s2, s2taken, snap, ri, res,
           acc, rprobe>>

Init ==
  /\ seq = 0
  /\ data = RoundPayload(0)
  /\ wround = 1
  /\ wi = 1
  /\ pcW = "w0"
  /\ pcR = [r \in Readers |-> "r0"]
  /\ s1 = [r \in Readers |-> 0]
  /\ s2 = [r \in Readers |-> 0]
  /\ s2taken = [r \in Readers |-> FALSE]
  /\ snap = [r \in Readers |-> RoundPayload(0)]
  /\ ri = [r \in Readers |-> 1]
  /\ res = [r \in Readers |-> RoundPayload(0)]
  /\ acc = [r \in Readers |-> FALSE]
  /\ rprobe = [sawOdd |-> FALSE, recheckSaved |-> FALSE, rawTorn |-> FALSE,
               raceLoad |-> FALSE, accepted |-> FALSE, hoisted |-> FALSE,
               acceptedOdd |-> FALSE]

(***************************************************************************)
(* THE WRITER -- `runquotad`, and there is exactly one of it. Single-writer  *)
(* discipline is a MODELLING ASSUMPTION here, not a checked property: the   *)
(* spec makes it a mapping-permission rule (clients MUST NOT hold a         *)
(* writable mapping) and M13b gates it by inspection, which is the right    *)
(* instrument for it. A second writer would need a completely different     *)
(* structure, not a stronger invariant.                                     *)
(***************************************************************************)

ReaderInFlight == \E r \in Readers : pcR[r] \in {"rLoad", "rSeq2", "rCheck"}

W0 ==
  /\ pcW = "w0"
  /\ ~(WriterWaitsForReaders /\ ReaderInFlight)
     (*********************************************************************)
     (* THE MUTATION, and it is the only place a reader variable appears   *)
     (* in a writer guard. Shipped (`WriterWaitsForReaders = FALSE`) this  *)
     (* conjunct is TRUE and the writer's enabling condition mentions no   *)
     (* reader state at all. See `shm_lease_seqlock_wblock_MC.cfg`.        *)
     (*********************************************************************)
  /\ IF wround > NumRounds
     THEN /\ pcW' = "wDone"
          /\ UNCHANGED <<seq, wi>>
     ELSE /\ pcW' = (IF WriterOrdered THEN "wStore" ELSE "wEvenEarly")
          /\ seq' = NextSeq(seq)                  \* bump to ODD
          /\ wi' = 1
  /\ UNCHANGED <<data, wround>>
  /\ UNCHANGED rvars
  /\ UNCHANGED rprobe

WEvenEarly ==
  (*************************************************************************)
  (* MUTATION (`WriterOrdered = FALSE`): the bump back to EVEN is issued    *)
  (* BEFORE the payload stores. This is the protocol-order form of "the     *)
  (* publishing store was not a release store" -- the counter says stable    *)
  (* while the payload is still being written.                             *)
  (*************************************************************************)
  /\ pcW = "wEvenEarly"
  /\ seq' = NextSeq(seq)
  /\ pcW' = "wStore"
  /\ UNCHANGED <<data, wround, wi>>
  /\ UNCHANGED rvars
  /\ UNCHANGED rprobe

WStore ==
  \* One payload word, one step. This is where the tear lives.
  /\ pcW = "wStore"
  /\ wi <= PayloadWords
  /\ data' = [data EXCEPT ![wi] = wround]
  /\ wi' = wi + 1
  /\ UNCHANGED <<seq, wround, pcW>>
  /\ UNCHANGED rvars
  /\ UNCHANGED rprobe

WStoreDone ==
  /\ pcW = "wStore"
  /\ wi > PayloadWords
  /\ pcW' = (IF WriterOrdered THEN "wEven" ELSE "wNext")
  /\ UNCHANGED <<seq, data, wround, wi>>
  /\ UNCHANGED rvars
  /\ UNCHANGED rprobe

WEven ==
  \* The shipped publish: bump back to EVEN, which is what makes the round
  \* visible to a reader that validates.
  /\ pcW = "wEven"
  /\ seq' = NextSeq(seq)
  /\ pcW' = "wNext"
  /\ UNCHANGED <<data, wround, wi>>
  /\ UNCHANGED rvars
  /\ UNCHANGED rprobe

WNext ==
  /\ pcW = "wNext"
  /\ wround' = wround + 1
  /\ pcW' = "w0"
  /\ UNCHANGED <<seq, data, wi>>
  /\ UNCHANGED rvars
  /\ UNCHANGED rprobe

StepW == W0 \/ WEvenEarly \/ WStore \/ WStoreDone \/ WEven \/ WNext

(***************************************************************************)
(* THE READER -- any client, on the admission path, holding a READ-ONLY      *)
(* mapping. It takes ONE snapshot and stops; a reader that looped would     *)
(* multiply the graph without adding a window, because every window this    *)
(* protocol has is inside one attempt.                                     *)
(***************************************************************************)

RSeq1(r) ==
  /\ pcR[r] = "r0"
  /\ s1' = [s1 EXCEPT ![r] = seq]
  /\ pcR' = [pcR EXCEPT ![r] = "rParity"]
  /\ UNCHANGED <<s2, s2taken, snap, ri, res, acc>>
  /\ UNCHANGED wvars
  /\ UNCHANGED rprobe

RParityOdd(r) ==
  \* The counter is odd: a round is in flight, so there is nothing to read.
  \* RETRY. This is one of the two retries; the other is the s2 comparison.
  /\ pcR[r] = "rParity"
  /\ ReaderChecksParity
  /\ IsOdd(s1[r])
  /\ pcR' = [pcR EXCEPT ![r] = "r0"]
  /\ rprobe' = [rprobe EXCEPT !.sawOdd = TRUE]
  /\ UNCHANGED <<s1, s2, s2taken, snap, ri, res, acc>>
  /\ UNCHANGED wvars

RParityOk(r) ==
  /\ pcR[r] = "rParity"
  /\ (IsEven(s1[r]) \/ ~ReaderChecksParity)
  /\ pcR' = [pcR EXCEPT ![r] = "rLoad"]
  /\ ri' = [ri EXCEPT ![r] = 1]
  /\ rprobe' = [rprobe EXCEPT !.acceptedOdd = @ \/ IsOdd(s1[r])]
  /\ UNCHANGED <<s1, s2, s2taken, snap, res, acc>>
  /\ UNCHANGED wvars

RLoad(r) ==
  \* One payload word, one step, so the writer may interleave between them.
  \* `raceLoad` records that this load happened while a round was in flight,
  \* which is the state the whole protocol exists for.
  /\ pcR[r] = "rLoad"
  /\ ri[r] <= PayloadWords
  /\ snap' = [snap EXCEPT ![r][ri[r]] = data[ri[r]]]
  /\ ri' = [ri EXCEPT ![r] = ri[r] + 1]
  /\ rprobe' = [rprobe EXCEPT !.raceLoad = @ \/ IsOdd(seq)]
  /\ UNCHANGED <<pcR, s1, s2, s2taken, res, acc>>
  /\ UNCHANGED wvars

RSeq2Early(r) ==
  (*************************************************************************)
  (* MUTATION (`ReaderOrdered = FALSE`): the SECOND seq load fires while    *)
  (* the payload loads are still outstanding -- the reader validates a       *)
  (* counter it read BEFORE the data it is validating. This is the          *)
  (* protocol-order shadow of the pair herd7 settles in                     *)
  (* `litmus/seqlock-recheck-vs-payload*.litmus`, and it is the pair a      *)
  (* hand-written seqlock most often gets wrong.                           *)
  (*************************************************************************)
  /\ ~ReaderOrdered
  /\ pcR[r] = "rLoad"
  /\ ~s2taken[r]
  /\ s2' = [s2 EXCEPT ![r] = seq]
  /\ s2taken' = [s2taken EXCEPT ![r] = TRUE]
  /\ rprobe' = [rprobe EXCEPT !.hoisted = TRUE]
  /\ UNCHANGED <<pcR, s1, snap, ri, res, acc>>
  /\ UNCHANGED wvars

RLoadDone(r) ==
  /\ pcR[r] = "rLoad"
  /\ ri[r] > PayloadWords
  /\ pcR' = [pcR EXCEPT ![r] = "rSeq2"]
  /\ UNCHANGED <<s1, s2, s2taken, snap, ri, res, acc>>
  /\ UNCHANGED wvars
  /\ UNCHANGED rprobe

RSeq2(r) ==
  /\ pcR[r] = "rSeq2"
  /\ IF s2taken[r]
     THEN UNCHANGED <<s2, s2taken>>          \* already hoisted; do not re-read
     ELSE /\ s2' = [s2 EXCEPT ![r] = seq]
          /\ s2taken' = [s2taken EXCEPT ![r] = TRUE]
  /\ pcR' = [pcR EXCEPT ![r] = "rCheck"]
  /\ UNCHANGED <<s1, snap, ri, res, acc>>
  /\ UNCHANGED wvars
  /\ UNCHANGED rprobe

RawTorn(r) == \A k \in 0 .. NumRounds : snap[r] # RoundPayload(k)

RAccept(r) ==
  \* Validation passed (or, under the mutation, was never performed). The
  \* snapshot becomes the reader's answer.
  /\ pcR[r] = "rCheck"
  /\ (~ReaderRechecks \/ s2[r] = s1[r])
  /\ res' = [res EXCEPT ![r] = snap[r]]
  /\ acc' = [acc EXCEPT ![r] = TRUE]
  /\ pcR' = [pcR EXCEPT ![r] = "rDone"]
  /\ rprobe' = [rprobe EXCEPT !.accepted = TRUE, !.rawTorn = @ \/ RawTorn(r)]
  /\ UNCHANGED <<s1, s2, s2taken, snap, ri>>
  /\ UNCHANGED wvars

RRetry(r) ==
  \* The counter moved under the reader. Discard and start over. This is the
  \* action `shm_lease_seqlock_noretry_MC.cfg` DELETES, and the gate requires
  \* that deletion to break `NoTornRead`.
  /\ pcR[r] = "rCheck"
  /\ ReaderRechecks
  /\ s2[r] # s1[r]
  /\ pcR' = [pcR EXCEPT ![r] = "r0"]
  /\ s2taken' = [s2taken EXCEPT ![r] = FALSE]
  /\ rprobe' = [rprobe EXCEPT !.recheckSaved = TRUE,
                              !.rawTorn = @ \/ RawTorn(r)]
  /\ UNCHANGED <<s1, s2, snap, ri, res, acc>>
  /\ UNCHANGED wvars

StepR(r) ==
  \/ RSeq1(r) \/ RParityOdd(r) \/ RParityOk(r) \/ RLoad(r) \/ RSeq2Early(r)
  \/ RLoadDone(r) \/ RSeq2(r) \/ RAccept(r) \/ RRetry(r)

(***************************************************************************)
(* SPECS. There are TWO, and the difference between them is the whole       *)
(* content of "a writer never blocks on a reader".                          *)
(***************************************************************************)

AllDone == pcW = "wDone" /\ \A r \in Readers : pcR[r] = "rDone"

Terminating == AllDone /\ UNCHANGED vars

Next == StepW \/ (\E r \in Readers : StepR(r)) \/ Terminating

Spec == Init /\ [][Next]_vars
        /\ WF_vars(StepW)
        /\ \A r \in Readers : WF_vars(StepR(r))

SpecWriterOnly ==
  (*************************************************************************)
  (* THE WRITER-NEVER-BLOCKS SPEC: weak fairness for the WRITER ONLY.        *)
  (* Readers may take steps or may never take another step for the rest of  *)
  (* time -- a client descheduled, swapped out, stopped in a debugger, or     *)
  (* killed between its two seq loads. `WriterFinishes` must still hold.     *)
  (* This is the same device `shm_lease_wait.tla` uses to deny fairness to   *)
  (* `SpuriousWake`: withholding fairness is how you state that nothing may  *)
  (* depend on the other party moving.                                       *)
  (*************************************************************************)
  Init /\ [][Next]_vars /\ WF_vars(StepW)

(***************************************************************************)
(* INVARIANTS                                                              *)
(***************************************************************************)

TypeOK ==
  /\ seq \in 0 .. SeqBound
  /\ data \in [Words -> 0 .. NumRounds]
  /\ wround \in 1 .. (NumRounds + 1)
  /\ wi \in 1 .. (PayloadWords + 1)
  /\ pcW \in {"w0", "wEvenEarly", "wStore", "wEven", "wNext", "wDone"}
  /\ pcR \in [Readers -> {"r0", "rParity", "rLoad", "rSeq2", "rCheck", "rDone"}]
  /\ s1 \in [Readers -> 0 .. SeqBound]
  /\ s2 \in [Readers -> 0 .. SeqBound]

NoTornRead ==
  (*************************************************************************)
  (* THE GATE'S SENTENCE, TRANSCRIBED: "every value a reader returns is some *)
  (* single writer round's complete payload". Stated over what the reader   *)
  (* ACCEPTED (`res`), never over what it happened to load (`snap`), because *)
  (* a torn `snap` is not a defect -- it is the state the retry exists for,   *)
  (* and `shm_lease_seqlock_torn_probe.cfg` requires it to be reachable.     *)
  (*************************************************************************)
  \A r \in Readers :
    acc[r] => \E k \in 0 .. NumRounds : res[r] = RoundPayload(k)

WriterAlwaysEnabled ==
  (*************************************************************************)
  (* A WRITER NEVER BLOCKS ON A READER, as a state predicate: at every       *)
  (* reachable state, a writer with work left has a step it can take. No     *)
  (* reader can put the writer into a state where it must wait.              *)
  (*************************************************************************)
  (pcW # "wDone") => ENABLED StepW

ReaderAlwaysEnabled ==
  (*************************************************************************)
  (* AND THE MIRROR, which the spec demands separately: "No reader may       *)
  (* block, and no reader may fail." A reader that has not finished always   *)
  (* has a step available -- it may have to RETRY, but it never waits.        *)
  (*************************************************************************)
  \A r \in Readers : (pcR[r] # "rDone") => ENABLED StepR(r)

SeqParityMatchesRound ==
  (*************************************************************************)
  (* THE EVEN-ODD DISCIPLINE ITSELF: the counter is ODD exactly while a      *)
  (* round is in flight. This is what a reader's parity test is entitled to  *)
  (* conclude, and it is FALSE under `WriterOrdered = FALSE` -- which is why  *)
  (* that mutation's configuration does not list it.                         *)
  (*************************************************************************)
  IsOdd(seq) <=> pcW \in {"wStore", "wEven"}

AcceptedSeqEven ==
  \* A reader never accepts a snapshot it validated against an ODD counter.
  \A r \in Readers : acc[r] => IsEven(s1[r])

AcceptedMatchesCounter ==
  (*************************************************************************)
  (* SHARPER THAN `NoTornRead`, AND IT IS WHAT A SEQLOCK ACTUALLY PROMISES:  *)
  (* a snapshot validated against counter value `v` is exactly the payload   *)
  (* of the round `v` NAMES, not merely of some round. Round `k` completes   *)
  (* by leaving the counter at `2k`, so the accepted snapshot must be        *)
  (* `RoundPayload(v \div 2)`.                                               *)
  (*                                                                       *)
  (* WHAT MAKES IT TRUE IS COUNTER MONOTONICITY, and that is worth naming   *)
  (* because the structures spec never states it. `s2 = s1` is evidence that *)
  (* the entry did not change ONLY because the counter cannot return to a    *)
  (* value it has left. Under `SeqModulus > 0` it can, this invariant is     *)
  (* meaningless (`v \div 2` no longer names a round) and `NoTornRead` itself *)
  (* fails -- see `shm_lease_seqlock_wrap_MC.cfg`. So this invariant is       *)
  (* listed only in the non-wrapping configurations, and its absence from    *)
  (* the wrapping one is the point rather than an omission.                  *)
  (*                                                                       *)
  (* NOTE WHAT IS *NOT* CLAIMED: nothing here bounds STALENESS. A reader may  *)
  (* return round 2's payload long after round 3 was published, and the      *)
  (* transport spec permits exactly that ("a stale entry is a slightly worse  *)
  (* estimate, never an incorrect admission"). An earlier draft of this      *)
  (* module asserted the opposite -- that a reader accepting after the writer  *)
  (* had quiesced must hold the FINAL round -- and TLC refuted it at depth 27  *)
  (* with a reader that had snapshotted round 2 before the last round ran.   *)
  (* That refutation was correct and the invariant was wrong.                *)
  (*************************************************************************)
  SeqModulus = 0 =>
    \A r \in Readers : acc[r] => res[r] = RoundPayload(s1[r] \div 2)

(***************************************************************************)
(* LIVENESS                                                                *)
(***************************************************************************)

ReaderTerminates == <>(\A r \in Readers : pcR[r] = "rDone")
  \* READER TERMINATION UNDER A WRITER THAT EVENTUALLY STOPS. The writer
  \* publishes `NumRounds` rounds and halts; no reader may retry forever.

WriterFinishes == <>(pcW = "wDone")
  \* Checked under BOTH specs. Under `Spec` it is unremarkable; under
  \* `SpecWriterOnly`, where readers have no fairness and may simply stop
  \* forever, it is the statement that the writer does not depend on them.

(***************************************************************************)
(* NON-VACUITY. Checked as negations in `*_probe.cfg`; TLC MUST violate     *)
(* them. Without these, every green run above is consistent with a workload *)
(* in which the reader and the writer never actually met.                   *)
(***************************************************************************)

ProbeAllReached ==
  ~(/\ rprobe.sawOdd        \* a reader caught the counter ODD and retried
    /\ rprobe.recheckSaved  \* and a reader retried on the SECOND load's compare
    /\ rprobe.rawTorn       \* and a raw snapshot really was TORN before validation
    /\ rprobe.raceLoad      \* and a payload word was loaded MID-ROUND
    /\ rprobe.accepted)     \* and a reader nevertheless finished

ProbeRawTornReached == ~rprobe.rawTorn
  (*************************************************************************)
  (* THE ONE THAT MATTERS MOST. If a reader's raw snapshot is never torn,    *)
  (* `NoTornRead` is green because nothing tore, not because the retry       *)
  (* caught it -- and the model would prove nothing at all. TLC must produce  *)
  (* the behaviour in which the reader's own loads straddle a round.         *)
  (*************************************************************************)

ProbeRaceLoadReached == ~rprobe.raceLoad
  \* The narrower half: a payload load issued while the writer was inside a
  \* round, i.e. the reader and the writer are genuinely concurrent.

================================================================================
