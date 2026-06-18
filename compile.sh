#!/usr/bin/env bash
# Build evocube + the `hex` binary inside the build environment.
#
# This script FAILS LOUDLY if either build step fails. Previously it had no error
# handling, so a failed `evocube` build was silently ignored and the self-contained
# image shipped with `hex` but no real `evocube` executable (the docker build still
# reported success). We check exit codes AND verify the produced binaries.
#
# Note: deliberately NOT using `set -e` because the Vulkan `setup-env.sh` sourced
# below references unset vars; we use explicit `|| { ...; exit 1; }` checks instead.

# ---- evocube (CPU only: OpenMP; no CUDA/LibTorch) ----
cd /space/evocube || exit 1
mkdir -p build
cd build || exit 1
cmake .. || { echo "ERROR: evocube cmake configure failed" >&2; exit 1; }
make -j"$(nproc)" all || { echo "ERROR: evocube build failed" >&2; exit 1; }
# Verify a representative evocube executable was actually produced.
test -x /space/evocube/build/polycube_withHexEx \
  || { echo "ERROR: evocube produced no polycube_withHexEx binary" >&2; exit 1; }

# ---- libraries: libtorch + Vulkan SDK ----
export Torch_DIR='/space/lib/libtorch/share/cmake/Torch/'
# enable libtorch first, then vulkan
source /space/lib/vulkan-sdk-1.3.268.0/setup-env.sh

# ---- interactive-hex-meshing (hex: CUDA + LibTorch + Vulkan) ----
cd /space/interactive-hex-meshing || exit 1
mkdir -p build/Release
cd build/Release || exit 1
cmake ../.. -DCMAKE_BUILD_TYPE=Release -DTorch_DIR="$Torch_DIR" \
  || { echo "ERROR: hex cmake configure failed" >&2; exit 1; }
make -j"$(nproc)" all || { echo "ERROR: hex build failed" >&2; exit 1; }
test -x /space/interactive-hex-meshing/bin/Release/hex \
  || { echo "ERROR: hex produced no binary" >&2; exit 1; }

cd /space
echo "OK: evocube + hex built successfully."
