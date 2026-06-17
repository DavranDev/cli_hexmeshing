# Week-2 Update — Command-line hex-meshing tool

**Date:** 2026-06-16 · **Branch:** `cli-runner` (parent `DavranDev/cli_hexmeshing`;
the CDM submodule is **unchanged this week**) · Follows the Week-1
[REPORT.md](REPORT.md).

This update is organized as **the four Week-2 deliverables (T1–T4)**, then what
rolls to Week 3.

> **GPU validation (added 2026-06-17):** the dev box now has a working NVIDIA driver
> (RTX 4090, 580.159.03), so the GPU run-tests that were pending are **done**: the
> self-contained image's full smoke test **PASSES — 18 526 hexes, 0 inverted**, the
> `xvfb` headless run PASSES with no display, and per-stage GPU utilization was
> measured (deform 76% / decompose 57% / discretize 28% / hexahedralize 68%). Running
> the test also surfaced and fixed a real shell bug in `run.sh`'s in-container path
> (a `set -u` trip on the Vulkan `setup-env.sh`).

---

## 1. Summary

All four Week-2 items are delivered. The biggest is a **one-step, self-contained
Dockerfile** that compiles the updated source into a ready-to-run image (no host
mount, no manual `compile.sh`). Alongside it: a **headless feasibility memo** that
pins down exactly what a `--headless` mode needs (and shows `xvfb-run` works as a
stopgap today), a **per-stage GPU/CUDA dependency map** with the Vulkan-vs-CUDA
split made concrete, and a **compile-verified native (non-Docker) build** on a
clean `ubuntu:22.04`. All changes are additive — **no CDM model/optimizer/geometry
algorithm was touched** (the submodule has zero source changes this week).

---

## 2. The four deliverables

### T1 — Self-contained Dockerfile  ✅ built & smoke-verified on GPU

A new `Dockerfile.build` (+ `.dockerignore`) compiles evocube + `hex` *inside* the
image from the checked-out source. A reviewer needs **two commands**, never
touching `compile.sh`:
```bash
docker build -f Dockerfile.build -t hexmesh-cli:week2 .
docker run --runtime=nvidia --gpus all --rm \
  -e DISPLAY=$DISPLAY -e NVIDIA_DRIVER_CAPABILITIES=all -e HEX_LOCAL=1 \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw -v "$(pwd)/output:/space/output" \
  hexmesh-cli:week2 ./cli_run/smoke_test.sh        # PASS = 0 inverted
```
- **Built + verified:** ~5 min, ~26 GB image; `ldd hex` clean; the full smoke test
  **PASSES on the RTX 4090 — 18 526 hexes, 0 inverted** (both with X11 and via `xvfb`).
  The in-container runner is `HEX_LOCAL=1`, an additive branch in `run.sh` (default
  docker behavior unchanged) that renders configs and execs `hex` directly.
- **GPU is build-free, run-bound:** the build needs no GPU (`nvcc` cross-compiles);
  a GPU + Vulkan are needed only at `docker run`.
- **Verified-fix found:** the repo's `vulkansdk.tar.xz` is the **wrong Vulkan
  version (1.4.341.1)**; the build uses the proven **1.3.268.0**.
- Details: [BUILD.md](BUILD.md) §A2 (baked-in vs mounted, the two-stage slimming
  that's deferred until it can be GPU-validated).

### T2 — Headless feasibility memo  ✅ memo delivered (no source changed)

[HEADLESS.md](HEADLESS.md). Headline: a true `--headless` mode is a **guarding /
startup change, not a logic rewrite**.
- **Every script-path view call is display-only (class a).** The only "view that
  does real work" (class b) was the **already-fixed** Stage-1 polycube writeback;
  the Discretization `pending_view_` block the plan flagged is **mouse-only** (never
  runs headless). Compute is libtorch/CUDA, independent of the Vulkan device.
- **xvfb result (verified on GPU 2026-06-17):** `xvfb-run ./cli_run/smoke_test.sh`
  with **no `DISPLAY`** runs the whole pipeline → **PASS, 18 526 hexes, 0 inverted**.
  So the headless-via-virtual-display stopgap (design C) works **today**, zero code
  changes. (Before the driver was installed it stopped at `vkCreateInstance: Found no
  drivers!` — confirming Xvfb covers the *display* half and only the GPU/ICD was missing.)
- **Effort:** C `xvfb-run` (0 LOC, now) → B surfaceless-Vulkan `--headless`
  (~4–5 startup files, stages untouched, ~2–3 days) → A no-Vulkan CUDA-only
  (~6–8 files, ~1–1.5 wks, fold into CPU-only work).
- **Prototype deferred on purpose:** it's only "done" when the smoke test still
  gives 0 inverted, which needs a GPU we don't have — so memo + estimate now,
  prototype in Week 3.

### T3 — Dependency map, part 1  ✅ static map delivered

[DEPENDENCY_MAP.md](DEPENDENCY_MAP.md). The two questions, kept separate:
- **(V) Vulkan/X11 = display-only** for all four stages.
- **(C) CUDA splits cleanly:** **Stage 2 discretize = CPU-only now** (combinatorial,
  zero direct *or transitive* CUDA — confirmed); **Stage 0 deform = CPU-cheap**
  (libtorch `.cuda()` only, no kernel); **Stages 1 & 3 = kernel-port-needed** (the
  two CUDA-only geomlib kernels — `PointTetMeshTest`/SDF for stage 1,
  `GeneralizedProjection` for stage 3; neither has a CPU variant).
- **Crux:** ~40 hard-coded libtorch `.cuda()` (mechanical to move; no device knob
  today) vs. 2 `.cu` kernels (the real gate). Fact-check: `kCUDA`/`.cuda()` lives in
  **5** hex/src files, not 6 (`torch_utils.cpp` is CPU helpers). Per-stage
  `nvidia-smi` runtime evidence (measured 2026-06-17) corroborates the split — peak
  GPU util **deform 76% / decompose 57% / hexahedralize 68%** vs **discretize 28%**
  (the CPU-compute outlier).

### T4 — Native (non-Docker) build  ✅ compile-verified (runtime needs a driver)

[BUILD.md](BUILD.md) §B, upgraded from "written, unverified" to **compile-verified
on a clean `ubuntu:22.04` container (2026-06-16)** — evocube and `hex` both build.
- **The gap that was missing from the doc:** the CUDA 12.4 toolkit install
  (`cuda-keyring` → `cuda-toolkit-12-4`, **toolkit only — not the `cuda`
  metapackage**, which pulls the driver) + `PATH=/usr/local/cuda/bin`. Now in §B.
- **No system cuDNN needed** — LibTorch ships its own `libcudnn.so.9`. evocube needs
  no CUDA (OpenMP only). geomlib pins `CMAKE_CUDA_ARCHITECTURES=75`.
- **Runtime not verified** (needs an NVIDIA driver; a GPU-less container can't) —
  stated as a known gap, with the full gaps list in §B.4. Finished well under the
  3-hour timebox.

---

## 3. What rolls to Week 3

| Item | Why it's Week 3 |
|---|---|
| ~~Run-validate T1/T2 on a GPU host~~ **DONE 2026-06-17** | Docker smoke (X11 + `xvfb`) PASS, 18 526 hexes / 0 inverted; per-stage GPU util measured. *(Only the bare-metal native-binary run on GPU is still unexercised — same binary, lower priority.)* |
| **True headless impl** | prototype design B (`--headless`, surfaceless Vulkan) and gate it on the smoke-test metric diff |
| **Dependency map part 2** | ~~per-stage runtime evidence~~ (done); scope the device-knob refactor + the two kernel ports |
| **CPU-only feasibility** | Stage 2 first (CPU-now), then cost the libtorch knob (Stage 0) and the geomlib kernel ports (Stages 1 & 3) |
| **Two-stage image slimming** | shrink the 26 GB image once a GPU host can validate the slim runtime stage |
| **Consolidated report** | fold Week-1 + Week-2 docs into one report-ready document |

---

## 4. Artifacts (all on `cli-runner`, parent repo)

- **One-step build:** `Dockerfile.build`, `.dockerignore`; [BUILD.md](BUILD.md) §A2.
- **Headless memo:** [HEADLESS.md](HEADLESS.md).
- **Dependency map:** [DEPENDENCY_MAP.md](DEPENDENCY_MAP.md).
- **Native build, compile-verified:** [BUILD.md](BUILD.md) §B.
- **In-container runner:** additive `HEX_LOCAL=1` branch in `cli_run/run.sh`
  (default docker path unchanged).
- **Security:** `github_token.txt` moved out of the working tree + `.gitignore` guard.
- **Note:** the CDM submodule has **no source changes** this week — Week-2 work is
  entirely parent-repo docs + build tooling.
