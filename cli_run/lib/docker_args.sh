#!/usr/bin/env bash
# Shared `docker run` argument assembly for the CPU and CUDA image variants.
#
# Sourced by cli_run/run.sh, ./hex and run_docker.sh. Each of those used to
# assemble its own docker command line, so the GPU and Vulkan flags existed in
# three places and could drift independently — and a single stale `--gpus all`
# is enough to make a "CPU-only" launch fail on a machine with no GPU. This file
# is the only place those options are emitted.
#
# THREE CONCEPTS THAT MUST NOT BE CONFLATED:
#
#   HEX_IMAGE_VARIANT=cpu|cuda   which image / build is being launched
#   HEX_RENDERER=vulkan|none     whether that image contains the renderer
#   hex --device cpu|cuda        which device the pipeline math runs on
#
# A CUDA-enabled image can legitimately run its CPU path (that is the long-
# standing `--device cpu` behaviour), so CPU *launch* mode is never inferred
# from `--device cpu`. Only HEX_IMAGE_VARIANT selects it.
#
# shellcheck shell=bash

# Echoes the renderer the caller wants: "vulkan" (default) or "none".
# Orthogonal to hexmesh_variant, exactly as HEX_ENABLE_VULKAN is orthogonal to
# HEX_ENABLE_CUDA. Together they name one of the four build variants.
hexmesh_renderer() {
  local r="${HEX_RENDERER:-vulkan}"
  case "$r" in
    vulkan|none) printf '%s' "$r" ;;
    *)
      echo "ERROR: HEX_RENDERER must be 'vulkan' or 'none' (got '$r')." >&2
      return 1
      ;;
  esac
}

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

# Echoes the canonical image for one of the three launch roles:
#
#   build     compiler/development environment used by setup.sh/run_docker.sh
#   pipeline  image used by cli_run/run.sh and setup.sh smoke tests
#   cli       self-contained image used by the top-level ./hex wrapper
#
# CUDA+Vulkan deliberately keeps its historical split: pipeline runs use the
# bind-mounted docker-hexmesh environment while ./hex uses hexmesh-cli:latest.
# The other three variants are self-contained, so their pipeline and CLI images
# are the same slim runtime image.
hexmesh_image() {
  local role="${1:-}"
  local variant renderer
  variant="$(hexmesh_variant)" || return 1
  renderer="$(hexmesh_renderer)" || return 1

  case "$role" in
    build)
      case "$variant:$renderer" in
        cpu:vulkan)  printf '%s' 'hexmesh-cpu:build' ;;
        cpu:none)    printf '%s' 'hexmesh-novk:build' ;;
        cuda:vulkan) printf '%s' 'docker-hexmesh' ;;
        cuda:none)   printf '%s' 'hexmesh-cuda-novk:build' ;;
      esac
      ;;
    pipeline)
      case "$variant:$renderer" in
        cpu:vulkan)  printf '%s' 'hexmesh-cpu:latest' ;;
        cpu:none)    printf '%s' 'hexmesh-novk:latest' ;;
        cuda:vulkan) printf '%s' 'docker-hexmesh' ;;
        cuda:none)   printf '%s' 'hexmesh-cuda-novk:latest' ;;
      esac
      ;;
    cli)
      case "$variant:$renderer" in
        cpu:vulkan)  printf '%s' 'hexmesh-cpu:latest' ;;
        cpu:none)    printf '%s' 'hexmesh-novk:latest' ;;
        cuda:vulkan) printf '%s' 'hexmesh-cli:latest' ;;
        cuda:none)   printf '%s' 'hexmesh-cuda-novk:latest' ;;
      esac
      ;;
    *)
      echo "ERROR: hexmesh_image role must be 'build', 'pipeline', or 'cli' (got '$role')." >&2
      return 1
      ;;
  esac
}

# Populates the array HEXMESH_DOCKER_ARGS with the variant-dependent portion of
# a `docker run` command line: GPU passthrough and Vulkan ICD selection.
#
# The CPU branch is deliberately empty. The Vulkan image selects lavapipe
# internally, while the renderer-free image has no loader or ICD at all.
# Bind-mounting the host's ICD directory into either would undermine that
# isolation and can reintroduce a GPU dependency.
hexmesh_runtime_docker_args() {
  local variant
  variant="$(hexmesh_variant)" || return 1

  HEXMESH_DOCKER_ARGS=()
  local renderer
  renderer="$(hexmesh_renderer)" || return 1

  if [[ "$variant" == cuda ]]; then
    HEXMESH_DOCKER_ARGS+=(
      --runtime=nvidia
      --gpus all
    )
    if [[ "$renderer" == vulkan ]]; then
      HEXMESH_DOCKER_ARGS+=(
        --env=NVIDIA_DRIVER_CAPABILITIES=all
        --env=VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
        -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro
      )
    else
      # A renderer-free binary makes no Vulkan call, so it needs CUDA compute
      # and nothing graphical. Asking for the graphics capability anyway would
      # mount an ICD this build cannot and must not use.
      HEXMESH_DOCKER_ARGS+=(--env=NVIDIA_DRIVER_CAPABILITIES=compute,utility)
    fi
  fi
}

# Echoes the LD_LIBRARY_PATH the binary needs, rooted at $1 (default /space).
# The CPU variant has no Vulkan SDK — it links the distro loader — so it must
# not reference lib/vulkan-sdk at all.
hexmesh_ld_library_path() {
  local root="${1:-/space}"
  local variant
  variant="$(hexmesh_variant)" || return 1

  local renderer
  renderer="$(hexmesh_renderer)" || return 1

  # A renderer-free build links no loader at all, so the SDK's lib dirs are dead
  # weight -- and pointing at them on a host without the SDK is a hard error.
  if [[ "$variant" == cuda && "$renderer" == vulkan ]]; then
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
  local want got want_r got_r
  want="$(hexmesh_variant)" || return 1
  want_r="$(hexmesh_renderer)" || return 1

  if [[ ! -f "$marker" ]]; then
    echo "WARNING: $marker is missing; cannot confirm the binary matches HEX_IMAGE_VARIANT=$want." >&2
    return 0
  fi

  # A marker written before the renderer option existed has no renderer= line.
  # Treat that as "vulkan", which is what those builds were.
  got_r="$(sed -n 's/^renderer=//p' "$marker" | head -n 1)"
  got_r="${got_r:-vulkan}"
  if [[ "$got_r" != "$want_r" ]]; then
    echo "ERROR: $bin_dir/hex was built with renderer '$got_r', but HEX_RENDERER=$want_r." >&2
    echo "       All variants share bin/Release, so the last build wins. Rebuild with:" >&2
    if [[ "$want_r" == none ]]; then
      echo "         HEX_NO_VULKAN=1 bash compile.sh   (or ./setup.sh --no-vulkan)" >&2
    else
      echo "         bash compile.sh                   (or ./setup.sh)" >&2
    fi
    return 1
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
