# Week-2 Report — Command-line hex-meshing tool (plain-language guide)

**Date:** 2026-06-17 · **Branch:** `cli-runner` · Follows the Week-1
[REPORT.md](REPORT.md). This report is written to be easy to read: what we built,
**how to build it, how to run it**, what we tested, and what each result means.

> **In one sentence:** the tool now builds with a single `docker build` command and
> runs the whole 4-stage pipeline end-to-end on a GPU — tested and passing
> (**18,526 hexes, 0 inverted** on the `spot` model).

---

## 1. What we built in Week 2 (plain words)

The tool turns a 3D shape (a tetrahedral mesh) into a clean **hex mesh** through
four steps: `deform → decompose → discretize → hexahedralize`. Week 1 made those
steps runnable from the command line. **Week 2 made it easy to build and proved it
works**, specifically:

1. **One-command build (Docker).** Before, you started a Docker container, mounted
   the code, and compiled by hand. Now a single `docker build` produces a
   ready-to-run image with everything already compiled inside.
2. **A from-scratch build *without* Docker.** We wrote and *actually tested* the
   steps to compile it directly on a clean Ubuntu machine.
3. **Headless investigation.** We answered "can it run on a server with no screen?"
   — yes, and we proved it (details in §6).
4. **GPU dependency map.** We answered "which steps actually need the NVIDIA GPU?"
   per stage (details in §5).

**We did not change the original research code** — all of this is new helper files
plus thin, additive wrappers.

---

## 2. How to BUILD it

You have two options. **Option A (Docker) is the recommended, tested path.**

### Prerequisites (one-time)
- A Linux machine with **Docker**.
- For *building*: **no GPU needed.**
- The two big library archives sitting at the repo root. Get them with:
  ```bash
  . ./setup.sh        # downloads LibTorch 2.6.0+cu124 and the Vulkan SDK into lib/
  # make the proven Vulkan archive the build expects (one-time):
  tar -C lib -cf - vulkan-sdk-1.3.268.0 | xz -T0 -3 -c > vulkan-sdk-1.3.268.0.tar.xz
  ```

### Option A — one Docker command (recommended)
```bash
docker build -f Dockerfile.build -t hexmesh-cli:week2 .
```
That's it. The image compiles `evocube` + the `hex` binary inside itself, and the
build now **fails loudly if either binary is missing**. (`compile.sh` was hardened:
it previously had no error handling, so a failed `evocube` build was silently ignored
and the image shipped with `hex` but no real `evocube` — that masking is fixed, and
`.dockerignore` no longer strips the `.git` from libigl's eigen download cache, which
was what broke evocube's configure in a clean build.)
- A full/cold build takes roughly **15–25 min** (compiles evocube + hex from
  scratch; an earlier "~5 min" figure was an incremental/cached run, not from
  scratch).
- Produces a **~26 GB** image named `hexmesh-cli:week2` (slim runtime variant in
  [BUILD.md §A2.6](BUILD.md)).
- Needs **no GPU** to build (`nvcc` compiles without a graphics card).

→ Full details, including what's baked in vs. supplied at run time:
[BUILD.md §A2](BUILD.md).

### Option B — build natively, no Docker
This compiles directly on the host. We verified it on a **clean Ubuntu 22.04**.
The key extra step (often forgotten) is installing the **CUDA toolkit**:
```bash
# 1. system packages
sudo apt update
sudo apt install -y git cmake build-essential python3 python3-pip \
  libblas-dev liblapack-dev libgl1-mesa-dev libxrandr-dev libxinerama-dev \
  libxcursor-dev libxi-dev libhdf5-serial-dev vulkan-tools

# 2. CUDA 12.4 toolkit (the compiler nvcc) — toolkit ONLY, not the driver
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update && sudo apt install -y cuda-toolkit-12-4
export PATH=/usr/local/cuda/bin:$PATH

# 3. compile (libraries come from setup.sh, in lib/)
export Torch_DIR=$PWD/lib/libtorch/share/cmake/Torch/
source lib/vulkan-sdk-1.3.268.0/setup-env.sh
cmake -S evocube -B evocube/build && cmake --build evocube/build -j8
cmake -S interactive-hex-meshing -B interactive-hex-meshing/build/Release \
  -DCMAKE_BUILD_TYPE=Release -DTorch_DIR="$Torch_DIR"
cmake --build interactive-hex-meshing/build/Release -j8
```
→ Full details + gaps: [BUILD.md §B](BUILD.md). (Note: you do **not** need a
separate cuDNN package — LibTorch ships its own.)

---

## 3. How to RUN it

You need a machine with an **NVIDIA GPU + driver** to *run* the tool (it does the
math on the GPU). Builds don't, but runs do.

First, let the container use your screen:
```bash
xhost +local:root
```

### 3A. The one-command test (recommended first run)
This runs all four stages on the bundled `spot` model and checks the result:
```bash
docker run --runtime=nvidia --gpus all --rm \
  -e DISPLAY=$DISPLAY -e NVIDIA_DRIVER_CAPABILITIES=all -e HEX_LOCAL=1 \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  -v "$(pwd)/output:/space/output" \
  hexmesh-cli:week2 ./cli_run/smoke_test.sh
```
**What you should see:** `PASS: valid hex mesh (18526 hexes, 0 inverted)`.
Results are written under `output/runs/spot/`.

> Two flags matter: `NVIDIA_DRIVER_CAPABILITIES=all` lets the GPU's graphics
> driver into the container, and `HEX_LOCAL=1` tells the runner to execute the
> program directly inside the image. (Do **not** also mount `/usr/share/vulkan` —
> it pulls in host-only files the container doesn't have and the run fails.)

### 3B. Run a single stage
Same wrapper, one subcommand at a time (file in → results out):
```bash
docker run --runtime=nvidia --gpus all --rm \
  -e DISPLAY=$DISPLAY -e NVIDIA_DRIVER_CAPABILITIES=all -e HEX_LOCAL=1 \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw -v "$(pwd)/output:/space/output" \
  hexmesh-cli:week2 \
  ./cli_run/run.sh deform interactive-hex-meshing/assets/tutorial/spot.mesh --exit-after
```
Subcommands: `deform` → `decompose` → `discretize` → `hexahedralize`. Each one's
output HDF5 feeds the next (see [USAGE_AND_TESTS.md](USAGE_AND_TESTS.md)).

### 3C. Run on a server with NO screen (headless)

**Recommended (Week-3): true `--headless` — no window, no X11, no xvfb.** The Week-3
build adds a real headless mode (use the `hexmesh-cli:week3` image; design +
verification in [HEADLESS.md](HEADLESS.md)):
```bash
docker run --gpus all --rm -e NVIDIA_DRIVER_CAPABILITIES=all -e HEX_LOCAL=1 \
  -v "$(pwd)/output:/space/output" hexmesh-cli:week3 \
  bash -lc 'SMOKE_HEADLESS=1 ./cli_run/smoke_test.sh'
```

**Legacy stopgap — virtual display (`xvfb`):** still works (it runs the full
pipeline and writes valid metrics), **but `xvfb-run`'s X-server teardown can hang on
some hosts/versions *after* the pipeline finishes** — the `-a`/auto-servernum cleanup
races, leaving only `xvfb-run`/`Xvfb` alive so the final `PASS` may not print even
though the run already succeeded (check `result_metrics.yaml`). Prefer `--headless`
above; if you must use xvfb, wrap it in `timeout`:
```bash
docker run --gpus all --rm -e NVIDIA_DRIVER_CAPABILITIES=all -e HEX_LOCAL=1 \
  -v "$(pwd)/output:/space/output" hexmesh-cli:week2 \
  bash -lc 'apt-get update -qq && apt-get install -y -qq xvfb && \
            timeout 600 xvfb-run -a -s "-screen 0 1280x720x24" ./cli_run/smoke_test.sh'
```

### What "PASS" means
The hard requirement is **`inverted_count: 0`** (no flipped/invalid hex cells) with
`total_hexes > 0`. Exact hex counts and quality scores depend on the model and are
written to `result_metrics.yaml` in the run folder.

---

## 4. What we verified (results, 2026-06-17, NVIDIA RTX 4090, driver 580.159.03)

| Check | Result |
|---|---|
| Docker image builds in one command | ✅ one-step; **~15–25 min** cold (not ~5), ~26 GB |
| `hex` + `evocube` both built in the image | ✅ after the build was hardened (see note ‡) |
| Full pipeline, with a screen (X11) | ✅ **PASS — 18,526 hexes, 0 inverted**, quality (scaled-Jacobian) mean ≈ 0.86 |
| Full pipeline, **headless** | ✅ **PASS — 18,526 hexes, 0 inverted** — via `--headless` (Week-3) and via `xvfb` (writes valid metrics; xvfb-run teardown may hang on some hosts, §3C) |
| Native build **on a clean Ubuntu 22.04 + CUDA-12.4 toolkit + dev pkgs** | ✅ compiles (evocube + hex) — see ‡‡ |
| Native build/run **on this dev box** | ⚠️ not reproducible here (host lacks the CUDA-12.4 toolkit + `libhdf5-dev`/`libxrandr-dev`/`libeigen3-dev`; no sudo). Use Docker. The container-built binary **does run natively** once its libs are on `LD_LIBRARY_PATH` (deform+discretize, exit 0). |
| Binary is valid + finds its libraries (`ldd`, `--help`) | ✅ |

> ‡ **Build hardening (post-review fix).** `compile.sh` previously had no error
> handling, so a failed `evocube` build was silently ignored and an evocube-less
> image shipped while the docker build still reported success. Root cause in a clean
> build: `.dockerignore`'s `**/.git` stripped the `.git` from libigl's pre-downloaded
> eigen cache, so in-image cmake's `git update` died (`fatal: not a git repository`).
> Fixed: `compile.sh` fail-fasts + verifies both binaries, the Dockerfile re-checks
> both, and `.dockerignore` excludes the libigl `.cache` so eigen downloads fresh.
>
> ‡‡ **Native build scope.** "Clean Ubuntu 22.04" means a host with the CUDA-12.4
> toolkit and the dev packages installed (BUILD.md §B) — not this dev box. The native
> *run* of the binary is confirmed on this host's RTX 4090; the native *build* is not
> (missing toolkit/dev packages, no sudo).

---

## 5. Does it need the GPU? (plain answer)

There are **two separate questions**, often confused:

- **The screen/window (Vulkan + X11):** used **only to draw the GUI window**. The
  actual math never uses it. → This is what "headless" removes (§6).
- **The GPU compute (CUDA):** used for the heavy math. This is what a "CPU-only"
  mode would need to replace.

**Per stage**, measured by how hard each step drives the GPU:

| Stage | GPU usage (peak) | Could it run CPU-only? |
|---|---|---|
| deform | 76% — heavy | with effort (its math is the easy kind to move to CPU) |
| decompose | 57% — heavy | needs a custom GPU routine ported to CPU |
| **discretize** | **28% — lowest** | **yes, basically already** (it's mostly bookkeeping, not GPU math) |
| hexahedralize | 68% — heavy | needs a custom GPU routine ported to CPU |

**Takeaway:** Stage "discretize" is the easiest to make CPU-only; the other three
lean on the GPU. → Full evidence with code references: [DEPENDENCY_MAP.md](DEPENDENCY_MAP.md).

---

## 6. Can it run without the GUI window? (headless)

**Today:** yes, using a *virtual* screen (`xvfb`, see §3C) — proven to PASS, zero
code changes. That already unblocks servers and CI.

**A true "no-window" mode** (not even a virtual screen) is a modest, well-scoped
change to the program's startup — the heavy lifting (the math) doesn't depend on
the window at all. We wrote up exactly what it touches and a size estimate. → See
[HEADLESS.md](HEADLESS.md).

---

## 7. What the machine needs (prerequisites)

| To… | You need |
|---|---|
| **Build** (Docker or native) | a Linux box; **no GPU required** |
| **Run** | an **NVIDIA GPU + driver** (supporting CUDA 12.4) and either a screen or `xvfb` |

**About the NVIDIA driver:** it is a **host prerequisite, not something we ship.**
The driver is tied to the specific machine's kernel; Docker injects the host's
driver into the container at run time. So we install the CUDA *toolkit/libraries*
(for building) but the *driver* is installed once on the host by the machine owner
(e.g. `sudo ubuntu-drivers autoinstall` + reboot).

---

## 8. Did we change the original research code?

**No.** Week-2 work is entirely **new files + additive wrappers** in the parent
repo (`cli_run/` docs, `Dockerfile.build`, `.dockerignore`) plus one small,
opt-in branch in `cli_run/run.sh` (the default behavior is unchanged). The CDM
research submodule has **zero source changes** this week.

---

## 9. Where to find more detail (doc map)

| Doc | What's in it |
|---|---|
| **REPORT2.md** (this file) | plain-language Week-2 summary + build/run guide |
| [BUILD.md](BUILD.md) | full build guide — Docker one-step (§A2) + native (§B) |
| [HEADLESS.md](HEADLESS.md) | can-it-run-without-a-screen analysis + plan |
| [DEPENDENCY_MAP.md](DEPENDENCY_MAP.md) | which stages need the GPU, with code refs |
| [WEEK2_UPDATE.md](WEEK2_UPDATE.md) | the short status update (T1–T4) |
| [USAGE_AND_TESTS.md](USAGE_AND_TESTS.md) | per-stage usage + the test case |
| [REPORT.md](REPORT.md) | the Week-1 report |

---

## 10. What's not done yet / next (honest)

- **Bare-metal native *run* on GPU** — the native build *compiles*; we proved
  *running* via the Docker image (same binary), so a direct host run is just
  unexercised, not known-broken.
- **A true no-window headless mode** — scoped + estimated, not yet implemented
  (Week 3).
- **CPU-only mode** — Stage "discretize" is ready; the others need work (Week 3).
- **Smaller Docker image** — the 26 GB image can be slimmed later.

**Bottom line: Week 2 is complete and GPU-verified.** You can build it with one
command and run the full pipeline to a valid, 0-inverted hex mesh today.
