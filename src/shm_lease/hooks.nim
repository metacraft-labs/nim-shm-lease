## Deterministic schedule-hook seams for `nim-shm-lease`.
##
## Mirrors `nim-shm-gset/src/shm_gset/hooks.nim` (and its
## `-d:shmGSetScheduleHooks` gate) exactly, so the two libraries have one
## convention rather than two. Every concurrency-sensitive site in this library —
## every budget CAS, every rollback CAS, the magic publish, and the atomic rename
## that makes a segment discoverable — calls `scheduleHook(point)`.
##
## In a normal build the hook is a **compile-time no-op**: the call folds away, so
## the claim path stays "one load, one compare, one CAS" with nothing added. Under
## `-d:shmLeaseScheduleHooks` a test installs a callback that pauses / coordinates
## at a chosen point, which is how the campaign's later milestones drive a specific
## interleaving deterministically instead of chasing it as a flake
## (`RunQuota-Observation-Store.milestones.org` M5/M7 both require this, and the
## design spec lists "deterministic interleaving tests at every CAS, publish, and
## role-transfer site" as a condition of adoption).
##
## The hook is a plain thread-local proc pointer, so it works for the in-process
## thread harness. It deliberately does NOT reach across a process boundary —
## cross-process interleaving is driven by the kill/delay-injection harness (M7),
## not by this callback.

type
  SchedulePoint* = enum
    ## The CAS / publish sites a test may intercept. Kept stable so a test refers
    ## to a point by NAME, not by ordinal.
    slpBeforeBudgetCas      ## about to CAS a budget word down by a claim
    slpAfterBudgetCas       ## just after a claim CAS (won or lost)
    slpBeforeReleaseCas     ## about to CAS a budget word back up by a release
    slpAfterReleaseCas      ## just after a release CAS (won or lost)
    slpBeforeRollbackCas    ## a multi-word claim was refused on a later word;
                            ## about to give an earlier word back
    slpBeforeAnchorPublish  ## header fields written; about to publish the
                            ## boot/pid/start-time anchor
    slpBeforeMagicPublish   ## segment fully initialised; about to release-store
                            ## the magic that makes the contents trustworthy
    slpBeforeSegmentRename  ## temp segment complete; about to rename it into its
                            ## FINAL name (the publish-before-write boundary)
    slpAfterSegmentRename   ## the segment is now discoverable under its final name
    # --- M3: the futex-class blocking wrapper (`shm_lease/waitword`) ----------
    #
    # The design spec lists "deterministic interleaving tests at every CAS,
    # publish, and role-transfer site" as a condition of adoption, and the wait
    # path adds three race sites the budget CAS does not have: the LOST-WAKEUP
    # window between a waiter registering and re-checking, the park itself, and
    # the waker's decision to skip the syscall because the word records no waiter.
    # Each gets a named seam.
    slpBeforeWaiterRegister ## about to publish "a waiter exists" on a wait word
    slpAfterWaiterRegister  ## registered; about to RE-CHECK the value. Pausing
                            ## here is what lets a test drive the lost-wakeup race
    slpBeforeWaitPark       ## about to enter the kernel and sleep
    slpAfterWaitPark        ## returned from the kernel (woken, spurious, or timeout)
    slpBeforeWakePublish    ## about to release-store the new wait-word value
    slpBeforeWakeSyscall    ## waiters observed non-zero; about to enter the kernel
    slpAfterWakeSyscall     ## the wake syscall returned
    # --- M4: the observation ring (`shm_lease/obsring`) -----------------------
    #
    # The ring's ticket CAS and release-store publish live in `nim-shm-queue`'s
    # Layer 1 and carry that library's own seams; what M4 adds on top is the
    # SIGNALLING DECISION and the consumer's decision to sleep, and those are
    # exactly where a lost wakeup would live. Each gets a named seam so the
    # publish-versus-park window can be driven deterministically instead of chased
    # as a flake.
    slpBeforeObsPublish     ## about to append an observation to the ring
    slpAfterObsPublish      ## the append returned; about to test the waiter count
    slpBeforeObsSignal      ## a waiter was observed; about to bump + wake
    slpBeforeObsIdlePublish ## the consumer has seen the ring EMPTY and is about to
                            ## publish its idle token. Pausing here is what lets a
                            ## test land an append in the window a naive
                            ## "snapshot tail-head" producer would lose
    slpBeforeObsConsumerPark ## the consumer has registered, re-checked the ring AND
                            ## the value, and is about to sleep. Pausing here is
                            ## what lets a test publish into the pre-park window
    # --- M5: the flat-combining arbiter (`shm_lease/arbiter`) ----------------
    #
    # The design spec's condition of adoption names "every CAS, publish, AND
    # ROLE-TRANSFER site", and the role transfer is the one the earlier
    # milestones had nothing to intercept. MV2's model says why each of these is
    # a race site rather than a step: the acquisition CAS is what FENCES the
    # previous owner (every acquisition, clean or stolen, bumps the epoch), and
    # the commit CAS is the round's LINEARISATION POINT — a combiner descheduled
    # immediately before it, stolen from, and then resumed is the
    # false-positive-steal behaviour a kill-injection suite cannot reach
    # (`verification/README.md` Finding 4). Pausing at `slpBeforeCommitCas` and
    # stealing the role from another handle drives exactly that interleaving
    # deterministically.
    slpBeforeRoleCas        ## about to CAS the combiner role word (acquire or STEAL)
    slpAfterRoleCas         ## the role CAS returned (won or lost)
    slpBeforeLedgerCas      ## about to CAS a per-slot ledger entry (raise or decide)
    slpBeforeCommitCas      ## the round is decided; about to CAS the commit flag
                            ## INSIDE the role word — the linearisation point
    slpBeforeSeqAdvance     ## about to advance the monotone combine sequence
    slpBeforeBudgetRefresh  ## about to recompute the budget CACHE from the ledger
    slpBeforeGrantPublish   ## outcome payload stored; about to CAS the waiter's
                            ## value word to the combine epoch
    slpBeforeRoleRelease    ## about to CAS the role word back to unowned

  ScheduleHook* = proc (point: SchedulePoint) {.gcsafe, raises: [].}

when defined(shmLeaseScheduleHooks):
  var activeHook {.threadvar.}: ScheduleHook

  proc setScheduleHook*(h: ScheduleHook) =
    ## Install (or clear, with `nil`) the current thread's schedule hook. Only
    ## available under `-d:shmLeaseScheduleHooks`.
    activeHook = h

  proc scheduleHook*(point: SchedulePoint) {.inline.} =
    let h = activeHook
    if h != nil:
      h(point)

  const scheduleHooksEnabled* = true
else:
  proc scheduleHook*(point: SchedulePoint) {.inline.} = discard
    ## Compile-time no-op: the call is erased in a normal build.

  const scheduleHooksEnabled* = false
