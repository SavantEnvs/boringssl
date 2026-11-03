#!/usr/bin/env bash
#
# mayhem/test.sh — RUN BoringSSL's own gtest suites (built by mayhem/build.sh with normal flags).
# Counts come from each gtest binary's own summary; a binary that prints no summary (crashed, or neutered
# to exit(0)) counts as one failure, so a no-op patch cannot pass.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"
TB="$SRC/build/tests"

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

passed=0; failed=0; skipped=0
for t in crypto_test ssl_test pki_test decrepit_test; do
  bin="$TB/$t"
  if [ ! -x "$bin" ]; then echo "missing test runner $bin (mayhem/build.sh must build it)" >&2; failed=$((failed+1)); continue; fi
  log="$(mktemp)"
  "$bin" >"$log" 2>&1; rc=$?
  tail -n 15 "$log"
  ran="$(sed -nE 's/^\[==========\] ([0-9]+) tests? from .* ran\..*/\1/p' "$log" | tail -n1)"
  p="$(sed -nE 's/^\[  PASSED  \] ([0-9]+) tests?\./\1/p' "$log" | tail -n1)"
  s="$(sed -nE 's/^\[  SKIPPED \] ([0-9]+) tests?.*/\1/p' "$log" | head -n1)"
  f="$(sed -nE 's/^\[  FAILED  \] ([0-9]+) tests?, listed below:/\1/p' "$log" | tail -n1)"
  rm -f "$log"
  if [ -z "$ran" ] || [ -z "$p" ]; then
    echo "$t produced no gtest summary (rc=$rc)" >&2; failed=$((failed+1)); continue
  fi
  passed=$((passed+p)); skipped=$((skipped+${s:-0})); failed=$((failed+${f:-0}))
  [ "$rc" -eq 0 ] || [ -n "${f:-}" ] || failed=$((failed+1))
done
emit_ctrf "gtest" "$passed" "$failed" "$skipped"
