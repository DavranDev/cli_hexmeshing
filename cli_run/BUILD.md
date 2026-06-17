# Building the command-line hex-meshing tool from scratch

This guide builds the **CLI** hex-meshing tool (`hex` binary + `cli_run/run.sh`
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
From the **host** (not the build shell) — `cli_run/run.sh` launches its own
container per stage:
```bash
./cli_run/run.sh deform interactive-hex-meshing/assets/tutorial/spot.mesh --exit-after
```
See [USAGE_AND_TESTS.md](USAGE_AND_TESTS.md)
for all four stages and the full chain. To verify the whole pipeline in one
command:
```bash
./cli_run/smoke_test.sh        # PASS = valid hex mesh, 0 inverted
```

> **Rebuilding after a source change:** re-enter `. ./run_docker.sh` and run
> `. /space/compile.sh` again (it's incremental), then re-run `cli_run/smoke_test.sh`.

---

## A2. One-step build — self-contained image (`Dockerfile.build`)  ← recommended

Sections A.2–A.5 use the env-only `Dockerfile`: it installs dependencies, and you
then bind-mount the host source and run `compile.sh` by hand. `Dockerfile.build`
folds all of that into the image: it COPYs the source from the build context and
compiles `hex` + evocube **inside** the image. A reviewer needs only two commands —
no host-mounted source, no manual `compile.sh`.

### A2.1 Prerequisites
Two library archives must sit at the repo root; the build COPYs them (it does
**not** re-download):
- `libtorch-cxx11-abi-shared-with-deps-2.6.0+cu124.zip` — LibTorch (from `setup.sh`).
- `vulkan-sdk-1.3.268.0.tar.xz` — the **proven** Vulkan SDK 1.3.268.0, repackaged
  once from the working `lib/vulkan-sdk-1.3.268.0` tree:
  ```bash
  tar -C lib -cf - vulkan-sdk-1.3.268.0 | xz -T0 -3 -c > vulkan-sdk-1.3.268.0.tar.xz
  ```
  > ⚠️ The repo also carries a `vulkansdk.tar.xz`, but that is a **different,
  > untested version (1.4.341.1)** — the build deliberately ignores it.
  > `compile.sh` and `run.sh` are pinned to **1.3.268.0**, and LunarG's direct
  > download link for that older SDK now 404s, so we ship it from the local proven
  > tree instead of re-downloading.

Docker is required. **No GPU is needed to build** (`nvcc` compiles without a device).

### A2.2 Build
```bash
docker build -f Dockerfile.build -t hexmesh-cli:week2 .
```
- Build context is **~3.7 GB** (source tree + the two archives; `.dockerignore`
  keeps out `lib/`, build trees, the prebuilt host binary, and the token).
- Wall time: **~5 min** on a 24-core / 62 GB host with the apt/pip layers cached
  (the evocube + hex compile itself is ~2 min at `make -j8`); budget **~8–10 min**
  for a cold build (first-time apt + pip + library extraction).
- Image size: **~26 GB** (`docker images hexmesh-cli:week2`). Large because it is
  built from the CUDA *devel* base + LibTorch + Vulkan SDK; see A2.6 for slimming.

### A2.3 Run the smoke test (GPU needed only here, at run time)
On a host with an NVIDIA driver + GPU. Allow the container to reach your X server,
then run:
```bash
xhost +local:root                                  # let the container use $DISPLAY
docker run --runtime=nvidia --gpus all --rm \
  -e DISPLAY=$DISPLAY -e NVIDIA_DRIVER_CAPABILITIES=all -e HEX_LOCAL=1 \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  -v "$(pwd)/output:/space/output" \
  hexmesh-cli:week2 ./cli_run/smoke_test.sh         # PASS = valid hex mesh, 0 inverted
```
`NVIDIA_DRIVER_CAPABILITIES=all` makes the NVIDIA Container Toolkit inject the
Vulkan ICD + GL libs into the container — **do not** also bind-mount the host
`/usr/share/vulkan` (it drags in host-only implicit layers the container lacks and
the run aborts). `HEX_LOCAL=1` tells `cli_run/run.sh` to run `hex` **directly**
inside the container instead of launching another docker container (its default
host-side behavior — see A.5 — is unchanged). The image is laid out at `/space`
exactly like the A.5 mounts, so the paths the runner writes into its YAML resolve
correctly. Drop `./cli_run/smoke_test.sh` for an interactive shell.

**No display? Run headless on a virtual one** (no `DISPLAY`, no X mount):
```bash
docker run --runtime=nvidia --gpus all --rm \
  -e NVIDIA_DRIVER_CAPABILITIES=all -e HEX_LOCAL=1 \
  -v "$(pwd)/output:/space/output" hexmesh-cli:week2 \
  bash -lc 'apt-get update -qq && apt-get install -y -qq xvfb && \
            xvfb-run -a -s "-screen 0 1280x720x24" ./cli_run/smoke_test.sh'
```

> **Verified 2026-06-17 (RTX 4090, driver 580.159.03, CUDA 12.4 image):** both the
> X11 and the `xvfb` runs print `PASS` on `spot.mesh` — **18 526 hexes, 0 inverted**,
> scaled-Jacobian min 0.024 / mean 0.86 / max 0.9998.

To run a single stage the same way:
```bash
docker run --runtime=nvidia --gpus all --rm \
  -e DISPLAY=$DISPLAY -e NVIDIA_DRIVER_CAPABILITIES=all -e HEX_LOCAL=1 \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw -v "$(pwd)/output:/space/output" \
  hexmesh-cli:week2 \
  ./cli_run/run.sh deform interactive-hex-meshing/assets/tutorial/spot.mesh --exit-after
```

### A2.4 What is baked in vs supplied at run time
| | |
|---|---|
| **Baked into the image** | compiled `hex` + evocube binaries, LibTorch + Vulkan SDK runtime libs, the CLI wrapper (`cli_run/`), and the tutorial meshes (`interactive-hex-meshing/assets/`) used by the smoke test |
| **Supplied at run time only** | a writable `output/` mount (to get results onto the host), any **custom input mesh** you want to process, and — for the real pipeline — the **NVIDIA GPU + driver, Vulkan ICD, and an X11 `DISPLAY`** |

### A2.5 GPU is build-free, run-bound
`docker build` needs no GPU and no display (`nvcc` cross-compiles). A working
**NVIDIA driver (CUDA ≥ 12.4), the Vulkan ICD, and an X11 display are required
only at `docker run` time** — the tool still opens a Vulkan window today (see the
GUI note at the bottom). A true headless mode is tracked separately
(`cli_run/HEADLESS.md`, in progress).

### A2.6 Two-stage runtime slimming (next step, not yet shipped)
The current image is built from the CUDA **devel** base (the proven environment)
so it is large. Splitting it into a `builder` stage + a slim `runtime` stage
(CUDA **runtime** base, copying only the binaries + runtime `.so`s + assets) is a
documented follow-up: it needs the full GPU+X11 smoke test to validate that no
runtime library was dropped, so it is intentionally deferred rather than shipped
unverified.

---

## B. Native / non-Docker build (compile-verified on clean ubuntu:22.04)

The Docker image is only a build environment; nothing in the pipeline *requires*
a container. The same build runs on the host. **Compile-verified** on a clean
`ubuntu:22.04` container on 2026-06-16 — evocube and `hex` both build from the
steps below. **Runtime is not verified** (a GPU-less container can't provide the
NVIDIA driver); see §B.4 for the exact status and known gaps.

### B.1 Host packages
```bash
sudo apt update
sudo apt install -y git cmake build-essential python3 python3-pip \
  libblas-dev liblapack-dev libgl1-mesa-dev libxrandr-dev libxinerama-dev \
  libxcursor-dev libxi-dev libhdf5-serial-dev vulkan-tools
```
(`cmake` ≥ 3.18 is required; ubuntu 22.04's 3.22 is fine. The `pip install numpy
meshio open3d h5py` from the Docker setup is **runtime/script-only** — used by
evocube's `build_hdf5.py` helper, *not* needed to compile `hex` or evocube.)

**CUDA 12.4 toolkit** — geomlib has two `.cu` kernels, so `nvcc` is required. The
Docker path gets this from its `cuda:12.4.1-cudnn-devel` base; on a clean host
install the **toolkit only** (the `cuda` metapackage also pulls the GPU *driver*,
which a build host does not need):
```bash
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update
sudo apt install -y cuda-toolkit-12-4        # nvcc + headers + cudart + cupti; NO driver
export PATH=/usr/local/cuda/bin:$PATH        # so cmake's FindCUDA/CUDAToolkit find nvcc
```
You do **not** need a separate cuDNN package — LibTorch 2.6.0+cu124 ships its own
`libcudnn.so.9` under `lib/libtorch/lib`.

### B.2 Libraries
Use the same downloads as `setup.sh` (LibTorch 2.6.0+cu124, Vulkan SDK 1.3.268.0)
unpacked into `lib/libtorch` and `lib/vulkan-sdk-1.3.268.0`.

### B.3 Build
```bash
export PATH=/usr/local/cuda/bin:$PATH
export Torch_DIR=$PWD/lib/libtorch/share/cmake/Torch/
source lib/vulkan-sdk-1.3.268.0/setup-env.sh

# evocube (CPU only — OpenMP; no CUDA / LibTorch)
cmake -S evocube -B evocube/build && cmake --build evocube/build -j8

# hex (CUDA + LibTorch + Vulkan)
cmake -S interactive-hex-meshing -B interactive-hex-meshing/build/Release \
  -DCMAKE_BUILD_TYPE=Release -DTorch_DIR="$Torch_DIR"
cmake --build interactive-hex-meshing/build/Release -j8
```
Binary: `interactive-hex-meshing/bin/Release/hex`. To run it you also need
`export LD_LIBRARY_PATH=$PWD/lib/libtorch/lib:$VULKAN_SDK/lib` (plus an NVIDIA
driver + X11 display — see the GUI note).

### B.4 Verification status + known gaps
**Compile-verified on a clean `ubuntu:22.04` container on 2026-06-16** (24-core
host; repo copied to a writable dir, then §B.1→§B.3 as written). Results:
evocube built all targets; `hex` built in ~2 min; the binary is a valid ELF whose
`ldd` resolves cleanly (with the `LD_LIBRARY_PATH` above) and `hex --help` runs;
its size matches the Docker build's. CUDA toolkit install took ~4 min.

- **Runtime is NOT verified.** Running `hex` needs an NVIDIA driver supporting
  CUDA ≥ 12.4, which a GPU-less container can't provide. The *build* is GPU-free
  (`nvcc` cross-compiles).
- **Fixed GPU arch.** geomlib pins `CMAKE_CUDA_ARCHITECTURES=75` (Turing) in
  `geomlib/geomlib/CMakeLists.txt`, so the binary targets sm_75; on a different
  GPU generation it relies on PTX/JIT (untested). Edit that value to match your
  card if needed.
- **Benign warning.** cmake prints `Could NOT find nvtx3` (an optional LibTorch
  CUDA profiling header); it does not affect the build or link.
- **Writable checkout required.** evocube's bundled libigl writes generated files
  into its own source tree at configure time, so build from a writable checkout
  (a read-only source mount fails at configure). Normal clones are writable.
- **Not validated:** a full pipeline *run* (needs a driver) and non-Turing GPUs.

---

## C. Running the prebuilt binary (no compilation)

A prebuilt `hex` is published as a GitHub Release asset on the fork. It runs
**only** in a matching environment:

- the `docker-hexmesh` image (or a host with the same libraries),
- NVIDIA driver supporting CUDA 12.4, LibTorch 2.6.0+cu124, Vulkan SDK 1.3.268.0,
- an X11 display (`DISPLAY` set) — the binary opens a Vulkan window.

Drop the downloaded `hex` into `interactive-hex-meshing/bin/Release/` and use
`cli_run/run.sh` as in A.5. If your environment differs, build from source (A or B).

---

## GUI note (current limitation)

The tool currently still **launches the Vulkan GUI window**, runs the requested
stage(s), and — with `--exit-after` (which `cli_run/run.sh` and `smoke_test.sh`
pass) — closes the window and exits. So it needs Vulkan + a display today. A true
no-GUI headless mode (and a look at which steps actually need the GPU) is on the
roadmap; see `small_plan.txt`.
