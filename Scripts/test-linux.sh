#!/usr/bin/env bash

set -euo pipefail

scratch_path="${SWIFT_SCRATCH_PATH:-.build}"
test_timeout_seconds="${SWIFT_TEST_TIMEOUT_SECONDS:-60}"
completion_marker="__LICENSESEAT_XCTEST_BODY_AND_CLEANUP_COMPLETE__"

classify_test_result() {
  local status="$1"
  local output_file="$2"
  local zero_failure_marker_count
  local all_marker_count

  zero_failure_marker_count="$(grep -Fxc "${completion_marker} failures=0" "$output_file" || true)"
  all_marker_count="$(grep -Fc "$completion_marker" "$output_file" || true)"

  # Exactly one zero-failure attestation is mandatory. The test-only base
  # emits it after the body, assertion recording, teardown blocks, and all SDK
  # cleanup. Missing, duplicate, or non-zero markers fail closed.
  if [[ "$zero_failure_marker_count" -ne 1 || "$all_marker_count" -ne 1 ]]; then
    return 1
  fi

  if [[ "$status" -eq 0 ]]; then
    return 0
  fi

  # Swift 6.2/6.3 corelibs XCTest can leave its no-op async teardown bridge
  # waiting after the attested lifecycle has completed. Only that external
  # timeout is recoverable; every other exit status remains a failure.
  if [[ "$status" -eq 124 ]]; then
    return 2
  fi

  return 1
}

run_classifier_self_test() {
  local fixture
  local actual
  fixture="$(mktemp)"

  assert_classification() {
    local expected="$1"
    local status="$2"
    local contents="$3"
    printf '%b' "$contents" > "$fixture"

    set +e
    classify_test_result "$status" "$fixture"
    actual=$?
    set -e

    if [[ "$actual" -ne "$expected" ]]; then
      printf 'Classifier self-test failed: expected %s, got %s\n' \
        "$expected" "$actual" >&2
      exit 1
    fi
  }

  assert_classification 0 0 "${completion_marker} failures=0\n"
  assert_classification 2 124 "${completion_marker} failures=0\n"
  assert_classification 1 124 ""
  assert_classification 1 124 "${completion_marker} failures=1\n"
  assert_classification 1 1 "${completion_marker} failures=0\n"
  assert_classification 1 0 \
    "${completion_marker} failures=0\n${completion_marker} failures=0\n"
  assert_classification 1 0 "ordinary XCTest output\n"
  rm -f "$fixture"
  printf 'Linux runner classifier self-tests passed\n'
}

if [[ "${LICENSESEAT_LINUX_RUNNER_SELF_TEST:-0}" == "1" ]]; then
  run_classifier_self_test
  exit 0
fi

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
# discovered case in a fresh process so no case leaks URLSession/run-loop state
# into another. The test base emits a zero-failure lifecycle attestation after
# repository cleanup; the classifier above permits only the known no-op async
# teardown stall after that marker and fails closed for every earlier timeout.
test_list="$scratch_path/licenseseat-linux-test-cases.txt"
test_output="$scratch_path/licenseseat-linux-current-test.log"
"$test_binary" --list-tests \
  | awk '$0 ~ /^[^[:space:]\/]+\/[^[:space:]\/]+$/ { print }' \
  > "$test_list"

if [[ ! -s "$test_list" ]]; then
  printf 'The Linux XCTest executable did not report any test cases\n' >&2
  exit 1
fi

executed_count=0
runner_teardown_stall_count=0
while IFS= read -r test_case; do
  [[ -n "$test_case" ]] || continue
  executed_count=$((executed_count + 1))
  printf 'Running %s\n' "$test_case"

  set +e
  timeout --foreground "${test_timeout_seconds}s" \
    "$test_binary" "$test_case" > "$test_output" 2>&1
  status=$?
  set -e
  cat "$test_output"

  set +e
  classify_test_result "$status" "$test_output"
  classification=$?
  set -e

  case "$classification" in
    0)
      ;;
    2)
      runner_teardown_stall_count=$((runner_teardown_stall_count + 1))
      printf 'Accepted attested corelibs XCTest teardown stall: %s\n' \
        "$test_case"
      ;;
    *)
      if [[ "$status" -eq 124 ]]; then
        printf 'Timed out without a zero-failure lifecycle attestation after %ss: %s\n' \
          "$test_timeout_seconds" "$test_case" >&2
      else
        printf 'Test process failed lifecycle attestation (status %s): %s\n' \
          "$status" "$test_case" >&2
      fi
      if [[ "$status" -eq 0 ]]; then
        exit 1
      fi
      exit "$status"
      ;;
  esac
done < "$test_list"

printf 'Linux XCTest cases completed: %s (%s attested teardown stalls)\n' \
  "$executed_count" "$runner_teardown_stall_count"
