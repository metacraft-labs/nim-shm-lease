## Packed multi-dimensional reservation arithmetic for `nim-shm-lease`.
##
## The whole point of this module is that a RunQuota reservation vector — CPU
## slots, memory, process count, IO weight — is made to fit in ONE 64-bit word,
## because then a claim is `read / test fit / CAS the decremented value / retry`
## and admission needs no arbiter, no lock, and no IPC
## (`reprobuild-specs/RunQuota-Shared-Memory-Transport.md` §"1. The fit check and
## claim are the easy part").
##
## PACKING — four 16-bit fields, little end first:
##
## | bits  | dimension            | ceiling                                   |
## |-------|----------------------|-------------------------------------------|
## | 0–15  | CPU slots            | 65535 slots                               |
## | 16–31 | memory, 64 MiB units | 65535 × 64 MiB = 4095 GiB (~4 TiB)        |
## | 32–47 | process count        | 65535 concurrent processes                |
## | 48–63 | IO weight            | 65535 weight units                        |
##
## WHY 16 BITS EACH, and why 64-bit CAS is enough: 4 × 16 = 64 exactly, and every
## per-dimension ceiling above is orders of magnitude beyond any real build host
## (the largest machines today are ~256 cores / ~2 TiB RAM, and RunQuota's process
## and IO-weight budgets are policy numbers in the tens to hundreds). Coarsening
## memory to the spec's suggested 64 MiB unit is what buys the memory dimension its
## headroom in only 16 bits. So there is no need for a 128-bit CAS
## (`cmpxchg16b` / `CASP`); the spec permits one but conditions it on the packing
## being "genuinely too tight", and it is not. A future 5th dimension, or a memory
## ceiling above 4 TiB, is the trigger to revisit — at which point the choice is
## either a 256 MiB unit (16 TiB in the same 16 bits) or the 128-bit CAS.
##
## BORROW SAFETY — the reason `fitsPacked` is not optional. A packed subtraction is
## field-wise ONLY while every field difference is non-negative; one underflowing
## field borrows from the field above it and silently corrupts a *different*
## dimension. Therefore the fit test is performed per field BEFORE the CAS, and
## `packedSub` documents that precondition. `tests/test_shm_lease.nim` contains the
## negative proof: subtracting without the fit test produces an observable
## overcommit that the invariant checker catches.
##
## This module is pure arithmetic, so it compiles and is testable on EVERY
## platform, including the portable no-op arm.

const
  LeaseDimCount* = 4
    ## Number of reservation dimensions packed into one budget word.
  DimBits* = 16
    ## Bit width of one dimension.
  DimMax* = 0xFFFF'u32
    ## Largest value a single dimension can hold.
  MemUnitBytes* = 64 * 1024 * 1024
    ## Memory coarsening unit (64 MiB), per the spec's "64 MiB or 256 MiB
    ## granularity is ample for admission". Stored in the segment header so an
    ## attacher never has to agree with the creator out of band.

type
  LeaseDim* = enum
    ## The packed dimensions, in ascending bit position. The ordinal IS the field
    ## index, so `dimShift` is `ord(d) * DimBits`.
    ldCpuSlots  ## bits 0–15
    ldMemUnits  ## bits 16–31, in `MemUnitBytes` units
    ldProcs     ## bits 32–47
    ldIoWeight  ## bits 48–63

  ResourceVec* = object
    ## An UNPACKED reservation vector. Host-side only — shared memory never holds
    ## this type, only its packed `uint64` form (position independence: a packed
    ## budget word is a value, not a pointer).
    cpuSlots*: uint32
    memUnits*: uint32
    procs*: uint32
    ioWeight*: uint32

func dimShift*(d: LeaseDim): int {.inline.} = ord(d) * DimBits

func vecField*(v: ResourceVec; d: LeaseDim): uint32 {.inline.} =
  case d
  of ldCpuSlots: v.cpuSlots
  of ldMemUnits: v.memUnits
  of ldProcs: v.procs
  of ldIoWeight: v.ioWeight

proc setVecField*(v: var ResourceVec; d: LeaseDim; value: uint32) {.inline.} =
  case d
  of ldCpuSlots: v.cpuSlots = value
  of ldMemUnits: v.memUnits = value
  of ldProcs: v.procs = value
  of ldIoWeight: v.ioWeight = value

func vec*(cpuSlots, memUnits, procs, ioWeight: uint32): ResourceVec {.inline.} =
  ResourceVec(cpuSlots: cpuSlots, memUnits: memUnits, procs: procs,
    ioWeight: ioWeight)

func validVec*(v: ResourceVec): bool {.inline.} =
  ## Every dimension must be representable in `DimBits`. A caller handing over an
  ## out-of-range vector is a programming error, reported rather than truncated —
  ## a truncated claim would under-reserve, which is exactly the overcommit this
  ## library exists to prevent.
  v.cpuSlots <= DimMax and v.memUnits <= DimMax and v.procs <= DimMax and
    v.ioWeight <= DimMax

func packVec*(v: ResourceVec): uint64 {.inline.} =
  ## Pack an in-range vector. Out-of-range fields are masked; callers MUST have
  ## checked `validVec` first (the public API does).
  (uint64(v.cpuSlots and DimMax)) or
  (uint64(v.memUnits and DimMax) shl 16) or
  (uint64(v.procs and DimMax) shl 32) or
  (uint64(v.ioWeight and DimMax) shl 48)

func unpackVec*(w: uint64): ResourceVec {.inline.} =
  ResourceVec(
    cpuSlots: uint32(w and 0xFFFF'u64),
    memUnits: uint32((w shr 16) and 0xFFFF'u64),
    procs: uint32((w shr 32) and 0xFFFF'u64),
    ioWeight: uint32((w shr 48) and 0xFFFF'u64))

func packedField*(w: uint64; d: LeaseDim): uint32 {.inline.} =
  uint32((w shr dimShift(d)) and 0xFFFF'u64)

func fitsPacked*(avail, want: uint64): bool {.inline.} =
  ## PER-FIELD fit test: does `want` fit inside `avail` in EVERY dimension?
  ##
  ## Written as an explicit per-field comparison rather than a SWAR trick because
  ## the obvious SWAR form (`((avail or H) - want) and H`) requires every field to
  ## be ≤ 0x7FFF, which would throw away half of each dimension's range. If
  ## measurement ever shows this loop on the critical path, the fix is to widen the
  ## word (128-bit CAS) and then SWAR, not to shrink the fields.
  ##
  ## This is the precondition of `packedSub`: it is what makes the packed
  ## subtraction field-wise instead of borrowing across dimensions.
  for d in LeaseDim:
    let sh = dimShift(d)
    if ((want shr sh) and 0xFFFF'u64) > ((avail shr sh) and 0xFFFF'u64):
      return false
  true

func packedSub*(avail, want: uint64): uint64 {.inline.} =
  ## Field-wise subtraction. PRECONDITION: `fitsPacked(avail, want)`. Under that
  ## precondition no field borrows, so a single 64-bit subtract is exactly the
  ## field-wise result — which is what lets the claim be one CAS.
  avail - want

func packedAdd*(cur, give: uint64): uint64 {.inline.} =
  ## Field-wise addition. PRECONDITION: every field of `cur + give` is ≤ `DimMax`,
  ## i.e. `fitsPacked(capacity - cur, give)`. Under that precondition no field
  ## carries into the next dimension.
  cur + give

func memUnitsForBytes*(bytes: uint64): uint64 {.inline.} =
  ## Coarsen a byte count to whole `MemUnitBytes` units, rounding UP. Rounding up
  ## is not a detail: rounding down would under-reserve, and under-reserving
  ## memory is precisely the OOM that RunQuota exists to prevent.
  (bytes + uint64(MemUnitBytes) - 1) div uint64(MemUnitBytes)

func `-`*(a, b: ResourceVec): ResourceVec {.inline.} =
  ## Field-wise difference, saturating at zero (so a caller computing
  ## `capacity - remaining` for a report can never wrap into a nonsense number).
  ResourceVec(
    cpuSlots: (if a.cpuSlots >= b.cpuSlots: a.cpuSlots - b.cpuSlots else: 0),
    memUnits: (if a.memUnits >= b.memUnits: a.memUnits - b.memUnits else: 0),
    procs: (if a.procs >= b.procs: a.procs - b.procs else: 0),
    ioWeight: (if a.ioWeight >= b.ioWeight: a.ioWeight - b.ioWeight else: 0))

func `+`*(a, b: ResourceVec): ResourceVec {.inline.} =
  ResourceVec(
    cpuSlots: a.cpuSlots + b.cpuSlots,
    memUnits: a.memUnits + b.memUnits,
    procs: a.procs + b.procs,
    ioWeight: a.ioWeight + b.ioWeight)

func `$`*(v: ResourceVec): string =
  "(cpu: " & $v.cpuSlots & ", memUnits: " & $v.memUnits & ", procs: " &
    $v.procs & ", io: " & $v.ioWeight & ")"
