## The ANCHOR on every platform that has one: boot id + owner pid + process
## start time, judged by `anchorVerdict`.
##
## `tests/test_shm_lease.nim` carries the same verdict clauses against the lease
## segment, and that file is POSIX-only by construction (it forks and maps). The
## anchor is not: it is the one piece of this library a consumer uses on Windows
## today -- `runquota`'s published stats table records its publisher's anchor in
## the segment header and reports a stale publisher from it -- so its contract is
## asserted here with nothing but processes, on Linux, macOS and Windows alike.
##
## NO MOCKS. Real processes, started and ended by this test; the start time a
## process reads for ITSELF compared with the one another process reads for it;
## and a pid whose process has exited, both while a handle to it is still held
## and after the last handle is gone -- the two states that differ on Windows,
## where a process object outlives its process for as long as anybody holds it.

import std/[os, osproc, streams, strutils, unittest]

import shm_lease/anchor

const childFlag = "--anchor-child"

proc selfExe(): string = getAppFilename()

when isMainModule:
  if paramCount() >= 1 and paramStr(1) == childFlag:
    # THE CHILD: report what it computes about ITSELF, then either exit or
    # wait to be told to (a line on stdin), so the parent can observe it alive.
    let pid = getCurrentProcessId()
    echo "pid " & $pid
    echo "start " & $processStartTime(pid)
    echo "boot " & $bootId()
    flushFile(stdout)
    if paramCount() >= 2 and paramStr(2) == "--linger":
      discard stdin.readLine()
    quit 0

proc parseReport(text: string): tuple[pid, start, boot: uint64] =
  for line in text.splitLines():
    let parts = line.strip().split(' ')
    if parts.len != 2: continue
    case parts[0]
    of "pid": result.pid = parseBiggestUInt(parts[1])
    of "start": result.start = parseBiggestUInt(parts[1])
    of "boot": result.boot = parseBiggestUInt(parts[1])
    else: discard

suite "anchor: boot id + owner pid + process START TIME, on every platform":
  test "the anchor is supported here":
    check anchorSupported

  test "start time is what decides pid reuse, and it IS consulted":
    let myPid = getCurrentProcessId()
    let myStart = processStartTime(myPid)
    check myStart != 0'u64
    check processStartTime(myPid) == myStart
    check anchorVerdict(bootId(), uint64(myPid), myStart) == avLive
    # SAME pid, SAME boot, process demonstrably alive -- but a different start
    # time. Only the start time can tell these apart.
    check anchorVerdict(bootId(), uint64(myPid), myStart + 1) == avPidReused
    check anchorVerdict(bootId(), uint64(myPid), myStart - 1) == avPidReused
    # An unknown (0) recorded start time falls back to boot + pid.
    check anchorVerdict(bootId(), uint64(myPid), 0'u64) == avLive

  test "a previous boot and a missing owner are their own verdicts":
    let myPid = getCurrentProcessId()
    let myStart = processStartTime(myPid)
    check anchorVerdict(bootId() + 2, uint64(myPid), myStart) == avStaleBoot
    check anchorVerdict(bootId(), 0'u64, 0'u64) == avNoOwner

  test "bootId is stable, never zero, and the SAME in another process":
    ## Stability within a process is necessary and not sufficient: the segment
    ## header is written by one process and judged by another, so a boot id
    ## that two processes of one boot compute differently makes every live
    ## segment read as `avStaleBoot`. A derivation from "now minus uptime"
    ## differs between two calls by the clock's own jitter, which is why the
    ## cross-process comparison is repeated rather than made once.
    let mine = bootId()
    check mine != 0'u64
    for _ in 0 ..< 200:
      check bootId() == mine
    for _ in 0 ..< 3:
      let output = execProcess(selfExe(), args = [childFlag],
        options = {poStdErrToStdOut})
      let report = parseReport(output)
      check report.boot == mine

  test "another process reads a child's start time exactly as the child does":
    var child = startProcess(selfExe(), args = [childFlag, "--linger"],
      options = {})
    let output = child.outputStream
    var lines: seq[string] = @[]
    for _ in 0 ..< 3:
      lines.add(output.readLine())
    let report = parseReport(lines.join("\n"))
    check report.pid == uint64(child.processID)
    check report.start != 0'u64
    # THE CROSS-PROCESS AGREEMENT the anchor depends on: the publisher records
    # its own start time and a reader recomputes it from the pid.
    check processStartTime(child.processID) == report.start
    check pidAlive(report.pid)
    check anchorVerdict(bootId(), report.pid, report.start) == avLive
    check anchorVerdict(bootId(), report.pid, report.start + 1) == avPidReused

    # Let it go, and wait for it WHILE STILL HOLDING the process. On Windows the
    # process object -- and with it the pid -- survives its exit for as long as
    # a handle is held, and `OpenProcess` still succeeds on it; the anchor must
    # not take a successful open for proof of life.
    child.inputStream.writeLine("go")
    child.inputStream.flush()
    check child.waitForExit(10_000) == 0
    check not pidAlive(report.pid)
    check anchorVerdict(bootId(), report.pid, report.start) == avOwnerGone
    child.close()

    # ...and after the last handle is gone the pid is free for reuse, so the
    # only honest claim is that the anchor is not LIVE: either nothing wears
    # the pid, or something else does and its start time says so.
    check anchorVerdict(bootId(), report.pid, report.start) in
      {avOwnerGone, avPidReused}
