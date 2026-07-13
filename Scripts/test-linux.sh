#!/usr/bin/env bash

set -euo pipefail

scratch_path="${SWIFT_SCRATCH_PATH:-.build}"
test_timeout_seconds="${SWIFT_TEST_TIMEOUT_SECONDS:-60}"

if [[ ! "$test_timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  printf 'SWIFT_TEST_TIMEOUT_SECONDS must be a positive integer, got %s\n' \
    "$test_timeout_seconds" >&2
  exit 1
fi

swift build \
  --build-tests \
  --scratch-path "$scratch_path" \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors

bin_path="$(swift build --show-bin-path --scratch-path "$scratch_path")"
test_binary="$bin_path/LicenseSeatPackageTests.xctest"

if [[ ! -x "$test_binary" ]]; then
  printf 'Could not find the compiled Linux XCTest executable under %s\n' "$scratch_path" >&2
  exit 1
fi

# Swift 6.2 corelibs XCTest can strand its async bridge when one process runs a
# mixed collection of @MainActor and synchronous XCTest cases. Execute every
# discovered case in a fresh process: coverage is identical, failures retain
# their normal XCTest exit status, and no case can leak URLSession/run-loop
# state into the next case.
test_list="$scratch_path/licenseseat-linux-test-cases.txt"
"$test_binary" --list-tests \
  | awk '$0 ~ /^[^[:space:]\/]+\/[^[:space:]\/]+$/ { print }' \
  > "$test_list"

if [[ ! -s "$test_list" ]]; then
  printf 'The Linux XCTest executable did not report any test cases\n' >&2
  exit 1
fi

while IFS= read -r test_case; do
  [[ -n "$test_case" ]] || continue
  printf 'Running %s\n' "$test_case"
  if timeout --foreground "${test_timeout_seconds}s" "$test_binary" "$test_case"; then
    continue
  else
    status=$?
    if [[ "$status" -eq 124 ]]; then
      printf 'Timed out after %ss: %s\n' "$test_timeout_seconds" "$test_case" >&2
    fi
    exit "$status"
  fi
done < "$test_list"
