#!/usr/bin/env bash
# THE FENCE-SHAPE BARRIER — a check that FAILS when the seq-cst fence in
# `wakeAll` / `wakeOne` is deleted or moved.
#
# WHY THIS EXISTS, and why the litmus tier is not it. `verification/litmus/`
# proves that the fenced pair is Forbidden and the unfenced pair is Allowed under
# C11, x86-TSO and AArch64. That is a statement about the MODELS. A `.litmus` file
# is a standalone program: herd7's verdict is a deterministic function of the file,
# so NO change to `src/` can move it. Delete `fullFence()` from `waitword.nim` and
# `just verify-litmus` still passes every one of its sixteen verdicts — verified by
# doing exactly that. The litmus tier pins the INTENDED shape; nothing was checking
# that the shipped machine code still had it.
#
# WHAT THIS CHECKS. That in the optimised machine code of BOTH `wakeAll` and
# `wakeOne` a full-fence instruction executes BEFORE the load of `waiters`, with no
# earlier load of `waiters`. That is the publisher half of the store-buffering pair
# `waitOn`'s docstring describes: the caller's release store of `value` happens
# before the call, so a fence at the top of the callee — ahead of the load whose
# result decides whether the wake syscall is skipped — is what closes the window,
# for every caller, including ones that assemble `publishValue` + `wakeAll`
# themselves.
#
# WHY NOT A SOURCE GREP. A grep for `fullFence()` is inspection wearing automation's
# clothes: it passes if the call is moved somewhere useless (after the load, into
# `wakeRaw`, behind an `if`). Only the instruction stream settles where the barrier
# actually landed.
#
# THE CHECK REFUSES TO PASS WHAT IT CANNOT READ. If it cannot find the procs, cannot
# corroborate that the load it found is the `waiters` load (`WwOffWaiters == 4`), or
# does not know this architecture, it FAILS loudly rather than reporting a pass. A
# check that degrades to green on unfamiliar codegen is the defect it was written to
# remove. `SHM_LEASE_ALLOW_UNCHECKED_FENCE_SHAPE=1` downgrades an unsupported
# ARCHITECTURE or a missing disassembler to a loud non-fatal skip; it is a
# deliberate operator opt-out, and the banner names it.
#
# HOW IT WAS PROVEN TO FAIL: delete the two `fullFence()` calls from
# `src/shm_lease/waitword.nim` and re-run. Both procs report
# `NO FULL FENCE ... before the waiters load` and the script exits 1. Moving the
# call to AFTER the load — the relocation a source grep cannot see — fails the same
# way, and so does weakening `ATOMIC_SEQ_CST` to `ATOMIC_ACQUIRE`.
#
# CROSS-ARCHITECTURE SELF-CHECK. `SHM_LEASE_FENCE_SHAPE_BIN=<file>` plus
# `SHM_LEASE_FENCE_SHAPE_ARCH=<arch>` analyse a PREBUILT binary or object under
# another architecture's profile instead of building the driver. That is how the
# x86-64 profile below was exercised from an arm64 host (cross-compile the Nim-
# generated C for x86-64, then point this at the object). It is a maintenance tool,
# announces itself loudly, and is never used by `just test`.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root" || exit 1

override_bin="${SHM_LEASE_FENCE_SHAPE_BIN:-}"
arch="${SHM_LEASE_FENCE_SHAPE_ARCH:-$(uname -m)}"
allow_skip="${SHM_LEASE_ALLOW_UNCHECKED_FENCE_SHAPE:-0}"

loud_skip() {
  echo
  echo "!!! ============================================================== !!!"
  echo "!!! FENCE-SHAPE BARRIER **SKIPPED** — NOT VERIFIED ON THIS HOST     !!!"
  echo "!!! $1"
  echo "!!! The seq-cst fence in wakeAll/wakeOne is UNCHECKED in this run.  !!!"
  echo "!!! This is NOT a pass.                                             !!!"
  echo "!!! ============================================================== !!!"
  echo
  if [ "$allow_skip" = "1" ]; then
    echo "SHM_LEASE_ALLOW_UNCHECKED_FENCE_SHAPE=1 is set; continuing anyway (rc 0)."
    exit 0
  fi
  echo "Set SHM_LEASE_ALLOW_UNCHECKED_FENCE_SHAPE=1 to accept an unchecked run." >&2
  exit 1
}

# --- architecture profile ----------------------------------------------------
#
# `fence_re`  — a FULL fence, i.e. one that orders an earlier store against a
#               later load. On ARM64 that is `dmb ish` (or the stronger `dmb sy`);
#               `dmb ishst` and `dmb ishld` are deliberately NOT accepted, because
#               neither orders store->load and substituting one is exactly the
#               "optimisation" this barrier exists to catch. On x86-64 a seq-cst
#               fence is `mfence` or a `lock`-prefixed no-op (`lock orl $0x0,(%rsp)`
#               is what clang emits) or a locked `xchg`.
# `load_kind` — how the load of `waiters` is recognised; see `find_waiters_load`.
case "$arch" in
  arm64|aarch64)
    fence_re='(^|[[:space:]])dmb[[:space:]]+(ish|sy)([[:space:]]|$)'
    fence_desc='dmb ish / dmb sy'
    load_kind=arm64
    ;;
  x86_64|amd64)
    fence_re='(^|[[:space:]])(mfence|lock|xchg)([[:space:]]|$)'
    fence_desc='mfence / lock-prefixed op / locked xchg'
    load_kind=x86_64
    ;;
  *)
    loud_skip "unknown architecture '$arch' — no fence/load instruction profile."
    ;;
esac

# --- tools -------------------------------------------------------------------

if ! command -v objdump >/dev/null 2>&1; then
  loud_skip "no 'objdump' on PATH — cannot disassemble."
fi

nim_flags=(--skipParentCfg --skipUserCfg --hints:off --threads:on
            --warning:BareExcept:off --path:src --path:tests
            --path:../nim-shm-queue/src)

mkdir -p test-logs
bin="test-logs/fence_shape_driver"
dis="test-logs/fence-shape.dis"

echo "=== fence-shape barrier ($arch; fence = $fence_desc) ==="

if [ -n "$override_bin" ]; then
  echo "  *** CROSS-ARCHITECTURE SELF-CHECK: analysing '$override_bin' under the"
  echo "  *** '$arch' profile. This does NOT check the binary this host builds."
  bin="$override_bin"
  if [ ! -f "$bin" ]; then
    echo "FAIL: SHM_LEASE_FENCE_SHAPE_BIN='$bin' does not exist." >&2
    exit 1
  fi
else
  # `-d:release` and NOT `-d:danger`: release keeps the overflow check on the
  # `off + WwOffWaiters` addition, which is what materialises the constant 4 the
  # corroboration below looks for, and it is the optimisation level `just build`
  # ships. `-d:danger` would fold the offset away and the corroboration would
  # (correctly, loudly) refuse to pass.
  if ! nim c "${nim_flags[@]}" -d:release -o:"$bin" \
        tests/fence_shape_driver.nim > test-logs/fence-shape-build.log 2>&1; then
    echo "FAIL: could not build the fence-shape driver." >&2
    tail -20 test-logs/fence-shape-build.log >&2
    exit 1
  fi

  # Run it: both calls must take the syscall-free fast path, or the driver has
  # stopped exercising the path the fence protects.
  run_out="$("./$bin" 2>&1)"
  echo "  ${run_out//$'\n'/$'\n'  }"
  for want in "wakeAll=wkNoWaiters" "wakeOne=wkNoWaiters"; do
    if ! printf '%s\n' "$run_out" | grep -q "$want"; then
      echo "FAIL: driver did not take the wake fast path (expected $want)." >&2
      exit 1
    fi
  done
fi

if ! objdump -d "$bin" > "$dis" 2>test-logs/fence-shape-objdump.log; then
  echo "FAIL: objdump could not disassemble $bin." >&2
  tail -10 test-logs/fence-shape-objdump.log >&2
  exit 1
fi

# --- slicing -----------------------------------------------------------------
#
# Nim mangles these into `wakeAll__<rot13 of the absolute source path>_<id>`, so the
# symbol is matched by PREFIX; the path component differs per checkout and must not
# be baked in. Both objdump flavours (LLVM's on Darwin, GNU's on Linux) print
# `<addr> <symbol>:` headers and separate function bodies with a blank line.
#
# Operand comments (`<sym+0x..>` on both, `##`/`#` trailing comments) are stripped
# so a symbol NAME can never be mistaken for a mnemonic.
slice_proc() {
  awk -v pat="$1" '
    /^[0-9a-fA-F]+ <.*>:$/ { inproc = (index($0, pat) > 0); next }
    /^[[:space:]]*$/ { if (inproc) exit; next }
    inproc { print }
  ' "$dis" | sed -e 's/[[:space:]]*##.*$//' -e 's/[[:space:]]*#[[:space:]].*$//' \
                  -e 's/<[^<>]*>//g'
}

# --- the load of `waiters` ---------------------------------------------------
#
# ARM64: `loadU32SeqCst` compiles to an acquire-ordered load (`ldar`), and there is
# no other acquire-ordered load anywhere in `wakeAll` / `wakeOne` — the only other
# memory traffic in the prologue is the thread-local error flag, a plain `ldrb`. The
# FIRST such instruction is therefore the load of `waiters`, which also makes "no
# intervening load of waiters" true by construction.
#
# x86-64: a seq-cst load is a plain `mov`, so it is recognised structurally instead:
# the first `mov` that loads memory into a register through a general-purpose base
# register — excluding `%rip` (globals and the TLS descriptor), `%rsp`/`%rbp`
# (spills) and `%fs`/`%gs` (thread-locals). `base` and `off` are both runtime
# arguments, so the wait word can only be reached through such a register.
find_waiters_load() {
  local body="$1"
  if [ "$load_kind" = arm64 ]; then
    printf '%s\n' "$body" | grep -nE '(^|[[:space:]])(ldar|ldarb|ldarh|ldapr|ldaxr)([[:space:]]|$)' | head -1
  else
    printf '%s\n' "$body" \
      | grep -nE 'mov[a-z]*[[:space:]]+[^,]*\(%[a-z0-9]+(,%[a-z0-9]+(,[0-9]+)?)?\),[[:space:]]*%' \
      | grep -vE '%rip|%rsp|%rbp|%esp|%ebp|%fs:|%gs:' | head -1
  fi
}

fail=0

check_proc() {
  local label="$1" pat="$2"
  local body
  body="$(slice_proc "$pat")"

  if [ -z "$body" ]; then
    echo "  $label: FAIL — symbol '${pat}*' not found in $dis."
    echo "           (dead-stripped, inlined, or renamed: the check cannot pass" \
          "what it cannot read)"
    fail=1
    return
  fi

  local hit load_line load_text
  hit="$(find_waiters_load "$body")"
  if [ -z "$hit" ]; then
    echo "  $label: FAIL — could not locate the load of \`waiters\` in the" \
          "disassembly."
    echo "           The codegen changed shape; re-verify BY HAND and update this" \
          "check. Not a pass."
    fail=1
    return
  fi
  load_line="${hit%%:*}"
  load_text="$(printf '%s\n' "$body" | sed -n "${load_line}p" | sed 's/^[[:space:]]*//')"

  # CORROBORATION that this really is `base + off + WwOffWaiters`: somewhere between
  # the entry and the load, the constant 4 must be materialised — as an immediate
  # (`#0x4` / `$0x4`, the separate `off + 4` add that `-d:release`'s overflow check
  # forces) or folded into the load's own displacement (`0x4(`, `, #4]`, `#0x4]`).
  # Without it the instruction found is not demonstrably the waiter-count load and
  # the verdict below would be about the wrong instruction.
  local prefix
  prefix="$(printf '%s\n' "$body" | sed -n "1,${load_line}p")"
  if ! printf '%s\n' "$prefix" | grep -qE '[#$]0x4([^0-9a-fA-F]|$)|[#$]4([^0-9]|$)' \
      && ! printf '%s\n' "$load_text" | grep -qE '0x4\(|,[[:space:]]*#(0x)?4\]'; then
    echo "  $label: FAIL — found a load but could NOT corroborate it as" \
          "\`waiters\` (offset +4)."
    echo "           load: $load_text"
    echo "           Re-verify BY HAND and update this check. Not a pass."
    fail=1
    return
  fi

  local fence_line
  fence_line="$(printf '%s\n' "$prefix" | grep -nE "$fence_re" | head -1)"
  fence_line="${fence_line%%:*}"

  if [ -z "$fence_line" ]; then
    echo "  $label: FAIL — NO FULL FENCE ($fence_desc) before the waiters load."
    echo "           waiters load: $load_text"
    echo "           The store-buffering window in \`waitOn\`'s docstring is OPEN:" \
          "a wake can be skipped while a waiter parks on the stale value."
    fail=1
    return
  fi

  local fence_text
  fence_text="$(printf '%s\n' "$body" | sed -n "${fence_line}p" | sed 's/^[[:space:]]*//')"
  echo "  $label: OK"
  echo "      fence  -> $fence_text"
  echo "      waiters-> $load_text"
}

check_proc "wakeAll" "wakeAll__"
check_proc "wakeOne" "wakeOne__"

echo
if [ "$fail" -ne 0 ]; then
  echo "FENCE-SHAPE BARRIER FAILED." >&2
  echo "Full disassembly: $dis" >&2
  exit 1
fi
echo "fence-shape barrier: a full fence precedes the waiters load in both procs."
