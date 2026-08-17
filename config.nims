switch("path", "src")
switch("threads", "on")

# M4: the observation ring rides `nim-shm-queue`'s Layer 1 rather than growing a
# second copy of the MPSC protocol, so the sibling checkout is on the path when it
# is present (the workspace layout). Absent, only `shm_lease/obsring` fails to
# compile; the rest of the library is unaffected. `shm_lease.nimble` and the
# `Justfile` thread the same path -- the Justfile restates it because
# `--skipParentCfg` suppresses this file.
when system.dirExists("../nim-shm-queue/src"):
  switch("path", "../nim-shm-queue/src")
