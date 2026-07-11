#!/usr/bin/env bash
#
# libfuse/mayhem/build.sh — build libfuse's OSS-Fuzz harness (fuzz_optparse) as a sanitized
# libFuzzer target (+ a standalone reproducer), AND a small golden oracle over the fuzzed
# fuse_opt_parse() path for mayhem/test.sh.
#
# FUZZED SURFACE: libfuse's option parser, lib/fuse_opt.c — fuse_opt_parse() and friends. The
# harness (mayhem/harnesses/fuse_optparse.c, vendored from OSS-Fuzz) builds a struct fuse_args
# argv[] from the input bytes via the AdaLogics fuzz-header (vendored alongside it as
# ada_fuzz_header.h) and drives fuse_opt_parse() against an option_spec. Inputs are NOT files —
# they are the AdaLogics byte stream the header slices into 75-byte argv strings + an int.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). We compile libfuse3 ITSELF (lib/fuse_opt.c et al.) with $SANITIZER_FLAGS
# **plus -fsanitize=fuzzer-no-link** so the parser code — not just the harness — gets ASan+UBSan
# and SanitizerCoverage edge instrumentation (the base SANITIZER_FLAGS is ASan+UBSan only; without
# fuzzer-no-link on the library libFuzzer sees zero coverage feedback and the corpus collapses).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
# DEBUG_FLAGS: DWARF-3 debug info for Mayhem triage (clang-19 default is DWARF-5; §6.2 item 10).
# Use `:=` (keep-if-set) so callers can override (e.g. for a lighter debug build).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
export DEBUG_FLAGS
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"

# SanitizerCoverage for the fuzzed library (only meaningful when sanitizers are on — an empty
# SANITIZER_FLAGS means "no instrumentation", so don't force coverage in that case).
COV=""
case "$SANITIZER_FLAGS" in *fsanitize=*) COV="-fsanitize=fuzzer-no-link";; esac

# ── 1) Build the libfuse3 static library WITH sanitizers + coverage (the fuzzed parser is
#       instrumented). Follows OSS-Fuzz: meson static lib, no examples/tests/utils. io-uring is
#       disabled so we don't need liburing/libnuma in the image. ─────────────────────────────────
BUILD="$SRC/mayhem-build"
rm -rf "$BUILD"
env CC="$CC" CFLAGS="$SANITIZER_FLAGS $COV $DEBUG_FLAGS" \
  meson setup "$BUILD" "$SRC" \
    -Dexamples=false -Dtests=false -Dutils=false \
    -Ddefault_library=static -Denable-io-uring=false
ninja -C "$BUILD" -j"$MAYHEM_JOBS" lib/libfuse3.a
LIBFUSE="$BUILD/lib/libfuse3.a"
ls -la "$LIBFUSE"

# Harness include paths: lib/ + include/ for the FUSE headers, the meson build dir for the
# generated fuse_config.h, and the harness dir for the vendored ada_fuzz_header.h.
INC="-I$SRC/lib -I$SRC/include -I$BUILD -I$HARNESS_DIR"

# The vendored AdaLogics header does an intentional unaligned `*(int*)ptr` load (ada_fuzz_header.h)
# that UBSan's `alignment` check flags on the very first input, flooding the run. It's benign UB in
# the harness SCAFFOLDING (not in libfuse), so we drop ONLY the alignment check for the harness TU.
# The libfuse library keeps the full ASan+UBSan (including alignment).
HARNESS_NOALIGN=""
case "$SANITIZER_FLAGS" in *undefined*) HARNESS_NOALIGN="-fno-sanitize=alignment";; esac

# Compile the harness once (shared by the libFuzzer target and the standalone reproducer).
# $DEBUG_FLAGS is placed AFTER $SANITIZER_FLAGS so its -gdwarf-3 wins over any implicit DWARF
# version in the sanitizer flags (§6.2 item 10).
$CC $SANITIZER_FLAGS $COV $HARNESS_NOALIGN $DEBUG_FLAGS $INC \
    -Wno-incompatible-pointer-types-discards-qualifiers \
    -c "$HARNESS_DIR/fuse_optparse.c" -o "$BUILD/fuzz_optparse.o"

# ── 2) libFuzzer target -> /mayhem/fuzz_optparse  +  standalone reproducer -> *-standalone ───────
$CC $SANITIZER_FLAGS $COV $DEBUG_FLAGS \
    "$BUILD/fuzz_optparse.o" $LIB_FUZZING_ENGINE "$LIBFUSE" -lpthread -ldl -lrt -lm \
    -o /mayhem/fuzz_optparse

$CC $SANITIZER_FLAGS $COV $DEBUG_FLAGS \
    "$STANDALONE_FUZZ_MAIN" "$BUILD/fuzz_optparse.o" "$LIBFUSE" -lpthread -ldl -lrt -lm \
    -o /mayhem/fuzz_optparse-standalone
echo "built fuzz_optparse (+ standalone)"

# ── 3) Golden oracle for mayhem/test.sh. libfuse's OWN suite is pytest that mounts a real FUSE fs
#       (needs /dev/fuse + CAP_SYS_ADMIN) — NOT self-contained in a container, so we build a small
#       known-answer oracle over the SAME fuzzed surface (fuse_opt_parse and friends) instead. It
#       links the freshly built libfuse3.a and asserts byte-exact parser behaviour; a no-op /
#       exit(0) patch to lib/fuse_opt.c cannot pass it. Built with NORMAL flags (no sanitizer /
#       coverage noise) so test.sh is an honest PATCH oracle. ──────────────────────────────────
TESTBUILD="$SRC/mayhem-tests"
rm -rf "$TESTBUILD"
env CC="$CC" CFLAGS="" meson setup "$TESTBUILD" "$SRC" \
    -Dexamples=false -Dtests=false -Dutils=false \
    -Ddefault_library=static -Denable-io-uring=false
ninja -C "$TESTBUILD" -j"$MAYHEM_JOBS" lib/libfuse3.a
$CC -O1 -g -I"$SRC/include" -I"$TESTBUILD" \
    "$HARNESS_DIR/oracle_optparse.c" "$TESTBUILD/lib/libfuse3.a" \
    -lpthread -ldl -lrt -lm -o "$TESTBUILD/oracle_optparse"
echo "built golden oracle in mayhem-tests/"

echo "build.sh complete:"
ls -la /mayhem/fuzz_optparse /mayhem/fuzz_optparse-standalone "$TESTBUILD/oracle_optparse"
