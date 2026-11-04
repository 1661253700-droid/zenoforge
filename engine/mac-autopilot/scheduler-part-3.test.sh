#!/usr/bin/env bash
# Run partition 3 of the scheduler cases with the shared fixtures.
set -euo pipefail
SCHED_TEST_PART=3 bash "$(dirname -- "${BASH_SOURCE[0]}")/scheduler.test.sh"
