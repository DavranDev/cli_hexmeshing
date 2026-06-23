# Report (latest) — Command-line hex-meshing tool (consolidated: Weeks 1–3)

**One document to build, run, verify, and understand the GPU/CPU story.** It folds
the Week-1/2/3 work into a single report mapped to your questions, with **plain-language
build/run command blocks inline** and the deeper analyses cross-linked to their source
docs. Where a claim needs a GPU, it is stated as measured (this dev box turned out to
*be* a working GPU host — RTX 4090, driver 580.159.03 — so the Week-2 "pending a GPU
host" items are now closed).

Status date: 2026-06-18. Branch `cli-runner` (parent `cli_hexmeshing` + submodule
`interactive-hex-meshing`). **Not yet pushed** — committed in one batch at week's end
(your call); see §11.

> **In one sentence:** the tool builds with a single `docker build`, runs the whole
> 4-stage pipeline end-to-end on a GPU — now also **fully headless (no screen, no
> xvfb)** — and is verified passing (**18,526 hexes, 0 inverted** on the `spot` model).

> This report supersedes and folds in the earlier Week-1 / Week-2 / Week-3 reports.
> The Week-1 [REPORT.md](REPORT.md) remains for history.

---

## 0. Coverage of your asks (where each is answered)

| # | Your item | Status | Where |
|---|---|---|---|
| 1 | Simplified from-scratch build guide | ✅ | §2, [BUILD.md](BUILD.md) |
| 2 | Docker **and** non-Docker build | ✅ | §2, BUILD.md §A/§B |
| 3 | End-to-end Dockerfile for the updated source | ✅ | §2, `Dockerfile.build`, BUILD.md §A2 |
| 4 | Well-documented for the report | ✅ | this doc + the doc map (§12) |
| 5 | Provide the compiled binary | ✅ | §2.3, `dist/MANIFEST.md` |
| 6 | Simplest usage + I/O behaviour | ✅ | §3–§4, [how_to_run.txt](how_to_run.txt) |
| 7 | Test cases + verify-after-change | ✅ | §5, `cli_run/smoke_test.sh` |
| 8 | Track original-source changes | ✅ | §6, [SOURCE_CHANGES.md](SOURCE_CHANGES.md) |
| 9 | Keep under Git | ✅ (push at week end) | §11 |
| 10 | Run without GUI / auto-close GUI | ✅ | §7 (`--exit-after`) |
| 11 | **True headless mode** | ✅ implemented + gate PASS | §7, [HEADLESS.md](HEADLESS.md) |
| 12 | Which steps need NVIDIA/Vulkan/GPU | ✅ static + runtime | §8, [DEPENDENCY_MAP.md](DEPENDENCY_MAP.md) |
| 13 | CPU-only feasibility per step | ✅ scoped + S2 proven | §9, [CPU_ONLY.md](CPU_ONLY.md) |

---

## 1. What this tool does (plain words)

The tool turns a 3D shape (a tetrahedral mesh) into a clean **hex mesh** through four
steps: `deform → decompose → discretize → hexahedralize`. Week 1 made those steps
runnable from the command line. Week 2 made it **easy to build and proved it works**.
Week 3 added a **true headless mode**, a **runtime GPU dependency map**, the start of a
**CPU-only path**, and a **slim image** + **prebuilt binary**.

**We did not change the original research algorithms** — all of this is new helper files
plus thin, additive wrappers (see §6).

---

## 2. Build

Two supported paths; **the build needs no GPU** (`nvcc` cross-compiles without a
graphics card). Full guide: [BUILD.md](BUILD.md).

### Prerequisites (one-time)
- A Linux machine with **Docker** (for Option A) or the dev toolchain (Option B).
- For *building*: **no GPU needed.**
- The two big library archives at the repo root. Get them with:
  ```bash
  . ./setup.sh        # downloads LibTorch 2.6.0+cu124 and the Vulkan SDK into lib/
  # make the proven Vulkan archive the build expects (one-time):
  tar -C lib -cf - vulkan-sdk-1.3.268.0 | xz -T0 -3 -c > vulkan-sdk-1.3.268.0.tar.xz
  ```

### 2.1 Docker — one self-contained command (recommended)
`Dockerfile.build` COPYs the source and compiles `hex` + evocube inside the image. The
build **fails loudly if either binary is missing** (`compile.sh` was hardened — it
previously masked a failed evocube build; `.dockerignore` no longer strips the `.git`
from libigl's eigen cache that broke evocube's configure). A cold build is **~15–25 min**
(an earlier "~5 min" figure was an incremental/cached run, not from scratch). It is
**multi-stage** with two selectable targets:

| Target | Base | Size | Use |
|---|---|---|---|
| `build` (devel, self-contained) | `cuda:12.4.1-cudnn-devel` | 26.1 GB | full env incl. GUI |
| `runtime` (slim) | `cuda:12.4.1-cudnn-runtime` | **15.2 GB** | run-only (−42%) |

```bash
docker build -f Dockerfile.build --target build   -t hexmesh-cli:latest .   # devel
docker build -f Dockerfile.build --target runtime  -t hexmesh-cli:slim   .   # slim
```

→ Full details, including what's baked in vs. supplied at run time:
[BUILD.md §A2](BUILD.md).

### 2.2 Native (no Docker)
Compile-verified on a **clean Ubuntu 22.04** (CUDA-12.4 toolkit + LibTorch 2.6.0+cu124
+ Vulkan SDK 1.3.268.0). The key extra step (often forgotten) is installing the **CUDA
toolkit** — the compiler `nvcc`, *not* the driver:

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

**End-to-end native run validated** on this host's RTX 4090 (the in-container-built
`hex` runs natively — deform + the other stages — headless, exit 0). Full details +
gaps: [BUILD.md §B](BUILD.md). (Note: you do **not** need a separate cuDNN package —
LibTorch ships its own.)

### 2.3 Prebuilt binary
`hex` (current GUI-sync + headless build) — sha256 `c30d98f0…3d30c0`, 9.1 MB.
Delivery: **Docker image (portable, recommended)** or the bare binary as a GitHub
Release asset (uploaded at week-end with the push). Provenance + exact checksums
are in `SETUP_FROM_SCRATCH.md`; running instructions are in BUILD.md §C. It runs
as-is **only** on a
matching env (CUDA 12.4 + driver ≥550 + LibTorch 2.6.0+cu124 + Vulkan 1.3.268.0).

---

## 3. How to RUN it

You need a machine with an **NVIDIA GPU + driver** (supporting CUDA 12.4) to *run* the
tool — it does the math on the GPU. Builds don't, but runs do.

### 3A. The one-command test (recommended first run)
This runs all four stages on the bundled `spot` model in true headless mode and
checks the result. It needs no X11 authorization, `DISPLAY`, or GLFW window:
```bash
docker run --rm --gpus all \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e HEX_LOCAL=1 \
  -e SMOKE_HEADLESS=1 \
  -v "$(pwd)/output:/space/output" \
  hexmesh-cli:latest ./cli_run/smoke_test.sh
```
**What you should see:** `PASS: valid hex mesh (18526 hexes, 0 inverted)`.
Results are written under `output/runs/spot/`.

> `NVIDIA_DRIVER_CAPABILITIES=all` exposes the GPU driver, `HEX_LOCAL=1` executes
> `hex` directly inside the image, and `SMOKE_HEADLESS=1` avoids all X11/GLFW and
> presentation-queue dependencies. Do **not** mount host Vulkan files.

### 3B. Run a single stage
Same wrapper, one subcommand at a time (file in → results out):
```bash
docker run --runtime=nvidia --gpus all --rm \
  -e DISPLAY=$DISPLAY -e NVIDIA_DRIVER_CAPABILITIES=all -e HEX_LOCAL=1 \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw -v "$(pwd)/output:/space/output" \
  hexmesh-cli:latest \
  ./cli_run/run.sh deform interactive-hex-meshing/assets/tutorial/spot.mesh --exit-after
```
Subcommands: `deform` → `decompose` → `discretize` → `hexahedralize`. Each one's output
HDF5 feeds the next (see §4 and [how_to_run.txt](how_to_run.txt)).

### 3C. Run on a server with NO screen (headless)

**Recommended (Week-3): true `--headless` — no window, no X11, no xvfb.** Use the
`hexmesh-cli:latest` (or `:slim`) image; design + verification in
[HEADLESS.md](HEADLESS.md):
```bash
docker run --gpus all --rm -e NVIDIA_DRIVER_CAPABILITIES=all -e HEX_LOCAL=1 \
  -v "$(pwd)/output:/space/output" hexmesh-cli:latest \
  bash -lc 'SMOKE_HEADLESS=1 ./cli_run/smoke_test.sh'
```

**Legacy stopgap — virtual display (`xvfb`):** still works (it runs the full pipeline
and writes valid metrics), **but `xvfb-run`'s X-server teardown can hang on some
hosts/versions *after* the pipeline finishes** — leaving only `xvfb-run`/`Xvfb` alive so
the final `PASS` may not print even though the run already succeeded (check
`result_metrics.yaml`). Prefer `--headless`; if you must use xvfb, wrap it in `timeout`:
```bash
docker run --gpus all --rm -e NVIDIA_DRIVER_CAPABILITIES=all -e HEX_LOCAL=1 \
  -v "$(pwd)/output:/space/output" hexmesh-cli:latest \
  bash -lc 'apt-get update -qq && apt-get install -y -qq xvfb && \
            timeout 600 xvfb-run -a -s "-screen 0 1280x720x24" ./cli_run/smoke_test.sh'
```

### What "PASS" means
The hard requirement is **`inverted_count: 0`** (no flipped/invalid hex cells) with
`total_hexes > 0`. Exact hex counts and quality scores depend on the model and are
written to `result_metrics.yaml` in the run folder.

---

## 4. Usage + I/O behaviour

Each pipeline stage is one subcommand; I/O is file-based. Details + the full 4-stage
chain: [how_to_run.txt](how_to_run.txt).

```bash
./cli_run/run.sh deform        <input.mesh|.hdf5>  --headless   # Stage 0
./cli_run/run.sh decompose     <stage_0.hdf5>      --headless   # Stage 1
./cli_run/run.sh discretize    <stage_1.hdf5>      --headless   # Stage 2
./cli_run/run.sh hexahedralize <stage_2.hdf5>      --headless   # Stage 3
```

Each stage writes a run dir under `output/runs/<example>/`; the final stage emits
`result.mesh` (MEDIT) + `result_metrics.yaml` (quality summary). Parameters live in the
per-stage YAML in `cli_run/configs/` (copy + edit to tune).

---

## 5. Test cases + verifying after a change

`cli_run/smoke_test.sh` runs all four stages on a tutorial mesh and gates on the result.
Hard pass criterion: **`inverted_count == 0` and `total_hexes > 0`.**

```bash
SMOKE_HEADLESS=1 ./cli_run/smoke_test.sh      # recommended: headless, no display
./cli_run/smoke_test.sh                       # GUI/--exit-after compatibility test
```

**Verified 2026-06-18 (RTX 4090):** PASS, **18 526 hexes, 0 inverted** on `spot.mesh` —
identically via GUI(xvfb), `--headless`, the slim image, and the bare extracted binary
in a matching env it did not build. Quality (scaled-Jacobian) mean ≈ 0.86. After any
code change: rebuild (§2) then run the smoke (§5, `cli_run/smoke_test.sh`); usage and
chaining details live in [how_to_run.txt](how_to_run.txt).

---

## 6. Did we change the original CDM source?

Yes, but **small and additive — no model / optimizer / geometry algorithm was changed.**
Full per-file breakdown + how to regenerate the diff: [SOURCE_CHANGES.md](SOURCE_CHANGES.md).

- Footprint vs the pre-CLI baseline (`d0a904a`): **+1003 / −133 across 34 files**
  (`git -C interactive-hex-meshing diff --stat d0a904a`). It grew over the weeks, all
  additively: +590/−4/18 (W1 CLI) → +682/−33/21 (W3 `--headless` guards) →
  +967/−121/32 (W3 CPU-only) → **+1003/−133/34 (GUI synchronization fix)**.
- Four focused buckets, **no model/optimizer/geometry algorithm changed**:
  (1) new CLI logic isolated in `hex/src/cli/` (script runner + metrics) + thin
  `RunFromScript()` shims that drive the **same** code the GUI buttons do;
  (2) surfaceless-Vulkan `if (!headless)` startup guards (§7);
  (3) the CPU-only device knob (`.cuda()`→`.to(ComputeDevice())`) + CPU branches in the
  two `.cu` kernels that reuse the identical per-element math (§9); and
  (4) a Vulkan acquire-fence fix that keeps the standalone GUI render loop alive.
- Keeps future upstream merges low-risk.

---

## 7. Headless mode (design + status)

`--exit-after` (item #10) opens the GUI window, runs the script, closes it — still needs
a display. **`--headless` (item #11) creates no window / surface / swapchain /
render-pipelines / GUI at all** (surfaceless Vulkan, "design B"): it keeps the Vulkan
*device* (the views still allocate buffers) but never presents, runs the pipeline, and
exits. Implementation is a **startup guard, not a logic rewrite** — confined to 5 startup
files; no stage/optimizer/view code changed. Full design, call-site analysis, and
before/after trace: [HEADLESS.md](HEADLESS.md) §0.

**Metric gate (definition of done) — PASS** (2026-06-18, RTX 4090): full chain via
`--headless` with **no `DISPLAY`** → `total_hexes 18526, inverted_count 0`, identical to
the GUI run.

---

## 8. GPU / Vulkan / CUDA per-stage dependency map (final)

Two **independent** dependencies, often conflated:
- **(V) Vulkan + X11** — only the GUI renderer. Removing it = headless (§7).
- **(C) CUDA** — the actual math (libtorch + 2 geomlib `.cu` kernels). Removing it =
  CPU-only (§9).

Static trace + **runtime evidence** (per-stage `nvidia-smi`, RTX 4090). Full table +
call chains: [DEPENDENCY_MAP.md](DEPENDENCY_MAP.md).

| Stage | peak GPU util | CUDA compute? | CPU-only verdict |
|---|---:|---|---|
| 0 deform | 72 % | yes (libtorch only, no kernel) | cheap (device knob) |
| 1 decompose | 55 % | yes (SDF kernel `PointTetMeshTest`) | needs kernel port |
| 2 discretize | **13 %** | **no** | **runs CPU-only now** |
| 3 hexahedralize | 66 % | yes (projection kernel) | needs kernel port |

Stage 2's low utilisation is the runtime confirmation that it does no CUDA compute
(decisively cross-checked in §9).

### 8.1 Per-stage timing — GPU vs CPU (measured)

Wall-clock of the `hex` process per stage (Vulkan/libtorch init → stage done), headless,
`spot.mesh` (2 332-vertex tet → 18 526 hexes), on this box (RTX 4090 vs `--device cpu`).
Docker container start-up is excluded (≈ equal for both modes). Reproduce with
`./cli_run/smoke_test.sh` (GPU) and `SMOKE_DEVICE=cpu ./cli_run/smoke_test.sh` (CPU).

| Stage | GPU (cuda) | CPU (`--device cpu`) | CPU ÷ GPU |
|---|---:|---:|---:|
| 0 deform | 3.6 s | 9.6 s | 2.7× |
| 1 decompose | 1.5 s | 76.7 s | 51× |
| 2 discretize | 0.6 s | 0.6 s | 1.0× |
| 3 hexahedralize | 2.8 s | 267.7 s | 96× |
| **Total** | **8.5 s** | **354.6 s** | **≈ 42×** |

The timings track the dependency map exactly: **S2** (no CUDA compute) is identical on CPU;
**S0** (libtorch only, no kernel) pays only a modest 2.7×; **S1** and **S3** — the two stages
backed by custom CUDA kernels — blow up to 51× / 96× when forced onto the CPU fallback, which
is precisely why §9 flags those two as needing a kernel port rather than a mechanical device
knob.

---

## 9. CPU-only feasibility + recommended path

Full per-stage verdict, file-level costs, and recommended order: [CPU_ONLY.md](CPU_ONLY.md).

- **S2 discretize — runs CPU-only NOW (proven).** Ran end-to-end on a CUDA-less box
  (software Vulkan via lavapipe) → **18 526 hexes, exit 0, no CUDA op**.
- **S0 deform — after a device knob (~0.5–1 day).** ~39 hard-coded `.cuda()` calls across
  5 files, **all mechanical** (`.cuda()` → `.to(device)`); S0 has no kernel.
- **S1 / S3 — device knob + a CUDA-kernel port.** `point_tet_mesh_test` (S1 SDF) is a
  trivial O(N·T) port (~0.5 day); `generalized_projection` (S3) is a medium O(P·F) port
  (~1.5–2.5 days, per-iteration perf caveat).

**Recommended:** S2 (now) → S0 device knob → S1 kernel → S3 kernel. Minimum-useful CPU
deliverable = S2 + S0; full CPU pipeline ≈ 3–4.5 days more.

---

## 10. What the machine needs (prerequisites)

| To… | You need |
|---|---|
| **Build** (Docker or native) | a Linux box; **no GPU required** |
| **Run** | an **NVIDIA GPU + driver** (supporting CUDA 12.4) and, for the GUI, a screen or `xvfb` (not needed with `--headless`) |

**About the NVIDIA driver:** it is a **host prerequisite, not something we ship.** The
driver is tied to the specific machine's kernel; Docker injects the host's driver into
the container at run time. So we install the CUDA *toolkit/libraries* (for building) but
the *driver* is installed once on the host by the machine owner (e.g.
`sudo ubuntu-drivers autoinstall` + reboot).

---

## 11. Known gaps + what's left

- **Git push (item #9):** all Week-1/2/3 work is committed/staged locally on `cli-runner`
  but **not pushed yet** — by choice, to commit everything in one batch at week's end
  (submodule fork first, then the parent pointer). The bare-binary GitHub Release upload
  happens with that push.
- **CPU-only is not finished, by design** — S2 runs CPU-only today; S0/S1/S3 are a costed
  follow-on (§9), not a one-week deliverable.
- **Slim image GUI:** the slim runtime base omits the full NVIDIA GL stack, so the
  on-screen GUI needs the *devel* image; the slim image is validated for **headless** use
  (CUDA on the GPU, views on software Vulkan). See BUILD.md §A2.6.
- **No remaining GPU-host blockers** — the items Week 2 marked "pending a GPU host" (smoke
  PASS, xvfb, per-stage GPU evidence, native run, slim validation, the headless metric
  gate) are all now measured on the local RTX 4090.

---

## 12. Doc map (where the detail lives)

| Topic | Doc |
|---|---|
| Build (Docker one-step + native + slim) | [BUILD.md](BUILD.md) |
| Usage + examples + I/O | [how_to_run.txt](how_to_run.txt) |
| Test / verify | `cli_run/smoke_test.sh` |
| Original-source change tracking | [SOURCE_CHANGES.md](SOURCE_CHANGES.md) |
| Headless design + status | [HEADLESS.md](HEADLESS.md) |
| GPU/Vulkan/CUDA per-stage map | [DEPENDENCY_MAP.md](DEPENDENCY_MAP.md) |
| CPU-only feasibility + plan | [CPU_ONLY.md](CPU_ONLY.md) |
| Prebuilt binary provenance | `dist/MANIFEST.md` |
| Week-1 report (superseded by this) | [REPORT.md](REPORT.md) |

**Bottom line:** a reader can build (Docker or native), run any stage or the full chain
(GUI or fully headless), verify with one smoke command, see exactly what was changed in
the original source, and understand precisely which steps need the GPU and what a
CPU-only port would cost — all validated on real hardware.
</content>
</invoke>
