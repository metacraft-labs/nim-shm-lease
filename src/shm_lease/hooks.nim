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
