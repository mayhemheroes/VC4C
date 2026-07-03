# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for VC4C — builds ON TOP of the org C/C++ base image.
# VC4C is an OpenCL-to-QPU compiler; we fuzz its built-in SPIR-V binary parser
# (Frontend::SPIR_V) — no external clang/spirv-llvm tool required at build time.
#
# Build:
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) -t vc4c-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an
# empty value breaks clang ("must be a non-negative decimal integer") both here and for
# any in-image rebuild. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# Declare WITHOUT a default so the base ENV flows through to build.sh when not overridden.
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# VC4C's cmake build fetches small deps (cpplog, SPIRV-Headers, variant) via
# ExternalProject / FetchContent at configure time.  We pre-clone them here
# (with network) into /opt/vc4c-deps/ so that build.sh (and offline PATCH-tier
# re-runs) can configure cmake fully air-gapped using FETCHCONTENT_SOURCE_DIR_*
# and pre-populated ExternalProject source trees.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
        cmake git \
 && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/doe300/cpplog.git        /opt/vc4c-deps/cpplog \
 && git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git /opt/vc4c-deps/spirv-headers \
 && git clone --depth 1 https://github.com/mpark/variant.git         /opt/vc4c-deps/variant

USER mayhem

WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Functional oracle: mayhem/test.sh runs VC4C's disassembler over a fixed compiled
# QPU binary and asserts the hex listing matches the committed golden byte-for-byte
# (upstream's TestFrontends::testDisassembler KAT). It needs no clang/llvm-spirv tool
# and no VideoCore IV hardware, so it runs air-gapped here. A failing suite fails the build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
