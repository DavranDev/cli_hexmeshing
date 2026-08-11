#!/usr/bin/env bash
# Interactive development shell inside the build environment, with the repo
# bind-mounted at /space.
#
#   ./run_docker.sh                        # CUDA build environment (default)
#   HEX_IMAGE_VARIANT=cpu ./run_docker.sh  # CPU-only build environment, no GPU
#
# HEX_IMAGE_VARIANT selects the *image/build*; it is unrelated to the
# `hex --device cpu|cuda` flag, which a CUDA-enabled binary also honours.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cli_run/lib/docker_args.sh
source "$ROOT/cli_run/lib/docker_args.sh"
HEX_VARIANT="$(hexmesh_variant)"

# GUI passthrough is only meaningful with a display; harmless to skip otherwise.
if [[ -n "${DISPLAY:-}" ]]; then
  xhost +local:root >/dev/null 2>&1 || true
fi

# GPU + Vulkan ICD options: empty for the CPU variant, so no --gpus,
# no --runtime=nvidia and no NVIDIA ICD bind-mount can reach a CPU launch.
hexmesh_runtime_docker_args

docker_args=(
  run --rm -it
  "${HEXMESH_DOCKER_ARGS[@]}"
  --env="DISPLAY=${DISPLAY:-}"
  --env="LD_LIBRARY_PATH=$(hexmesh_ld_library_path /space)"
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw
  -v "$ROOT/lib:/space/lib"
  -v "$ROOT/evocube:/space/evocube"
  -v "$ROOT/interactive-hex-meshing:/space/interactive-hex-meshing"
  -v "$ROOT/compile.sh:/space/compile.sh"
  -v "$ROOT/patches:/space/patches:ro"
  -v "$ROOT/data:/space/data"
  -v "$ROOT/output:/space/output"
)

if [[ "$HEX_VARIANT" == cpu ]]; then
  IMAGE="${HEX_IMAGE:-hexmesh-cpu:build}"
  # compile.sh reads this to skip the LunarG SDK and pass -DHEX_ENABLE_CUDA=OFF.
  docker_args+=(--env=HEX_CPU_ONLY=1)
else
  IMAGE="${HEX_IMAGE:-docker-hexmesh}"
  docker_args+=(
    --env="VULKAN_SDK_ROOT=/space/lib/vulkan-sdk"
    --env="VULKAN_SDK=/space/lib/vulkan-sdk/x86_64"
    --env="VK_LAYER_PATH=/space/lib/vulkan-sdk/x86_64/share/vulkan/explicit_layer.d"
    --env="VK_ADD_LAYER_PATH=/space/lib/vulkan-sdk/x86_64/share/vulkan/explicit_layer.d"
  )
fi

# This script used to hardcode `sudo docker`. Prefer the unprivileged docker
# when the user is in the docker group, and fall back to sudo when it is needed.
docker_bin=(docker)
if ! docker info >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
  docker_bin=(sudo docker)
fi

exec "${docker_bin[@]}" "${docker_args[@]}" "$IMAGE"
