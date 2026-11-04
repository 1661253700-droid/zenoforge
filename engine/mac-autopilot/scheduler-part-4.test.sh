#!/usr/bin/env bash
# Run partition 4 of the scheduler cases with the shared fixtures.
set -euo pipefail
SCHED_TEST_PART=4 bash "$(dirname -- "${BASH_SOURCE[0]}")/scheduler.test.sh"
