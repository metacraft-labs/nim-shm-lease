## Justfile — nim-shm-lease.
##
## Recipe taxonomy (per `codetracer-specs/Repo-Requirements.md`, matching the
## sibling `nim-shm-queue`): top-level aggregates `build`, `test`, `lint`,
## `format`/`fmt`, plus `bench` and `clean`.
##
## `nimble test` runs the same three files, but only once the repo has at least one
## commit (nimble derives the package version from the VCS revision). This `just`
## runner needs no commit, so it is the blessed runner during development — the
## same convention as `nim-shm-gset`.

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

alias t := test
alias fmt := format

# Hermetic + threading flags applied to every nim invocation here.
# `--threads:on` mirrors `config.nims` (the hook tests drive interleavings with
# threads); `--path:src` is re-stated because `--skipParentCfg` suppresses
# `config.nims`.
nim-flags := "--skipParentCfg --skipUserCfg --hints:off --threads:on --warning:BareExcept:off"
# `--path:../nim-shm-queue/src` is the M4 dependency: the observation ring rides
# `nim-shm-queue`'s Layer 1 (ticket-CAS append, release-store publish,
# single-consumer drain, atomic signalled drop counter) rather than growing a
# second copy of the same MPSC protocol. The sibling checkout is the workspace
# layout; `shm_lease.nimble` threads the same path when the directory exists, which
# is the convention `nim-shm-queue` itself already uses for its vendored libs.
src-paths := "--path:src --path:tests --path:../nim-shm-queue/src"

# --- Default targets ---

# Build: compile (no run) every test + benchmark, as a sanity check.
build:
    #!/usr/bin/env bash
    # `pipefail` so a failing `nim c` propagates through `| tee`. Without it tee's
    # RC=0 masks the failure and the recipe reports success — a false green.
    set -euo pipefail
    mkdir -p test-logs
    nim c {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/test_shm_lease tests/test_shm_lease.nim 2>&1 | tee test-logs/build.log
    nim c {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/test_shm_lease_multiprocess \
        tests/test_shm_lease_multiprocess.nim 2>&1 | tee -a test-logs/build.log
    nim c {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/test_shm_lease_waitword \
        tests/test_shm_lease_waitword.nim 2>&1 | tee -a test-logs/build.log
    nim c {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/test_shm_lease_wait_multiprocess \
        tests/test_shm_lease_wait_multiprocess.nim 2>&1 | tee -a test-logs/build.log
    nim c {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/test_shm_lease_obsring \
        tests/test_shm_lease_obsring.nim 2>&1 | tee -a test-logs/build.log
    nim c {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/test_shm_lease_obs_multiprocess \
        tests/test_shm_lease_obs_multiprocess.nim 2>&1 | tee -a test-logs/build.log
    nim c {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/test_shm_lease_arbiter \
        tests/test_shm_lease_arbiter.nim 2>&1 | tee -a test-logs/build.log
    nim c {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/test_shm_lease_arbiter_multiprocess \
        tests/test_shm_lease_arbiter_multiprocess.nim 2>&1 | tee -a test-logs/build.log
    nim c {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/test_shm_lease_starvation \
        tests/test_shm_lease_starvation.nim 2>&1 | tee -a test-logs/build.log
    nim c {{nim-flags}} {{src-paths}} -d:shmLeaseScheduleHooks \
        -o:test-logs/test_shm_lease_hooks \
        tests/test_shm_lease_hooks.nim 2>&1 | tee -a test-logs/build.log
    nim c {{nim-flags}} {{src-paths}} \
        -o:test-logs/test_shm_lease_reclaim \
        tests/test_shm_lease_reclaim.nim 2>&1 | tee -a test-logs/build.log
    nim c {{nim-flags}} {{src-paths}} -d:shmLeaseScheduleHooks \
        -o:test-logs/test_shm_lease_kill_injection \
        tests/test_shm_lease_kill_injection.nim 2>&1 | tee -a test-logs/build.log

# Test: the whole suite. Deterministic — no flaky stress in `test`.
test: test-unit test-integration test-waitword test-wait-integration \
      test-fence-shape test-obsring test-obs-integration test-arbiter \
      test-arbiter-integration test-starvation test-hooks test-reclaim \
      test-kill-injection

# Unit: packed-budget arithmetic, fixed-claim-order enforcement, boot+pid+start-time
# anchoring, over-release refusal, and the NEGATIVE controls proving the overcommit
# detector and the stored-pointer checker actually fail when they should.
test-unit:
    #!/usr/bin/env bash
    # `pipefail` so a FAILING TEST propagates through `| tee` instead of being
    # reported as success. Without it `unittest`'s non-zero exit is swallowed and
    # `just test` goes green with `[FAILED]` lines in its own output.
    set -euo pipefail
    mkdir -p test-logs
    nim c -r {{nim-flags}} {{src-paths}} \
        tests/test_shm_lease.nim 2>&1 | tee test-logs/test-unit.log

# Integration: THE M2 GATE. N real processes claim/release multi-dimensional
# reservations against one shared packed budget, each mapping the segment at a
# DELIBERATELY DIFFERENT virtual base (MAP_FIXED) — no overcommit, no lost update,
# total released == total claimed, position independence (SM-7).
test-integration:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    nim c -r {{nim-flags}} {{src-paths}} \
        tests/test_shm_lease_multiprocess.nim 2>&1 | tee test-logs/test-integration.log

# M3 unit: the futex-class blocking wrapper. Capability record, the KERNEL syscall
# counter calibrated before it is trusted, SM-2's two fast paths measured at zero
# with a forced-syscall control, spurious-wakeup tolerance, and the macOS prefault
# hazard exhibited (an untouched page fails the park with EFAULT).
test-waitword:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    nim c -r {{nim-flags}} {{src-paths}} \
        tests/test_shm_lease_waitword.nim 2>&1 | tee test-logs/test-waitword.log

# M3 integration: THE M3 GATE. Real processes at DELIBERATELY DIFFERING virtual
# bases (MAP_FIXED over one pre-fork PROT_NONE reservation, strided by
# `sysconf(_SC_PAGESIZE)`): a waiter blocks and a second process wakes it (SM-7 +
# the inode+offset keying rule), a blocked waiter burns no CPU over a multi-second
# block while a SPINNING control burns a core (SM-1), the fast path costs zero
# syscalls in the child too (SM-2), and the process-local scope is shown NOT to be
# woken cross-process. Takes ~7s, most of it the deliberate multi-second block;
# `SHM_LEASE_BLOCK_SECONDS` overrides the window.
test-wait-integration:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    nim c -r {{nim-flags}} {{src-paths}} \
        tests/test_shm_lease_wait_multiprocess.nim 2>&1 | tee test-logs/test-wait-integration.log

# THE FENCE-SHAPE BARRIER: disassembles `wakeAll` / `wakeOne` and requires a FULL
# fence instruction (`dmb ish` on arm64, `mfence`/`lock`-prefixed on x86-64) to
# precede the load of `waiters`, with no earlier load of it.
#
# IT LIVES IN `test`, NOT IN `verify`, and the placement is the point. `verify` is
# deliberately opt-in — TLC and herd7 are not in the dev shell — and the litmus
# tests it runs CANNOT fail in response to a source change: a `.litmus` file is a
# standalone model, so herd7's verdict is a function of that file alone. Delete
# `fullFence()` from `waitword.nim` and all twenty-eight litmus verdicts still pass.
# The person who would delete it is optimising `src/` and runs `just test`; this is
# the tier that has to notice. It needs nothing `test` does not already need — the
# Nim compiler and the platform's `objdump`.
#
# It FAILS rather than degrading to green when it cannot read what it is checking
# (symbol missing, unfamiliar codegen, unknown architecture); see the script header
# for the opt-out and for the mutations it was proven against.
test-fence-shape:
    #!/usr/bin/env bash
    # `pipefail` so a FAILING barrier propagates through `| tee` instead of being
    # reported as success — the same false-green hazard the other recipes guard.
    set -euo pipefail
    mkdir -p test-logs
    tests/check-fence-shape.sh 2>&1 | tee test-logs/test-fence-shape.log

# M4 unit: the observation ring. The segment format and its refusals, position
# independence across two bases, OS-1 (publishing never blocks, never fails, needs
# no daemon), OS-2 (drops counted, `windowCompleteness` truthful), the kernel
# syscall counter RE-CALIBRATED before M4 trusts it, and the signalling rule
# measured at zero syscalls against a signal-on-every-append control.
test-obsring:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    nim c -r {{nim-flags}} {{src-paths}} \
        tests/test_shm_lease_obsring.nim 2>&1 | tee test-logs/test-obsring.log

# M4 integration: THE M4 GATE. Real producer processes at DELIBERATELY DIFFERING
# virtual bases saturating a small ring while a throttled consumer drains it
# (delivered + dropped == produced, exactly, with a DERIVED lower bound on the drop
# count and no torn records); the per-process cost of observing measured against a
# no-observation control and against two IPC controls that must exceed the same
# tolerance; a multi-second quiet window costing ZERO consumer wakeups against a
# POLLING control that burns thousands of syscalls; and a sustained non-empty ring
# signalled exactly ONCE. Takes ~4s, most of it the deliberate idle window;
# `SHM_LEASE_OBS_IDLE_SECONDS` overrides it, `SHM_LEASE_OBS_PRODUCERS` /
# `SHM_LEASE_OBS_ROUNDS` / `SHM_LEASE_OBS_PERTURB_ROUNDS` the load.
test-obs-integration:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    nim c -r {{nim-flags}} {{src-paths}} \
        tests/test_shm_lease_obs_multiprocess.nim 2>&1 | tee test-logs/test-obs-integration.log

# M5 unit: THE FLAT-COMBINING ARBITER, against the four constraints MV2 derived
# BEFORE this code existed (`verification/tla/shm_lease_combine.tla`). One suite per
# constraint, each with a POSITIVE assertion and — where the mechanism can be switched
# off — a NEGATIVE CONTROL that switches exactly that one off and requires the damage
# to appear: an incrementally decremented budget word destroying capacity, a fit test
# blind to its own proposals overcommitting, a counter-bump publication making wakes
# exceed grants, and a raise pass without serialisation erasing a collected grant.
# Also: the commit CAS failing after a steal (Finding 4, executed), the steal
# detector's two halves shown to be separately load-bearing, `publishGrant`'s
# inherited precondition refused by construction, and a round measured at ZERO
# syscalls against a forced-syscall control.
test-arbiter:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    nim c -r {{nim-flags}} {{src-paths}} \
        tests/test_shm_lease_arbiter.nim 2>&1 | tee test-logs/test-arbiter.log

# M5 integration: THE M5 GATE. Real processes at DELIBERATELY DIFFERING virtual
# bases, with the ARBITER ROLE MIGRATING BETWEEN THEM — structurally, not by luck:
# a child does not begin the measured workload until it has personally owned the
# role, every child's first request is on the board before any round may run, and
# no child may leave until the parent says all are done. Asserts (a) wakes <=
# grants under a release that frees capacity for four PARKED waiters, (b) no waiter
# is ever woken without its answer, and (c) every decision of every committed round
# is identical to a single-threaded reference implementation replayed in epoch
# order. Plus the two controls that give those teeth: a single-combiner run of the
# same workload (ONE owner, same reference agreement — packing unchanged by
# migration) and a deliberately blind fit test the reference is required to catch.
test-arbiter-integration:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    nim c -r {{nim-flags}} {{src-paths}} -d:release \
        tests/test_shm_lease_arbiter_multiprocess.nim 2>&1 | \
        tee test-logs/test-arbiter-integration.log

# M6 integration: THE M6 GATE. A large memory claim (8 GiB) is admitted within an
# ASSERTED BOUND while a 512 MiB small-claim storm runs continuously for the whole
# of its wait — and the SAME harness FAILS for four other admission policies: the
# naive packed-CAS loop with no arbiter at all, M5's slot-ordered first fit, arrival
# order without a reservation, and a reservation handed to the wrong request. The
# storm's continuity is STRUCTURAL (claimers overlap their reservations, so
# `held + pending` never dips below the storm's whole demand, and the parent
# samples the minimum) rather than a matter of scheduling. Takes ~18s, almost all
# of it the four deliberate starvation deadlines.
test-starvation:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    nim c -r {{nim-flags}} {{src-paths}} -d:release \
        tests/test_shm_lease_starvation.nim 2>&1 | \
        tee test-logs/test-starvation.log

# EXTERNAL syscall counting for SM-2, the `strace`/`dtruss` half of the milestone's
# wording. The suite's own SM-2 assertions use the kernel's per-task counter, which
# is exact and needs no privileges; this recipe is the independent cross-check, and
# on Linux it is the ONLY route (Linux exposes no cheap in-process counter).
#
# NOT part of `test`, because it needs a tracer that is frequently unavailable:
# on macOS `dtrace`/`dtruss` require root AND a SIP configuration that permits
# DTrace (`csrutil enable --without dtrace`), and on a stock host it refuses with
# "DTrace requires additional privileges". The recipe says so rather than failing
# obscurely.
test-syscalls:
    #!/usr/bin/env bash
    set -uo pipefail
    mkdir -p test-logs
    nim c {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/probe_fastpath benchmarks/probe_fastpath.nim
    echo "--- in-process kernel counter (always available on macOS) ---"
    ./test-logs/probe_fastpath
    ./test-logs/probe_fastpath --control
    if command -v strace >/dev/null 2>&1; then
      echo "--- strace -c (fast path: expect ZERO futex calls) ---"
      strace -c -f ./test-logs/probe_fastpath 2>&1 | tee test-logs/syscalls-fast.log
      echo "--- strace -c (control: expect ~200000 futex calls) ---"
      strace -c -f ./test-logs/probe_fastpath --control 2>&1 | tee test-logs/syscalls-control.log
    elif command -v dtruss >/dev/null 2>&1; then
      echo "--- dtruss -c (needs root + SIP configured to permit DTrace) ---"
      sudo -n dtruss -c ./test-logs/probe_fastpath 2>&1 | tee test-logs/syscalls-fast.log \
        || echo "dtruss unavailable on this host (SIP / privileges) — the " \
                "in-process kernel counter above is the measurement that stands"
    else
      echo "no external syscall tracer on this host; the in-process kernel counter above stands"
    fi

# Deterministic interleavings driven through the schedule hooks at every CAS,
# publish AND wait/wake site (`-d:shmLeaseScheduleHooks`), including the
# publish-before-write boundary and M3's publish-vs-park window. These are
# regression tests, not stress.
test-hooks:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    nim c -r {{nim-flags}} {{src-paths}} -d:shmLeaseScheduleHooks \
        tests/test_shm_lease_hooks.nim 2>&1 | tee test-logs/test-hooks.log

# M7 RECLAMATION (SM-6): a client killed while holding a reservation has it
# reclaimed, a LIVE holder never is, and a pid reused by a new process on the same
# boot breaks neither direction. Real forks, real SIGKILLs, real `kill(pid, 0)`
# probes; the only constructed thing is which of two REAL start times a stale
# anchor records, which is what a pid reuse is from the reclaimer's side.
test-reclaim:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    nim c -r {{nim-flags}} {{src-paths}} \
        tests/test_shm_lease_reclaim.nim 2>&1 | tee test-logs/test-reclaim.log

# THE M7 GATE: SIGKILL at EVERY schedule hook, including mid-combine while holding
# the arbiter role. Loops over `SchedulePoint` itself — so a seam added later is
# covered without editing this recipe — and for each one requires the victim to
# have died BY SIGKILL, admission to recover inside a derived bound, the structure
# to be intact and the dead client's capacity to come back exactly.
# `-d:shmLeaseScheduleHooks` because the kill is injected at the hooks.
test-kill-injection:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    nim c -r {{nim-flags}} {{src-paths}} -d:shmLeaseScheduleHooks \
        tests/test_shm_lease_kill_injection.nim 2>&1 | \
        tee test-logs/test-kill-injection.log

# Sanitizers over the in-process thread harness (the algorithm's memory ordering;
# TSAN does NOT cross the process boundary, and it shadows by VIRTUAL address while
# every process maps the segment at its own base — so the cross-mapping ordering is
# what the multi-process gate covers, not this). `-d:useMalloc` routes Nim
# allocations through malloc so the sanitizers can see them; `detect_leaks=0`
# because Nim's runtime intentionally leaves reachable allocations at exit.
#
# NOT part of `test`, and UNVERIFIED on this host: on Darwin 25.5 / arm64 both arms
# build but neither runs — the TSAN binary dies with SIGSEGV and the ASan binary
# hangs in `dyld` before reaching `main`. Reproduced 2026-07-30; not diagnosed, and
# NOT claimed as passing anywhere. Run this on x86-64 Linux, where the sibling
# `nim-shm-gset` runs the equivalent recipe.
test-sanitizers:
    nim c {{nim-flags}} {{src-paths}} --mm:orc -d:useMalloc --debugger:native \
        -d:shmLeaseScheduleHooks \
        --passc:-fsanitize=thread --passl:-fsanitize=thread \
        -o:test-logs/shmlease-tsan tests/test_shm_lease_hooks.nim
    TSAN_OPTIONS="halt_on_error=1" ./test-logs/shmlease-tsan
    nim c {{nim-flags}} {{src-paths}} --mm:orc -d:useMalloc --debugger:native \
        --passc:"-fsanitize=address,undefined -fno-sanitize-recover=undefined" \
        --passl:"-fsanitize=address,undefined" \
        -o:test-logs/shmlease-asan tests/test_shm_lease.nim
    ASAN_OPTIONS="detect_leaks=0" ./test-logs/shmlease-asan

# Longer parameterisable many-process soak over the same harness as the gate.
# `just soak 60` runs each child for 60x the default round count.
soak factor="10":
    @mkdir -p test-logs
    SHM_LEASE_ROUND_FACTOR={{factor}} nim c -r {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/soak tests/test_shm_lease_multiprocess.nim

# Lint: nim check over the library modules + every test.
lint: lint-nim lint-portable-arm

# The portable no-op arm must keep compiling on a platform that has no
# `mmap(MAP_SHARED)`. Cross-checking against Windows is the cheapest way to prove
# it, and it is exactly the platform the campaign defers — so this check is what
# stops the "reports unavailable off Linux/macOS" promise from bit-rotting.
lint-portable-arm:
    #!/usr/bin/env bash
    # `pipefail` is what makes the "cannot bit-rot" claim TRUE rather than merely
    # intended: without it a hard `nim check` error in the portable arm is masked
    # by tee's RC=0 and the recipe reports success. Verified by breaking the arm
    # deliberately and requiring this recipe to fail.
    set -euo pipefail
    mkdir -p test-logs
    nim check --os:windows --cpu:amd64 {{nim-flags}} {{src-paths}} \
        src/shm_lease.nim 2>&1 | tee test-logs/lint-portable-arm.log

lint-nim:
    #!/usr/bin/env bash
    # `pipefail` so a non-zero `nim check` propagates through `| tee` (otherwise
    # tee's RC=0 masks a failing check — a false green).
    set -euo pipefail
    mkdir -p test-logs
    nim check {{nim-flags}} {{src-paths}} src/shm_lease.nim 2>&1 | tee test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} tests/test_shm_lease.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} tests/test_shm_lease_multiprocess.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} tests/test_shm_lease_waitword.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} tests/test_shm_lease_wait_multiprocess.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} tests/test_shm_lease_obsring.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} tests/test_shm_lease_obs_multiprocess.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} tests/test_shm_lease_arbiter.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} tests/test_shm_lease_arbiter_multiprocess.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} tests/test_shm_lease_starvation.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} tests/test_shm_lease_reclaim.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} -d:shmLeaseScheduleHooks \
        tests/test_shm_lease_kill_injection.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} tests/fence_shape_driver.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} benchmarks/bench_wait.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} benchmarks/bench_obsring.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} benchmarks/probe_fastpath.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} benchmarks/probe_obs_contention.nim 2>&1 | tee -a test-logs/lint-nim.log
    # **M8**: all three arms of the preemption study, because two of them are
    # reached only through a `-d:` flag and an arm nothing checks is an arm that
    # rots. The plain check is the CONTROL build; the two defines are the wall and
    # wall+cpu instruments.
    nim check {{nim-flags}} {{src-paths}} benchmarks/probe_preemption.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} -d:shmLeaseRoleTiming \
        benchmarks/probe_preemption.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} -d:shmLeaseRoleTiming \
        -d:shmLeaseRoleCpuTiming \
        benchmarks/probe_preemption.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} -d:shmLeaseScheduleHooks \
        tests/test_shm_lease_hooks.nim 2>&1 | tee -a test-logs/lint-nim.log

# ===========================================================================
# MV1 + MV2 + MV3 — the FORMAL / weak-memory verification tier (`verification/`).
# ===========================================================================
#
# NOT part of `test`: TLC is not in the dev shell, so these recipes pull it from
# nixpkgs on demand and are deliberately opt-in. `verification/README.md` records
# what ran, with state counts and depths, and — the half that matters more — the
# COVERAGE BOUNDARIES of what ran.

# Everything in the tier that is runnable on this host.
verify: verify-tla verify-tla-negative verify-litmus

# TLA+/TLC over the shipped protocol models — MV1's CLAIM and WAIT (gate items
# (a) and (b)) — and over TWO protocols modelled BEFORE the code that must obey
# them: MV2's flat-combining COMBINER (before M5) and MV3's per-entry SEQLOCK for
# the published aggregate table (before M13b). Every invariant must HOLD and
# every liveness property must hold.
verify-tla:
    #!/usr/bin/env bash
    set -euo pipefail
    cd verification/tla
    echo "=== (a) CLAIM protocol: ascending multi-word claim, rollback, release ==="
    nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -config shm_lease_claim_MC.cfg shm_lease_claim_MC.tla
    echo "=== (a) CLAIM protocol: the ENFORCED claim order excludes the cycle ==="
    nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -config shm_lease_claim_ord_MC.cfg shm_lease_claim_ord_MC.tla
    echo "=== (a) CLAIM protocol: the per-field fit test, on the borrow workload ==="
    nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -config shm_lease_claim_borrow_fit_MC.cfg \
            shm_lease_claim_borrow_MC.tla
    echo "=== (b) WAIT protocol: grant-then-wake, park, re-validate ==="
    nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -config shm_lease_wait_MC.cfg shm_lease_wait_MC.tla
    echo "=== (b) WAIT protocol: the same, with a seq-cst fence after the bump ==="
    nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -config shm_lease_wait_tso_fence_MC.cfg shm_lease_wait_MC.tla
    echo "=== MV2 COMBINER: role, round, grants, release, STEAL; death at every step ==="
    nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -config shm_lease_combine_MC.cfg shm_lease_combine_MC.tla
    echo "=== MV2 COMBINER: the FALSE-POSITIVE STEAL -- descheduled, stolen from, resumed ==="
    nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -config shm_lease_combine_stall_MC.cfg shm_lease_combine_MC.tla
    echo "=== MV2 COMBINER: TWO faults, so the recovering round may itself be abandoned ==="
    nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -config shm_lease_combine_f2_MC.cfg shm_lease_combine_MC.tla
    echo "=== MV2 COMBINER: SAFETY under an arbitrarily wrong steal detector ==="
    # `-deadlock` DISABLES deadlock checking. It is correct here and only here:
    # this configuration deliberately runs the epoch counter to its bound (see
    # `shm_lease_combine_livelock_MC.cfg`, which is required to fail on exactly
    # that), so the successor-less states at the bound are the bound talking.
    nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -deadlock -config shm_lease_combine_live_MC.cfg \
            shm_lease_combine_MC.tla
    echo "=== M6 ADMISSION POLICY: arrival order + one reservation head ==="
    # The LIVENESS tier. `shm_lease_combine` says nothing about WHICH pending
    # request a round decides in favour of, because M5's policy was first fit;
    # M6 adds a policy whose whole content is a liveness property, so it gets its
    # own model rather than an extension that would multiply MV2's 1.3M-state
    # graph by a fairness-checked temporal property. `LargeAdmitted` (SM-4) and
    # `SmallsKeepGoing` (the cure is not permanent underutilization) must BOTH
    # hold; the three policy mutations below must break the first.
    nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -config shm_lease_admit_MC.cfg shm_lease_admit_MC.tla
    echo "=== M7 RESERVATION + COMBINE + DEATH + RECLAMATION, in ONE model ==="
    # THE MODEL M6's `:deferred:` (4) SAID WAS OWED BEFORE M7. `shm_lease_admit`
    # has the reservation but no role, no steal and no death; `shm_lease_combine`
    # has all of those but no release and no requeue — so a reservation
    # interacting with a combiner that dies mid-round was checked by NEITHER.
    # This configuration checks it, and adds M7's own two safety rules: nothing a
    # LIVE process holds is ever taken from it, and what is genuinely consumed
    # never exceeds the machine.
    nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -config shm_lease_reclaim_MC.cfg shm_lease_reclaim_MC.tla
    echo "=== MV3 SEQLOCK: the published aggregate table, modelled BEFORE M13b ==="
    # MV3, and it is MV2's precedent applied again: `shm_lease_seqlock.tla`
    # describes NOTHING in `../src`. It is a constraint on what M13b may be
    # written as. `NoTornRead` is the gate's sentence transcribed;
    # `ReaderTerminates` is reader termination under a writer that eventually
    # stops; `WriterAlwaysEnabled` is "a writer never blocks on a reader" as a
    # state predicate. `AcceptedMatchesCounter` is sharper than the gate asks
    # for and is what surfaced the counter-width finding.
    nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -config shm_lease_seqlock_MC.cfg shm_lease_seqlock_MC.tla
    echo "=== MV3 SEQLOCK: a WIDER entry -- three payload words, not two ==="
    # A three-word entry has a tear shape a two-word one does not: first and
    # last word from the new round with the middle word from the old. The
    # published table carries several counters per key, so this is the shape
    # M13b actually has rather than a bigger number.
    nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -config shm_lease_seqlock_wide_MC.cfg \
            shm_lease_seqlock_MC.tla
    echo "=== MV3 SEQLOCK: the writer finishes with readers given NO FAIRNESS ==="
    # THE STRONG FORM OF "a writer never blocks on a reader". `SpecWriterOnly`
    # gives weak fairness to the writer alone, so TLC must consider behaviours
    # in which a reader takes one step and then never takes another -- stopped
    # in a debugger, swapped out, or killed with a snapshot half-taken. Same
    # device `shm_lease_wait.tla` uses to withhold fairness from `SpuriousWake`.
    # `shm_lease_seqlock_wblock_live_MC.cfg` is required to BREAK this.
    nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -config shm_lease_seqlock_writeronly_MC.cfg \
            shm_lease_seqlock_MC.tla
    echo "=== MV2 COMBINER: Finding 4's mutation vs. every NON-GHOST invariant ==="
    # GREEN ON PURPOSE, and it is what keeps Finding 4 from overstating itself.
    # `shm_lease_combine_unfenced_MC.cfg` is REQUIRED to violate `NeverBoth` on
    # these same constants; this run asks whether the half-applied round then
    # DAMAGES anything, using only invariants stated over real state rather than
    # over the `eres`/`edisc` ghosts. It does not, and the finding says so.
    nix shell nixpkgs#tlaplus --command \
        tlc -workers 4 -config shm_lease_combine_unfenced_damage_MC.cfg \
            shm_lease_combine_MC.tla

# THE NEGATIVE CONTROLS, and they are what make the green runs above evidence.
# Each of these MUST report a violation; a recipe that passes here has found a
# model that cannot fail, which is worse than a model that fails.
#
# Two kinds are mixed deliberately and are labelled as such: NON-VACUITY probes
# (the workload really does reach the interesting states) and MUTATIONS (breaking
# a load-bearing rule really does break an invariant).
verify-tla-negative:
    #!/usr/bin/env bash
    set -euo pipefail
    cd verification/tla
    expect_violation() {
      local label="$1"; shift
      echo "--- MUST VIOLATE: $label"
      if nix shell nixpkgs#tlaplus --command tlc -workers 4 "$@" > /tmp/mv1-neg.log 2>&1; then
        echo "FAIL: TLC found NO error, but this configuration must produce one."
        echo "      ($label)"
        tail -20 /tmp/mv1-neg.log
        return 1
      fi
      grep -E "Error: (Invariant|Deadlock|Temporal)" /tmp/mv1-neg.log | head -2
      grep -E "distinct states found" /tmp/mv1-neg.log | tail -1
    }
    expect_violation "non-vacuity: refusal + rollback + lost CAS + grant all occur" \
        -config shm_lease_claim_MC_probe.cfg shm_lease_claim_MC.tla
    expect_violation "non-vacuity: the csOutOfOrder refusal really fires" \
        -config shm_lease_claim_ord_MC_probe.cfg shm_lease_claim_ord_MC.tla
    expect_violation "mutation: claim order NOT enforced -> waits-for CYCLE reachable" \
        -config shm_lease_claim_ord_nocheck_MC.cfg shm_lease_claim_ord_MC.tla
    expect_violation "mutation: whole-word fit test -> packed BORROW across dimensions" \
        -config shm_lease_claim_borrow_MC.cfg shm_lease_claim_borrow_MC.tla
    expect_violation "non-vacuity: all eight wait/wake windows occur in one behaviour" \
        -config shm_lease_wait_MC_probe.cfg shm_lease_wait_MC.tla
    expect_violation "mutation: value bumped BEFORE the payload -> stale grant read" \
        -config shm_lease_wait_order_MC.cfg shm_lease_wait_MC.tla
    expect_violation "FINDING: publishGrant twice on one slot -> the first grant is LOST" \
        -config shm_lease_wait_overwrite_MC.cfg shm_lease_wait_MC.tla
    expect_violation "FINDING: store-load reorder on the bump/waiters pair -> LOST WAKEUP" \
        -deadlock -config shm_lease_wait_tso_MC.cfg shm_lease_wait_MC.tla
    expect_violation "MV2 non-vacuity: acquire+steal+die mid-round+discard+complete-by-other" \
        -config shm_lease_combine_MC_probe.cfg shm_lease_combine_MC.tla
    expect_violation "MV2 non-vacuity: stolen from while descheduled, then RESUMED and fenced" \
        -config shm_lease_combine_resume_probe.cfg shm_lease_combine_MC.tla
    expect_violation "MV2 non-vacuity: death BETWEEN the payload store and the value bump" \
        -config shm_lease_combine_pub_probe.cfg shm_lease_combine_MC.tla
    expect_violation "MV2 mutation: NO steal protocol -> admission WEDGED for every process" \
        -config shm_lease_combine_nosteal_MC.cfg shm_lease_combine_MC.tla
    expect_violation "M7 non-vacuity: a combiner DEAD mid-round while a RESERVATION stands" \
        -config shm_lease_reclaim_probe.cfg shm_lease_reclaim_MC.tla
    expect_violation "M7 non-vacuity: the reaper is actually exercised" \
        -config shm_lease_reclaim_reap_probe.cfg shm_lease_reclaim_MC.tla
    expect_violation "M7 mutation: NO RECLAMATION -> a dead client's capacity is leaked FOREVER" \
        -deadlock -config shm_lease_reclaim_noreclaim_MC.cfg shm_lease_reclaim_MC.tla
    expect_violation "M7 mutation: reclamation fires on a LIVE holder -> REAL OVERCOMMIT" \
        -config shm_lease_reclaim_live_MC.cfg shm_lease_reclaim_MC.tla
    expect_violation "M7 mutation: no steal + a reservation standing -> admission WEDGED" \
        -deadlock -config shm_lease_reclaim_nosteal_MC.cfg shm_lease_reclaim_MC.tla
    expect_violation "MV2 mutation: published value is a COUNTER BUMP -> DOUBLE GRANT on steal" \
        -config shm_lease_combine_counter_MC.cfg shm_lease_combine_MC.tla
    # `NoDoubleGrant`'s witness here is a RE-GRANT OF AN ALREADY-COLLECTED
    # request, not an overwrite of an unread one -- the overwrite case cannot
    # violate this invariant and is witnessed by `GrantCoherent`. See Finding 3.
    expect_violation "MV2 mutation: slot NOT serialised -> ALREADY-COLLECTED request GRANTED AGAIN" \
        -config shm_lease_combine_noserial_MC.cfg shm_lease_combine_MC.tla
    expect_violation "MV2 FINDING 6: budget word incrementally decremented -> CAPACITY DESTROYED" \
        -config shm_lease_combine_budget_MC.cfg shm_lease_combine_MC.tla
    expect_violation "MV2 FINDING 4: commit resolved in a DIFFERENT word from the role transfer" \
        -config shm_lease_combine_unfenced_MC.cfg shm_lease_combine_MC.tla
    expect_violation "MV2 FINDING 5: unsound steal detector -> UNBOUNDED role churn" \
        -config shm_lease_combine_livelock_MC.cfg shm_lease_combine_MC.tla
    expect_violation "MV2 mutation: round's fit test blind to its own grants -> OVERCOMMIT" \
        -config shm_lease_combine_fit_MC.cfg shm_lease_combine_MC.tla
    expect_violation "M6 non-vacuity: the reservation really does REFUSE a request that fits" \
        -config shm_lease_admit_probe.cfg shm_lease_admit_MC.tla
    expect_violation "M6 mutation: M5's policy (slot order, no reservation) -> LARGE CLAIM STARVES" \
        -config shm_lease_admit_firstfit_MC.cfg shm_lease_admit_MC.tla
    expect_violation "M6 mutation: arrival order WITHOUT the reservation -> LARGE CLAIM STARVES" \
        -config shm_lease_admit_noreserve_MC.cfg shm_lease_admit_MC.tla
    expect_violation "M6 mutation: the reservation given to the WRONG request -> LARGE CLAIM STARVES" \
        -config shm_lease_admit_slotorder_MC.cfg shm_lease_admit_MC.tla
    echo "--- the safety half of the no-enforcement mutation MUST still hold:"
    expect_violation "MV3 non-vacuity: odd seq, a failed re-check, a TORN raw snapshot, a mid-round load, and a completed read all occur" \
        -config shm_lease_seqlock_MC_probe.cfg shm_lease_seqlock_MC.tla
    expect_violation "MV3 non-vacuity: a reader's OWN payload loads really do straddle a writer round" \
        -config shm_lease_seqlock_torn_probe.cfg shm_lease_seqlock_MC.tla
    # THE GATE'S NAMED CONTROL: "the model with the reader's retry removed MUST
    # violate no-torn-read". Everything else about the structure still works.
    expect_violation "MV3 MUTATION: the reader's retry removed -> torn read accepted" \
        -config shm_lease_seqlock_noretry_MC.cfg shm_lease_seqlock_MC.tla
    expect_violation "MV3 MUTATION: the bump-to-even issued BEFORE the payload stores -> torn read" \
        -config shm_lease_seqlock_unfenced_MC.cfg shm_lease_seqlock_MC.tla
    expect_violation "MV3 MUTATION: the reader's SECOND seq load hoisted above its payload loads -> torn read" \
        -config shm_lease_seqlock_hoist_MC.cfg shm_lease_seqlock_MC.tla
    expect_violation "MV3 MUTATION: the reader keeps the comparison and drops the ODD test -> torn read" \
        -config shm_lease_seqlock_noparity_MC.cfg shm_lease_seqlock_MC.tla
    # FINDING 7. Nothing is deleted and nothing is reordered: the counter merely
    # WRAPS, which the structures spec never forbids because it never states a
    # width. `s2 == s1` stops being evidence of stability the moment the counter
    # can return to a value it has left.
    expect_violation "MV3 FINDING: a counter that WRAPS under a descheduled reader -> torn read (ABA)" \
        -config shm_lease_seqlock_wrap_MC.cfg shm_lease_seqlock_MC.tla
    # These two are what make `shm_lease_seqlock_writeronly_MC.cfg` evidence
    # rather than a property of the transcription: with the coupling introduced,
    # the writer really can be blocked, for an instant and then forever.
    expect_violation "MV3 MUTATION: a writer that waits for in-flight readers is BLOCKABLE (safety)" \
        -config shm_lease_seqlock_wblock_MC.cfg shm_lease_seqlock_MC.tla
    expect_violation "MV3 MUTATION: ...and WEDGED forever by a reader that stops between its two seq loads (liveness)" \
        -config shm_lease_seqlock_wblock_live_MC.cfg shm_lease_seqlock_MC.tla

    nix shell nixpkgs#tlaplus --command tlc -workers 4 \
        -config shm_lease_claim_ord_nocheck_safety_MC.cfg shm_lease_claim_ord_MC.tla

# herd7 litmus tests (MV1 gate item (c), extended by MV3): the ordering pairs the
# structures depend
# on, under the C11, x86-TSO and AArch64 memory models. This is the tier that
# settles what TLC structurally cannot — TLC explores sequentially-consistent
# interleavings and does not model reordering.
#
# The runner CHECKS EVERY VERDICT rather than printing output, and nine of the
# twenty-eight tests are required to be ALLOWED (they are the controls that make
# the Forbidden verdicts mean something, plus the `:first_target:` defect itself,
# which is kept as the "before" half of its own regression barrier now that the
# fix has landed, plus MV3's four relaxed seqlock controls, which its gate
# requires by name).
#
# nixpkgs has NO herdtools7 on aarch64-darwin under any attribute, so
# `verification/litmus/get-herd7.sh` builds it through opam against the nixpkgs
# OCaml; it caches into `verification/litmus/herd7-opam` and is skipped when
# `herd7` is already on PATH. On Linux, prefer `nix shell nixpkgs#herdtools7`.
verify-litmus:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v herd7 >/dev/null 2>&1; then
      cached="$(pwd)/verification/litmus/herd7-opam/mv1/bin"
      if [ ! -x "$cached/herd7" ]; then
        echo "herd7 not on PATH and not cached; building it (a few minutes)..."
        verification/litmus/get-herd7.sh
      fi
      export PATH="$cached:$PATH"
    fi
    verification/litmus/run-litmus.sh

# Format: nimpretty when available.
format: format-nim

format-nim:
    @if command -v nimpretty >/dev/null 2>&1; then \
      nimpretty src/shm_lease.nim src/shm_lease/*.nim tests/*.nim benchmarks/*.nim; \
    else \
      echo "nimpretty not available; skipping Nim formatting"; \
    fi

# Benchmarks: uncontended and contended claim/release cost. Numbers here are the
# POC's own self-contained measurement; the socket comparison is campaign M1/M8,
# which needs a real build and is deliberately NOT a dependency of this repo.
bench:
    @mkdir -p test-logs
    nim c -r {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/bench_claim benchmarks/bench_claim.nim
    nim c -r {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/bench_wait benchmarks/bench_wait.nim
    nim c -r {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/bench_obsring benchmarks/bench_obsring.nim
    nim c -r {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/probe_obs_contention benchmarks/probe_obs_contention.nim

# ===========================================================================
# M8 — THE PREEMPTION STUDY. Deliberately NOT part of `bench`.
# ===========================================================================
#
# It takes minutes rather than seconds (it injects real CPU oversubscription and
# holds it for a measured window per rep per load point), so it is opt-in, the
# same way the `verify-*` tier is.
#
# THREE ARMS, THREE BINARIES, AND THE THIRD ARM IS THE REASON:
#
#   `notiming` — the library built with NO role timing at all. It is the CONTROL:
#       its admission latency and admission rate say what the workload costs when
#       the instrument is absent, so the instrument's own footprint is a measured
#       difference rather than an assurance.
#   `wall`     — `-d:shmLeaseRoleTiming`. Two `CLOCK_MONOTONIC` reads per combine
#       round, measured at ~13 ns and ZERO syscalls. THE PRIMARY DISTRIBUTION.
#   `cpu`      — `+ -d:shmLeaseRoleCpuTiming`. Adds two
#       `CLOCK_THREAD_CPUTIME_ID` reads, which cost ~110 ns AND A SYSCALL EACH, so
#       this arm perturbs the p50 badly and exists ONLY to attribute the TAIL: it
#       is what turns "the tail is long" into "the holder was off CPU".
#
# Read the three together, and read the ranges rather than the point values.
preemption-study:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    nim c {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/probe_preemption_notiming benchmarks/probe_preemption.nim
    nim c {{nim-flags}} {{src-paths}} -d:release -d:shmLeaseRoleTiming \
        -o:test-logs/probe_preemption_wall benchmarks/probe_preemption.nim
    nim c {{nim-flags}} {{src-paths}} -d:release -d:shmLeaseRoleTiming \
        -d:shmLeaseRoleCpuTiming \
        -o:test-logs/probe_preemption_cpu benchmarks/probe_preemption.nim
    for arm in wall cpu notiming; do
      echo "########## ARM: ${arm} ##########"
      ./test-logs/probe_preemption_${arm} 2>&1 | tee "test-logs/preemption-${arm}.log"
    done

# Single-source-of-truth version bump (version.txt is read by shm_lease.nimble).
bump-version version:
    printf '%s\n' "{{version}}" > version.txt

clean:
    rm -rf test-logs nimcache
    find tests benchmarks -maxdepth 1 -type f -perm -u+x -not -name "*.nim" -delete
