#!/usr/bin/env bash
#
# libfuse/mayhem/test.sh — RUN the golden oracle built by mayhem/build.sh and emit a CTRF summary.
# exit 0 iff every oracle check passed.
#
# WHY a golden oracle and not libfuse's own suite: libfuse's tests are a pytest suite that mounts a
# real FUSE filesystem (it needs /dev/fuse and CAP_SYS_ADMIN), so it is NOT self-contained inside an
# unprivileged build container. Instead, mayhem-tests/oracle_optparse is a known-answer test over the
# EXACT fuzzed surface — lib/fuse_opt.c's fuse_opt_parse / add_arg / insert_arg / match / add_opt — so
# it is a real PATCH oracle: a no-op or exit(0) patch to fuse_opt.c cannot pass it. This script only
# RUNS the pre-built binary; it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

ORACLE="$SRC/mayhem-tests/oracle_optparse"

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

if [ ! -x "$ORACLE" ]; then
  echo "missing $ORACLE — run mayhem/build.sh first" >&2
  emit_ctrf "fuse_opt-oracle" 0 1 0; exit 2
fi

echo "=== running golden oracle: $ORACLE ==="
out="$("$ORACLE" 2>&1)"; rc=$?
echo "$out"

# The oracle prints a final "ORACLE pass=<n> fail=<n>" line.
PASSED=$(printf '%s\n' "$out" | sed -n 's/.*ORACLE pass=\([0-9][0-9]*\) fail=[0-9][0-9]*.*/\1/p' | tail -1)
FAILED=$(printf '%s\n' "$out" | sed -n 's/.*ORACLE pass=[0-9][0-9]* fail=\([0-9][0-9]*\).*/\1/p' | tail -1)

if [ -z "$PASSED" ] || [ -z "$FAILED" ]; then
  echo "could not parse oracle summary; using exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "fuse_opt-oracle" 1 0 0; exit 0; }
  emit_ctrf "fuse_opt-oracle" 0 1 0; exit 1
fi

emit_ctrf "fuse_opt-oracle" "$PASSED" "$FAILED" 0
