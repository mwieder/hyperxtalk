#!/bin/bash
# Build the vendored thirdparty libraries that have working xcodeprojs
# (libskia libsqlite libxml libzip libxslt libiodbc) and copy their
# .a outputs from _build/mac/Debug/ into prebuilt/lib/mac/.
#
# libcairo is intentionally excluded here — it is built by
# build-libcairo-mac-arm64.sh (meson) earlier in the prebuilt-mac pass
# and is already present in prebuilt/lib/mac/libcairo.a.  The xcodeproj
# for libcairo uses an older build system that no longer works, so we
# skip it to avoid a spurious BUILD FAILED in the log.
#
# Extracted from BUILD1.md steps 2 + 4 so `make prebuilt-mac` can call a
# single script instead of embedding the loop in the Makefile.
#
# Usage (from repo root):
#   sh prebuilt/scripts/build-thirdparty-mac-arm64.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BUILD_OUT="${REPO_ROOT}/_build/mac/Debug"
PREBUILT_LIB="${REPO_ROOT}/prebuilt/lib/mac"

mkdir -p "${PREBUILT_LIB}"

# libcairo is excluded — already built via meson in build-libcairo-mac-arm64.sh
LIBS="libskia libsqlite libxml libzip libxslt libiodbc"

FAILED_LIBS=""
for LIB in ${LIBS}; do
    echo "=== Building ${LIB} ==="
    if xcodebuild \
        -project "${REPO_ROOT}/build-mac/livecode/thirdparty/${LIB}/${LIB}.xcodeproj" \
        -configuration Debug \
        -arch arm64 \
        SOLUTION_DIR="${REPO_ROOT}" \
        2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"; then
        :
    else
        echo "ERROR: ${LIB} build failed — re-running with full output:"
        xcodebuild \
            -project "${REPO_ROOT}/build-mac/livecode/thirdparty/${LIB}/${LIB}.xcodeproj" \
            -configuration Debug \
            -arch arm64 \
            SOLUTION_DIR="${REPO_ROOT}" \
            2>&1 | tail -40
        FAILED_LIBS="${FAILED_LIBS} ${LIB}"
    fi
done

if [ -n "${FAILED_LIBS}" ]; then
    echo ""
    echo "ERROR: The following libraries failed to build:${FAILED_LIBS}"
    exit 1
fi

echo ""
echo "=== Copying outputs into prebuilt/lib/mac ==="
for OUT in libcairo.a libxslt.a libiodbc.a libxml.a libzip.a libsqlite.a; do
    if [ -f "${BUILD_OUT}/${OUT}" ]; then
        cp "${BUILD_OUT}/${OUT}" "${PREBUILT_LIB}/${OUT}"
    else
        echo "WARNING: ${OUT} not found in ${BUILD_OUT} — skipping"
    fi
done
for F in "${BUILD_OUT}"/libskia*.a; do
    [ -f "$F" ] && cp "$F" "${PREBUILT_LIB}/$(basename "$F")"
done

# Rebuild libskia_opt_arm.a with real NEON + CRC32 objects.
# The GYP target_conditions arch check often fails to select NEON sources at
# config time, leaving the archive as a stub (opts_dummy.o only). This script
# compiles the correct sources directly and replaces the stub.
echo "=== Rebuilding libskia_opt_arm.a with NEON + CRC32 sources ==="
sh "${SCRIPT_DIR}/build-libskia-opt-arm-mac-arm64.sh"

echo ""
echo "=== Done. prebuilt/lib/mac now has: ==="
ls "${PREBUILT_LIB}/" | sort
