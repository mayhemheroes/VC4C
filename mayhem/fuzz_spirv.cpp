/*
 * mayhem/fuzz_spirv.cpp — libFuzzer harness for VC4C's built-in SPIR-V binary parser
 * and full compilation pipeline (SPIRVLexer → normalize → optimize → codegen).
 *
 * Input: arbitrary bytes treated as SPIR-V binary (SourceType::SPIRV_BIN).
 * Frontend::SPIR_V forces the built-in SPIRVLexer (no external clang/spirv-llvm needed).
 */

#include <cstddef>
#include <cstdint>
#include <exception>
#include <sstream>
#include <vector>

/* VC4C public API */
#include "Compiler.h"    /* vc4c::Compiler, vc4c::Configuration, vc4c::Frontend */
#include "Precompiler.h" /* vc4c::CompilationData, vc4c::SourceType */

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    /* SPIR-V has a 5-word (20-byte) minimum header; bail early on trivial inputs */
    if(size < 20)
        return 0;

    try
    {
        /* Wrap the fuzzer bytes as a SPIR-V binary CompilationData (no copy into a file) */
        std::vector<uint8_t> buf(data, data + size);
        vc4c::CompilationData input(buf.begin(), buf.end(), vc4c::SourceType::SPIRV_BIN, "fuzz");

        vc4c::Configuration config;
        /* Force the SPIR-V front-end so precompilation is a no-op (input == outputType),
         * the built-in SPIRVLexer handles parsing and no external tool is required. */
        config.frontend = vc4c::Frontend::SPIR_V;

        /* Route logger to a sink so verbose output does not slow fuzzing */
        std::wostringstream sink;
        vc4c::setLogger(sink, /*coloredOutput=*/false);

        /* Full pipeline: lex → normalize → optimize → adjust → codegen.
         * CompilationError/std::exception on invalid input is expected. */
        vc4c::Compiler::compile(input, config);
    }
    catch(...)
    {
        /* All exceptions are expected for malformed / non-kernel SPIR-V */
    }
    return 0;
}
