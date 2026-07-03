#!/usr/bin/env bash
#
# mayhem/build.sh — build VC4C's libVC4CC + vc4c CLI with ASan+UBSan, then compile
# the mayhem/fuzz_spirv.cpp libFuzzer harness against the library.
#
# Air-gapped / re-runnable (SPEC §6.5):
#   The Dockerfile pre-clones three small deps into /opt/vc4c-deps/ (cpplog,
#   SPIRV-Headers, variant).  build.sh points cmake at them so NO network access
#   is needed — not on the first run and not on offline PATCH-tier re-runs.
#
#   cmake knobs that enable this:
#     FETCHCONTENT_FULLY_DISCONNECTED=ON   → forbids any FetchContent network fetch
#     FETCHCONTENT_SOURCE_DIR_*            → per-dep local source overrides
#     BUILD_OFFLINE=ON                     → sets EP_UPDATE_DISCONNECTED=1 (no git-pull)
#
# Build knobs (ENV, overridable via --build-arg):
#   SANITIZER_FLAGS  -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#   DEBUG_FLAGS      -g -gdwarf-3   (DWARF < 4; clang's plain -g emits DWARF-5)
#   CC / CXX         clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer
#   MAYHEM_JOBS      $(nproc) fallback
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export CC CXX SANITIZER_FLAGS DEBUG_FLAGS LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# ---------------------------------------------------------------------------
# asan_options: bake detect_leaks=0 into both fuzz binaries.
#
# LSan (LeakSanitizer) exits 1 when the process is traced (Mayhem's ptrace-based
# coverage collector) → every run produces 0 edges → has_critical_errors abort.
# __asan_default_options() fills gaps not covered by Mayhem's runtime ASAN_OPTIONS,
# so detect_leaks=0 takes effect before LSan initialises. Weak symbol: the runtime
# env can still override individual options if needed. Full ASan+UBSan stays active.
# ---------------------------------------------------------------------------
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/asan_options.c -o /tmp/vc4c_asan.o

# ---------------------------------------------------------------------------
# 0. Pre-populate ExternalProject source tree for cpplog.
#
# cmake's ExternalProject_Add for cpplog clones to:
#   ${CMAKE_BINARY_DIR}/cpplog/src/cpplog-project/
# We seed this from /opt/vc4c-deps/cpplog (pre-cloned in the Dockerfile)
# so cmake never needs network, even on the very first configure.
# SPIRV-Headers and variant use FetchContent (controlled via cmake variables below).
# ---------------------------------------------------------------------------
EP_CPPLOG="$SRC/build/cpplog/src/cpplog-project"
if [ ! -d "$EP_CPPLOG" ]; then
    mkdir -p "$(dirname "$EP_CPPLOG")"
    cp -rp /opt/vc4c-deps/cpplog "$EP_CPPLOG"
fi

# ---------------------------------------------------------------------------
# 1. Configure cmake.
#
# Options:
#   FETCHCONTENT_FULLY_DISCONNECTED=ON  → no network for FetchContent deps
#   FETCHCONTENT_SOURCE_DIR_*           → pre-cloned dirs override GitHub clones
#   BUILD_OFFLINE=ON                    → EP_UPDATE_DISCONNECTED=1 (no git pull)
#   LLVMLIB_FRONTEND=ON                 → cmake finds the clang binary
#                                         (avoids FATAL_ERROR "No OpenCL compiler")
#                                         No llvm-dev needed: if LLVM libs are absent
#                                         VC4C_ENABLE_LLVM_LIB_FRONTEND stays OFF and
#                                         hasLLVMFrontend() returns false at runtime.
#   SPIRV_FRONTEND=OFF                  → no SPIRV-Tools dependency
#   BUILD_TESTING=OFF                   → no cpptest-lite dependency
#   VC4CL_STDLIB_PRECOMPILE=OFF         → skip pre-compiling VC4CLStdLib headers
# ---------------------------------------------------------------------------
mkdir -p build
cmake -S . -B build \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
    -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
    -DCMAKE_BUILD_TYPE=Debug \
    -DBUILD_OFFLINE=ON \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    "-DFETCHCONTENT_SOURCE_DIR_SPIRV-HEADERS=/opt/vc4c-deps/spirv-headers" \
    -DFETCHCONTENT_SOURCE_DIR_VARIANT=/opt/vc4c-deps/variant \
    -DLLVMLIB_FRONTEND=ON \
    -DSPIRV_FRONTEND=OFF \
    -DBUILD_TESTING=OFF \
    -DVC4CL_STDLIB_PRECOMPILE=OFF \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_EXE_LINKER_FLAGS="/tmp/vc4c_asan.o"

# ---------------------------------------------------------------------------
# 2. Build the shared library (VC4CC) and the vc4c CLI binary.
#
# VC4CC is the library our libFuzzer harness links against.
# VC4C is the CLI tool kept for target parity with the original integration.
# Both are built with SANITIZER_FLAGS + DEBUG_FLAGS (DWARF-3).
# ---------------------------------------------------------------------------
cmake --build build -j"$MAYHEM_JOBS" --target VC4CC VC4C

LIB="$SRC/build/src/libVC4CC.so"
BIN="$SRC/build/src/vc4c"
[ -f "$LIB" ] || { echo "ERROR: libVC4CC.so not built" >&2; exit 1; }
[ -f "$BIN" ] || { echo "ERROR: vc4c not built" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 3. Compile the libFuzzer harness (fuzz_spirv).
#    Links against libVC4CC.so; rpath set so the image can run it from /mayhem.
#    Also builds a standalone non-fuzzer reproducer (fuzz_spirv-standalone).
# ---------------------------------------------------------------------------
HARNESS="$SRC/mayhem/fuzz_spirv.cpp"
INCLUDES="-I$SRC/include"

# Fuzzer binary (libFuzzer engine embedded).
# /tmp/vc4c_asan.o bakes detect_leaks=0 (weak __asan_default_options) so LSan is
# disabled under Mayhem's ptrace tracer without dropping full ASan+UBSan coverage.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
    -std=c++14 \
    $INCLUDES \
    "$HARNESS" \
    /tmp/vc4c_asan.o \
    -L"$SRC/build/src" -lVC4CC \
    -Wl,-rpath,/mayhem/build/src \
    -o /mayhem/fuzz_spirv

# Standalone reproducer: compile STANDALONE_FUZZ_MAIN as C (preserves C linkage
# on LLVMFuzzerTestOneInput), then link with clang++.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS \
    -c "$STANDALONE_FUZZ_MAIN" \
    -o /tmp/standalone_main.o

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS \
    -std=c++14 \
    $INCLUDES \
    "$HARNESS" \
    /tmp/standalone_main.o \
    -L"$SRC/build/src" -lVC4CC \
    -Wl,-rpath,/mayhem/build/src \
    -o /mayhem/fuzz_spirv-standalone

# ---------------------------------------------------------------------------
# 4. Clean (NORMAL-flags) build of the vc4c CLI for the functional-test oracle.
#
#    mayhem/test.sh runs THIS binary, NOT the sanitized/instrumented fuzz build
#    (SPEC §6.3 / port-repo step 8: the test suite is built with the project's
#    normal flags in a SEPARATE build tree, so PATCH grading = patch→build.sh→
#    test.sh exercises the real, un-instrumented compiler behaviour).
#
#    Only the VC4CC lib + VC4C CLI are needed — the oracle is a disassembler
#    known-answer test (vc4c --disassemble --hex) which needs no clang / LLVM /
#    spirv-llvm tool and no VideoCore IV hardware, so it is fully air-gapped.
#    cmake bakes an absolute build-rpath into build-test/src/vc4c, so it finds
#    build-test/src/libVC4CC.so at /mayhem/build-test/src when run in the image.
# ---------------------------------------------------------------------------
EP_CPPLOG_TEST="$SRC/build-test/cpplog/src/cpplog-project"
if [ ! -d "$EP_CPPLOG_TEST" ]; then
    mkdir -p "$(dirname "$EP_CPPLOG_TEST")"
    cp -rp /opt/vc4c-deps/cpplog "$EP_CPPLOG_TEST"
fi

mkdir -p build-test
cmake -S . -B build-test \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$DEBUG_FLAGS" \
    -DCMAKE_CXX_FLAGS="$DEBUG_FLAGS" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DBUILD_OFFLINE=ON \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    "-DFETCHCONTENT_SOURCE_DIR_SPIRV-HEADERS=/opt/vc4c-deps/spirv-headers" \
    -DFETCHCONTENT_SOURCE_DIR_VARIANT=/opt/vc4c-deps/variant \
    -DLLVMLIB_FRONTEND=ON \
    -DSPIRV_FRONTEND=OFF \
    -DBUILD_TESTING=OFF \
    -DVC4CL_STDLIB_PRECOMPILE=OFF

cmake --build build-test -j"$MAYHEM_JOBS" --target VC4CC VC4C

TESTBIN="$SRC/build-test/src/vc4c"
[ -f "$TESTBIN" ] || { echo "ERROR: normal-flags vc4c (test-oracle binary) not built" >&2; exit 1; }

echo "build.sh: OK — /mayhem/fuzz_spirv, /mayhem/fuzz_spirv-standalone built"
echo "        vc4c CLI (sanitized) at: $BIN"
echo "        vc4c CLI (test oracle, normal flags) at: $TESTBIN"
