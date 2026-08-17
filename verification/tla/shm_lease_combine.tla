------------------------- MODULE shm_lease_combine -------------------------
(***************************************************************************)
(* THE FLAT-COMBINING ARBITER of RunQuota's shared-memory admission path.   *)
(* MV2 -- MODELLED BEFORE M5 IMPLEMENTS IT, which is the point of the       *)
(* milestone: the model constrains the code rather than rationalising it.   *)
(*                                                                         *)
(* The contract being modelled is                                          *)
(* `reprobuild-specs/RunQuota-Shared-Memory-Transport.md` SS"3. Flat        *)
(* combining puts the policy in shared memory", SS"4. Structural crash       *)
(* safety is where the real design work is" and SS"Waiting Without          *)
(* Spinning" SS4 (grant-then-wake), pinned onto the segment layout in        *)
(* `RunQuota-Shared-Memory-Structures.md`: `LhOffReserved2` (offset 96, the *)
(* COMBINER ROLE WORD) and `LhOffReserved3` (offset 104, the COMBINE        *)
(* SEQUENCE).                                                              *)
(*                                                                         *)
(* ======================================================================= *)
(* THE PROTOCOL THIS MODEL PINS                                            *)
(* ======================================================================= *)
(*                                                                         *)
(* ROLE WORD (`LhOffReserved2`), one u64, CAS-mutated:                     *)
(*     [owner, epoch, committed]                                           *)
(*   `owner` is the anchor tag (boot id + pid + start time, collapsed here  *)
(*   to a process identity); `epoch` is the round this owner is running and *)
(*   INCREASES ON EVERY ACQUISITION, clean or stolen; `committed` is the    *)
(*   round's commit flag. Resolving the commit and the role transfer with   *)
(*   ONE CAS ON ONE WORD is not cosmetic -- see FINDING 4 in                *)
(*   verification/README.md. Putting the flag in THIS word is one of the    *)
(*   two ways to do that, and it is the one modelled here.                  *)
(*                                                                         *)
(* COMBINE SEQUENCE (`LhOffReserved3`), one u64, MONOTONE:                  *)
(*     `cseq` = the highest epoch whose round is committed.                 *)
(*   A ledger entry is EFFECTIVE iff its stamp is <= `cseq`. So `cseq` is   *)
(*   both the durable record of "was this round applied" that the spec asks *)
(*   the sequence number to provide, and the switch that makes a whole      *)
(*   round take effect at once.                                            *)
(*                                                                         *)
(* PER-SLOT LEDGER ENTRY `res[q]`, one u64, CAS-mutated:                    *)
(*     [epoch, dec, amt]                                                    *)
(*   The outcome word. `epoch` is the stamp. EVERY mutation of it is a CAS  *)
(*   whose expected value carries an epoch, which is what makes a stale     *)
(*   combiner's write FAIL rather than corrupt.                             *)
(*                                                                         *)
(* BUDGET WORD: a CACHE of `Capacity - sum of effective grants`, recomputed *)
(*   and never incrementally mutated. See FINDING 6 -- an incrementally      *)
(*   mutated budget word cannot be made crash-safe by a sequence number,    *)
(*   because the decrement and the stamp are two words.                     *)
(*                                                                         *)
(* WAIT SLOT `wire[q]`: [val, tag, amt, dec] -- the M3 wait word plus its    *)
(*   payload. The PUBLISHED VALUE IS THE EPOCH, not a counter bump, which   *)
(*   is what makes republication after a steal idempotent.                  *)
(*                                                                         *)
(* A ROUND, in order, every step one atomic word write:                     *)
(*   1. SeqRepair  -- any process: if the role word says committed and       *)
(*                    `cseq` has not caught up, advance `cseq`. PUBLIC and  *)
(*                    IDEMPOTENT, and it MUST precede an acquisition, or a  *)
(*                    steal would erase the only record that the previous   *)
(*                    round committed.                                     *)
(*   2. TryRole / Steal -- CAS the role word to [me, epoch+1, FALSE].        *)
(*   3. cRaise    -- per slot: CAS every NON-EFFECTIVE entry with an older   *)
(*                   stamp up to my epoch, decision cleared. This is the    *)
(*                   DISCARD of a half-applied round AND the fence that     *)
(*                   blocks the previous owner's proposals.                 *)
(*   4. cScan     -- per pending slot: CAS [myEpoch, none, 0] ->             *)
(*                   [myEpoch, grant|refuse, amt], deciding against the      *)
(*                   effective ledger plus this round's own proposals.       *)
(*   5. cCommit   -- CAS role [me, e, FALSE] -> [me, e, TRUE]. THE           *)
(*                   LINEARISATION POINT of the whole round.                 *)
(*   6. cSeq      -- advance `cseq` to e (same operation as SeqRepair).       *)
(*   7. cRefresh  -- recompute the budget cache from the effective ledger.    *)
(*   8. cPub      -- per effective entry: payload, then the value, which is   *)
(*                   the entry's epoch. Grant-then-wake, idempotent.         *)
(*   9. cRel      -- release: role := [none, e, TRUE].                        *)
(*                                                                         *)
(* ======================================================================= *)
(* WHAT IS MODELLED FAITHFULLY                                             *)
(* ======================================================================= *)
(*                                                                         *)
(*  1. DEATH AT EVERY STEP AT WHICH A REQUEST IS OUTSTANDING. `Die(p)` is   *)
(*     enabled at every program counter except `idle`, and only on a `live` *)
(*     process -- so in particular at EVERY step of a combine round, at both *)
(*     halves of a publication, and while a waiter is mid-collection. A     *)
(*     dead process never takes another step. A model that only kills       *)
(*     between rounds proves nothing about the case this milestone exists   *)
(*     for.                                                                *)
(*                                                                         *)
(*     THE TWO EXCLUSIONS, STATED SO A READER CAN JUDGE THEM. `pc = "idle"` *)
(*     is excluded: nothing is published there, the process holds nothing,  *)
(*     and killing it is indistinguishable from it never having run. And    *)
(*     `alive[p] = "stalled"` is excluded from `Die` DIRECTLY -- but         *)
(*     "descheduled and then killed" is still reachable as                  *)
(*     `Stall` -> `Resume` -> `Die`, at the cost of TWO faults. So it is     *)
(*     reachable in the three `MaxFaults = 2` configurations -- MC_probe,   *)
(*     f2 and unfenced_damage -- and NOT in any `MaxFaults = 1` one.        *)
(*                                                                         *)
(*  2. THE FALSE-POSITIVE STEAL, which is HARDER than death and is the      *)
(*     case a kill-injection suite cannot reach. `Stall(p)` descheduled a    *)
(*     combiner; the steal detector fires; the stealer runs; and then       *)
(*     `Resume(p)` puts the original combiner back ON THE SAME ROUND with   *)
(*     stale locals. With `StealFromLive = TRUE` the detector may even fire  *)
(*     on a RUNNING combiner, i.e. a fully arbitrary timeout. Everything    *)
(*     the resurrected combiner then does is a real step, not an abort.     *)
(*                                                                         *)
(*  3. EVERY SHARED MUTATION IS A CAS WITH AN EXPECTED VALUE, and the       *)
(*     expected value is written as a guard on the action. That is what     *)
(*     makes "the stale write fails" a checked consequence rather than an   *)
(*     assumption.                                                         *)
(*                                                                         *)
(*  4. PUBLICATION IS TWO STEPS -- payload, then value -- so the grant-then- *)
(*     wake window is present and a death between them is reachable.        *)
(*                                                                         *)
(*  5. NON-BLOCKING ADMISSION (SM-8). A process that finds the role taken   *)
(*     neither spins nor parks; it stays pending and may retry or collect.  *)
(*                                                                         *)
(* ======================================================================= *)
(* WHAT IS ABSTRACTED -- read this before quoting any result                *)
(* ======================================================================= *)
(*                                                                         *)
(*  - SEQUENTIALLY-CONSISTENT INTERLEAVINGS, as in MV1. TLC does not model  *)
(*    ARMv8 or x86-TSO reordering. The release/acquire pairing on the       *)
(*    payload/value pair is ASSUMED to work; that it does is the litmus     *)
(*    tier's question and `litmus/grant-payload-publish.litmus` answers it.  *)
(*                                                                         *)
(*  - ONE BUDGET DIMENSION, not the packed four. The packed borrow hazard   *)
(*    is MV1's ground (`shm_lease_claim.tla`, `NoBorrow`) and re-modelling  *)
(*    it here would multiply the state space to re-prove a property already *)
(*    proved. What MV2 is about is WHOSE arithmetic runs and whether it     *)
(*    survives a death, not how the word is packed.                        *)
(*                                                                         *)
(*  - THE PARK/WAKE MACHINERY IS NOT RE-MODELLED. MV1's                    *)
(*    `shm_lease_wait.tla` exhausts the kernel compare-and-park, the        *)
(*    pre-park window, spurious wakeups and the waker's fast path. Here a   *)
(*    waiter observes `wire[q].val` moving and then reads the payload, as   *)
(*    TWO steps, so the payload-overwrite window is preserved -- which is    *)
(*    the only part of the wait protocol MV2's invariants depend on. The     *)
(*    two models COMPOSE: MV2 says WHICH grant is published and HOW MANY    *)
(*    TIMES, MV1 says the waiter cannot sleep through it.                   *)
(*                                                                         *)
(*  - ONE REQUEST PER PROCESS per behaviour. A slot is never reused for a   *)
(*    second request, so requeue-after-refusal is out of scope. This is a   *)
(*    real exclusion: M6's anti-starvation gate needs a refused request to  *)
(*    STAY queued and be re-decided in a later round. Nothing in this       *)
(*    protocol precludes that -- a requeue is a fresh proposal into a slot   *)
(*    whose entry is stamped with an older epoch, which `cRaise` already    *)
(*    handles -- but this model does not check it.                          *)
(*                                                                         *)
(*  - THE STEAL DETECTOR IS AN ORACLE, not a timeout. `Steal` is enabled    *)
(*    whenever the role holder is not currently runnable (dead or stalled), *)
(*    and additionally on a RUNNING holder when `StealFromLive = TRUE`. So   *)
(*    the model never assumes the detector is accurate; it assumes only     *)
(*    that a detector EXISTS. Bounding the timeout is M7's job.             *)
(*                                                                         *)
(*  - RECLAMATION IS OUT OF SCOPE. A dead process's granted capacity stays  *)
(*    taken here. That leak is SM-6 and M7, and modelling it would confuse  *)
(*    "the combine conserved capacity" with "the owner gave it back".       *)
(*                                                                         *)
(*  - A GUARD AND ITS WRITE ARE ONE STEP, AND EIGHT ACTIONS READ A SHARED   *)
(*    WORD OTHER THAN THE ONE THEY WRITE. Only `CCommit` (fenced branch)    *)
(*    and `CRelease` are single-word guard-and-write; `SeqRepair`,          *)
(*    `TryRole`/`Steal`, `CRaiseOne`, `CDecide`, `CSeq`, `CRefresh`,       *)
(*    `CPubPayload` and `CPubValue` are not, and `CDecide` writes TWO       *)
(*    shared words under `BudgetIsCache = FALSE`. Each is individually      *)
(*    defensible -- by the epoch stamp invalidating an interfering writer's  *)
(*    CAS, by `cseq` being frozen for the duration of a live round, or by   *)
(*    the written word being a self-healing cache -- but those arguments are *)
(*    STATED AND NOT CHECKED. `verification/README.md` enumerates all       *)
(*    eight with the argument for each; read it before quoting any result   *)
(*    about a step whose implementation would need more than one access.    *)
(*                                                                         *)
(*  - CROSS-SLOT MISDELIVERY IS NOT REPRESENTABLE. Slots are addressed by   *)
(*    the process that owns them, so "a waiter receives a grant meant for   *)
(*    another WAITER" cannot occur by construction. The other reading of    *)
(*    the gate's clause -- a waiter receiving a grant meant for another      *)
(*    REQUEST -- is representable and is checked by `GrantCoherent`, which   *)
(*    has two failing configurations.                                       *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
  Procs,             \* the client processes; each owns one slot and may combine
  Capacity,          \* the budget, ONE dimension
  Want,              \* [Procs -> Nat] what each process asks for
  MaxEpochs,         \* bound on role acquisitions (see EpochBoundNotBinding)
  MaxFaults,         \* bound on death + stall injections
  IdempotentPublish, \* TRUE = published value IS the epoch; FALSE = counter bump
  BudgetIsCache,     \* TRUE = budget recomputed from the ledger; FALSE = decremented
  SerialisePerSlot,  \* TRUE = an effective, uncollected decision is never re-decided
  AllowSteal,        \* TRUE = the steal protocol exists
  StealFromLive,     \* TRUE = the detector may fire on a RUNNING combiner
  AllowStall,        \* TRUE = a combiner may be descheduled and later resume
  CommitFencedByRole,\* TRUE = the commit flag lives INSIDE the role word
  CountOwnProposals  \* TRUE = the fit test sees THIS round's own grants

NoOwner == "none"

CombinerPCs == {"cRaise", "cScan", "cCommit", "cSeq", "cRefresh", "cPub", "cRel"}

VARIABLES
  role,      \* [owner, epoch, committed]      -- LhOffReserved2
  cseq,      \* Nat, highest COMMITTED epoch   -- LhOffReserved3
  budget,    \* Nat, the budget word
  res,       \* [Procs -> [epoch, dec, amt]]   -- the per-slot ledger entry
  wire,      \* [Procs -> [val, tag, amt, dec]] -- the wait slot + payload
  reqst,     \* [Procs -> {"idle", "pending"}]
  pc,        \* [Procs -> STRING]
  ep,        \* [Procs -> Nat] the epoch this process is running (0 = none)
  pubd,      \* [Procs -> SUBSET Procs] slots published in THIS round (round-local)
  pubcur,    \* [Procs -> Procs \cup {NoOwner}] the slot mid-publication
  alive,     \* [Procs -> {"live", "stalled", "dead"}]
  seenVal,   \* [Procs -> Nat] the value this waiter has acknowledged
  obsVal,    \* [Procs -> Nat] the value it observed but has not yet read behind
  ncol,      \* [Procs -> Nat] outcomes collected
  ngrant,    \* [Procs -> Nat] GRANTS collected -- NoDoubleGrant is about this
  colAmt,    \* [Procs -> Nat] the amount the waiter believes it holds
  badTag,    \* BOOLEAN: some waiter read a payload not published with the value it saw
  eres,      \* [1..MaxEpochs -> {"open", "completed", "discarded"}]
  edisc,     \* SUBSET 1..MaxEpochs: every epoch EVER marked discarded (history)
  faults,    \* Nat, injections left
  cprobe

vars == <<role, cseq, budget, res, wire, reqst, pc, ep, pubd, pubcur, alive,
          seenVal, obsVal, ncol, ngrant, colAmt, badTag, eres, edisc, faults,
          cprobe>>

(***************************************************************************)
(* DERIVED VIEWS OF THE LEDGER                                             *)
(***************************************************************************)

RECURSIVE SumAmt(_)
SumAmt(S) == IF S = {} THEN 0
             ELSE LET q == CHOOSE x \in S : TRUE
                  IN res[q].amt + SumAmt(S \ {q})

Effective(q) == res[q].dec = "grant" /\ res[q].epoch <= cseq

EffSet == {q \in Procs : Effective(q)}

Held == SumAmt(EffSet)
  \* What the COMMITTED ledger says is taken. This, not the budget word, is
  \* the authority -- which is the whole of FINDING 6.

PropSet(e) == {q \in Procs : res[q].dec = "grant" /\ res[q].epoch = e}

DecidedIn(e) == {q \in Procs : res[q].epoch = e /\ res[q].dec # "none"}

Quiet ==
  /\ role.owner = NoOwner
  /\ \A p \in Procs : pc[p] \notin CombinerPCs
  /\ \A p \in Procs : pubcur[p] = NoOwner

Init ==
  /\ role = [owner |-> NoOwner, epoch |-> 0, committed |-> TRUE]
  /\ cseq = 0
  /\ budget = Capacity
  /\ res = [p \in Procs |-> [epoch |-> 0, dec |-> "none", amt |-> 0]]
  /\ wire = [p \in Procs |-> [val |-> 0, tag |-> 0, amt |-> 0, dec |-> "none"]]
  /\ reqst = [p \in Procs |-> "idle"]
  /\ pc = [p \in Procs |-> "idle"]
  /\ ep = [p \in Procs |-> 0]
  /\ pubd = [p \in Procs |-> {}]
  /\ pubcur = [p \in Procs |-> NoOwner]
  /\ alive = [p \in Procs |-> "live"]
  /\ seenVal = [p \in Procs |-> 0]
  /\ obsVal = [p \in Procs |-> 0]
  /\ ncol = [p \in Procs |-> 0]
  /\ ngrant = [p \in Procs |-> 0]
  /\ colAmt = [p \in Procs |-> 0]
  /\ badTag = FALSE
  /\ eres = [e \in 1 .. MaxEpochs |-> "open"]
  /\ edisc = {}
  /\ faults = MaxFaults
  /\ cprobe = [acquired |-> FALSE, stole |-> FALSE, stoleFromLive |-> FALSE,
               diedMidRound |-> FALSE, discarded |-> FALSE,
               completedByOther |-> FALSE, granted |-> FALSE, refused |-> FALSE,
               resumed |-> FALSE, fenced |-> FALSE, redelivered |-> FALSE,
               diedMidPublish |-> FALSE]

(***************************************************************************)
(* THE REQUESTER SIDE                                                      *)
(***************************************************************************)

Unch(x) == UNCHANGED x

RPublish(p) ==
  \* Publish the request into shared memory. Release store; nothing waits.
  /\ alive[p] = "live"
  /\ pc[p] = "idle"
  /\ reqst' = [reqst EXCEPT ![p] = "pending"]
  /\ pc' = [pc EXCEPT ![p] = "pending"]
  /\ UNCHANGED <<role, cseq, budget, res, wire, ep, pubd, pubcur, alive,
                 seenVal, obsVal, ncol, ngrant, colAmt, badTag, eres, edisc, faults,
                 cprobe>>

RSee(p) ==
  \* The wait word moved. ONE atomic load. (MV1 exhausts how the waiter got
  \* here -- fast path, park, kernel compare, spurious wake. See ABSTRACTED.)
  /\ alive[p] = "live"
  /\ pc[p] \in {"pending", "settled"}
  /\ wire[p].val # seenVal[p]
  /\ obsVal' = [obsVal EXCEPT ![p] = wire[p].val]
  /\ pc' = [pc EXCEPT ![p] = IF pc[p] = "settled" THEN "reReading" ELSE "reading"]
  /\ cprobe' = [cprobe EXCEPT !.redelivered = @ \/ (pc[p] = "settled")]
  /\ UNCHANGED <<role, cseq, budget, res, wire, reqst, ep, pubd, pubcur, alive,
                 seenVal, ncol, ngrant, colAmt, badTag, eres, edisc, faults>>

RRead(p) ==
  \* Read the payload AFTER observing the value. A SEPARATE step, so the
  \* overwrite window MV1 found is present here too.
  /\ alive[p] = "live"
  /\ pc[p] \in {"reading", "reReading"}
  /\ badTag' = (badTag \/ (wire[p].tag # obsVal[p]))
  /\ ncol' = [ncol EXCEPT ![p] = @ + 1]
  /\ ngrant' = [ngrant EXCEPT ![p] = @ + (IF wire[p].dec = "grant" THEN 1 ELSE 0)]
  /\ colAmt' = [colAmt EXCEPT ![p] = wire[p].amt]
  /\ seenVal' = [seenVal EXCEPT ![p] = obsVal[p]]
  /\ pc' = [pc EXCEPT ![p] = "settled"]
  /\ UNCHANGED <<role, cseq, budget, res, wire, reqst, ep, pubd, pubcur, alive,
                 obsVal, eres, edisc, faults, cprobe>>

(***************************************************************************)
(* THE COMBINE SEQUENCE WORD -- a PUBLIC, IDEMPOTENT repair.                *)
(*                                                                         *)
(* This is the step that makes "was this round applied" decidable. The role *)
(* word carries the commit flag, `cseq` carries the durable record, and any *)
(* process may copy one into the other. It MUST run before an acquisition:  *)
(* a steal overwrites the role word, and with it the only evidence that the *)
(* previous round committed.                                               *)
(***************************************************************************)

SeqNeedsRepair == role.committed /\ role.epoch > cseq /\ role.epoch > 0

SeqRepair(p) ==
  /\ alive[p] = "live"
  /\ SeqNeedsRepair
  /\ cseq' = role.epoch
  /\ eres' = [eres EXCEPT ![role.epoch] = "completed"]
  /\ UNCHANGED <<role, budget, res, wire, reqst, pc, ep, pubd, pubcur, alive,
                 seenVal, obsVal, ncol, ngrant, colAmt, badTag, edisc, faults,
                 cprobe>>

(***************************************************************************)
(* ROLE ACQUISITION -- a CAS on the role word. The epoch ALWAYS increases,   *)
(* clean acquisition or steal alike, because it is the fence.               *)
(***************************************************************************)

WorkPending ==
  (*************************************************************************)
  (* "IS THERE ANYTHING TO COMBINE." A client takes the role only while some *)
  (* published request has NOT YET RECEIVED A PUBLISHED ANSWER, and the test  *)
  (* for that is `wire[q].val = 0` -- THE VALUE WORD, NOT THE PAYLOAD.        *)
  (*                                                                        *)
  (* BOTH HALVES OF THAT SENTENCE COST A DEADLOCK TO LEARN, and TLC found     *)
  (* each of them:                                                          *)
  (*                                                                        *)
  (*  - Testing the LEDGER (`res[q].dec = "none"`) deadlocks in 157 states:  *)
  (*    a combiner that died having DECIDED every request but COMMITTED none  *)
  (*    leaves a state in which no survivor sees work, so nobody steals and   *)
  (*    every request is stranded. An uncommitted decision is not progress.   *)
  (*                                                                        *)
  (*  - Testing the PAYLOAD (`wire[q].dec = "none"`) deadlocks in 711 states: *)
  (*    a combiner that died BETWEEN the payload store and the value bump     *)
  (*    leaves a slot whose payload is written and whose waiter has been told *)
  (*    nothing. The value word is the publication marker -- it is what the    *)
  (*    waiter waits on -- so it is the only sound test, and the liveness of    *)
  (*    the whole steal protocol turns on the recovery test and the waiter's   *)
  (*    test being THE SAME test.                                             *)
  (*                                                                        *)
  (* It is also what keeps the epoch counter from being burned on empty      *)
  (* rounds, which is what lets `EpochBoundNotBinding` come back green and    *)
  (* therefore what makes `MaxEpochs` a non-constraint rather than a bound.   *)
  (*************************************************************************)
  \E q \in Procs : reqst[q] = "pending" /\ wire[q].val = 0

PrevRoundUnresolved ==
  (*************************************************************************)
  (* "IS THE ROUND I AM ABOUT TO OVERWRITE STILL UNRESOLVED." The acquirer  *)
  (* reads this to decide whether it is DISCARDING a half-applied round.    *)
  (*                                                                       *)
  (* THIS READ IS TOGGLED BY `CommitFencedByRole` TOGETHER WITH THE COMMIT  *)
  (* WRITE, AND THAT PAIRING IS NOT COSMETIC. Under the shipped design the  *)
  (* commit is a bit inside the role word, so the acquirer's CAS reads it   *)
  (* for free and `~role.committed` is the test. Under                     *)
  (* `CommitFencedByRole = FALSE` THAT BIT DOES NOT EXIST -- the commit is a *)
  (* monotone store on `cseq` -- so an implementer of that design has no bit *)
  (* to read and writes the test the design does give them: "has `cseq`     *)
  (* caught up with the round the role word names?".                       *)
  (*                                                                       *)
  (* Deleting the WRITE while leaving the READ would model neither design.  *)
  (* It would make the bit permanently FALSE, so EVERY acquisition over a   *)
  (* decided round -- including one that committed cleanly -- would be       *)
  (* labelled "discarded", and the counterexample TLC printed would be a    *)
  (* mislabelling rather than a protocol defect. Finding 4's evidence       *)
  (* depends on this predicate being the alternative design's OWN test.     *)
  (*************************************************************************)
  IF CommitFencedByRole
  THEN ~role.committed /\ role.epoch > 0
  ELSE role.epoch > cseq   \* `role.epoch > 0` is implied: cseq >= 0.

TakeRole(p, stolen) ==
  /\ role.epoch < MaxEpochs
  /\ ~SeqNeedsRepair
  /\ WorkPending
  /\ role' = [owner |-> p, epoch |-> role.epoch + 1, committed |-> FALSE]
  /\ ep' = [ep EXCEPT ![p] = role.epoch + 1]
  /\ pubd' = [pubd EXCEPT ![p] = {}]
  /\ pc' = [pc EXCEPT ![p] = "cRaise"]
  /\ LET disc == PrevRoundUnresolved /\ DecidedIn(role.epoch) # {}
     IN /\ eres' = IF disc THEN [eres EXCEPT ![role.epoch] = "discarded"] ELSE eres
        /\ edisc' = IF disc THEN edisc \cup {role.epoch} ELSE edisc
  /\ cprobe' = [cprobe EXCEPT
                  !.acquired = @ \/ ~stolen,
                  !.stole = @ \/ stolen,
                  !.stoleFromLive = @ \/ (stolen /\ role.owner # NoOwner
                                          /\ alive[role.owner] = "live"),
                  !.discarded = @ \/ (PrevRoundUnresolved
                                      /\ DecidedIn(role.epoch) # {})]
  /\ UNCHANGED <<cseq, budget, res, wire, reqst, pubcur, alive, seenVal,
                 obsVal, ncol, ngrant, colAmt, badTag, faults>>

TryRole(p) ==
  \* SM-8: a process that does NOT get the role neither spins nor parks; it
  \* simply stays pending and the engine runs other work.
  /\ alive[p] = "live"
  /\ pc[p] = "pending"
  /\ role.owner = NoOwner
  /\ TakeRole(p, FALSE)

Steal(p) ==
  \* The steal path. The detector is an oracle (see ABSTRACTED): it fires on a
  \* holder that is not currently runnable, and -- when `StealFromLive` -- on one
  \* that is, which is a fully arbitrary timeout.
  /\ AllowSteal
  /\ alive[p] = "live"
  /\ pc[p] = "pending"
  /\ role.owner # NoOwner
  /\ role.owner # p
  /\ (alive[role.owner] # "live" \/ StealFromLive)
  /\ TakeRole(p, TRUE)

(***************************************************************************)
(* THE ROUND. Every step below is one atomic word write, and `Die` is        *)
(* enabled between any two of them.                                         *)
(***************************************************************************)

NonEffective(q) == res[q].dec = "none" \/ res[q].epoch > cseq

RaiseNeeded(p, q) ==
  \* Raise every entry that is NOT effective up to my epoch, clearing its
  \* decision. This is BOTH the discard of a half-applied round AND the fence
  \* that blocks the previous owner: after it, that owner's proposal CAS
  \* (which expects its OWN epoch) can no longer match.
  /\ res[q].epoch < ep[p]
  /\ (SerialisePerSlot => NonEffective(q))

CRaiseOne(p) ==
  /\ alive[p] = "live"
  /\ pc[p] = "cRaise"
  /\ \E q \in Procs :
       /\ RaiseNeeded(p, q)
       /\ res' = [res EXCEPT ![q] = [epoch |-> ep[p], dec |-> "none", amt |-> 0]]
  /\ UNCHANGED <<role, cseq, budget, wire, reqst, pc, ep, pubd, pubcur, alive,
                 seenVal, obsVal, ncol, ngrant, colAmt, badTag, eres, edisc, faults,
                 cprobe>>

CRaiseDone(p) ==
  /\ alive[p] = "live"
  /\ pc[p] = "cRaise"
  /\ \A q \in Procs : ~RaiseNeeded(p, q)
  /\ pc' = [pc EXCEPT ![p] = "cScan"]
  /\ UNCHANGED <<role, cseq, budget, res, wire, reqst, ep, pubd, pubcur, alive,
                 seenVal, obsVal, ncol, ngrant, colAmt, badTag, eres, edisc, faults,
                 cprobe>>

DecideNeeded(p, q) ==
  /\ reqst[q] = "pending"
  /\ res[q].epoch = ep[p]
  /\ res[q].dec = "none"

Avail(p) ==
  (*************************************************************************)
  (* THE FIT TEST. `CountOwnProposals = FALSE` is the MUTATION and it is the *)
  (* single most plausible bug in a BULK-ADMISSION round: decide every       *)
  (* request in the round against the view the round STARTED with, because   *)
  (* the round's own grants are not effective yet -- they are stamped with an *)
  (* epoch above `cseq` by construction. Every individual decision is then   *)
  (* correct against a real state of the budget, and their sum overcommits.  *)
  (*************************************************************************)
  IF BudgetIsCache
  THEN Capacity - Held - (IF CountOwnProposals THEN SumAmt(PropSet(ep[p])) ELSE 0)
  ELSE budget

CDecide(p) ==
  \* The combiner's global view: it decides against the effective ledger plus
  \* this round's own uncommitted proposals. Bulk admission -- one round settles
  \* every pending request. A CAS from [myEpoch, none, 0].
  /\ alive[p] = "live"
  /\ pc[p] = "cScan"
  /\ \E q \in Procs :
       /\ DecideNeeded(p, q)
       /\ LET fits == Want[q] <= Avail(p) IN
          /\ res' = [res EXCEPT ![q] =
                       [epoch |-> ep[p],
                        dec |-> IF fits THEN "grant" ELSE "refuse",
                        amt |-> IF fits THEN Want[q] ELSE 0]]
          /\ budget' = IF ~BudgetIsCache /\ fits THEN budget - Want[q] ELSE budget
          /\ cprobe' = [cprobe EXCEPT !.granted = @ \/ fits,
                                      !.refused = @ \/ ~fits]
  /\ UNCHANGED <<role, cseq, wire, reqst, pc, ep, pubd, pubcur, alive, seenVal,
                 obsVal, ncol, ngrant, colAmt, badTag, eres, edisc, faults>>

CScanDone(p) ==
  /\ alive[p] = "live"
  /\ pc[p] = "cScan"
  /\ \A q \in Procs : ~DecideNeeded(p, q)
  /\ pc' = [pc EXCEPT ![p] = "cCommit"]
  /\ UNCHANGED <<role, cseq, budget, res, wire, reqst, ep, pubd, pubcur, alive,
                 seenVal, obsVal, ncol, ngrant, colAmt, badTag, eres, edisc, faults,
                 cprobe>>

CCommit(p) ==
  \* THE LINEARISATION POINT. A CAS on the role word from [me, e, FALSE] to
  \* [me, e, TRUE]. A combiner that was stolen from CANNOT execute it, because
  \* the stealer already replaced the word -- which is why the commit flag lives
  \* in the role word and not beside it.
  \*
  \* `CommitFencedByRole = FALSE` is the MUTATION, and it is not a strawman: it
  \* is the obvious implementation, in which the commit is a monotone store on
  \* the SEPARATE combine-sequence word and the role word is only a lock. A
  \* stolen-from combiner can still execute it, because nothing it touches was
  \* changed by the steal.
  /\ alive[p] = "live"
  /\ pc[p] = "cCommit"
  /\ IF CommitFencedByRole
     THEN /\ role.owner = p
          /\ role.epoch = ep[p]
          /\ ~role.committed
          /\ role' = [role EXCEPT !.committed = TRUE]
          /\ UNCHANGED <<cseq, eres>>
     ELSE /\ cseq < ep[p]
          /\ cseq' = ep[p]
          /\ eres' = [eres EXCEPT ![ep[p]] = "completed"]
          /\ UNCHANGED role
  /\ pc' = [pc EXCEPT ![p] = "cSeq"]
  /\ UNCHANGED <<budget, res, wire, reqst, ep, pubd, pubcur, alive,
                 seenVal, obsVal, ncol, ngrant, colAmt, badTag, edisc, faults,
                 cprobe>>

CSeq(p) ==
  /\ alive[p] = "live"
  /\ pc[p] = "cSeq"
  /\ IF SeqNeedsRepair
     THEN /\ cseq' = role.epoch
          /\ eres' = [eres EXCEPT ![role.epoch] = "completed"]
     ELSE UNCHANGED <<cseq, eres>>
  /\ pc' = [pc EXCEPT ![p] = "cRefresh"]
  /\ UNCHANGED <<role, budget, res, wire, reqst, ep, pubd, pubcur, alive,
                 seenVal, obsVal, ncol, ngrant, colAmt, badTag, edisc, faults,
                 cprobe>>

CRefresh(p) ==
  \* Recompute the budget CACHE from the effective ledger. Idempotent and
  \* self-healing: a process that dies here leaves a stale cache, and the next
  \* combiner recomputes it. Under `BudgetIsCache = FALSE` this step does not
  \* exist and the word is authoritative -- see FINDING 6.
  /\ alive[p] = "live"
  /\ pc[p] = "cRefresh"
  /\ budget' = IF BudgetIsCache THEN Capacity - Held ELSE budget
  /\ pc' = [pc EXCEPT ![p] = "cPub"]
  /\ UNCHANGED <<role, cseq, res, wire, reqst, ep, pubd, pubcur, alive, seenVal,
                 obsVal, ncol, ngrant, colAmt, badTag, eres, edisc, faults, cprobe>>

PubNeeded(p, q) ==
  /\ res[q].dec # "none"
  /\ res[q].epoch <= cseq
  /\ IF IdempotentPublish
     THEN wire[q].val # res[q].epoch  \* a DURABLE test on shared state
     ELSE q \notin pubd[p]            \* ROUND-LOCAL memory a stealer does not have

NewVal(q) == IF IdempotentPublish THEN res[q].epoch ELSE wire[q].val + 1

CPubPayload(p) ==
  \* Step 1 of grant-then-wake: the payload, tagged with the value that is about
  \* to be published, so "the waiter read the payload that went with the value
  \* it saw" is a checkable equality (as in MV1's `shm_lease_wait.tla`).
  /\ alive[p] = "live"
  /\ pc[p] = "cPub"
  /\ pubcur[p] = NoOwner
  /\ \E q \in Procs :
       /\ PubNeeded(p, q)
       /\ wire' = [wire EXCEPT ![q] = [val |-> wire[q].val,
                                       tag |-> NewVal(q),
                                       amt |-> res[q].amt,
                                       dec |-> res[q].dec]]
       /\ pubcur' = [pubcur EXCEPT ![p] = q]
  /\ UNCHANGED <<role, cseq, budget, res, reqst, pc, ep, pubd, alive, seenVal,
                 obsVal, ncol, ngrant, colAmt, badTag, eres, edisc, faults, cprobe>>

CPubValue(p) ==
  \* Step 2: the RELEASE bump. Under the shipped design the value written is the
  \* entry's EPOCH, so republishing after a steal writes the same word twice and
  \* the waiter sees one transition. Under `IdempotentPublish = FALSE` it is a
  \* bare counter bump -- which is what `publishGrant` does today.
  /\ alive[p] = "live"
  /\ pc[p] = "cPub"
  /\ pubcur[p] # NoOwner
  /\ LET q == pubcur[p] IN
     /\ wire' = [wire EXCEPT ![q].val = wire[q].tag]
     /\ pubd' = [pubd EXCEPT ![p] = @ \cup {q}]
     /\ cprobe' = [cprobe EXCEPT !.completedByOther = @ \/ (res[q].epoch # ep[p])]
  /\ pubcur' = [pubcur EXCEPT ![p] = NoOwner]
  /\ UNCHANGED <<role, cseq, budget, res, reqst, pc, ep, alive, seenVal, obsVal,
                 ncol, ngrant, colAmt, badTag, eres, edisc, faults>>

CPubDone(p) ==
  /\ alive[p] = "live"
  /\ pc[p] = "cPub"
  /\ pubcur[p] = NoOwner
  /\ \A q \in Procs : ~PubNeeded(p, q)
  /\ pc' = [pc EXCEPT ![p] = "cRel"]
  /\ UNCHANGED <<role, cseq, budget, res, wire, reqst, ep, pubd, pubcur, alive,
                 seenVal, obsVal, ncol, ngrant, colAmt, badTag, eres, edisc, faults,
                 cprobe>>

CRelease(p) ==
  /\ alive[p] = "live"
  /\ pc[p] = "cRel"
  /\ role.owner = p
  /\ role' = [role EXCEPT !.owner = NoOwner]
  /\ pc' = [pc EXCEPT ![p] = "pending"]
  /\ UNCHANGED <<cseq, budget, res, wire, reqst, ep, pubd, pubcur, alive,
                 seenVal, obsVal, ncol, ngrant, colAmt, badTag, eres, edisc, faults,
                 cprobe>>

CAbort(p) ==
  \* A combiner that discovers it no longer holds the role -- because it was
  \* stolen from while descheduled -- abandons the round. It has already been
  \* fenced out of every mutation by the epoch stamps; this is how it NOTICES.
  /\ alive[p] = "live"
  /\ pc[p] \in CombinerPCs
  /\ ~(role.owner = p /\ role.epoch = ep[p])
  /\ pc' = [pc EXCEPT ![p] = "pending"]
  /\ pubcur' = [pubcur EXCEPT ![p] = NoOwner]
  /\ cprobe' = [cprobe EXCEPT !.fenced = TRUE]
  /\ UNCHANGED <<role, cseq, budget, res, wire, reqst, ep, pubd, alive, seenVal,
                 obsVal, ncol, ngrant, colAmt, badTag, eres, edisc, faults>>

(***************************************************************************)
(* THE ENVIRONMENT: DEATH AT EVERY STEP, AND THE FALSE-POSITIVE STEAL.      *)
(***************************************************************************)

Die(p) ==
  \* Enabled at every program counter AT WHICH A REQUEST IS OUTSTANDING -- which
  \* is every one except `idle`, and so includes every step of a round and both
  \* halves of a publication. A dead process never takes another step.
  \*
  \* The `alive[p] = "live"` conjunct means a STALLED process cannot be killed
  \* in one step; `Stall` -> `Resume` -> `Die` reaches "descheduled and then
  \* killed" and costs two faults, so it is reachable only where `MaxFaults > 1`.
  /\ alive[p] = "live"
  /\ faults > 0
  /\ pc[p] # "idle"
  /\ alive' = [alive EXCEPT ![p] = "dead"]
  /\ faults' = faults - 1
  /\ cprobe' = [cprobe EXCEPT
                  !.diedMidRound = @ \/ (pc[p] \in CombinerPCs),
                  !.diedMidPublish = @ \/ (pubcur[p] # NoOwner)]
  /\ UNCHANGED <<role, cseq, budget, res, wire, reqst, pc, ep, pubd, pubcur,
                 seenVal, obsVal, ncol, ngrant, colAmt, badTag, eres, edisc>>

Stall(p) ==
  \* Descheduled. The OS scheduler is entirely willing to do this to a large,
  \* CPU-hungry build client holding the role -- the residual objection the
  \* transport spec raises. Not fair; not a step of the protocol.
  /\ AllowStall
  /\ alive[p] = "live"
  /\ faults > 0
  /\ pc[p] \in CombinerPCs
  /\ alive' = [alive EXCEPT ![p] = "stalled"]
  /\ faults' = faults - 1
  /\ UNCHANGED <<role, cseq, budget, res, wire, reqst, pc, ep, pubd, pubcur,
                 seenVal, obsVal, ncol, ngrant, colAmt, badTag, eres, edisc,
                 cprobe>>

Resume(p) ==
  \* And back, ON THE SAME ROUND, with stale locals -- possibly after another
  \* process has stolen the role and run a whole round in the meantime.
  /\ alive[p] = "stalled"
  /\ alive' = [alive EXCEPT ![p] = "live"]
  /\ cprobe' = [cprobe EXCEPT !.resumed = @ \/ (role.owner # p)]
  /\ UNCHANGED <<role, cseq, budget, res, wire, reqst, pc, ep, pubd, pubcur,
                 seenVal, obsVal, ncol, ngrant, colAmt, badTag, eres, edisc, faults>>

(***************************************************************************)

StepOf(p) ==
  \/ RPublish(p) \/ RSee(p) \/ RRead(p)
  \/ SeqRepair(p) \/ TryRole(p) \/ Steal(p)
  \/ CRaiseOne(p) \/ CRaiseDone(p) \/ CDecide(p) \/ CScanDone(p)
  \/ CCommit(p) \/ CSeq(p) \/ CRefresh(p)
  \/ CPubPayload(p) \/ CPubValue(p) \/ CPubDone(p) \/ CRelease(p)
  \/ CAbort(p)

AllDone == \A p \in Procs : alive[p] = "dead" \/ pc[p] = "settled"

Terminating == AllDone /\ UNCHANGED vars
  \* The ONLY legitimate terminal state. Any other state with no successor is a
  \* real deadlock and TLC reports it -- which is how `AllowSteal = FALSE` fails.

Next ==
  \/ \E p \in Procs : StepOf(p) \/ Die(p) \/ Stall(p) \/ Resume(p)
  \/ Terminating

Spec == Init /\ [][Next]_vars
        /\ \A q \in Procs : WF_vars(StepOf(q))
        /\ \A r \in Procs : WF_vars(Resume(r))
        \* NO fairness on Die or Stall: nothing may depend on a fault arriving,
        \* and nothing may depend on one NOT arriving either.

(***************************************************************************)
(* INVARIANTS                                                              *)
(***************************************************************************)

TypeOK ==
  /\ role.owner \in Procs \cup {NoOwner}
  /\ role.epoch \in 0 .. MaxEpochs
  /\ role.committed \in BOOLEAN
  /\ cseq \in 0 .. MaxEpochs
  /\ budget \in (0 - Capacity) .. Capacity
  /\ \A q \in Procs : res[q].dec \in {"none", "grant", "refuse"}
  /\ \A q \in Procs : res[q].epoch \in 0 .. MaxEpochs
  /\ pc \in [Procs -> {"idle", "pending", "reading", "reReading", "settled"}
                        \cup CombinerPCs]
  /\ alive \in [Procs -> {"live", "stalled", "dead"}]
  /\ faults \in 0 .. MaxFaults
  /\ edisc \subseteq (1 .. MaxEpochs)
  /\ eres \in [1 .. MaxEpochs -> {"open", "completed", "discarded"}]

EpochBoundNotBinding == role.epoch < MaxEpochs
  (*************************************************************************)
  (* THE BOUND IS NOT A CONSTRAINT, and this is how that is PROVED rather   *)
  (* than asserted. If this holds on a green run then no behaviour ever ran *)
  (* out of epochs, so `MaxEpochs` excluded nothing from that run.          *)
  (*************************************************************************)

NoDoubleGrant == \A p \in Procs : ngrant[p] <= 1
  (*************************************************************************)
  (* NO REQUEST IS GRANTED TWICE. Each process makes one request, so a      *)
  (* second collected grant is a grant delivered twice. This is the gate's  *)
  (* headline property and the one MV1 handed over unresolved.              *)
  (*                                                                       *)
  (* Two separate mechanisms are needed and NEITHER SUFFICES ALONE:         *)
  (*  - `SerialisePerSlot` stops a live round re-deciding an answered slot; *)
  (*  - `IdempotentPublish` stops a STEALER republishing a grant the dead   *)
  (*    combiner had already published. Serialisation cannot help there,    *)
  (*    because the stealer's question is not "may I grant?" but "did the   *)
  (*    corpse already publish?".                                           *)
  (* Each has its own failing configuration.                                *)
  (*************************************************************************)

GrantCoherent == ~badTag
  (*************************************************************************)
  (* NO WAITER RECEIVES A GRANT MEANT FOR ANOTHER REQUEST. A waiter that    *)
  (* observes value v reads the payload published FOR v. This is MV1's      *)
  (* `GrantPayloadCoherent` restated for the arbiter, and it is the form    *)
  (* MV1's FINDING 1 takes once the publisher is a combiner.                *)
  (*************************************************************************)

NoOvercommit == Held <= Capacity
  \* NO CAPACITY CONJURED. Stated over the COMMITTED LEDGER, so it does not
  \* depend on the budget word looking plausible.

NonNegative == budget >= 0

BudgetExact == Quiet => budget = Capacity - Held
  (*************************************************************************)
  (* NO CAPACITY CONJURED OR DESTROYED ACROSS A COMBINE. At every quiescent *)
  (* state -- role free, no round in flight -- the budget word equals exactly *)
  (* what the committed ledger says is left. A round that was half-applied  *)
  (* and then discarded must leave NO trace, and an incrementally decremented *)
  (* budget word cannot manage that: its decrements are not undone.          *)
  (*************************************************************************)

GrantedEqualsTaken ==
  \A p \in Procs :
    (ngrant[p] >= 1) => /\ res[p].dec = "grant"
                        /\ res[p].epoch <= cseq
                        /\ colAmt[p] = res[p].amt
  (*************************************************************************)
  (* WHAT IS GRANTED IS EXACTLY WHAT WAS TAKEN FROM THE BUDGET. Every grant *)
  (* a waiter believes it holds is a COMMITTED ledger entry of exactly that *)
  (* amount -- so no waiter proceeds on a grant that the budget never paid   *)
  (* for, and no committed grant is silently resized.                        *)
  (*************************************************************************)

StealResolvesExactlyOnce ==
  \A e \in 1 .. MaxEpochs :
    (Quiet /\ e <= role.epoch /\ DecidedIn(e) # {}) => eres[e] # "open"
  (*************************************************************************)
  (* A STEALER EITHER COMPLETES OR DISCARDS A HALF-APPLIED ROUND, EXACTLY   *)
  (* ONCE -- NEVER BOTH, NEVER NEITHER.                                     *)
  (*                                                                       *)
  (* `eres[e]` is a ghost with three values and it is written by exactly    *)
  (* two places: `SeqRepair`/`CSeq` mark COMPLETED (only ever when the role  *)
  (* word's commit flag is set), and `TakeRole` marks DISCARDED (only ever   *)
  (* when it is NOT set and round e actually proposed something). The two    *)
  (* are mutually exclusive because the commit flag is a single atomic bit   *)
  (* inside the role word; `NeverBoth` below is what checks that the         *)
  (* protocol really keeps them exclusive rather than the ghost hiding it.   *)
  (*************************************************************************)

NeverBoth ==
  \A e \in 1 .. MaxEpochs :
    /\ (eres[e] = "discarded") => (e > cseq \/ DecidedIn(e) = {})
    /\ (eres[e] = "completed") => (cseq >= e)
    /\ ~(e \in edisc /\ eres[e] = "completed")
  (*************************************************************************)
  (* NEVER BOTH. A round marked DISCARDED has NO EFFECTIVE DECISION: either  *)
  (* its number is still uncommitted, or every entry it stamped has been     *)
  (* cleared by the raise pass. A round marked COMPLETED has committed.      *)
  (* An epoch satisfying both readings would be a round HALF APPLIED AND     *)
  (* HALF THROWN AWAY -- exactly the failure the gate names, and exactly what *)
  (* a stale combiner committing behind a stealer's back would produce.       *)
  (*                                                                        *)
  (* NOTE the shape of the first clause, because getting it wrong is easy    *)
  (* and the first draft of this model did: `cseq` is MONOTONE and it does   *)
  (* pass a discarded round's number. That is harmless -- what must be true   *)
  (* is that no entry STAMPED with that number survives to be swept up by     *)
  (* the `epoch <= cseq` effectiveness test, and the raise pass is what      *)
  (* guarantees it.                                                         *)
  (*************************************************************************)

NoDiscardOfCollected ==
  \A q \in Procs :
    (ncol[q] >= 1 /\ wire[q].dec # "none") => res[q].dec # "none"
  \* NO LOST REQUEST, safety half: an outcome a waiter has already collected and
  \* is acting on is never erased from the ledger behind it. A round that clears
  \* the board rather than respecting an answered slot violates this.

(***************************************************************************)
(* LIVENESS                                                                *)
(***************************************************************************)

AllSettled == <>(\A p \in Procs : alive[p] = "dead" \/ pc[p] = "settled")
  (*************************************************************************)
  (* NO LOST REQUEST, and NO DEADLOCK WHEN THE ROLE HOLDER VANISHES. Every  *)
  (* published request is eventually granted or refused and the answer      *)
  (* reaches its waiter -- no matter where the combiner died. Dead processes *)
  (* are excused; nobody else is.                                           *)
  (*************************************************************************)

(***************************************************************************)
(* NON-VACUITY. Checked as a NEGATION in `*_probe.cfg`; TLC MUST violate it *)
(* and its counterexample is a single behaviour in which all of these       *)
(* happened. Without it the green runs above could be green because the     *)
(* interesting states were never reached.                                   *)
(***************************************************************************)

ProbeAllReached ==
  ~(/\ cprobe.acquired
    /\ cprobe.stole
    /\ cprobe.diedMidRound
    /\ cprobe.discarded
    /\ cprobe.completedByOther
    /\ cprobe.granted
    /\ cprobe.refused
    /\ cprobe.fenced)

ProbeResumeReached ==
  ~(/\ cprobe.stole
    /\ cprobe.resumed
    /\ cprobe.fenced
    /\ cprobe.granted)
  \* The FALSE-POSITIVE STEAL specifically: a combiner descheduled, stolen from,
  \* and then resurrected onto a round it no longer owns.

ProbeDiedMidPublish == ~cprobe.diedMidPublish
  \* Death BETWEEN the payload store and the value bump -- the narrowest window
  \* in the whole protocol, and the one a stealer must republish through.

================================================================================
