#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run all tests/test-*.sh files. No network access and no root needed.

set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

failed=''
for t in test-*.sh; do
    printf '%s\n' "$t"
    if ! bash "$t"; then
        failed="$failed $t"
    fi
done

if [[ -n "$failed" ]]; then
    printf 'FAILED:%s\n' "$failed" >&2
    exit 1
fi
printf 'all test files passed\n'
