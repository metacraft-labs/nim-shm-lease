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

alias t := test
alias fmt := format

# Hermetic + threading flags applied to every nim invocation here.
# `--threads:on` mirrors `config.nims` (the hook tests drive interleavings with
# threads); `--path:src` is re-stated because `--skipParentCfg` suppresses
# `config.nims`.
nim-flags := "--skipParentCfg --skipUserCfg --hints:off --threads:on --warning:BareExcept:off"
src-paths := "--path:src --path:tests"

# --- Default targets ---

# Build: compile (no run) every test + benchmark, as a sanity check.
build:
    @mkdir -p test-logs
    nim c {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/test_shm_lease tests/test_shm_lease.nim 2>&1 | tee test-logs/build.log
    nim c {{nim-flags}} {{src-paths}} -d:release \
        -o:test-logs/test_shm_lease_multiprocess \
        tests/test_shm_lease_multiprocess.nim 2>&1 | tee -a test-logs/build.log
    nim c {{nim-flags}} {{src-paths}} -d:shmLeaseScheduleHooks \
        -o:test-logs/test_shm_lease_hooks \
        tests/test_shm_lease_hooks.nim 2>&1 | tee -a test-logs/build.log

# Test: the whole suite. Deterministic — no flaky stress in `test`.
test: test-unit test-integration test-hooks

# Unit: packed-budget arithmetic, fixed-claim-order enforcement, boot+pid+start-time
# anchoring, over-release refusal, and the NEGATIVE controls proving the overcommit
# detector and the stored-pointer checker actually fail when they should.
test-unit:
    @mkdir -p test-logs
    nim c -r {{nim-flags}} {{src-paths}} \
        tests/test_shm_lease.nim 2>&1 | tee test-logs/test-unit.log

# Integration: THE M2 GATE. N real processes claim/release multi-dimensional
# reservations against one shared packed budget, each mapping the segment at a
# DELIBERATELY DIFFERENT virtual base (MAP_FIXED) — no overcommit, no lost update,
# total released == total claimed, position independence (SM-7).
test-integration:
    @mkdir -p test-logs
    nim c -r {{nim-flags}} {{src-paths}} \
        tests/test_shm_lease_multiprocess.nim 2>&1 | tee test-logs/test-integration.log

# Deterministic interleavings driven through the schedule hooks at every CAS and
# publish site (`-d:shmLeaseScheduleHooks`), including the publish-before-write
# boundary. These are regression tests, not stress.
test-hooks:
    @mkdir -p test-logs
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
    @mkdir -p test-logs
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
    nim check {{nim-flags}} {{src-paths}} -d:shmLeaseScheduleHooks \
        tests/test_shm_lease_hooks.nim 2>&1 | tee -a test-logs/lint-nim.log

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

# Single-source-of-truth version bump (version.txt is read by shm_lease.nimble).
bump-version version:
    printf '%s\n' "{{version}}" > version.txt

clean:
    rm -rf test-logs nimcache
    find tests benchmarks -maxdepth 1 -type f -perm -u+x -not -name "*.nim" -delete
