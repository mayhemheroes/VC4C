/*
 * mayhem/vc4c_target.cpp — file-input harness for the `vc4c` Mayhem target.
 *
 * Mayhem delivers each test input as a FILE (the `@@` substitution).  This reads
 * that file, wraps its bytes as a SPIR-V binary module and drives VC4C's BUILT-IN
 * SPIR-V front-end + full compilation pipeline (SPIRVLexer -> normalize -> optimize
 * -> adjust -> codegen) — the exact same instrumented code path the healthy
 * fuzz_spirv libFuzzer harness exercises, and no external clang/llvm-spirv tool.
 *
 * WHY A WRAPPER (not the real vc4c CLI):
 *   The public `vc4c` CLI (src/main.cpp) calls Compiler::compile WITHOUT a try/catch.
 *   Compiler::compile logs and RE-THROWS CompilationError, so on empty / malformed /
 *   non-SPIR-V input (e.g. Mayhem's baseline empty testcase, or any mutation that
 *   corrupts the SPIR-V magic -> "Pre-compilation: Unhandled pre-compilation") the
 *   exception escapes main() -> std::terminate() -> SIGABRT.  Mayhem records that as
 *   an "Uncaught Exception" CRITICAL error on the seed/baseline, aborts the run and
 *   reports edges=0.  main.cpp is upstream source we keep additively unmodified, so we
 *   provide this thin, exception-safe entry point instead.  Genuine memory-safety bugs
 *   in the parser still trap via ASan (a real crash, not a caught C++ exception).
 */
#include <cstdint>
#include <exception>
#include <fstream>
#include <iterator>
#include <sstream>
#include <vector>

#include "Compiler.h"    /* vc4c::Compiler, vc4c::Configuration, vc4c::Frontend */
#include "Precompiler.h" /* vc4c::CompilationData, vc4c::SourceType */

int main(int argc, char** argv)
{
    if(argc < 2)
        return 0;

    std::ifstream in(argv[1], std::ios::binary);
    if(!in)
        return 0;
    std::vector<uint8_t> buf((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());

    /* SPIR-V has a 5-word (20-byte) minimum header; skip trivial inputs cheaply. */
    if(buf.size() < 20)
        return 0;

    try
    {
        /* Wrap bytes as a SPIR-V binary CompilationData (no temp file needed). */
        vc4c::CompilationData input(buf.begin(), buf.end(), vc4c::SourceType::SPIRV_BIN, "input");

        vc4c::Configuration config;
        /* Force the SPIR-V front-end: precompilation becomes a no-op (input type ==
         * output type), the built-in SPIRVLexer parses, no external tool is invoked. */
        config.frontend = vc4c::Frontend::SPIR_V;

        /* Silence verbose compiler logging (route to an in-memory sink). */
        std::wostringstream sink;
        vc4c::setLogger(sink, /*coloredOutput=*/false);

        /* In-memory compile (2-arg overload, no output file) — exercises the full
         * lex -> normalize -> optimize -> adjust -> codegen pipeline. */
        vc4c::Compiler::compile(input, config);
    }
    catch(...)
    {
        /* CompilationError / std::exception on malformed / non-kernel SPIR-V is
         * EXPECTED and recoverable — swallow it so we exit cleanly instead of
         * aborting.  ASan-detected memory errors are NOT C++ exceptions and still
         * crash the process, surfacing as real Mayhem defects. */
    }
    return 0;
}
