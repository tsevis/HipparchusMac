#!/bin/bash
#
# Build Vendor/geos/geos.xcframework from a pinned GEOS release.
#
# Reproducible by construction: the version and its sha256 are literals below,
# the archive is verified before it is unpacked, and every CMake flag that
# affects the output is listed here rather than inherited from the environment.
# Re-running the script on the same machine, or on any machine with the same
# Xcode, produces the same library. The flags actually used are recorded in
# Vendor/geos/MANIFEST.txt beside the artefact.
#
# The artefact is committed, so a clean clone builds with no CMake and no
# network. You only need to run this to move to a new GEOS.
#
# Usage:  Scripts/build-geos-xcframework.sh [--force]
#
set -euo pipefail

GEOS_VERSION="3.14.1"
GEOS_SHA256="3c20919cda9a505db07b5216baa980bacdaa0702da715b43f176fb07eff7e716"
GEOS_URL="https://download.osgeo.org/geos/geos-${GEOS_VERSION}.tar.bz2"

# Matches the platforms.macOS version in Package.swift and App/project.yml.
DEPLOYMENT_TARGET="15.0"
ARCHS=(arm64 x86_64)

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${REPO}/.build/geos"
OUT="${REPO}/Vendor/geos"
XCFRAMEWORK="${OUT}/geos.xcframework"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ -d "${XCFRAMEWORK}" && ${FORCE} -eq 0 ]]; then
  echo "geos.xcframework already present. Pass --force to rebuild."
  exit 0
fi

for tool in cmake xcodebuild lipo libtool shasum; do
  command -v "${tool}" >/dev/null || { echo "error: ${tool} not found on PATH" >&2; exit 1; }
done

mkdir -p "${WORK}" "${OUT}"
ARCHIVE="${WORK}/geos-${GEOS_VERSION}.tar.bz2"

# --- fetch and verify -------------------------------------------------------
if [[ ! -f "${ARCHIVE}" ]]; then
  echo "==> Fetching ${GEOS_URL}"
  curl -fsSL --retry 3 -o "${ARCHIVE}.part" "${GEOS_URL}"
  mv "${ARCHIVE}.part" "${ARCHIVE}"
fi

echo "==> Verifying sha256"
ACTUAL="$(shasum -a 256 "${ARCHIVE}" | awk '{print $1}')"
if [[ "${ACTUAL}" != "${GEOS_SHA256}" ]]; then
  echo "error: sha256 mismatch for geos-${GEOS_VERSION}.tar.bz2" >&2
  echo "  expected ${GEOS_SHA256}" >&2
  echo "  actual   ${ACTUAL}" >&2
  echo "  refusing to build from an archive that is not the pinned release" >&2
  exit 1
fi

SRC="${WORK}/geos-${GEOS_VERSION}"
if [[ ! -d "${SRC}" ]]; then
  echo "==> Unpacking"
  tar -xjf "${ARCHIVE}" -C "${WORK}"
fi

# --- build one static library per architecture -------------------------------
# GEOS is C++ with a C API in a separate library, so libgeos.a and libgeos_c.a
# are merged into one archive. An XCFramework carries a single library, and a
# consumer linking only libgeos_c.a would fail on every C++ symbol behind it.
declare -a THIN_LIBS=()
for arch in "${ARCHS[@]}"; do
  BUILD="${WORK}/build-${arch}"
  echo "==> Configuring GEOS ${GEOS_VERSION} for ${arch}"
  cmake -S "${SRC}" -B "${BUILD}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="${arch}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_GEOSOP=OFF \
    -DBUILD_BENCHMARKS=OFF \
    -DBUILD_DOCUMENTATION=OFF \
    > "${BUILD}.configure.log" 2>&1 || { tail -40 "${BUILD}.configure.log" >&2; exit 1; }

  echo "==> Building ${arch}"
  cmake --build "${BUILD}" --config Release --parallel "$(sysctl -n hw.ncpu)" \
    > "${BUILD}.build.log" 2>&1 || { tail -40 "${BUILD}.build.log" >&2; exit 1; }

  GEOS_A="$(find "${BUILD}/lib" -name 'libgeos.a' | head -1)"
  GEOS_C_A="$(find "${BUILD}/lib" -name 'libgeos_c.a' | head -1)"
  [[ -f "${GEOS_A}" && -f "${GEOS_C_A}" ]] || { echo "error: ${arch} build produced no static libraries" >&2; exit 1; }

  MERGED="${WORK}/libgeos-merged-${arch}.a"
  libtool -static -o "${MERGED}" "${GEOS_A}" "${GEOS_C_A}" 2>/dev/null
  THIN_LIBS+=("${MERGED}")
done

# --- one universal library ---------------------------------------------------
echo "==> Creating universal library (${ARCHS[*]})"
UNIVERSAL_DIR="${WORK}/universal"
rm -rf "${UNIVERSAL_DIR}"
mkdir -p "${UNIVERSAL_DIR}"
UNIVERSAL="${UNIVERSAL_DIR}/libgeos.a"
lipo -create "${THIN_LIBS[@]}" -output "${UNIVERSAL}"

# --- stage the headers Swift imports ----------------------------------------
# geos_c.h is generated from geos_c.h.in at configure time, so it comes from the
# build tree, not the source tree. The module map is what makes `import CGEOS`
# work; only the C API is exposed, never the C++ headers.
HEADERS="${WORK}/include"
rm -rf "${HEADERS}"
mkdir -p "${HEADERS}"
GEOS_C_H="$(find "${WORK}/build-${ARCHS[0]}" -name 'geos_c.h' | head -1)"
[[ -f "${GEOS_C_H}" ]] || { echo "error: generated geos_c.h not found" >&2; exit 1; }
cp "${GEOS_C_H}" "${HEADERS}/geos_c.h"

# geos_c.h includes <geos/export.h> for its GEOS_DLL visibility macro, so that
# one C++ header has to come along. It is the only one: nothing else from the
# C++ tree is exposed.
mkdir -p "${HEADERS}/geos"
GEOS_EXPORT_H="${SRC}/include/geos/export.h"
[[ -f "${GEOS_EXPORT_H}" ]] || { echo "error: geos/export.h not found" >&2; exit 1; }
cp "${GEOS_EXPORT_H}" "${HEADERS}/geos/export.h"
cat > "${HEADERS}/module.modulemap" <<'MODULEMAP'
module CGEOS {
    header "geos_c.h"
    export *
}
MODULEMAP

# --- xcframework ------------------------------------------------------------
echo "==> Creating xcframework"
rm -rf "${XCFRAMEWORK}"
xcodebuild -create-xcframework \
  -library "${UNIVERSAL}" \
  -headers "${HEADERS}" \
  -output "${XCFRAMEWORK}" > "${WORK}/xcframework.log" 2>&1 \
  || { tail -40 "${WORK}/xcframework.log" >&2; exit 1; }

# --- manifest ---------------------------------------------------------------
cat > "${OUT}/MANIFEST.txt" <<MANIFEST
geos.xcframework
=================

Built by Scripts/build-geos-xcframework.sh. Do not edit by hand; rebuild with
    Scripts/build-geos-xcframework.sh --force

source          ${GEOS_URL}
version         ${GEOS_VERSION}
sha256          ${GEOS_SHA256}
architectures   ${ARCHS[*]} (single macOS slice, universal)
deployment      macOS ${DEPLOYMENT_TARGET}
libraries       libgeos.a + libgeos_c.a, merged with libtool -static
headers         geos_c.h (generated) + module.modulemap declaring module CGEOS

cmake flags
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_ARCHITECTURES=<arch>
  -DCMAKE_OSX_DEPLOYMENT_TARGET=${DEPLOYMENT_TARGET}
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DBUILD_SHARED_LIBS=OFF
  -DBUILD_TESTING=OFF
  -DBUILD_GEOSOP=OFF
  -DBUILD_BENCHMARKS=OFF
  -DBUILD_DOCUMENTATION=OFF

toolchain at build time
$(xcodebuild -version | sed 's/^/  /')
  cmake $(cmake --version | head -1 | awk '{print $3}')

GEOS is LGPL-2.1. It is linked statically here, which the licence permits on the
condition that the object files and this build script are available to anyone
who receives the binary. Both are in this repository.
MANIFEST

echo
echo "==> Done"
echo "    ${XCFRAMEWORK}"
lipo -info "$(find "${XCFRAMEWORK}" -name 'libgeos.a' | head -1)"
du -sh "${XCFRAMEWORK}"
