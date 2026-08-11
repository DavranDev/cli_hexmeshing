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

# CPU-only build: no CUDA toolkit, no CUDA LibTorch, no LunarG Vulkan SDK.
# Set by Dockerfile.cpu and by `setup.sh --cpu`. This selects the *build*
# variant; it is unrelated to `hex --device cpu`, which a CUDA-enabled binary
# can also use.
HEX_CPU_ONLY="${HEX_CPU_ONLY:-0}"

source_vulkan_sdk() {
  # A CPU-only build takes Vulkan from the distro (libvulkan-dev), which is
  # already on the default include/library paths. There is no setup-env.sh to
  # source, and the hard error below would abort the CPU image build.
  if [[ "$HEX_CPU_ONLY" == 1 ]]; then
    echo "OK: HEX_CPU_ONLY=1 — using the system Vulkan loader (no LunarG SDK)."
    return 0
  fi

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

# One build directory per variant. A single shared directory would carry a
# CMake cache from the other variant (CUDA paths, CUDA-enabled Torch), and
# selectively deleting cache entries to recover is exactly the fragile pattern
# the Vulkan_INCLUDE_DIR repair below already demonstrates.
if [[ "$HEX_CPU_ONLY" == 1 ]]; then
  hex_build_dir="build/cpu-release"
else
  hex_build_dir="build/cuda-release"
fi
echo "==> hex build directory: $hex_build_dir"
mkdir -p "$hex_build_dir"
cd "$hex_build_dir" || exit 1

# A cache can also go stale because a dependency tree MOVED rather than changed
# flags. Switching LibTorch variants renames lib/libtorch-<variant> to
# lib/libtorch, and the cache keeps absolute .so paths from the previous
# configure -- `-DTorch_DIR=` refreshes that one variable but does not re-derive
# the already-found library paths, so the build dies with
#   No rule to make target '/space/lib/libtorch-cpu/lib/libc10.so'
# The fix is a FULL reconfigure, not surgery on individual cache entries: any
# cached /space/lib path that no longer exists means the whole cache is suspect.
if [[ -f CMakeCache.txt ]]; then
  stale_dep=""
  # Only real cached PATH/FILEPATH values, and only their /space/lib entries.
  # Matching raw text would also hit INTERNAL bookkeeping such as
  # FIND_PACKAGE_MESSAGE_DETAILS_Torch, whose value embeds bracketed path lists
  # like "...include][v()]" -- that produced a path that never exists and made
  # this repair fire on every single run.
  while IFS= read -r cached_path; do
    [[ -n "$cached_path" && ! -e "$cached_path" ]] || continue
    stale_dep="$cached_path"
    break
  done < <(sed -n 's/^[A-Za-z_0-9]*:\(FILE\)\?PATH=//p' CMakeCache.txt \
             | tr ';' '\n' | grep -E '^/space/lib/' | sort -u)
  if [[ -n "$stale_dep" ]]; then
    # Remove the WHOLE build directory, not just the top-level cache: each
    # subdirectory keeps its own CMakeFiles/ with object files and link rules,
    # and those survive deleting only the top-level ones.
    echo "Removing stale hex build directory: dependency path no longer exists ($stale_dep)"
    cd /space/interactive-hex-meshing || exit 1
    rm -rf "$hex_build_dir"
    mkdir -p "$hex_build_dir"
    cd "$hex_build_dir" || exit 1
  fi
fi

# Both variants link to the same bin/Release/hex. If a previous build of the
# OTHER variant left a newer binary there, make considers the link target up to
# date against this variant's older objects and silently skips relinking --
# leaving the wrong binary in place. Delete it so the link must happen, and so
# the `test -x` below fails loudly if it does not.
rm -f /space/interactive-hex-meshing/bin/Release/hex \
      /space/interactive-hex-meshing/bin/Release/.hexmesh-variant

if [[ -f CMakeCache.txt ]]; then
  cached_vulkan_include="$(sed -n 's/^Vulkan_INCLUDE_DIR:PATH=//p' CMakeCache.txt | head -n 1)"
  if [[ -n "$cached_vulkan_include" && ! -d "$cached_vulkan_include" ]]; then
    echo "Removing stale hex CMake cache: Vulkan_INCLUDE_DIR=$cached_vulkan_include"
    rm -f CMakeCache.txt
    rm -rf CMakeFiles
  fi
fi

# Built as an array rather than spliced into a string, so an empty or quoted
# value can never silently merge with the next argument.
hex_cmake_args=(-DCMAKE_BUILD_TYPE=Release -DTorch_DIR="$Torch_DIR")
if [[ "$HEX_CPU_ONLY" == 1 ]]; then
  hex_cmake_args+=(-DHEX_ENABLE_CUDA=OFF)
else
  hex_cmake_args+=(-DHEX_ENABLE_CUDA=ON)
fi

cmake ../.. "${hex_cmake_args[@]}" \
  || { echo "ERROR: hex cmake configure failed" >&2; exit 1; }
make -j"$(nproc)" all || { echo "ERROR: hex build failed" >&2; exit 1; }
test -x /space/interactive-hex-meshing/bin/Release/hex \
  || { echo "ERROR: hex produced no binary" >&2; exit 1; }

# Both variants build into the same bin/Release (RUNTIME_OUTPUT_DIRECTORY is
# fixed in hex/CMakeLists.txt), so a CPU build overwrites a CUDA one and vice
# versa. Record which variant produced the binary that is actually there; the
# runner scripts read this and refuse a mismatched launch instead of failing
# obscurely at run time.
if [[ "$HEX_CPU_ONLY" == 1 ]]; then
  hex_built_variant=cpu
else
  hex_built_variant=cuda
fi

# Verify the ARTIFACT before labelling it. Writing the marker straight from
# HEX_CPU_ONLY records what was *requested*, not what was produced -- and when a
# skipped relink left the other variant's binary in place, that marker actively
# lied about it. Ask the binary what it is instead.
hex_help_out="$(LD_LIBRARY_PATH="/space/lib/libtorch/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  /space/interactive-hex-meshing/bin/Release/hex --help 2>&1)" \
  || { echo "ERROR: the freshly built hex could not run --help" >&2; echo "$hex_help_out" >&2; exit 1; }

if [[ "$hex_built_variant" == cuda ]]; then
  grep -q -- "--device cpu|cuda" <<<"$hex_help_out" \
    || { echo "ERROR: a CUDA build was requested but the binary advertises only --device cpu." >&2
         echo "ERROR: bin/Release/hex does not match this build; refusing to label it." >&2; exit 1; }
else
  if grep -q -- "--device cpu|cuda" <<<"$hex_help_out"; then
    echo "ERROR: a CPU-only build was requested but the binary advertises cuda." >&2
    echo "ERROR: bin/Release/hex does not match this build; refusing to label it." >&2
    exit 1
  fi
fi

printf 'variant=%s\n' "$hex_built_variant" \
  > /space/interactive-hex-meshing/bin/Release/.hexmesh-variant
echo "OK: hex binary variant = $hex_built_variant (verified against the binary)"

cd /space
echo "OK: evocube + hex built successfully."
