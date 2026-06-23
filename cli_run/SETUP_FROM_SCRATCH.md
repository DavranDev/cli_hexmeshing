# AutoHexMesh: setup from a clean machine

This runbook installs the host prerequisites, installs Docker, clones the exact
`cli-runner` branch with every nested submodule, prepares the external libraries,
builds the project images, and provides initial CPU/GPU checks.

Repository: <https://github.com/DavranDev/cli_hexmeshing/tree/cli-runner>

Validated checkout on 2026-06-21:

```text
cli_hexmeshing             88920b66b248801b5448d61f7afa6904c2d9933f
evocube                    c1a7930a147716ef25ee37e5de69f74c605c623a
interactive-hex-meshing    c58977ec40e1dfe70c00a9a1f4a406e5e3e04ed5
```

## CLI documentation is the source of truth

The important implementation and presentation material is under `cli_run/`:

| File | Use it for |
|---|---|
| `cli_run/BUILD.md` | Docker, slim-image, native, and binary build paths |
| `cli_run/USAGE_AND_TESTS.md` | Four-stage commands, tutorial inputs, and pass criteria |
| `cli_run/CPU_ONLY.md` | Implemented `--device cpu|cuda` behavior and CPU timings |
| `cli_run/HEADLESS.md` | Implemented `--headless` behavior and Vulkan requirements |
| `cli_run/DEPENDENCY_MAP.md` | CUDA versus Vulkan dependencies by stage |
| `cli_run/SOURCE_CHANGES.md` | Exact changes made to the CDM submodule |
| `cli_run/run.sh` | Current accepted arguments and actual container behavior |
| `cli_run/smoke_test.sh` | Current four-stage pass/fail gate |

Some paragraphs in `cli_run/README.md`, `REPORT.md`, `REPORT_LATEST.md`, and
`how_to_run.txt` preserve earlier Week-1/Week-2 status and are now stale. In
particular, true headless mode and the complete CPU path **are implemented**.
For current behavior, use the scripts themselves plus the implemented sections
of `HEADLESS.md` section 0 and `CPU_ONLY.md` section 5.

Current CLI facts:

- Four subcommands: `deform`, `decompose`, `discretize`, `hexahedralize`.
- There is no `full` subcommand; `smoke_test.sh` chains all four stages.
- `--exit-after` still creates a GUI window and requires a display.
- `--headless` creates no window, surface, swapchain, or GUI, but still requires
  a Vulkan ICD. The slim image supplies Mesa lavapipe for this.
- Compute defaults to `--device cuda`; pass `--device cpu` for CPU compute.
- The hard pass gate is `total_hexes > 0` and `inverted_count == 0`.

## 1. Ubuntu host requirements

Use Ubuntu 22.04 or 24.04 with Docker Engine. On an NVIDIA host, also install
the NVIDIA Container Toolkit.

An NVIDIA GPU is optional for CPU/headless operation. It is required for the
CUDA/GPU tests. Building the images does not require a GPU.

## 2. Install packages and Docker Engine

Install the host utilities:

```bash
sudo apt-get update
sudo apt-get install -y \
  ca-certificates curl wget git gnupg \
  unzip zip tar xz-utils \
  x11-xserver-utils vulkan-tools
```

Add Docker's official repository before installing Docker packages. This order
is important; the repository's current `install_docker.sh` attempts to install
Docker packages before adding the Docker repository and is therefore not the
recommended clean-machine installer.

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

cat <<EOF | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt-get update
sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

sudo systemctl enable --now docker
sudo docker run --rm hello-world
```

Optional: allow the current user to invoke Docker without `sudo`. Membership in
the `docker` group is effectively root-level access.

```bash
sudo usermod -aG docker "$USER"
newgrp docker
docker version
```

### Ubuntu NVIDIA Container Toolkit

Install this only on an Ubuntu host with an NVIDIA GPU.

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor --yes \
      -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -sSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

Official references:

- <https://docs.docker.com/engine/install/ubuntu/>
- <https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html>

## 3. Clone the exact branch and all submodules

Run inside Ubuntu:

```bash
mkdir -p ~/src
cd ~/src

git clone \
  --branch cli-runner \
  --single-branch \
  --recurse-submodules \
  https://github.com/DavranDev/cli_hexmeshing.git \
  AutoHexMesh

cd AutoHexMesh
git submodule sync --recursive
git submodule update --init --recursive
```

Verify the checkout:

```bash
git branch --show-current
git rev-parse HEAD
git submodule status --recursive
git status --short
```

Expected branch:

```text
cli-runner
```

Update the same checkout later without switching branches:

```bash
cd ~/src/AutoHexMesh
git pull --ff-only
git submodule sync --recursive
git submodule update --init --recursive
```

## 4. Required external archives

`Dockerfile.build` requires these files at the repository root:

```text
libtorch-cxx11-abi-shared-with-deps-2.6.0+cu124.zip
vulkan-sdk-1.3.268.0.tar.xz
```

Download LibTorch:

```bash
cd ~/src/AutoHexMesh

curl -L --fail --retry 5 \
  'https://download.pytorch.org/libtorch/cu124/libtorch-cxx11-abi-shared-with-deps-2.6.0%2Bcu124.zip' \
  -o libtorch-cxx11-abi-shared-with-deps-2.6.0+cu124.zip

sha256sum libtorch-cxx11-abi-shared-with-deps-2.6.0+cu124.zip
```

Validated LibTorch checksum:

```text
be21b2ad0d7848fed3f909711889a549864b6cf06d564c58454eeb32a76eaaae
```

### Vulkan SDK compatibility archive

LunarG no longer publishes the old 1.3.268 download used by the original
scripts. On 2026-06-21, its old URLs returned HTTP 404. The clean build was
validated with the current official LunarG Linux SDK, version 1.4.350.1, while
retaining the historical directory name expected by `compile.sh` and `run.sh`.

Run these commands on a fresh checkout:

```bash
cd ~/src/AutoHexMesh

curl -L --fail --retry 5 \
  'https://sdk.lunarg.com/sdk/download/latest/linux/vulkan-sdk.tar.xz' \
  -o vulkansdk-current.tar.xz

mkdir -p lib
tar -xf vulkansdk-current.tar.xz -C lib
mv lib/1.4.350.1 lib/vulkan-sdk-1.3.268.0

tar -C lib -cf - vulkan-sdk-1.3.268.0 \
  | xz -T0 -3 -c > vulkan-sdk-1.3.268.0.tar.xz

sha256sum vulkansdk-current.tar.xz vulkan-sdk-1.3.268.0.tar.xz
```

Validated checksums for the 2026-06-21 inputs:

```text
6cce33c7e5383814150c5041820769d93c65a1fd883002e5949b067045a07daa  vulkansdk-current.tar.xz
c8958b798622566682679d52e3243ef82a9f77d1998bcf5ff2ee057732e3548c  vulkan-sdk-1.3.268.0.tar.xz
```

The `latest` URL can change. For a reproducible presentation, publish or retain
these exact validated archives instead of silently accepting a newer SDK. If a
new SDK is intentionally adopted, replace `1.4.350.1` in the `mv` command and
rerun all tests in section 7.

## 5. Build the self-contained Docker images

`Dockerfile.build` produces **two final images**, not two persistent build
containers:

| Image | Contents | Intended use | Measured size |
|---|---|---|---:|
| `hexmesh-cli:latest` | Compilers, CUDA toolkit, source, build trees, and compiled binaries | Development, rebuilding, debugging, GUI | 28.2 GB unpacked |
| `hexmesh-cli:slim` | Runtime libraries, assets, CLI scripts, and compiled binaries; no CMake or NVCC | Deployment and headless CPU/GPU runs | 15.9 GB unpacked |

Docker may create temporary containers and intermediate stages while building;
BuildKit discards those. Section 6's `docker-hexmesh:latest` is a separate,
optional legacy environment image and is not one of these two deliverables.

Confirm both archives exist:

```bash
cd ~/src/AutoHexMesh
test -f libtorch-cxx11-abi-shared-with-deps-2.6.0+cu124.zip
test -f vulkan-sdk-1.3.268.0.tar.xz
mkdir -p output
```

Build the full development/GUI image:

```bash
docker build --no-cache --progress=plain \
  -f Dockerfile.build \
  --target build \
  -t hexmesh-cli:latest .
```

Build the smaller runtime/headless image. Docker reuses the preceding build
layers:

```bash
docker build --progress=plain \
  -f Dockerfile.build \
  --target runtime \
  -t hexmesh-cli:slim .
```

Verify:

```bash
docker images | grep -E 'hexmesh-cli|REPOSITORY'

docker run --rm hexmesh-cli:latest bash -lc '
  test -x /space/interactive-hex-meshing/bin/Release/hex
  command -v cmake
  command -v nvcc
'

docker run --rm hexmesh-cli:slim bash -lc '
  test -x /space/interactive-hex-meshing/bin/Release/hex
  ! command -v cmake
  ! command -v nvcc
  ./cli_run/run.sh --help
'
```

Measured clean-build results on the validated host:

```text
hexmesh-cli:latest  PASS  cold build 9:20.41; 28.2 GB unpacked; 9,615,889,093 inspect bytes
hexmesh-cli:slim    PASS  build 1:06.59; 15.9 GB unpacked; 5,568,293,348 inspect bytes
```

The slim build reused the full image's completed build stage. Later rebuilds
may be faster because of Docker's cache; use `--no-cache` when demonstrating a
strict cold build.

The first fresh runtime test exposed an invalid Vulkan validation-layer path in
both targets. `Dockerfile.build` and `cli_run/run.sh` were corrected to use the
SDK's actual `share/vulkan/explicit_layer.d` directory, both images were
rebuilt, and the final GPU/headless and GUI tests below passed without an
environment-variable workaround.

## 6. Optional environment-only image

This is the older development workflow. Source and libraries remain on the host
and are bind-mounted into the container.

Extract the libraries:

```bash
cd ~/src/AutoHexMesh
mkdir -p lib
unzip -q libtorch-cxx11-abi-shared-with-deps-2.6.0+cu124.zip -d lib
tar -xf vulkan-sdk-1.3.268.0.tar.xz -C lib
```

Build the environment image:

```bash
docker build --no-cache --progress=plain \
  -t docker-hexmesh:latest .
```

Compile the bind-mounted source non-interactively:

```bash
docker run --rm \
  -v "$PWD/lib:/space/lib" \
  -v "$PWD/evocube:/space/evocube" \
  -v "$PWD/interactive-hex-meshing:/space/interactive-hex-meshing" \
  -v "$PWD/compile.sh:/space/compile.sh:ro" \
  docker-hexmesh:latest \
  bash /space/compile.sh
```

This writes `evocube/build/polycube_withHexEx` and
`interactive-hex-meshing/bin/Release/hex` into the mounted checkout. The
validated image build took 2:11.89 (6.23 GB); the mounted-source compile passed
in 5:27.27. A GPU is not required to compile.

For presentations and clean-machine reproduction, prefer the self-contained
images from section 5.

## 7. CLI operation and project tests

The self-contained images must run the wrapper with `HEX_LOCAL=1`. Without it,
`cli_run/run.sh` tries to launch a nested `docker-hexmesh` container using the
older environment-image workflow.

### 7.1 Display and compute modes

These are independent choices:

| Mode | Flag/environment | Display | Compute |
|---|---|---|---|
| GUI | no display flag | X11/Vulkan window | CUDA by default |
| Auto-closing GUI | `--exit-after` | Window still required | CPU or CUDA |
| True headless | `--headless` | No X11; Vulkan ICD still required | CPU or CUDA |
| CPU compute | `--device cpu` | Usually pair with `--headless` | CPU |
| GPU compute | `--device cuda` or omit `--device` | Any display mode | NVIDIA CUDA |

### 7.2 GPU + headless full pipeline

```bash
cd ~/src/AutoHexMesh

docker run --rm --gpus all \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e HEX_LOCAL=1 \
  -e SMOKE_HEADLESS=1 \
  -v "$PWD/output:/space/output" \
  hexmesh-cli:slim \
  ./cli_run/smoke_test.sh
```

Pass condition:

```text
total_hexes > 0
inverted_count = 0
PASS: valid hex mesh
```

This invokes `smoke_test.sh`, which chains all four stages and defaults to the
bundled `spot.mesh` tutorial input.

Validated result on 2026-06-21: **PASS**, 18,526 hexes, 0 inverted,
scaled-Jacobian minimum 0.0245009158, wall time 10.24 seconds.

### 7.3 CPU-only + headless full pipeline

`smoke_test.sh` currently chooses GUI versus headless but does not forward a
compute-device option. Therefore, run the four stages explicitly for the CPU
gate. No GPU is passed to this container:

```bash
docker run --rm \
  -e HEX_LOCAL=1 \
  -v "$PWD/output:/space/output" \
  hexmesh-cli:slim bash -lc '
set -e
RUN=./cli_run/run.sh
M=interactive-hex-meshing/assets/tutorial/spot.mesh

$RUN deform "$M" --headless --device cpu
S0=$(ls -dt output/runs/spot/deformation_* | head -1)

$RUN decompose "$S0/stage_0_deformation.hdf5" --headless --device cpu
S1=$(ls -dt output/runs/spot/decomposition_* | head -1)

$RUN discretize "$S1/stage_1_decomposition.hdf5" --headless --device cpu
S2=$(ls -dt output/runs/spot/discretization_* | head -1)

$RUN hexahedralize "$S2/stage_2_discretization.hdf5" --headless --device cpu
S3=$(ls -dt output/runs/spot/hexahedralization_* | head -1)

METRICS="$S3/result_metrics.yaml"
test -f "$S3/result.mesh"
test -f "$METRICS"
HEXES=$(awk "/^total_hexes:/{print \$2}" "$METRICS")
INVERTED=$(awk "/^inverted_count:/{print \$2}" "$METRICS")
test "$HEXES" -gt 0
test "$INVERTED" -eq 0
cat "$METRICS"
echo "PASS: CPU headless — $HEXES hexes, 0 inverted"
'
```

Validated result on 2026-06-21 with no `--gpus` option: **PASS**, 18,526 hexes,
0 inverted, scaled-Jacobian minimum 0.0246162266, wall time 5:54.98.

### 7.4 GPU + auto-closing GUI stage on native Ubuntu

Unlike `--headless`, `--exit-after` opens a real window before closing it. This
is useful to prove the GUI/Vulkan path separately from headless operation:

```bash
xhost +local:root

docker run --rm --gpus all \
  -e DISPLAY="$DISPLAY" \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e HEX_LOCAL=1 \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  -v "$PWD/output:/space/output" \
  hexmesh-cli:latest \
  ./cli_run/run.sh deform \
    interactive-hex-meshing/assets/tutorial/spot.mesh \
    --exit-after --device cuda

xhost -local:root
```

Do not mount the host `/usr/share/vulkan` into the self-contained image; the CLI
build documentation records that doing so imports incompatible host layers.

Validated result on 2026-06-21: **PASS** in 10.52 seconds. The log recorded
`Preferred MSAA sample count: 4`, proving that the render/GUI path initialized,
then the stage completed and the process exited without the timeout firing.

### 7.5 Vulkan dependency boundary

CPU compute does not require an NVIDIA GPU, but the current application still
creates a surfaceless Vulkan instance in headless mode. Prove this boundary by
pointing the loader at a nonexistent ICD and expecting a nonzero exit:

```bash
set +e
docker run --rm \
  -e HEX_LOCAL=1 \
  -e VK_ICD_FILENAMES=/does/not/exist.json \
  -v "$PWD/output:/space/output" \
  hexmesh-cli:slim \
  ./cli_run/run.sh deform \
    interactive-hex-meshing/assets/tutorial/spot.mesh \
    --headless --device cpu
status=$?
set -e
test "$status" -ne 0
```

Validated result: expected failure, exit 134. Therefore the current status is:

- NVIDIA/CUDA is optional when `--device cpu` is selected.
- A Vulkan ICD is still mandatory, even with `--headless --device cpu`.
- The slim image supplies Mesa lavapipe, so CPU/headless works on a non-NVIDIA
  host without installing a physical Vulkan GPU.

### 7.6 Run a different tutorial mesh

The supplied Stage-0 inputs are `bob.mesh`, `bunny.mesh`, `horse.mesh`,
`rockerArm.mesh`, `spot.mesh`, and `kitten.vtk`.

```bash
docker run --rm --gpus all \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e HEX_LOCAL=1 \
  -e SMOKE_HEADLESS=1 \
  -v "$PWD/output:/space/output" \
  hexmesh-cli:slim \
  ./cli_run/smoke_test.sh \
    interactive-hex-meshing/assets/tutorial/bunny.mesh
```

### 7.7 Custom parameters

Copy the appropriate template, preserve its placeholders, edit only the values,
and pass the custom YAML after the input path:

```bash
cp cli_run/configs/stage_deformation.yaml my_deformation.yaml

docker run --rm \
  -e HEX_LOCAL=1 \
  -v "$PWD/output:/space/output" \
  -v "$PWD/my_deformation.yaml:/space/my_deformation.yaml:ro" \
  hexmesh-cli:slim \
  ./cli_run/run.sh deform \
    interactive-hex-meshing/assets/tutorial/spot.mesh \
    /space/my_deformation.yaml --headless --device cpu
```

The placeholders `__INPUT_PATH__`, `__RUN_DIR__`, and, for deformation,
`__INPUT_TYPE__` are replaced automatically by `run.sh`.

### 7.8 Output and verification

Each invocation creates:

```text
output/runs/<example>/<stage>_<YYYY_MM_DD>_<NNN>/
├── input.mesh, input.vtk, or input.hdf5
├── stage_N_<stage>.hdf5
├── result.mesh                 # final stage
├── result_metrics.yaml         # final stage
├── run_config.yaml
└── log.txt
```

The final acceptance checks are:

```bash
LATEST=$(ls -dt output/runs/<example>/hexahedralization_* | head -1)
test -f "$LATEST/result.mesh"
grep -E '^(total_hexes|inverted_count):' "$LATEST/result_metrics.yaml"
```

The detailed CLI documentation reviewed for this runbook is:

```text
cli_run/README.md
cli_run/BUILD.md
cli_run/USAGE_AND_TESTS.md
cli_run/CPU_ONLY.md
cli_run/HEADLESS.md
cli_run/DEPENDENCY_MAP.md
cli_run/SOURCE_CHANGES.md
cli_run/how_to_run.txt
cli_run/run.sh
cli_run/smoke_test.sh
cli_run/configs/*.yaml
```

## 8. Native build, packaged binaries, and Git tracking

### 8.1 Native Ubuntu build without Docker

Install the native development dependencies on Ubuntu 22.04. The CUDA toolkit
must match the CUDA 12.4 LibTorch archive:

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential cmake git python3 python3-pip \
  libblas-dev liblapack-dev libgl1-mesa-dev \
  libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev \
  libhdf5-serial-dev vulkan-tools

# Ubuntu 22.04: add NVIDIA's CUDA repository and install toolkit 12.4.
wget \
  https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update
sudo apt-get install -y cuda-toolkit-12-4

export PATH=/usr/local/cuda-12.4/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.4/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
nvcc --version

cd ~/src/AutoHexMesh
export Torch_DIR="$PWD/lib/libtorch/share/cmake/Torch"
set +u
source "$PWD/lib/vulkan-sdk-1.3.268.0/setup-env.sh"
set -u
export VK_LAYER_PATH="$VULKAN_SDK/share/vulkan/explicit_layer.d"

cmake -S evocube -B evocube/build-native -DCMAKE_BUILD_TYPE=Release
cmake --build evocube/build-native --parallel "$(nproc)"

cmake -S interactive-hex-meshing \
  -B interactive-hex-meshing/build/Native \
  -DCMAKE_BUILD_TYPE=Release \
  -DTorch_DIR="$Torch_DIR"
cmake --build interactive-hex-meshing/build/Native --parallel "$(nproc)"
```

This host could not honestly claim a native-build pass: it has CUDA 11.5, not
12.4, and lacks several development packages. The attempted configure reached
the project and then stopped at `RandR headers not found`; the container-built
binary also reported missing CUDA 12 and HDF5 runtime libraries on the host.
Install the listed prerequisites, rerun the commands, and only then mark native
build/runtime as passed. Docker CPU/GPU tests are fully passed independently.

### 8.2 Package the two principal executables

Extract the binaries from the tested full image and create a distributable
archive:

```bash
mkdir -p dist/linux-x86_64-cuda12.4
cid=$(docker create hexmesh-cli:latest)
docker cp "$cid:/space/interactive-hex-meshing/bin/Release/hex" \
  dist/linux-x86_64-cuda12.4/hex
docker cp "$cid:/space/evocube/build/polycube_withHexEx" \
  dist/linux-x86_64-cuda12.4/polycube_withHexEx
docker rm "$cid"

tar -C dist -czf \
  dist/autohexmesh-cli-runner-linux-x86_64-cuda12.4.tar.gz \
  linux-x86_64-cuda12.4

sha256sum \
  dist/linux-x86_64-cuda12.4/hex \
  dist/linux-x86_64-cuda12.4/polycube_withHexEx \
  dist/autohexmesh-cli-runner-linux-x86_64-cuda12.4.tar.gz
```

Validated artifacts:

```text
c30d98f0c01eaba8601e73e5c778aa3b709b07b206d3bc4da143b74b913d30c0  hex
4e72ae097a0d0d0afbe603ef3c00298a8257819cfcea5867106d8344a032d062  polycube_withHexEx
06e3eb11ffa636479eecdea0fca852aee703939c3587b8b7adf823e27c92884f  autohexmesh-cli-runner-linux-x86_64-cuda12.4.tar.gz
```

These are dynamically linked Linux x86-64 binaries. The target system needs
compatible CUDA 12.4, LibTorch, Vulkan, HDF5, and system runtime libraries;
otherwise use a tested Docker image.

### 8.3 Track changes to the original CDM source

The CLI work does modify the `interactive-hex-meshing` CDM submodule; it is not
only an external wrapper. Reproduce the audit with:

```bash
git -C interactive-hex-meshing diff --shortstat d0a904a
git -C interactive-hex-meshing diff --name-status d0a904a
git submodule status --recursive
git status --short
```

Validated result: 34 CDM files changed, 1003 insertions, and 133 deletions versus
the pre-CLI baseline `d0a904a`. The detailed per-file explanation is maintained
in `cli_run/SOURCE_CHANGES.md`; all nested submodules remain pinned by Git.

### 8.4 Acceptance status after the clean run

| Requirement | Result |
|---|---|
| Clean recursive clone | PASS |
| Full self-contained image | PASS |
| Slim runtime image | PASS |
| Legacy environment image + mounted compile | PASS |
| Four-stage CUDA/headless pipeline | PASS |
| Four-stage CPU/headless pipeline, no GPU exposed | PASS |
| GUI initialization and automatic exit | PASS |
| Output mesh and quality metrics | PASS |
| CPU without NVIDIA/CUDA | PASS |
| CPU without any Vulkan ICD | NOT SUPPORTED; expected failure confirmed |
| Packaged Linux executables | PASS |
| Native host compile/runtime | BLOCKED by missing host packages and CUDA 11.5/12.4 mismatch |
| Original-source Git audit | PASS |

## 9. Commands executed during the 2026-06-21 clean-clone session

These are the operational commands actually used for this checkout and basic
host verification. Docker and the host packages were already installed, so they
were verified rather than reinstalled.

```bash
cd /home/buddy/Documents

git clone --branch cli-runner --single-branch --recurse-submodules \
  https://github.com/DavranDev/cli_hexmeshing.git AutoHexMesh

cd /home/buddy/Documents/AutoHexMesh

git branch --show-current
git rev-parse HEAD
git submodule status --recursive
git status --short

docker --version
docker info --format '{{.ServerVersion}}'
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader

docker run --rm hello-world
docker run --rm --gpus all \
  nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

The image build commands actually executed were:

```bash
docker build --no-cache --progress=plain \
  -f Dockerfile.build --target build -t hexmesh-cli:latest .

docker build --progress=plain \
  -f Dockerfile.build --target runtime -t hexmesh-cli:slim .

docker build --no-cache --progress=plain \
  -t docker-hexmesh:latest .
```

Observed host verification:

```text
Docker client/server: 29.4.1
NVIDIA Container Toolkit package: 1.19.0
GPU: NVIDIA GeForce RTX 4090
Driver: 595.71.05
Docker hello-world: PASS
CUDA container nvidia-smi: PASS
```
