#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

for test_file in test-lib.sh test-install.sh test-output.sh test-guest.sh; do
  bash "$TEST_DIR/$test_file"
done
