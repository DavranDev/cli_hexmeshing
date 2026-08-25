#!/usr/bin/env bash
# Unit tests for cli_run/lib/docker_args.sh.
#
# Covers the complete CPU/CUDA x Vulkan/none matrix used by setup.sh,
# cli_run/run.sh, ./hex and run_docker.sh. Host-side only — no Docker needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cli_run/lib/docker_args.sh
source "$ROOT/cli_run/lib/docker_args.sh"
fail=0
expect_eq() { # <desc> <actual> <expected>
  local desc="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "ok:   $desc"
  else
    echo "FAIL: $desc: got '$actual', expected '$expected'"
    fail=1
  fi
}

expect_has() { # <desc> <text> <extended-regex>
  local desc="$1" value="$2" pattern="$3"
  if grep -Eq -- "$pattern" <<<"$value"; then
    echo "ok:   $desc"
  else
    echo "FAIL: $desc: '$value' does not match /$pattern/"
    fail=1
  fi
}

expect_lacks() { # <desc> <text> <extended-regex>
  local desc="$1" value="$2" pattern="$3"
  if grep -Eiq -- "$pattern" <<<"$value"; then
    echo "FAIL: $desc: '$value' unexpectedly matches /$pattern/"
    fail=1
  else
    echo "ok:   $desc"
  fi
}

unset HEX_IMAGE_VARIANT HEX_RENDERER
expect_eq "default variant" "$(hexmesh_variant)" cuda
expect_eq "default renderer" "$(hexmesh_renderer)" vulkan

HEX_IMAGE_VARIANT=cpu HEX_RENDERER=vulkan
expect_eq "CPU+Vulkan build image" "$(hexmesh_image build)" hexmesh-cpu:build
expect_eq "CPU+Vulkan pipeline image" "$(hexmesh_image pipeline)" hexmesh-cpu:latest
expect_eq "CPU+Vulkan CLI image" "$(hexmesh_image cli)" hexmesh-cpu:latest
expect_eq "CPU+Vulkan LD_LIBRARY_PATH" "$(hexmesh_ld_library_path /space)" /space/lib/libtorch/lib
hexmesh_runtime_docker_args
expect_lacks "CPU+Vulkan docker args have no GPU passthrough" "${HEXMESH_DOCKER_ARGS[*]-}" 'nvidia|--gpus|--runtime'

HEX_IMAGE_VARIANT=cpu HEX_RENDERER=none
expect_eq "CPU+none build image" "$(hexmesh_image build)" hexmesh-novk:build
expect_eq "CPU+none pipeline image" "$(hexmesh_image pipeline)" hexmesh-novk:latest
expect_eq "CPU+none CLI image" "$(hexmesh_image cli)" hexmesh-novk:latest
expect_eq "CPU+none LD_LIBRARY_PATH" "$(hexmesh_ld_library_path /space)" /space/lib/libtorch/lib
hexmesh_runtime_docker_args
expect_lacks "CPU+none docker args have no GPU/Vulkan wiring" "${HEXMESH_DOCKER_ARGS[*]-}" 'nvidia|--gpus|--runtime|vulkan|icd'

HEX_IMAGE_VARIANT=cuda HEX_RENDERER=vulkan
expect_eq "CUDA+Vulkan build image" "$(hexmesh_image build)" docker-hexmesh
expect_eq "CUDA+Vulkan pipeline image" "$(hexmesh_image pipeline)" docker-hexmesh
expect_eq "CUDA+Vulkan CLI image" "$(hexmesh_image cli)" hexmesh-cli:latest
expect_has "CUDA+Vulkan LD_LIBRARY_PATH has SDK" "$(hexmesh_ld_library_path /space)" '/space/lib/vulkan-sdk/'
hexmesh_runtime_docker_args
cuda_vk_args="${HEXMESH_DOCKER_ARGS[*]-}"
expect_has "CUDA+Vulkan has GPU passthrough" "$cuda_vk_args" '--runtime=nvidia.*--gpus all'
expect_has "CUDA+Vulkan has graphics capability" "$cuda_vk_args" 'NVIDIA_DRIVER_CAPABILITIES=all'
expect_has "CUDA+Vulkan has NVIDIA ICD" "$cuda_vk_args" 'VK_ICD_FILENAMES=.*/nvidia_icd.json'

HEX_IMAGE_VARIANT=cuda HEX_RENDERER=none
expect_eq "CUDA+none build image" "$(hexmesh_image build)" hexmesh-cuda-novk:build
expect_eq "CUDA+none pipeline image" "$(hexmesh_image pipeline)" hexmesh-cuda-novk:latest
expect_eq "CUDA+none CLI image" "$(hexmesh_image cli)" hexmesh-cuda-novk:latest
expect_eq "CUDA+none LD_LIBRARY_PATH" "$(hexmesh_ld_library_path /space)" /space/lib/libtorch/lib
hexmesh_runtime_docker_args
cuda_none_args="${HEXMESH_DOCKER_ARGS[*]-}"
expect_has "CUDA+none retains GPU compute passthrough" "$cuda_none_args" '--runtime=nvidia.*--gpus all'
expect_has "CUDA+none requests compute only" "$cuda_none_args" 'NVIDIA_DRIVER_CAPABILITIES=compute,utility'
expect_lacks "CUDA+none injects no Vulkan/graphics state" "$cuda_none_args" 'vulkan|icd|NVIDIA_DRIVER_CAPABILITIES=all|/usr/share/vulkan'

if hexmesh_image bogus >/dev/null 2>&1; then
  echo "FAIL: bogus image role accepted"; fail=1
else
  echo "ok:   bogus image role rejected"
fi

HEX_IMAGE_VARIANT=bogus
if hexmesh_variant >/dev/null 2>&1; then echo "FAIL: bogus variant accepted"; fail=1
else echo "ok:   bogus variant rejected"; fi

HEX_IMAGE_VARIANT=cuda HEX_RENDERER=bogus
if hexmesh_renderer >/dev/null 2>&1; then echo "FAIL: bogus renderer accepted"; fail=1
else echo "ok:   bogus renderer rejected"; fi

# The binary guard must catch either half of the selected build identity.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'variant=cuda\nrenderer=none\n' > "$tmp/.hexmesh-variant"
HEX_IMAGE_VARIANT=cuda HEX_RENDERER=none
hexmesh_check_binary_variant "$tmp" >/dev/null 2>&1 \
  && echo "ok:   matching binary identity accepted" \
  || { echo "FAIL: matching binary identity rejected"; fail=1; }

HEX_IMAGE_VARIANT=cpu
if hexmesh_check_binary_variant "$tmp" >/dev/null 2>&1; then
  echo "FAIL: mismatched binary variant accepted"; fail=1
else echo "ok:   mismatched binary variant rejected"; fi

HEX_IMAGE_VARIANT=cuda HEX_RENDERER=vulkan
if hexmesh_check_binary_variant "$tmp" >/dev/null 2>&1; then
  echo "FAIL: mismatched binary renderer accepted"; fail=1
else echo "ok:   mismatched binary renderer rejected"; fi

# Markers from before renderer= existed represent the historical Vulkan build.
printf 'variant=cuda\n' > "$tmp/.hexmesh-variant"
HEX_IMAGE_VARIANT=cuda HEX_RENDERER=vulkan
hexmesh_check_binary_variant "$tmp" >/dev/null 2>&1 \
  && echo "ok:   legacy marker accepted as Vulkan" \
  || { echo "FAIL: legacy marker rejected as Vulkan"; fail=1; }
HEX_RENDERER=none
if hexmesh_check_binary_variant "$tmp" >/dev/null 2>&1; then
  echo "FAIL: legacy marker accepted as renderer-free"; fail=1
else echo "ok:   legacy marker rejected as renderer-free"; fi

[[ $fail -eq 0 ]] && echo "PASS: docker_args helper" || { echo "FAIL"; exit 1; }
