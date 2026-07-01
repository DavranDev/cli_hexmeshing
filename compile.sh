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

apply_evocube_polycube_final_fix() {
  local marker="Skipping final-polycube measurement"
  local patch_file="/space/patches/evocube-polycube_final-segfault.patch"

  if grep -q "$marker" app/init_from_folder.cpp; then
    echo "OK: evocube missing-polycube_final fix already present."
    return 0
  fi

  if [[ ! -f "$patch_file" ]]; then
    echo "ERROR: evocube source is missing the polycube_final crash fix, and $patch_file was not found." >&2
    echo "ERROR: mount or copy the repository patches/ directory to /space/patches, then rerun /space/compile.sh." >&2
    exit 1
  fi
  command -v patch >/dev/null 2>&1 \
    || { echo "ERROR: patch command is required to apply $patch_file." >&2; exit 1; }

  echo "Applying evocube missing-polycube_final crash fix..."
  patch -p1 --forward < "$patch_file" \
    || { echo "ERROR: failed to apply $patch_file." >&2; exit 1; }

  grep -q "$marker" app/init_from_folder.cpp \
    || { echo "ERROR: evocube patch did not leave the expected marker in init_from_folder.cpp." >&2; exit 1; }
}

apply_evocube_polycube_final_fix

apply_evocube_init_from_folder_options_fix() {
  local marker="--input-dir PATH"
  local patch_file="/space/patches/evocube-init_from_folder-options.patch"

  if grep -q -- "$marker" app/init_from_folder.cpp; then
    echo "OK: evocube init_from_folder options fix already present."
    return 0
  fi

  if [[ ! -f "$patch_file" ]]; then
    echo "ERROR: evocube init_from_folder lacks reliable CLI options, and $patch_file was not found." >&2
    echo "ERROR: mount or copy the repository patches/ directory to /space/patches, then rerun /space/compile.sh." >&2
    exit 1
  fi
  command -v patch >/dev/null 2>&1 \
    || { echo "ERROR: patch command is required to apply $patch_file." >&2; exit 1; }

  echo "Applying evocube init_from_folder options fix..."
  patch -p1 --forward < "$patch_file" \
    || { echo "ERROR: failed to apply $patch_file." >&2; exit 1; }

  grep -q -- "$marker" app/init_from_folder.cpp \
    || { echo "ERROR: evocube patch did not leave the expected init_from_folder options marker." >&2; exit 1; }
}

apply_evocube_init_from_folder_options_fix

mkdir -p build
cd build || exit 1
cmake .. || { echo "ERROR: evocube cmake configure failed" >&2; exit 1; }
make -j"$(nproc)" all || { echo "ERROR: evocube build failed" >&2; exit 1; }
# Verify a representative evocube executable was actually produced.
test -x /space/evocube/build/polycube_withHexEx \
  || { echo "ERROR: evocube produced no polycube_withHexEx binary" >&2; exit 1; }

# ---- libraries: libtorch + Vulkan SDK ----
export Torch_DIR='/space/lib/libtorch/share/cmake/Torch/'

source_vulkan_sdk() {
  local sdk_root="${VULKAN_SDK_ROOT:-/space/lib/vulkan-sdk}"
  if [[ ! -f "$sdk_root/setup-env.sh" && -f /space/lib/vulkan-sdk-1.3.268.0/setup-env.sh ]]; then
    sdk_root="/space/lib/vulkan-sdk-1.3.268.0"
  fi
  if [[ ! -f "$sdk_root/setup-env.sh" ]]; then
    echo "ERROR: Vulkan SDK setup-env.sh not found." >&2
    echo "ERROR: run /space/setup.sh or make sure /space/lib/vulkan-sdk is mounted." >&2
    exit 1
  fi

  # enable libtorch first, then Vulkan
  source "$sdk_root/setup-env.sh"
  export VULKAN_SDK_ROOT="$sdk_root"
}

source_vulkan_sdk

# ---- interactive-hex-meshing (hex: CUDA + LibTorch + Vulkan) ----
cd /space/interactive-hex-meshing || exit 1

apply_hex_validation_layer_fix() {
  local marker="enable_validation_layer_ = false"
  local patch_file="/space/patches/interactive-hex-meshing-validation-layer-fallback.patch"

  if grep -q "$marker" vkoo/src/core/Instance.cpp; then
    echo "OK: hex missing-validation-layer fallback already present."
    return 0
  fi

  if [[ ! -f "$patch_file" ]]; then
    echo "ERROR: hex source is missing the Vulkan validation-layer fallback, and $patch_file was not found." >&2
    echo "ERROR: mount or copy the repository patches/ directory to /space/patches, then rerun /space/compile.sh." >&2
    exit 1
  fi
  command -v patch >/dev/null 2>&1 \
    || { echo "ERROR: patch command is required to apply $patch_file." >&2; exit 1; }

  echo "Applying hex Vulkan validation-layer fallback..."
  patch -p1 --forward < "$patch_file" \
    || { echo "ERROR: failed to apply $patch_file." >&2; exit 1; }

  grep -q "$marker" vkoo/src/core/Instance.cpp \
    || { echo "ERROR: hex patch did not leave the expected validation fallback marker." >&2; exit 1; }
}

apply_hex_validation_layer_fix

mkdir -p build/Release
cd build/Release || exit 1

if [[ -f CMakeCache.txt ]]; then
  cached_vulkan_include="$(sed -n 's/^Vulkan_INCLUDE_DIR:PATH=//p' CMakeCache.txt | head -n 1)"
  if [[ -n "$cached_vulkan_include" && ! -d "$cached_vulkan_include" ]]; then
    echo "Removing stale hex CMake cache: Vulkan_INCLUDE_DIR=$cached_vulkan_include"
    rm -f CMakeCache.txt
    rm -rf CMakeFiles
  fi
fi

cmake ../.. -DCMAKE_BUILD_TYPE=Release -DTorch_DIR="$Torch_DIR" \
  || { echo "ERROR: hex cmake configure failed" >&2; exit 1; }
make -j"$(nproc)" all || { echo "ERROR: hex build failed" >&2; exit 1; }
test -x /space/interactive-hex-meshing/bin/Release/hex \
  || { echo "ERROR: hex produced no binary" >&2; exit 1; }

cd /space
echo "OK: evocube + hex built successfully."
