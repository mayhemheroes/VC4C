/*
 * asan_options.c — bake detect_leaks=0 into the VC4C fuzz binaries.
 *
 * Mayhem owns the runtime ASAN_OPTIONS/LSAN_OPTIONS (abort_on_error=1, symbolize=0, …)
 * and sets them via the environment. It does NOT set detect_leaks, which defaults to 1 on
 * supported platforms. LeakSanitizer (LSan) requires /proc/self/mem write access and
 * fails fatally when the process is traced (e.g. under Mayhem's ptrace-based coverage
 * collector), causing every run to exit 1 → 0 edges → has_critical_errors abort.
 *
 * The fix: define __asan_default_options() and __lsan_default_options() WITHOUT the weak
 * attribute. The ASan/LSan runtimes define these as weak symbols; a non-weak (strong)
 * user definition always overrides the runtime's weak version, regardless of link order
 * or --whole-archive. detect_leaks=0 is supplied in BOTH hooks to cover whichever
 * sanitizer's flag parser initializes first. This completely disables LSan while leaving
 * full ASan + UBSan memory/UB error detection in place.
 *
 * Note: in simpler binaries (no shared ASan-instrumented libs), __attribute__((weak)) also
 * works; here we need strong symbols because libVC4CC.so is built with ASan and the
 * runtime is pulled in via --whole-archive, which puts multiple weak definitions in play.
 *
 * Linked into: /mayhem/build/src/vc4c (file-input target) and /mayhem/fuzz_spirv
 * (libFuzzer target). Same detect_leaks=0 pattern as mayhemheroes/my_basic.
 */

const char *__asan_default_options(void) {
    return "detect_leaks=0";
}

const char *__lsan_default_options(void) {
    return "detect_leaks=0";
}
