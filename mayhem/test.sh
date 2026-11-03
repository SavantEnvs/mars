#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the functional tests mayhem/build.sh built: zstd's own unit suite
# (mars/zstd/tests/fuzzer.c, asserts round trips / known sizes / error codes) and known-answer tests for
# mars' HTTP parser (mayhem/tests/http_test.cc). exit 0 = pass; CTRF report emitted.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

T="$SRC/build/mayhem/test"
for b in "$T/zstd_unit" "$T/http_test"; do
  [ -x "$b" ] || { echo "missing $b — mayhem/build.sh should have built it" >&2; emit_ctrf "mars" 0 1 0; exit 1; }
done

passed=0; failed=0
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# 1) zstd's unit suite: every numbered case must run and the run must reach its completion line.
#    (Each case asserts internally; a failure aborts with a non-zero status before the marker.)
out="$(cd "$W" && "$T/zstd_unit" -v -i1 2>&1)"; rc=$?
n_cases=$(printf '%s\n' "$out" | grep -oE 'test ?[0-9]+ :' | wc -l)
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'fuzzer tests completed'; then
  passed=$((passed + n_cases))
else
  failed=$((failed + 1)); echo "FAIL: zstd unit suite rc=$rc" >&2; printf '%s\n' "$out" | tail -5 >&2
fi
if [ "$n_cases" -lt 130 ]; then failed=$((failed + 1)); echo "FAIL: zstd unit suite ran only $n_cases cases (expected >=130)" >&2; fi

# 2) mars HTTP parser/builder known-answer tests: one PASS/FAIL line per assertion.
out="$("$T/http_test" 2>&1)"; rc=$?
p=$(printf '%s\n' "$out" | grep -c '^PASS ')
f=$(printf '%s\n' "$out" | grep -c '^FAIL ')
printf '%s\n' "$out" | grep '^FAIL ' >&2 || true
if [ "$p" -lt 25 ]; then failed=$((failed + 1)); echo "FAIL: http_test produced only $p PASS lines (expected >=25), rc=$rc" >&2; fi
[ "$rc" -eq 0 ] || { [ "$f" -gt 0 ] || failed=$((failed + 1)); }
passed=$((passed + p)); failed=$((failed + f))

emit_ctrf "mars-zstd-unit-and-http-kat" "$passed" "$failed" 0
