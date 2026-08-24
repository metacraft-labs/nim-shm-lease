#!/usr/bin/env bash
# Run every nim-shm-lease litmus test under herd7 and CHECK ITS VERDICT
# (MV1 gate item (c)).
#
# This is not a "look at the output" script. Every test below has a REQUIRED
# verdict and the script fails if any test does not produce it, because half of
# these tests are required to be ALLOWED and a suite that only knows how to
# report "Never" would silently turn its own controls into passes. Of the
# twenty-eight tests below, NINE are required to be ALLOWED.
#
#   Never     = the outcome is forbidden by the model
#   Sometimes = the outcome is permitted by the model
#
# HOW TO GET herd7. It is NOT in nixpkgs on aarch64-darwin (nor is `herdtools`,
# `herd7`, `litmus7`, `diy` or `ocamlPackages.herdtools7`). Use `./get-herd7.sh`,
# which builds herdtools7 7.58 through opam against the nixpkgs OCaml; it is the
# recipe that actually worked on this host, with the two non-obvious steps
# recorded. On Linux, `nix shell nixpkgs#herdtools7 --command ./run-litmus.sh`
# should work directly (untested -- see ../README.md).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v herd7 >/dev/null 2>&1; then
  echo "herd7 not found on PATH." >&2
  echo "Build it with: $here/get-herd7.sh   (then re-run this script)" >&2
  echo "Or, where nixpkgs packages it: nix shell nixpkgs#herdtools7 --command $0" >&2
  exit 127
fi

# test name -> required verdict
expect_never=(
  # The shipped ordering of the grant publish, under C11 and both hardware models.
  grant-payload-publish
  grant-payload-publish-aarch64
  # The publish-before-write rule every segment format depends on.
  header-magic-publish
  header-magic-publish-aarch64
  # The RMW atomicity the whole claim design assumes.
  budget-cas-atomicity
  # THE :first_target: FIX, AS SHIPPED. These three pin the pair that
  # `src/shm_lease/waitword.nim` is INTENDED to compile to (release store, seq-cst
  # fence in `wakeAll`, seq-cst load of `waiters`; waiter unfenced), under all
  # three models.
  #
  # THEY ARE NOT A REGRESSION BARRIER OVER `src/`, and an earlier version of this
  # comment claimed they were. Each `.litmus` file is a standalone model: herd7's
  # verdict is a function of the file alone, so deleting `fullFence()` from
  # `waitword.nim` leaves every verdict below unchanged (checked, 2026-08-18).
  # The barrier that DOES fail on that edit is `tests/check-fence-shape.sh`
  # (`just test-fence-shape`), which disassembles the shipped `wakeAll` / `wakeOne`
  # and requires a full fence instruction ahead of the `waiters` load. Keeping
  # these MODELS in step with the source is a review obligation.
  grant-bump-vs-waiters-FENCED-fix
  grant-bump-vs-waiters-x86-FENCED
  grant-bump-vs-waiters-aarch64-FENCED
  # THE REMEDY NOT TAKEN, kept because "both work" is part of the record.
  grant-bump-vs-waiters-SEQCST-fix
  # The UNFENCED waiter-side pair on ARM, which is why the defect never fired here.
  grant-bump-vs-waiters-aarch64
  # The same relaxed message passing that is BUGGY on ARM is invisible on x86.
  grant-payload-publish-x86-RELAXED-control
  # ---- MV3: THE PUBLISHED AGGREGATE TABLE'S SEQLOCK, modelled before M13b
  # writes it. Two pairs, three memory models each, shipped shape and relaxed
  # control -- twelve verdicts, and the gate asks for them PER MODEL rather than
  # as one summary, because M3's lost wakeup was Forbidden on ARMv8 and Allowed
  # on the other two and a summary would have hidden it.
  #
  # PAIR (a): the writer's payload stores against its bump-to-even, versus the
  # reader's seq load against its payload loads. The publish direction.
  seqlock-publish-vs-read
  seqlock-publish-vs-read-aarch64
  seqlock-publish-vs-read-x86
  # The relaxed publish is ALLOWED on C11 and ARMv8 (below) and FORBIDDEN here:
  # the defect is invisible to any amount of x86 testing.
  seqlock-publish-vs-read-x86-RELAXED-control
  #
  # PAIR (b): the reader's SECOND seq load against its payload loads -- the pair
  # a compiler or a weak model may sink, and the one a hand-written seqlock most
  # often gets wrong.
  seqlock-recheck-vs-payload
  seqlock-recheck-vs-payload-aarch64
  seqlock-recheck-vs-payload-x86
  seqlock-recheck-vs-payload-x86-RELAXED-control
)

expect_sometimes=(
  # Controls: these MUST be allowed, or the "Never" verdicts above came for free.
  grant-payload-publish-RELAXED-control
  grant-payload-publish-aarch64-RELAXED-control
  # THE :first_target: FINDING, now FIXED in the source but KEPT here: these two
  # pin the DEFECTIVE shape (release store, no fence, seq-cst load of `waiters`),
  # which C11 and x86-TSO both permit to lose a wakeup. They are what stops the
  # `-FENCED-fix` and `-x86-FENCED` Never verdicts above from being free: the two
  # pairs differ by one instruction and the verdicts differ with them.
  # See ../README.md "Finding 2".
  grant-bump-vs-waiters
  grant-bump-vs-waiters-x86
  # And the fence must be on the PUBLISHER: fencing only the waiter leaves the
  # lost wakeup reachable. This is what licenses the shipped asymmetry (no fence
  # in `waitOn`) instead of copying obsring's both-sides pairing by reflex.
  grant-bump-vs-waiters-WAITER-FENCE-ONLY-control
  # ---- MV3's REQUIRED-TO-FAIL CONTROLS, and the tier is not evidence without
  # them: the gate says "a relaxed variant of EACH pair MUST produce the torn
  # read under at least one of C11/ARMv8". Both pairs, both models, four files.
  seqlock-publish-vs-read-RELAXED-control
  seqlock-publish-vs-read-aarch64-RELAXED-control
  # The reader-side one is the sharper of the two: its WRITER IS FULLY FENCED,
  # so the torn read is bought entirely by the missing acquire fence in front of
  # the reader's second counter load.
  seqlock-recheck-vs-payload-RELAXED-control
  seqlock-recheck-vs-payload-aarch64-RELAXED-control
)

fail=0
run_one() {
  local name="$1" want="$2"
  local out got
  out="$(herd7 "$here/$name.litmus" 2>&1)"
  got="$(printf '%s\n' "$out" | awk '/^Observation/ {print $3}')"
  if [ -z "$got" ]; then
    printf '%-48s ERROR (herd7 produced no verdict)\n' "$name"
    printf '%s\n' "$out" | head -5
    fail=1
    return
  fi
  if [ "$got" = "$want" ]; then
    printf '%-48s %-9s OK\n' "$name" "$got"
  else
    printf '%-48s %-9s FAIL (required %s)\n' "$name" "$got" "$want"
    fail=1
  fi
}

echo "herd7: $(herd7 -version 2>&1 | head -1)"
echo
echo "=== must be FORBIDDEN (Never) ==="
for t in "${expect_never[@]}"; do run_one "$t" Never; done
echo
echo "=== must be ALLOWED (Sometimes) ==="
for t in "${expect_sometimes[@]}"; do run_one "$t" Sometimes; done
echo
if [ "$fail" -ne 0 ]; then
  echo "LITMUS TIER FAILED." >&2
else
  echo "litmus tier: all verdicts as required."
fi
exit $fail
