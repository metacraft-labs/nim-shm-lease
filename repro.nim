## Source-library interface for engine-driven consumers such as RunQuota.
## Cross-Repo-Source-Consumption §4.2a exports src/ through nimPathDirs;
## consuming this library does not build or run its test suite (SC-12).
import repro_project_dsl

package shm_lease:
  uses:
    "nim >=2.0"
    # shm_lease/obsring builds on the shared-memory queue.
    "nim-shm-queue"

  library shm_lease
