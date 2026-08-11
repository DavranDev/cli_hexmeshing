#!/usr/bin/env bash
# Shared `docker run` argument assembly for the CPU and CUDA image variants.
#
# Sourced by cli_run/run.sh, ./hex and run_docker.sh. Each of those used to
# assemble its own docker command line, so the GPU and Vulkan flags existed in
# three places and could drift independently — and a single stale `--gpus all`
# is enough to make a "CPU-only" launch fail on a machine with no GPU. This file
# is the only place those options are emitted.
#
# TWO CONCEPTS THAT MUST NOT BE CONFLATED:
#
#   HEX_IMAGE_VARIANT=cpu|cuda   which image / build is being launched
#   hex --device cpu|cuda        which device the pipeline math runs on
#
# A CUDA-enabled image can legitimately run its CPU path (that is the long-
# standing `--device cpu` behaviour), so CPU *launch* mode is never inferred
# from `--device cpu`. Only HEX_IMAGE_VARIANT selects it.
#
# shellcheck shell=bash

# Echoes the launch variant, defaulting to cuda so existing GPU workflows are
# unchanged by this file's introduction.
hexmesh_variant() {
  local v="${HEX_IMAGE_VARIANT:-cuda}"
  case "$v" in
    cpu|cuda) printf '%s' "$v" ;;
    *)
      echo "ERROR: HEX_IMAGE_VARIANT must be 'cpu' or 'cuda' (got '$v')." >&2
      return 1
      ;;
  esac
}

# Populates the array HEXMESH_DOCKER_ARGS with the variant-dependent portion of
# a `docker run` command line: GPU passthrough and Vulkan ICD selection.
#
# The CPU branch is deliberately empty. Dockerfile.cpu already sets
# VK_ICD_FILENAMES to lavapipe inside the image, and bind-mounting the host's
# /usr/share/vulkan/icd.d would drag the NVIDIA ICD back in on any machine that
# happens to have a driver installed — reintroducing a GPU dependency into the
# path that exists to avoid one.
hexmesh_runtime_docker_args() {
  local variant
  variant="$(hexmesh_variant)" || return 1

  HEXMESH_DOCKER_ARGS=()
  if [[ "$variant" == cuda ]]; then
    HEXMESH_DOCKER_ARGS+=(
      --runtime=nvidia
      --gpus all
      --env=NVIDIA_DRIVER_CAPABILITIES=all
      --env=VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
      -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro
    )
  fi
}

# Echoes the LD_LIBRARY_PATH the binary needs, rooted at $1 (default /space).
# The CPU variant has no Vulkan SDK — it links the distro loader — so it must
# not reference lib/vulkan-sdk at all.
hexmesh_ld_library_path() {
  local root="${1:-/space}"
  local variant
  variant="$(hexmesh_variant)" || return 1

  if [[ "$variant" == cuda ]]; then
    printf '%s' "$root/lib/libtorch/lib:$root/lib/vulkan-sdk/x86_64/lib/VulkanLoader/lib:$root/lib/vulkan-sdk/x86_64/lib"
  else
    printf '%s' "$root/lib/libtorch/lib"
  fi
}

# Both build variants write the same bin/Release/hex, because
# RUNTIME_OUTPUT_DIRECTORY is fixed in hex/CMakeLists.txt. compile.sh records
# which one produced the binary; refuse an obviously mismatched launch here
# rather than let it fail deep inside the pipeline.
#
# A missing marker means the binary predates this check, so it is a warning
# rather than an error — unlike the LibTorch marker, where guessing wrong
# silently reintroduces the CUDA dependency the CPU build exists to avoid.
hexmesh_check_binary_variant() {
  local bin_dir="$1"
  local marker="$bin_dir/.hexmesh-variant"
  local want got
  want="$(hexmesh_variant)" || return 1

  if [[ ! -f "$marker" ]]; then
    echo "WARNING: $marker is missing; cannot confirm the binary matches HEX_IMAGE_VARIANT=$want." >&2
    return 0
  fi

  got="$(sed -n 's/^variant=//p' "$marker" | head -n 1)"
  [[ -n "$got" ]] || return 0

  if [[ "$got" != "$want" ]]; then
    echo "ERROR: $bin_dir/hex was built for the '$got' variant, but HEX_IMAGE_VARIANT=$want." >&2
    echo "       Both variants share bin/Release, so the last build wins. Rebuild with:" >&2
    if [[ "$want" == cpu ]]; then
      echo "         HEX_CPU_ONLY=1 bash compile.sh   (or ./setup.sh --cpu)" >&2
    else
      echo "         bash compile.sh                  (or ./setup.sh)" >&2
    fi
    return 1
  fi
}
