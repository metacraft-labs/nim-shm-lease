#!/usr/bin/env bash
# Run every nim-shm-lease litmus test under herd7 and CHECK ITS VERDICT
# (MV1 gate item (c)).
#
# This is not a "look at the output" script. Every test below has a REQUIRED
# verdict and the script fails if any test does not produce it, because half of
# these tests are required to be ALLOWED and a suite that only knows how to
# report "Never" would silently turn its own controls into passes.
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
  # THE :first_target: REMEDIES -- what the fix would buy.
  grant-bump-vs-waiters-SEQCST-fix
  grant-bump-vs-waiters-x86-FENCED
  grant-bump-vs-waiters-aarch64
  # The same relaxed message passing that is BUGGY on ARM is invisible on x86.
  grant-payload-publish-x86-RELAXED-control
)

expect_sometimes=(
  # Controls: these MUST be allowed, or the "Never" verdicts above came for free.
  grant-payload-publish-RELAXED-control
  grant-payload-publish-aarch64-RELAXED-control
  # THE :first_target: ITSELF. Allowed is the FINDING, not a failure of this
  # script -- see ../README.md "Finding 2". The shipped release-store/seq-cst-load
  # pair does not forbid the lost wakeup under C11 or under x86-TSO.
  grant-bump-vs-waiters
  grant-bump-vs-waiters-x86
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
