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
    nim c {{nim-flags}} {{src-paths}} -d:shmLeaseScheduleHooks \
        -o:test-logs/test_shm_lease_hooks \
        tests/test_shm_lease_hooks.nim 2>&1 | tee -a test-logs/build.log

# Test: the whole suite. Deterministic — no flaky stress in `test`.
test: test-unit test-integration test-waitword test-wait-integration \
      test-obsring test-obs-integration test-hooks

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
    nim check {{nim-flags}} {{src-paths}} benchmarks/bench_wait.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} benchmarks/bench_obsring.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} benchmarks/probe_fastpath.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} benchmarks/probe_obs_contention.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} -d:shmLeaseScheduleHooks \
        tests/test_shm_lease_hooks.nim 2>&1 | tee -a test-logs/lint-nim.log

# ===========================================================================
# MV1 — the FORMAL / weak-memory verification tier (`verification/`).
# ===========================================================================
#
# NOT part of `test`: TLC is not in the dev shell, so these recipes pull it from
# nixpkgs on demand and are deliberately opt-in. `verification/README.md` records
# what ran, with state counts and depths, and — the half that matters more — the
# COVERAGE BOUNDARIES of what ran.

# Everything in the tier that is runnable on this host.
verify: verify-tla verify-tla-negative verify-litmus

# TLA+/TLC over the two shipped protocol models (MV1 gate items (a) and (b)).
# Every invariant must HOLD and every liveness property must hold.
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
    echo "--- the safety half of the no-enforcement mutation MUST still hold:"
    nix shell nixpkgs#tlaplus --command tlc -workers 4 \
        -config shm_lease_claim_ord_nocheck_safety_MC.cfg shm_lease_claim_ord_MC.tla

# herd7 litmus tests (MV1 gate item (c)): the ordering pairs the structures depend
# on, under the C11, x86-TSO and AArch64 memory models. This is the tier that
# settles what TLC structurally cannot — TLC explores sequentially-consistent
# interleavings and does not model reordering.
#
# The runner CHECKS EVERY VERDICT rather than printing output, and four of the
# thirteen tests are required to be ALLOWED (they are the controls that make the
# Forbidden verdicts mean something, plus the `:first_target:` finding itself).
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

# Single-source-of-truth version bump (version.txt is read by shm_lease.nimble).
bump-version version:
    printf '%s\n' "{{version}}" > version.txt

clean:
    rm -rf test-logs nimcache
    find tests benchmarks -maxdepth 1 -type f -perm -u+x -not -name "*.nim" -delete
