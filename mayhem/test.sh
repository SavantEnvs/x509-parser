#!/usr/bin/env bash
#
# mayhem/test.sh — RUN x509-parser's own test suite (already built by mayhem/build.sh via
# `cargo test --no-run`). Does NOT compile. Behavioral oracle: every test binary asserts real
# results (assert_eq!/known-answer DER fixtures under assets/), so a PATCH that neuters the parser
# into a no-op fails these assertions rather than merely "not crashing" — exactly what the
# anti-reward-hack sabotage check (SPEC §6.3) requires.
#
# REQUIRED OUTPUT: a CTRF (ctrf.io) summary — see emit_ctrf below.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BUILD_JSON="$SRC/mayhem/.cargo-test-build.json"
[ -f "$BUILD_JSON" ] || { echo "ERROR: $BUILD_JSON missing — build.sh should have produced it (cargo test --no-run)" >&2; emit_ctrf "cargo-test" 0 1; exit $?; }

# Extract every test-binary executable path cargo emitted for `cargo test --no-run`.
mapfile -t TEST_BINS < <(python3 -c '
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    if msg.get("reason") == "compiler-artifact" and msg.get("profile", {}).get("test") and msg.get("executable"):
        print(msg["executable"])
' "$BUILD_JSON")

[ "${#TEST_BINS[@]}" -gt 0 ] || { echo "ERROR: no test binaries found in $BUILD_JSON — is build.sh's cargo test --no-run failing silently?" >&2; emit_ctrf "cargo-test" 0 1; exit $?; }

TOTAL_PASSED=0 TOTAL_FAILED=0 TOTAL_IGNORED=0 ANY_RUN_FAILED=0
for bin in "${TEST_BINS[@]}"; do
  echo "=== running $bin ==="
  out="$("$bin" --test-threads="$(nproc)" 2>&1)"; rc=$?
  echo "$out"
  # Sum every "test result: ..." line (unit-test binary + each tests/*.rs integration binary).
  while read -r passed failed ignored; do
    [ -z "$passed" ] && continue
    TOTAL_PASSED=$((TOTAL_PASSED + passed))
    TOTAL_FAILED=$((TOTAL_FAILED + failed))
    TOTAL_IGNORED=$((TOTAL_IGNORED + ignored))
  done < <(printf '%s\n' "$out" | sed -nE 's/^test result: [a-zA-Z]+\. ([0-9]+) passed; ([0-9]+) failed; ([0-9]+) ignored;.*/\1 \2 \3/p')
  [ "$rc" -eq 0 ] || ANY_RUN_FAILED=1
done

# A non-zero exit with no "test result:" line parsed (e.g. the binary itself crashed/aborted) is a
# failure the summary line wouldn't otherwise capture — count it so the CTRF report stays honest.
if [ "$ANY_RUN_FAILED" -eq 1 ] && [ "$TOTAL_FAILED" -eq 0 ] && [ "$TOTAL_PASSED" -eq 0 ]; then
  TOTAL_FAILED=1
fi

emit_ctrf "cargo-test" "$TOTAL_PASSED" "$TOTAL_FAILED" "$TOTAL_IGNORED"
