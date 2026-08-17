#!/usr/bin/env bash
# Build herd7 (herdtools7) on a host where nixpkgs does not package it.
#
# WHY THIS EXISTS. On aarch64-darwin, nixpkgs has no herdtools7 under any
# attribute -- `herdtools7`, `herdtools`, `herd7`, `litmus7`, `diy` and
# `ocamlPackages.herdtools7` all fail to resolve. MV1's tooling note gave two
# routes and said the opam one was worth 30 minutes; it worked, in about that,
# and this script is the recipe so nobody has to re-derive it.
#
# THE TWO NON-OBVIOUS STEPS, both of which cost an attempt each:
#
#  1. `--packages=ocaml-system` so opam REUSES the nixpkgs OCaml (5.3.0) instead
#     of compiling ocaml-base-compiler from source. herdtools7 7.58 builds fine
#     against it and this turns a ~20-minute build into a ~2-minute one.
#
#  2. `nix-shell -p` rather than `nix shell`. herdtools7 needs zarith, which needs
#     GMP's HEADERS and its pkg-config file, and it also needs a binary literally
#     named `pkgconf` (for opam's `conf-pkg-config`) as well as one named
#     `pkg-config` (for `conf-gmp`'s own probe). `nix shell` only puts `bin/` on
#     PATH, so `gmp.h` is not on the compiler's include path and `conf-gmp` fails
#     with "fatal error: gmp.h: No such file or directory". `nix-shell -p` makes
#     them real build inputs, which sets NIX_CFLAGS_COMPILE and PKG_CONFIG_PATH.
#
# opam's own sandbox is disabled because it does not compose with the Nix one.
#
# Usage:
#   ./get-herd7.sh                  # builds into ./herd7-opam by default
#   OPAMROOT=/somewhere ./get-herd7.sh
#
# Then:
#   export PATH="$OPAMROOT/mv1/bin:$PATH"
#   ./run-litmus.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OPAMROOT="${OPAMROOT:-$here/herd7-opam}"
export OPAMYES=1 OPAMCONFIRMLEVEL=unsafe-yes

echo "OPAMROOT=$OPAMROOT"
nix-shell -p opam ocaml gmp pkg-config pkgconf gnumake gnupatch unzip curl git gcc rsync \
  --run '
  set -o pipefail
  ocaml -version
  pkg-config --exists gmp && echo "gmp.pc: found" || echo "gmp.pc: absent (may still work)"
  opam init --bare --no-setup --disable-sandboxing -y 2>&1 | tail -3
  opam switch create mv1 --packages=ocaml-system -y 2>&1 | tail -3
  eval $(opam env --switch=mv1 --set-switch)
  opam install herdtools7 --assume-depexts -y 2>&1 | tail -20
  echo
  echo "herd7:    $OPAMROOT/mv1/bin/herd7"
  "$OPAMROOT/mv1/bin/herd7" -version
'
echo
echo "Add to PATH:  export PATH=\"$OPAMROOT/mv1/bin:\$PATH\""
