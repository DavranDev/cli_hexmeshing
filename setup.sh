#!/usr/bin/env bash
# One-command NVIDIA setup: install host-side libraries, build the Docker image,
# compile the project inside Docker, and run a headless NVIDIA smoke test.
#
# This script deliberately downloads the current official LunarG SDK instead of
# depending on a checked-in Vulkan tarball. The extracted SDK is normalized to
# lib/vulkan-sdk so the rest of the project never depends on LunarG's changing
# top-level version directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

LIBTORCH_URL="${LIBTORCH_URL:-https://download.pytorch.org/libtorch/cu124/libtorch-cxx11-abi-shared-with-deps-2.6.0%2Bcu124.zip}"
VULKAN_SDK_URL="${VULKAN_SDK_URL:-https://sdk.lunarg.com/sdk/download/latest/linux/vulkan-sdk.tar.xz}"
RUN_SMOKE="${RUN_SMOKE:-1}"
BUILD_SELF_CONTAINED="${BUILD_SELF_CONTAINED:-0}"
CLEAN_CONTAINERS=0

usage() {
  cat <<'EOF'
Usage: ./setup.sh [--clean-containers] [--no-smoke] [--self-contained]

NVIDIA one-command setup:
  1. downloads LibTorch + current LunarG Vulkan SDK if missing
  2. builds docker-hexmesh
  3. compiles evocube + hex inside Docker
  4. runs no-crash checks
  5. runs the headless NVIDIA smoke test unless --no-smoke is passed

Options:
  --clean-containers  Remove all existing Docker containers before building.
  --no-smoke          Skip the final GPU smoke test.
  --self-contained    Also build hexmesh-cli:latest from Dockerfile.build.
  -h, --help          Show this help.

Environment overrides:
  LIBTORCH_URL=...         Override the LibTorch download URL.
  VULKAN_SDK_URL=...       Override the LunarG Vulkan SDK download URL.
  RUN_SMOKE=0             Same as --no-smoke.
  BUILD_SELF_CONTAINED=1  Same as --self-contained.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean-containers) CLEAN_CONTAINERS=1; shift ;;
    --no-smoke) RUN_SMOKE=0; shift ;;
    --self-contained) BUILD_SELF_CONTAINED=1; shift ;;
    -h|--help) usage; return 0 2>/dev/null || exit 0 ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

sudo_cmd=()
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  sudo_cmd=(sudo)
fi

docker_cmd=(docker)

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "==> Docker not found; running install_docker.sh"
    . "$ROOT/install_docker.sh"
  fi

  if docker info >/dev/null 2>&1; then
    docker_cmd=(docker)
  elif "${sudo_cmd[@]}" docker info >/dev/null 2>&1; then
    docker_cmd=("${sudo_cmd[@]}" docker)
  else
    echo "ERROR: Docker is installed but not usable by this user or sudo." >&2
    exit 1
  fi
}

clean_containers() {
  [[ "$CLEAN_CONTAINERS" == "1" ]] || return 0
  echo "==> Removing all Docker containers"
  mapfile -t containers < <("${docker_cmd[@]}" ps -aq)
  if [[ ${#containers[@]} -eq 0 ]]; then
    echo "==> No Docker containers to remove"
    return 0
  fi
  "${docker_cmd[@]}" rm -f "${containers[@]}"
}

install_setup_tools() {
  local missing=()
  for tool in wget unzip tar xz; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    echo "==> Setup tools already installed"
    return 0
  fi

  echo "==> Installing setup tools: ${missing[*]}"
  "${sudo_cmd[@]}" apt-get update
  "${sudo_cmd[@]}" apt-get install -y ca-certificates wget unzip xz-utils tar
}

install_host_vulkan_tools() {
  if command -v vulkaninfo >/dev/null 2>&1; then
    echo "==> Host Vulkan tools already installed"
    return 0
  fi

  echo "==> Installing host Vulkan tools for diagnostics"
  "${sudo_cmd[@]}" apt-get update
  "${sudo_cmd[@]}" apt-get install -y vulkan-tools
}

mkdir -p lib output

install_libtorch() {
  if [[ -d lib/libtorch ]]; then
    echo "==> LibTorch already installed at lib/libtorch"
    return
  fi

  local archive="libtorch-cxx11-abi-shared-with-deps-2.6.0+cu124.zip"
  local tmp_archive=""
  if [[ ! -f "$archive" ]]; then
    tmp_archive="$(mktemp --suffix=.zip)"
    echo "==> Downloading LibTorch"
    wget -O "$tmp_archive" "$LIBTORCH_URL"
    archive="$tmp_archive"
  else
    echo "==> Using existing $archive"
  fi

  rm -rf lib/libtorch
  unzip -q "$archive" -d lib

  if [[ -n "$tmp_archive" ]]; then
    rm -f "$tmp_archive"
  fi

  test -d lib/libtorch \
    || { echo "ERROR: LibTorch extraction did not create lib/libtorch" >&2; exit 1; }
}

install_vulkan_sdk() {
  if [[ -f lib/vulkan-sdk/setup-env.sh && -d lib/vulkan-sdk/x86_64 ]]; then
    echo "==> Vulkan SDK already installed at lib/vulkan-sdk"
    return
  fi

  local archive extract_dir top_dir
  archive="$(mktemp --suffix=.tar.xz)"
  extract_dir="$(mktemp -d)"

  echo "==> Downloading Vulkan SDK from LunarG"
  wget -O "$archive" "$VULKAN_SDK_URL"

  echo "==> Extracting Vulkan SDK"
  tar -xf "$archive" -C "$extract_dir"
  top_dir="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -z "$top_dir" ]]; then
    echo "ERROR: Vulkan SDK archive did not contain a top-level directory" >&2
    exit 1
  fi

  rm -rf lib/vulkan-sdk
  mv "$top_dir" lib/vulkan-sdk
  rm -f "$archive"
  rm -rf "$extract_dir"

  test -f lib/vulkan-sdk/setup-env.sh \
    || { echo "ERROR: Vulkan SDK extraction did not create setup-env.sh" >&2; exit 1; }
  test -f lib/vulkan-sdk/x86_64/lib/libVkLayer_khronos_validation.so \
    || { echo "ERROR: Vulkan validation layer library is missing" >&2; exit 1; }
  find lib/vulkan-sdk/x86_64/share/vulkan/explicit_layer.d \
      -name '*khronos_validation*.json' -print -quit | grep -q . \
    || { echo "ERROR: Vulkan validation layer manifest is missing" >&2; exit 1; }

}

build_env_image() {
  echo "==> Building docker-hexmesh environment image"
  "${docker_cmd[@]}" build -t docker-hexmesh .
}

compile_in_docker() {
  echo "==> Compiling evocube + hex inside docker-hexmesh"
  "${docker_cmd[@]}" run --rm \
    -v "$ROOT/lib:/space/lib" \
    -v "$ROOT/evocube:/space/evocube" \
    -v "$ROOT/interactive-hex-meshing:/space/interactive-hex-meshing" \
    -v "$ROOT/compile.sh:/space/compile.sh:ro" \
    -v "$ROOT/patches:/space/patches:ro" \
    docker-hexmesh \
    bash /space/compile.sh
}

build_self_contained_image() {
  [[ "$BUILD_SELF_CONTAINED" == "1" ]] || return 0
  echo "==> Building self-contained hexmesh-cli:latest"
  "${docker_cmd[@]}" build -f Dockerfile.build --target build -t hexmesh-cli:latest .
}

verify_nvidia_runtime() {
  "${docker_cmd[@]}" run --rm --runtime=nvidia --gpus all \
    nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/dev/null
}

run_checks() {
  echo "==> Running no-crash source/binary checks"
  "${docker_cmd[@]}" run --rm \
    -v "$ROOT:/space" \
    -w /space \
    docker-hexmesh \
    bash -lc 'export LD_LIBRARY_PATH="/space/lib/libtorch/lib:/space/lib/vulkan-sdk/x86_64/lib:/space/lib/vulkan-sdk/x86_64/lib/VulkanLoader/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"; ./scripts/verify_no_crash_fixes.sh'
}

run_nvidia_smoke() {
  [[ "$RUN_SMOKE" == "1" ]] || { echo "==> Skipping smoke test"; return 0; }

  echo "==> Checking NVIDIA Docker runtime"
  verify_nvidia_runtime \
    || { echo "ERROR: NVIDIA Docker runtime is not working; cannot run GPU smoke test." >&2; exit 1; }

  echo "==> Running headless NVIDIA smoke test"
  "${docker_cmd[@]}" run --rm \
    --runtime=nvidia \
    --gpus all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -e HEX_LOCAL=1 \
    -e VULKAN_SDK_ROOT=/space/lib/vulkan-sdk \
    -e VULKAN_SDK=/space/lib/vulkan-sdk/x86_64 \
    -e VK_LAYER_PATH=/space/lib/vulkan-sdk/x86_64/share/vulkan/explicit_layer.d \
    -e VK_ADD_LAYER_PATH=/space/lib/vulkan-sdk/x86_64/share/vulkan/explicit_layer.d \
    -e VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json \
    -e LD_LIBRARY_PATH=/space/lib/libtorch/lib:/space/lib/vulkan-sdk/x86_64/lib/VulkanLoader/lib:/space/lib/vulkan-sdk/x86_64/lib \
    -v /usr/share/vulkan/icd.d:/usr/share/vulkan/icd.d:ro \
    -v "$ROOT/lib:/space/lib:ro" \
    -v "$ROOT/interactive-hex-meshing:/space/interactive-hex-meshing" \
    -v "$ROOT/evocube:/space/evocube:ro" \
    -v "$ROOT/cli_run:/space/cli_run:ro" \
    -v "$ROOT/output:/space/output" \
    -w /space \
    docker-hexmesh \
    ./cli_run/smoke_test.sh
}

install_setup_tools
ensure_docker
clean_containers
install_libtorch
install_vulkan_sdk
build_env_image
compile_in_docker
build_self_contained_image
run_checks
run_nvidia_smoke
install_host_vulkan_tools

echo "OK: NVIDIA setup, compile, and verification complete."
