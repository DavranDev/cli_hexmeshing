# Building the command-line hex-meshing tool from scratch

This guide builds the **CLI** hex-meshing tool (`hex` binary + `cli/run.sh`
wrapper) from a clean checkout. The repo's top-level [README.md](../README.md)
covers the original GUI workflow; this document is the CLI-focused, reproducible
build for reviewers.

There are two paths:
- **Docker (recommended, verified)** — one environment image, no host library
  juggling. This is what we test against.
- **Native / non-Docker (experimental, not yet fully verified)** — build directly
  on the host. Documented here for completeness; full verification is planned.

---

## 0. Component & version summary

| Component | Version / source |
|---|---|
| Base image | `nvcr.io/nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04` |
| CUDA | 12.4 (host NVIDIA driver must be ≥ this) |
| LibTorch | 2.6.0+cu124 (`download.pytorch.org`) |
| Vulkan SDK | 1.3.268.0 (`sdk.lunarg.com`) |
| evocube submodule | `github.com/xmlyqing00/evocube` |
| CDM submodule | `github.com/DavranDev/interactive-hex-meshing`, branch `cli-runner` |

The big libraries (LibTorch, Vulkan SDK) are **not** in git — `setup.sh`
downloads them. They are gitignored along with `lib/` and the build output.

---

## A. Docker build (recommended)

### A.1 Host prerequisites
- Ubuntu (tested on 22.04/24.04), an **NVIDIA GPU + driver** (supporting CUDA ≥ 12.4),
  `git`, and an X11 display (the tool opens a Vulkan window; see "GUI note" below).
- Docker + the NVIDIA Container Toolkit. If you don't have them:
  ```bash
  . ./install_docker.sh
  # sanity check — should print your GPU:
  sudo docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi
  ```

### A.2 Clone (with submodules)
```bash
git clone --recurse-submodules https://github.com/DavranDev/cli_hexmeshing.git
cd cli_hexmeshing
```
`--recurse-submodules` checks out `evocube` and `interactive-hex-meshing` at the
exact commits this branch pins (the CDM submodule lands on the `cli-runner`
commit).

### A.3 Download libraries + build the environment image
```bash
. ./setup.sh
```
This downloads LibTorch 2.6.0+cu124 and Vulkan SDK 1.3.268.0 into `lib/`, then
builds the `docker-hexmesh` image (from the repo `Dockerfile`) and creates
`output/`.

### A.4 Compile the code
```bash
. ./run_docker.sh          # opens an interactive shell inside docker-hexmesh
#   --- now inside the container, at /space ---
. /space/compile.sh        # builds evocube + the hex binary
exit
```
`compile.sh` produces the binary at
`interactive-hex-meshing/bin/Release/hex` (on the host, via the mounted source).
You only need `hex` for the CLI; evocube is built too but is only needed to
generate fresh polycube inputs from raw `.obj` files.

### A.5 Run the CLI
From the **host** (not the build shell) — `cli/run.sh` launches its own
container per stage:
```bash
./cli/run.sh deform output/input_examples/stage_0_deformation/toy_plane.mesh --exit-after
```
See [how_to_run.txt](how_to_run.txt) and [USAGE_AND_TESTS.md](USAGE_AND_TESTS.md)
for all four stages and the full chain. To verify the whole pipeline in one
command:
```bash
./cli/smoke_test.sh        # PASS = valid hex mesh, 0 inverted
```

> **Rebuilding after a source change:** re-enter `. ./run_docker.sh` and run
> `. /space/compile.sh` again (it's incremental), then re-run `cli/smoke_test.sh`.

---

## B. Native / non-Docker build (experimental — not yet fully verified)

The Docker image is only a build environment; nothing in the pipeline *requires*
a container. The same build can run on the host. This path is documented from the
`Dockerfile` + `compile.sh` but has **not yet been verified end-to-end** on a
clean host — treat it as a starting point (full verification is scheduled).

### B.1 Host packages (from the Dockerfile)
```bash
sudo apt update
sudo apt install -y git cmake build-essential python3 python3-pip \
  libblas-dev liblapack-dev libgl1-mesa-dev libxrandr-dev libxinerama-dev \
  libxcursor-dev libxi-dev libhdf5-serial-dev vulkan-tools
pip install numpy meshio open3d h5py
```
You also need the **CUDA 12.4 toolkit** and a matching NVIDIA driver installed on
the host (the Docker path gets these from the base image).

### B.2 Libraries
Use the same downloads as `setup.sh` (LibTorch 2.6.0+cu124, Vulkan SDK
1.3.268.0) unpacked into `lib/libtorch` and `lib/vulkan-sdk-1.3.268.0`.

### B.3 Build
```bash
export Torch_DIR=$PWD/lib/libtorch/share/cmake/Torch/
source lib/vulkan-sdk-1.3.268.0/setup-env.sh

# evocube
cmake -S evocube -B evocube/build && cmake --build evocube/build -j8

# hex
cmake -S interactive-hex-meshing -B interactive-hex-meshing/build/Release \
  -DCMAKE_BUILD_TYPE=Release -DTorch_DIR="$Torch_DIR"
cmake --build interactive-hex-meshing/build/Release -j8
```
Binary: `interactive-hex-meshing/bin/Release/hex`. Run it after
`source lib/vulkan-sdk-1.3.268.0/setup-env.sh`.

---

## C. Running the prebuilt binary (no compilation)

A prebuilt `hex` is published as a GitHub Release asset on the fork. It runs
**only** in a matching environment:

- the `docker-hexmesh` image (or a host with the same libraries),
- NVIDIA driver supporting CUDA 12.4, LibTorch 2.6.0+cu124, Vulkan SDK 1.3.268.0,
- an X11 display (`DISPLAY` set) — the binary opens a Vulkan window.

Drop the downloaded `hex` into `interactive-hex-meshing/bin/Release/` and use
`cli/run.sh` as in A.5. If your environment differs, build from source (A or B).

---

## GUI note (current limitation)

The tool currently still **launches the Vulkan GUI window**, runs the requested
stage(s), and — with `--exit-after` (which `cli/run.sh` and `smoke_test.sh`
pass) — closes the window and exits. So it needs Vulkan + a display today. A true
no-GUI headless mode (and a look at which steps actually need the GPU) is on the
roadmap; see `small_plan.txt`.
