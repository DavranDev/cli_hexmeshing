#!/usr/bin/env bash
# One-command setup for the CPU/CUDA x Vulkan/none build matrix: install the
# selected host-side libraries, build its Docker images, compile, and smoke test.
#
# This script deliberately downloads the current official LunarG SDK instead of
# depending on a checked-in Vulkan tarball. The extracted SDK is normalized to
# lib/vulkan-sdk so the rest of the project never depends on LunarG's changing
# top-level version directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
# shellcheck source=cli_run/lib/docker_args.sh
source "$ROOT/cli_run/lib/docker_args.sh"

VULKAN_SDK_URL="${VULKAN_SDK_URL:-https://sdk.lunarg.com/sdk/download/latest/linux/vulkan-sdk.tar.xz}"
RUN_SMOKE="${RUN_SMOKE:-1}"
BUILD_SELF_CONTAINED="${BUILD_SELF_CONTAINED:-0}"
NVIDIA_FIX="${NVIDIA_FIX:-1}"
CLEAN_CONTAINERS=0

# CPU-only *build*: no CUDA toolkit, no CUDA LibTorch, no NVIDIA Container
# Toolkit, no LunarG Vulkan SDK. Distinct from `hex --device cpu`, which is a
# runtime device choice a CUDA-enabled build also supports.
HEX_CPU_ONLY="${HEX_CPU_ONLY:-0}"
# Renderer-free build (-DHEX_ENABLE_VULKAN=OFF). Composable with --cpu; the
# two flags are the four-variant matrix.
HEX_NO_VULKAN="${HEX_NO_VULKAN:-0}"

# LibTorch identity. These are the same constants Dockerfile.cpu takes as build
# arguments; the two consumers must not drift, so both record them in
# lib/libtorch/.hexmesh-variant.
LIBTORCH_VERSION="${LIBTORCH_VERSION:-2.6.0}"
LIBTORCH_ABI="${LIBTORCH_ABI:-cxx11}"

usage() {
  cat <<'EOF'
Usage: ./setup.sh [--cpu] [--no-vulkan] [--clean-containers] [--no-smoke]
                  [--self-contained]

One-command setup. Four variants -- --cpu and --no-vulkan are orthogonal:

  ./setup.sh                    CUDA + Vulkan   (GUI; the default, unchanged)
  ./setup.sh --cpu              CPU  + Vulkan
  ./setup.sh --no-vulkan        CUDA, headless-only, no Vulkan packages
  ./setup.sh --cpu --no-vulkan  CPU,  headless-only, no Vulkan packages


  ./setup.sh          CUDA + Vulkan renderer (needs an NVIDIA GPU + driver)
    1. downloads the cu124 LibTorch + current LunarG Vulkan SDK if missing
    2. builds docker-hexmesh
    3. compiles evocube + hex inside Docker
    4. runs no-crash checks
    5. runs the headless NVIDIA smoke test unless --no-smoke is passed

  ./setup.sh --cpu    CPU-only build + Vulkan renderer (no GPU at all)
    1. activates the +cpu LibTorch (downloading it only if not already parked);
       NO Vulkan SDK (uses the distro loader) and NO NVIDIA Container Toolkit
    2. builds hexmesh-cpu:build and hexmesh-cpu:latest from Dockerfile.cpu
    3. compiles evocube + hex with -DHEX_ENABLE_CUDA=OFF
    4. runs no-crash checks
    5. runs the headless CPU smoke test (SMOKE_DEVICE=cpu, no --gpus)

  Adding --no-vulkan to either of the above runs the same steps minus every
  Vulkan one: no SDK download, no host vulkan-tools, -DHEX_ENABLE_VULKAN=OFF,
  and a binary that links no Vulkan/imgui/glfw. Its build directory is
  build/<cuda|cpu>-novk-release and the binary is labelled renderer=none.

Options:
  --cpu               CPU-only build: link no CUDA at all. amd64 only.
  --no-vulkan         Renderer-free build: link no Vulkan, imgui or glfw at
                      all, and install no Vulkan SDK, loader, driver or
                      vulkan-tools. The binary is headless-only and requires
                      --script. Composable with --cpu.
  --clean-containers  Remove all existing Docker containers before building.
  --no-smoke          Skip the final smoke test.
  --no-nvidia-fix     Do not auto-install/configure the NVIDIA Container
                      Toolkit; only check it and error out if it is missing.
                      Ignored with --cpu, which never touches the toolkit.
  --self-contained    Also build hexmesh-cli:latest from Dockerfile.build.
                      Ignored with --cpu or --no-vulkan because those selected
                      images are already self-contained.
  -h, --help          Show this help.

LibTorch variants:
  One variant is active at lib/libtorch; the other is parked beside it as
  lib/libtorch-<variant> and reused on the way back, so switching between the
  CUDA and CPU builds is a rename rather than a multi-GB re-download. A parked
  tree is re-validated (build-version and the CUDA .so set must agree) before it
  is activated, and an unidentifiable tree is parked under a timestamped name
  rather than deleted. Only the active tree is ever on the include/link path.

  Switching variants invalidates an existing build directory, because CMake
  caches absolute paths to the LibTorch .so files. compile.sh detects that and
  reconfigures from scratch.

Environment overrides:
  LIBTORCH_URL=...         Override the LibTorch download URL. Must match the
                           selected variant; setup.sh validates the archive.
  VULKAN_SDK_URL=...       Override the LunarG Vulkan SDK download URL.
  HEX_CPU_ONLY=1          Same as --cpu.
  HEX_NO_VULKAN=1         Same as --no-vulkan.
  RUN_SMOKE=0             Same as --no-smoke.
  NVIDIA_FIX=0            Same as --no-nvidia-fix.
  BUILD_SELF_CONTAINED=1  Same as --self-contained.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpu) HEX_CPU_ONLY=1; shift ;;
    --no-vulkan) HEX_NO_VULKAN=1; shift ;;
    --clean-containers) CLEAN_CONTAINERS=1; shift ;;
    --no-smoke) RUN_SMOKE=0; shift ;;
    --no-nvidia-fix) NVIDIA_FIX=0; shift ;;
    --self-contained) BUILD_SELF_CONTAINED=1; shift ;;
    -h|--help) usage; return 0 2>/dev/null || exit 0 ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Translate setup's build flags to the same selectors used by every launcher.
# Keep these assignments local to this setup process; built images also record
# the pair in their ENV and the compiled binary marker records it independently.
if [[ "$HEX_CPU_ONLY" == 1 ]]; then
  HEX_IMAGE_VARIANT=cpu
else
  HEX_IMAGE_VARIANT=cuda
fi
if [[ "$HEX_NO_VULKAN" == 1 ]]; then
  HEX_RENDERER=none
else
  HEX_RENDERER=vulkan
fi

# Resolved after parsing, so --cpu can select the archive.
if [[ "$HEX_CPU_ONLY" == 1 ]]; then
  LIBTORCH_VARIANT="cpu"
  LIBTORCH_URL="${LIBTORCH_URL:-https://download.pytorch.org/libtorch/cpu/libtorch-cxx11-abi-shared-with-deps-2.6.0%2Bcpu.zip}"
  echo "==> Build variant: CPU-only (no CUDA will be installed or linked)"
else
  LIBTORCH_VARIANT="cu124"
  LIBTORCH_URL="${LIBTORCH_URL:-https://download.pytorch.org/libtorch/cu124/libtorch-cxx11-abi-shared-with-deps-2.6.0%2Bcu124.zip}"
  echo "==> Build variant: CUDA (cu124)"
fi

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
  # A renderer-free install has nothing to diagnose: no binary in this variant
  # can talk to a Vulkan driver.
  if [[ "$HEX_NO_VULKAN" == 1 ]]; then
    echo "==> Skipping host Vulkan tools (--no-vulkan build)"
    return 0
  fi

  # Host-side NVIDIA/Vulkan diagnostics are not part of the CPU-only path; the
  # CPU images carry their own vulkan-tools for the checks that matter there.
  if [[ "$HEX_CPU_ONLY" == 1 ]]; then
    echo "==> Skipping host Vulkan tools (CPU-only build)"
    return 0
  fi

  if command -v vulkaninfo >/dev/null 2>&1; then
    echo "==> Host Vulkan tools already installed"
    return 0
  fi

  echo "==> Installing host Vulkan tools for diagnostics"
  "${sudo_cmd[@]}" apt-get update
  "${sudo_cmd[@]}" apt-get install -y vulkan-tools
}

mkdir -p lib output

LIBTORCH_MARKER="lib/libtorch/.hexmesh-variant"

# Variants are kept side by side: the active one is lib/libtorch, any other is
# parked at lib/libtorch-<variant>. Switching between CUDA and CPU is then a
# rename instead of a multi-GB re-download, which matters on a machine that
# builds both. Only the *active* tree is ever on the include/link path, so the
# CPU-only guarantee is unaffected by a parked cu124 tree sitting next to it.
libtorch_park_dir() { printf 'lib/libtorch-%s' "$1"; }

# Echoes the variant a tree claims, or nothing. Prefers the marker; otherwise
# reads LibTorch's own build-version. Reading the tree's stated identity is not
# the same as guessing at it -- validate_libtorch_tree then has to agree.
libtorch_variant_of() {
  local dir="$1" bv
  if [[ -f "$dir/.hexmesh-variant" ]]; then
    sed -n 's/^variant=//p' "$dir/.hexmesh-variant" | head -n 1
    return 0
  fi
  [[ -f "$dir/build-version" ]] || return 0
  bv="$(tr -d '[:space:]' < "$dir/build-version")"
  [[ "$bv" == *+* ]] || return 0
  printf '%s' "${bv##*+}"
}

# True only if <dir> really is a usable LibTorch of <variant>. Used for both a
# freshly downloaded tree and a parked one, so a parked tree can never be
# activated on the strength of its directory name alone.
validate_libtorch_tree() {
  local dir="$1" variant="$2" why=""
  if   [[ ! -f "$dir/build-version" ]]; then why="no build-version"
  elif ! grep -qx "${LIBTORCH_VERSION}+${variant}" "$dir/build-version"; then
    why="build-version is '$(tr -d '[:space:]' < "$dir/build-version")', expected '${LIBTORCH_VERSION}+${variant}'"
  elif [[ ! -f "$dir/lib/libtorch_cpu.so" ]]; then why="missing lib/libtorch_cpu.so"
  elif [[ "$variant" == "cpu" ]] && ls "$dir/lib" 2>/dev/null | grep -Eiq 'cuda|cudnn|nvrtc|nccl'; then
    why="a +cpu tree must not ship CUDA libraries"
  elif [[ "$variant" != "cpu" && ! -f "$dir/lib/libtorch_cuda.so" ]]; then
    why="a CUDA tree must ship libtorch_cuda.so"
  fi
  if [[ -n "$why" ]]; then
    LIBTORCH_INVALID_REASON="$why"
    return 1
  fi
}

write_libtorch_marker() {
  printf 'variant=%s\nversion=%s\nabi=%s\n' \
    "$1" "$LIBTORCH_VERSION" "$LIBTORCH_ABI" > "$2/.hexmesh-variant"
}

# Moves the currently active tree out of the way instead of deleting it, so
# switching back later costs a rename. An unidentifiable tree is parked under a
# timestamp rather than removed -- this script should never be the reason a
# multi-GB download is lost.
park_active_libtorch() {
  local have="$1" park
  if [[ -n "$have" ]]; then
    park="$(libtorch_park_dir "$have")"
  else
    park="lib/libtorch-unidentified-$(date +%Y%m%d%H%M%S)"
  fi
  if [[ -e "$park" && -n "$have" ]]; then
    # The active tree is authoritative for its variant; drop the stale copy.
    echo "==> Replacing the previously parked $park"
    rm -rf "$park"
  fi
  mv lib/libtorch "$park"
  echo "==> Parked the ${have:-unidentified} LibTorch at $park (kept, not deleted)"
}

# The "already installed, skip" check cannot just test for the directory: a
# cu124 tree would happily satisfy a --cpu run and undermine the entire
# guarantee. The marker records what is actually installed.
install_libtorch() {
  local want="$LIBTORCH_VARIANT"
  local have="" park tmp_dir
  LIBTORCH_INVALID_REASON=""

  if [[ -d lib/libtorch ]]; then
    have="$(libtorch_variant_of lib/libtorch)"
    if [[ -n "$have" ]] && validate_libtorch_tree lib/libtorch "$have"; then
      if [[ "$have" == "$want" ]]; then
        write_libtorch_marker "$have" lib/libtorch
        echo "==> LibTorch already active: variant=$have version=$LIBTORCH_VERSION abi=$LIBTORCH_ABI"
        return
      fi
      echo "==> lib/libtorch holds the '$have' variant, but '$want' is required."
    else
      echo "==> lib/libtorch could not be identified (${LIBTORCH_INVALID_REASON:-no version info}); it will be parked, not trusted."
      have=""
    fi
    park_active_libtorch "$have"
  fi

  # Reuse a previously parked tree of the wanted variant before downloading.
  park="$(libtorch_park_dir "$want")"
  if [[ -d "$park" ]]; then
    if validate_libtorch_tree "$park" "$want"; then
      mv "$park" lib/libtorch
      write_libtorch_marker "$want" lib/libtorch
      echo "==> Activated the parked $want LibTorch (no download needed)"
      echo "==> LibTorch active: variant=$want version=$LIBTORCH_VERSION abi=$LIBTORCH_ABI"
      return
    fi
    echo "==> Ignoring $park: $LIBTORCH_INVALID_REASON"
  fi

  # Download and validate into a temp dir; nothing is moved into place until a
  # verified tree exists.
  tmp_dir="$(mktemp -d)"
  echo "==> Downloading LibTorch (variant=$want version=$LIBTORCH_VERSION abi=$LIBTORCH_ABI)"
  wget -O "$tmp_dir/libtorch.zip" "$LIBTORCH_URL"
  unzip -q "$tmp_dir/libtorch.zip" -d "$tmp_dir"

  if [[ ! -d "$tmp_dir/libtorch" ]]; then
    echo "ERROR: LibTorch archive did not contain a libtorch/ directory" >&2
    echo "       URL: $LIBTORCH_URL" >&2
    rm -rf "$tmp_dir"; exit 1
  fi
  if ! validate_libtorch_tree "$tmp_dir/libtorch" "$want"; then
    echo "ERROR: downloaded LibTorch is not a valid '$want' tree: $LIBTORCH_INVALID_REASON" >&2
    echo "       URL: $LIBTORCH_URL" >&2
    rm -rf "$tmp_dir"; exit 1
  fi

  mv "$tmp_dir/libtorch" lib/libtorch
  rm -rf "$tmp_dir"
  write_libtorch_marker "$want" lib/libtorch
  echo "==> LibTorch installed: variant=$want version=$LIBTORCH_VERSION abi=$LIBTORCH_ABI"
}

# True only if <dir> is a complete, usable SDK: env script, loader tree, and
# the validation layer (library + manifest). Applied to a pre-existing
# lib/vulkan-sdk and to a fresh extraction alike, so a half-extracted or
# corrupted tree can never satisfy the "already installed" check — it gets
# re-downloaded instead of failing later inside the compile.
validate_vulkan_sdk_tree() {
  local dir="$1"
  VULKAN_SDK_INVALID_REASON=""
  if   [[ ! -f "$dir/setup-env.sh" ]]; then VULKAN_SDK_INVALID_REASON="missing setup-env.sh"
  elif [[ ! -d "$dir/x86_64" ]]; then VULKAN_SDK_INVALID_REASON="missing the x86_64/ tree"
  elif [[ ! -f "$dir/x86_64/lib/libVkLayer_khronos_validation.so" ]]; then
    VULKAN_SDK_INVALID_REASON="missing the validation layer library"
  elif ! find "$dir/x86_64/share/vulkan/explicit_layer.d" \
         -name '*khronos_validation*.json' -print -quit 2>/dev/null | grep -q .; then
    VULKAN_SDK_INVALID_REASON="missing the validation layer manifest"
  fi
  [[ -z "$VULKAN_SDK_INVALID_REASON" ]]
}

install_vulkan_sdk() {
  # A CPU-only install takes Vulkan from the distro (libvulkan-dev +
  # mesa-vulkan-drivers, inside Dockerfile.cpu). The ~1.5 GB LunarG SDK only
  # supplied the loader, headers and validation layers, and
  # vkoo/src/core/Instance.cpp already falls back cleanly with no validation
  # layer present.
  if [[ "$HEX_NO_VULKAN" == 1 ]]; then
    echo "==> Skipping the LunarG Vulkan SDK (--no-vulkan build links no Vulkan)"
    unset VULKAN_SDK VULKAN_SDK_ROOT VK_LAYER_PATH VK_ADD_LAYER_PATH VK_ICD_FILENAMES
    return
  fi

  if [[ "$HEX_CPU_ONLY" == 1 ]]; then
    echo "==> Skipping the LunarG Vulkan SDK (CPU-only build uses the distro loader)"
    return
  fi

  if [[ -d lib/vulkan-sdk ]]; then
    if validate_vulkan_sdk_tree lib/vulkan-sdk; then
      echo "==> Vulkan SDK already installed at lib/vulkan-sdk"
      return
    fi
    echo "==> lib/vulkan-sdk is incomplete ($VULKAN_SDK_INVALID_REASON); re-downloading"
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

  validate_vulkan_sdk_tree lib/vulkan-sdk \
    || { echo "ERROR: extracted Vulkan SDK is incomplete: $VULKAN_SDK_INVALID_REASON" >&2; exit 1; }
}

# The image the compile + checks run in, per variant.
build_image_name() {
  hexmesh_image build
}

build_env_image() {
  case "$HEX_IMAGE_VARIANT:$HEX_RENDERER" in
    cpu:vulkan)
      echo "==> Building hexmesh-cpu:build (CPU + Vulkan build environment)"
      "${docker_cmd[@]}" build -f Dockerfile.cpu --target build -t hexmesh-cpu:build .
      echo "==> Building hexmesh-cpu:latest (slim CPU + Vulkan runtime)"
      "${docker_cmd[@]}" build -f Dockerfile.cpu --target runtime -t hexmesh-cpu:latest .
      ;;
    cpu:none)
      echo "==> Building hexmesh-novk:build (CPU, renderer-free build environment)"
      "${docker_cmd[@]}" build -f Dockerfile.novk --target build -t hexmesh-novk:build .
      echo "==> Building hexmesh-novk:latest (slim CPU, renderer-free runtime)"
      "${docker_cmd[@]}" build -f Dockerfile.novk --target runtime -t hexmesh-novk:latest .
      ;;
    cuda:vulkan)
      echo "==> Building docker-hexmesh environment image"
      "${docker_cmd[@]}" build -t docker-hexmesh .
      ;;
    cuda:none)
      echo "==> Building hexmesh-cuda-novk:build (CUDA, renderer-free build environment)"
      "${docker_cmd[@]}" build -f Dockerfile.cuda-novk --target build -t hexmesh-cuda-novk:build .
      echo "==> Building hexmesh-cuda-novk:latest (slim CUDA, renderer-free runtime)"
      "${docker_cmd[@]}" build -f Dockerfile.cuda-novk --target runtime -t hexmesh-cuda-novk:latest .
      ;;
  esac
}

compile_in_docker() {
  local image env_args=()
  image="$(build_image_name)"
  if [[ "$HEX_CPU_ONLY" == 1 ]]; then
    # compile.sh reads this to skip the LunarG SDK and pass -DHEX_ENABLE_CUDA=OFF.
    env_args=(-e HEX_CPU_ONLY=1)
  fi
  if [[ "$HEX_NO_VULKAN" == 1 ]]; then
    # ... and this to pass -DHEX_ENABLE_VULKAN=OFF and skip the SDK entirely.
    env_args+=(-e HEX_NO_VULKAN=1)
  fi

  echo "==> Compiling evocube + hex inside $image"
  "${docker_cmd[@]}" run --rm "${env_args[@]}" \
    -v "$ROOT/lib:/space/lib" \
    -v "$ROOT/evocube:/space/evocube" \
    -v "$ROOT/interactive-hex-meshing:/space/interactive-hex-meshing" \
    -v "$ROOT/compile.sh:/space/compile.sh:ro" \
    -v "$ROOT/patches:/space/patches:ro" \
    "$image" \
    bash /space/compile.sh
}

build_self_contained_image() {
  # Every CPU image and both renderer-free images are already self-contained.
  # Only the historical CUDA+Vulkan environment has an optional separate
  # self-contained image.
  if [[ "$HEX_CPU_ONLY" == 1 || "$HEX_NO_VULKAN" == 1 ]]; then
    [[ "$BUILD_SELF_CONTAINED" == "1" ]] \
      && echo "==> Ignoring --self-contained: $(hexmesh_image pipeline) is already self-contained"
    return 0
  fi
  [[ "$BUILD_SELF_CONTAINED" == "1" ]] || return 0
  echo "==> Building self-contained hexmesh-cli:latest"
  "${docker_cmd[@]}" build -f Dockerfile.build --target build -t hexmesh-cli:latest .
}

verify_nvidia_runtime() {
  "${docker_cmd[@]}" run --rm --runtime=nvidia --gpus all \
    nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/dev/null
}

nvidia_manual_steps() {
  cat >&2 <<'EOF'
Fix manually with:
  sudo apt-get install -y nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
  sudo docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
(or run ./install_docker.sh, which installs Docker + the toolkit from scratch)
EOF
}

# Install and configure the NVIDIA Container Toolkit so Docker can pass the GPU
# into containers. Mirrors the toolkit steps in install_docker.sh, but is only
# invoked when the runtime check has already failed, so it never touches a
# machine where the runtime already works.
install_nvidia_container_toolkit() {
  # The repo-add below needs curl + gnupg; install_setup_tools does not cover them.
  if ! command -v curl >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1; then
    echo "==> Installing curl + gnupg (needed to add the NVIDIA apt repo)"
    "${sudo_cmd[@]}" apt-get update
    "${sudo_cmd[@]}" apt-get install -y ca-certificates curl gnupg
  fi

  echo "==> Adding NVIDIA Container Toolkit apt repository"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | "${sudo_cmd[@]}" gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | "${sudo_cmd[@]}" tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

  echo "==> Installing nvidia-container-toolkit"
  "${sudo_cmd[@]}" apt-get update
  "${sudo_cmd[@]}" apt-get install -y nvidia-container-toolkit

  echo "==> Configuring the Docker runtime and restarting Docker"
  "${sudo_cmd[@]}" nvidia-ctk runtime configure --runtime=docker
  "${sudo_cmd[@]}" systemctl restart docker
}

# Make sure Docker can actually run GPU containers. If it already can, do
# nothing. Otherwise, unless --no-nvidia-fix was passed, install + configure the
# NVIDIA Container Toolkit and re-check.
ensure_nvidia_runtime() {
  echo "==> Checking NVIDIA Docker runtime"
  if verify_nvidia_runtime; then
    return 0
  fi

  if [[ "$NVIDIA_FIX" != "1" ]]; then
    echo "ERROR: NVIDIA Docker runtime is not working, and --no-nvidia-fix was set." >&2
    nvidia_manual_steps
    exit 1
  fi

  # The toolkit can only bridge a driver that exists; a missing host driver is
  # a separate problem we cannot fix here (it needs a driver install + reboot).
  if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi -L >/dev/null 2>&1; then
    echo "ERROR: Host NVIDIA driver not detected (nvidia-smi failed)." >&2
    echo "       Install the GPU driver first; the container toolkit cannot bridge a driver that isn't there." >&2
    exit 1
  fi

  echo "==> NVIDIA Docker runtime not working; installing/configuring the NVIDIA Container Toolkit"
  install_nvidia_container_toolkit

  if verify_nvidia_runtime; then
    echo "==> NVIDIA Docker runtime now working"
    return 0
  fi

  echo "ERROR: NVIDIA Docker runtime still not working after auto-install." >&2
  nvidia_manual_steps
  exit 1
}

# Host-side unit test of the shared docker-argument helper. Cheap, needs no
# image, and is the thing that keeps a stray --gpus out of a CPU launch.
run_arg_checks() {
  echo "==> Checking docker argument assembly (cli_run/lib/docker_args.sh)"
  bash "$ROOT/scripts/test_docker_args.sh"
}

run_checks() {
  # Source/patch inspection only, so it needs no GPU and no Vulkan — it just
  # needs an image with bash + patch. Run it in whichever one this variant built.
  local image ld_path
  image="$(build_image_name)"
  ld_path="$(hexmesh_ld_library_path /space)"

  echo "==> Running no-crash source/binary checks"
  "${docker_cmd[@]}" run --rm \
    -v "$ROOT:/space" \
    -w /space \
    -e "HEXMESH_LD_PATH=$ld_path" \
    "$image" \
    bash -lc 'export LD_LIBRARY_PATH="${HEXMESH_LD_PATH}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"; ./scripts/verify_no_crash_fixes.sh'
}

run_cpu_smoke() {
  local image smoke_env=()
  image="$(hexmesh_image pipeline)"
  if [[ "$HEX_RENDERER" == none ]]; then
    smoke_env=(-e SMOKE_NO_VULKAN=1)
  fi

  echo "==> Running headless CPU smoke test with $image (no GPU, no --gpus, no NVIDIA ICD)"
  # Deliberately minimal: the CPU runtime image is self-contained, so only
  # output/ is mounted. Mounting lib/ or the source tree would shadow the
  # image's +cpu LibTorch and its CUDA-free binary.
  "${docker_cmd[@]}" run --rm \
    -e HEX_LOCAL=1 \
    -e SMOKE_DEVICE=cpu \
    "${smoke_env[@]}" \
    -v "$ROOT/output:/space/output" \
    -w /space \
    "$image" \
    ./cli_run/smoke_test.sh
}

run_nvidia_smoke() {
  [[ "$RUN_SMOKE" == "1" ]] || { echo "==> Skipping smoke test"; return 0; }

  if [[ "$HEX_CPU_ONLY" == 1 ]]; then
    run_cpu_smoke
    return
  fi

  ensure_nvidia_runtime

  if [[ "$HEX_RENDERER" == none ]]; then
    local image
    image="$(hexmesh_image pipeline)"
    hexmesh_runtime_docker_args
    echo "==> Running renderer-free NVIDIA smoke test with $image"
    "${docker_cmd[@]}" run --rm \
      "${HEXMESH_DOCKER_ARGS[@]}" \
      -e HEX_LOCAL=1 \
      -e SMOKE_DEVICE=cuda \
      -e SMOKE_NO_VULKAN=1 \
      -v "$ROOT/output:/space/output" \
      -w /space \
      "$image" \
      ./cli_run/smoke_test.sh
    return
  fi

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
run_arg_checks
run_checks
run_nvidia_smoke
install_host_vulkan_tools

if [[ "$HEX_CPU_ONLY" == 1 && "$HEX_NO_VULKAN" == 1 ]]; then
  echo "OK: CPU-only, renderer-free setup, compile, and verification complete."
  echo "    Run the pipeline with: HEX_IMAGE_VARIANT=cpu HEX_RENDERER=none ./cli_run/run.sh <stage> <input> --no-vulkan --device cpu"
elif [[ "$HEX_CPU_ONLY" == 1 ]]; then
  echo "OK: CPU-only setup, compile, and verification complete (no CUDA installed or linked)."
  echo "    Run the pipeline with: HEX_IMAGE_VARIANT=cpu ./cli_run/run.sh <stage> <input> --headless --device cpu"
elif [[ "$HEX_NO_VULKAN" == 1 ]]; then
  echo "OK: CUDA, renderer-free setup, compile, and verification complete."
  echo "    Run the pipeline with: HEX_RENDERER=none ./cli_run/run.sh <stage> <input> --no-vulkan --device cuda"
else
  echo "OK: NVIDIA setup, compile, and verification complete."
fi
