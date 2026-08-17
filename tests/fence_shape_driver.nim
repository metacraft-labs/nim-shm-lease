## Driver for `tests/check-fence-shape.sh` — NOT a unittest.
##
## Its only job is to force `wakeAll` and `wakeOne` into a linked, optimised
## binary so their MACHINE CODE can be inspected. `wakeOne` in particular is
## dead-stripped out of every other binary in this repo, because nothing in the
## tree calls it yet (M5 will), so a shape check run against `test_shm_lease_waitword`
## would silently check one of the two procs and report a pass for both.
##
## It also RUNS, rather than merely linking: both calls take the syscall-free fast
## path (`waiters == 0`), so a driver that stopped exercising the very path the
## fence protects would announce itself here instead of quietly disassembling
## something else.
##
## No mock objects: this calls the shipped `wakeAll` / `wakeOne` in the shipped
## module, compiled with the flags `just build` uses.

import shm_lease/waitword

# The wait word is 8 bytes (`value` at +0, `waiters` at +4) and the atomics
# require 8-byte alignment in every mapping. A static, aligned buffer is enough:
# the fast path never enters the kernel, so nothing here needs a real `mmap`
# segment — and the cross-mapping behaviour is the multi-process gate's job, not
# this driver's.
var word {.align: 8.}: array[64, byte]

proc main() =
  let base = cast[ptr UncheckedArray[byte]](addr word[0])
  let a = wakeAll(base, 0)
  let b = wakeOne(base, 0)
  # Printed so a driver that stopped taking the fast path is visible in the log
  # rather than inferred; the shell check asserts on these two lines.
  echo "fence-shape-driver: wakeAll=", a
  echo "fence-shape-driver: wakeOne=", b

main()
