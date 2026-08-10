#!/usr/bin/env bash

set -euo pipefail

minimum_coverage="${1:-85}"
if [[ ! "$minimum_coverage" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Coverage threshold must be numeric, got %s\n' "$minimum_coverage" >&2
  exit 1
fi

package_bin="$(swift build --show-bin-path)"
test_binary="$package_bin/LicenseSeatPackageTests.xctest/Contents/MacOS/LicenseSeatPackageTests"
if [[ ! -x "$test_binary" ]]; then
  test_binary="$(find "$package_bin" -type f -name LicenseSeatPackageTests -perm +111 -print -quit)"
fi
coverage_profile="$(find .build -type f -name default.profdata -print -quit)"

if [[ -z "$test_binary" || ! -x "$test_binary" ]]; then
  printf 'Could not find the instrumented LicenseSeat test binary\n' >&2
  exit 1
fi
if [[ -z "$coverage_profile" || ! -f "$coverage_profile" ]]; then
  printf 'Could not find default.profdata; run swift test --enable-code-coverage first\n' >&2
  exit 1
fi

coverage_report="$(
  xcrun llvm-cov report "$test_binary" \
    -instr-profile "$coverage_profile" \
    -ignore-filename-regex='Tests/|/checkouts/|resource_bundle_accessor|runner\.swift'
)"
printf '%s\n' "$coverage_report"

line_coverage="$(
  awk '/^TOTAL/ { value = $10; gsub(/%/, "", value); print value }' \
    <<< "$coverage_report"
)"
if [[ ! "$line_coverage" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf 'Could not parse total line coverage\n' >&2
  exit 1
fi

awk -v current="$line_coverage" -v minimum="$minimum_coverage" 'BEGIN {
  if ((current + 0) < (minimum + 0)) {
    printf "Line coverage %.2f%% is below the required %.2f%%\n", current, minimum > "/dev/stderr"
    exit 1
  }
  printf "Line coverage %.2f%% satisfies the required %.2f%%\n", current, minimum
}'
