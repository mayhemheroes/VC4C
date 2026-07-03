#!/usr/bin/env bash
#
# mayhem/test.sh — functional known-answer test (KAT) for VC4C.
#
# WHAT IT ASSERTS
#   VC4C is a compiler/toolchain for VideoCore IV (Raspberry Pi GPU) QPU machine
#   code.  This oracle runs VC4C's built-in disassembler over a FIXED, committed
#   compiled-QPU binary (testing/formats/test.bin, a 5-kernel module) and asserts
#   the produced hex listing is BYTE-FOR-BYTE EQUAL to the project's own committed
#   golden (testing/formats/test_disassembled.hex).  This is exactly the assertion
#   made by upstream's TestFrontends::testDisassembler — a real known-answer test
#   of VC4C's binary<->hex machine-code translation, not "the tool exited 0".
#
#   Why this path: the disassembler is a pure, deterministic function of the input
#   binary — it needs NO external clang / llvm-spirv translator and NO VideoCore IV
#   hardware, so it runs fully air-gapped in the commit image (unlike VC4C's
#   OpenCL-C/SPIR-V compile+emulate tests, which require those tools/hardware).
#
# NON-REWARD-HACKABLE
#   The output is compared against a fixed golden the compiler must REPRODUCE, so a
#   neutered vc4c (e.g. main(){exit(0);}, or the verify-repo LD_PRELOAD sabotage that
#   _exit(0)s the binary before it writes anything) produces no/empty output → the
#   byte-exact diff and the structural checks FAIL.  "Ran without crashing" cannot
#   pass this.
#
# CONTRACT (SPEC §6.3)
#   * RUNS the normal-flags vc4c that mayhem/build.sh produced at build-test/src/vc4c
#     (the separate, un-instrumented build) — it does NOT compile anything here.
#   * Emits a CTRF (https://ctrf.io) results.summary (file + `CTRF {...}` stdout
#     marker) and exits non-zero iff failed>0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker); returns non-zero iff failed>0.
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

TOOL="vc4c-disassemble-kat"
VC4C="$SRC/build-test/src/vc4c"           # normal-flags binary from build.sh (NOT the fuzz build)
BIN_IN="$SRC/testing/formats/test.bin"                 # fixed 5-kernel compiled QPU module
GOLDEN="$SRC/testing/formats/test_disassembled.hex"    # project's committed golden hex listing

# The test-oracle binary and its fixtures must exist — a missing one is a build.sh bug (fail loudly).
if [ ! -x "$VC4C" ]; then
  echo "ERROR: normal-flags vc4c CLI missing at $VC4C — mayhem/build.sh must build it" >&2
  emit_ctrf "$TOOL" 0 1; exit $?
fi
if [ ! -f "$BIN_IN" ] || [ ! -f "$GOLDEN" ]; then
  echo "ERROR: KAT fixtures missing ($BIN_IN / $GOLDEN)" >&2
  emit_ctrf "$TOOL" 0 1; exit $?
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out.hex"
rm -f "$OUT"   # ensure no stale output — a neutered vc4c must leave nothing behind

# Run VC4C's disassembler: compiled QPU binary -> hex machine-code listing.
"$VC4C" --disassemble --hex -o "$OUT" "$BIN_IN" >"$WORK/vc4c.log" 2>&1
rc=$?

passed=0; failed=0

# --- Test 1: byte-for-byte known-answer match against the committed golden. ------------
if [ "$rc" -eq 0 ] && [ -s "$OUT" ] && diff -q "$GOLDEN" "$OUT" >/dev/null 2>&1; then
  echo "PASS[1/2] disassemble(test.bin) reproduces test_disassembled.hex exactly"
  passed=$((passed+1))
else
  echo "FAIL[1/2] disassembler output does not match golden (vc4c rc=$rc, out bytes=$( [ -f "$OUT" ] && wc -c <"$OUT" || echo 0))"
  [ -s "$WORK/vc4c.log" ] && sed 's/^/    vc4c: /' "$WORK/vc4c.log" | head -5
  [ -s "$OUT" ] && diff "$GOLDEN" "$OUT" 2>&1 | head -8 | sed 's/^/    diff: /'
  failed=$((failed+1))
fi

# --- Test 2: computed structural/semantic property of the produced listing. ------------
# The 5-kernel module must disassemble to a listing that names all 5 kernels and holds
# exactly 494 instruction/data words (0x... lines).  Independent of the exact-diff and
# still derived from real disassembler output, so a neuter can't fake it.
EXPECT_KERNELS="test_switch_2_default test_simple_if test_switch_2 test_switch_more test_switch_more_default"
EXPECT_WORDS=494
if [ -s "$OUT" ]; then
  words=$(grep -c '^0x' "$OUT" 2>/dev/null || echo 0)
  missing=""
  for k in $EXPECT_KERNELS; do
    grep -q "Kernel '$k'" "$OUT" 2>/dev/null || missing="$missing $k"
  done
  if [ -z "$missing" ] && [ "$words" -eq "$EXPECT_WORDS" ]; then
    echo "PASS[2/2] listing names all 5 kernels and holds $EXPECT_WORDS machine-code words"
    passed=$((passed+1))
  else
    echo "FAIL[2/2] structural check (words=$words expected=$EXPECT_WORDS; missing kernels:${missing:- none})"
    failed=$((failed+1))
  fi
else
  echo "FAIL[2/2] no disassembler output to inspect"
  failed=$((failed+1))
fi

emit_ctrf "$TOOL" "$passed" "$failed"
