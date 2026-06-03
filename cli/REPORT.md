# Week-1 Report — Command-line hex-meshing tool

**Date:** 2026-06-02 · **Branch:** `cli-runner` (parent `DavranDev/cli_hexmeshing`
+ submodule `DavranDev/interactive-hex-meshing`) · **Release:** `cli-runner-v1`

This report is organized as **direct answers to each item in your email**
(Section 2). Section 1 is a one-paragraph summary; Section 3 lists what is done
vs. scheduled for Weeks 2–3; Section 4 lists artifacts. Every factual claim
(diff size, pushed branch, published binary, smoke-test result) was re-verified
on the date above.

---

## 1. Summary

We built a **command-line driver** for the existing CDM ("interactive-hex-meshing")
pipeline — one subcommand per stage, `deform → decompose → discretize →
hexahedralize` — and got **all four stages running and validated end-to-end**
from a single raw tet mesh, with quality metrics exported automatically. Along
the way we found and fixed a real **Stage-1 (decomposition) headless bug** (the
optimized polycube was being discarded). We wrote build / usage / test /
change-tracking docs and a one-command smoke test, pushed everything to the
`cli-runner` branch on both repos, and published the prebuilt binary as a GitHub
Release asset.

**Validation:** the full chain runs end-to-end on the tutorial meshes that ship
with the CDM source (`interactive-hex-meshing/assets/tutorial/` — `bob`, `bunny`,
`horse`, `rockerArm`, `spot`, `kitten.vtk`). The pass gate is **0 inverted
hexes** (a hard requirement), checked automatically by `cli/smoke_test.sh`, which
prints `PASS`. Exact hex counts and scaled-Jacobian values are model-dependent
and written per run to `result_metrics.yaml` — they'll be captured live on the
demo mesh.

> **One honest caveat up front:** the tool today still opens the Vulkan GUI
> window, runs the stage, and closes it (with `--exit-after`). It is *scripted
> GUI automation*, not yet a *true headless* CLI. A real no-GUI mode and the
> GPU/CPU dependency analysis are scoped for Weeks 2–3 (Section 3).

---

## 2. Answers to your questions

### Q1 — A from-scratch download & build guide: Docker *and* non-Docker, and possibly a single self-contained Dockerfile

**Where:** [BUILD.md](BUILD.md). It documents **two paths** plus a note on the
third option you suggested.

**(a) Docker path — DONE and verified.** This is what we test against. Five steps
from a clean machine:
```bash
git clone --recurse-submodules https://github.com/DavranDev/cli_hexmeshing.git
cd cli_hexmeshing
. ./setup.sh          # downloads LibTorch 2.6.0+cu124 + Vulkan SDK 1.3.268.0, builds the docker-hexmesh image
. ./run_docker.sh     # interactive shell inside the image
. /space/compile.sh   # builds evocube + the hex binary  ->  interactive-hex-meshing/bin/Release/hex
./cli/smoke_test.sh   # sanity-check: PASS = valid hex mesh, 0 inverted
```

**(b) Native / non-Docker path — DOCUMENTED, not yet fully verified.**
[BUILD.md](BUILD.md) §B lists the host packages, the LibTorch/Vulkan downloads,
and the `cmake` build for evocube + hex without a container. It is derived from
the `Dockerfile` + `compile.sh`, but we have **not yet verified it end-to-end on
a clean host** — that verification is a **Week-2** task (it needs an as-clean-as-
possible machine to be trustworthy). It is labelled experimental in the doc so no
one is misled.

**(c) A single self-contained Dockerfile that builds the updated source in one
step — NOT done yet; scheduled for Week 2.** Today the build is: prebuilt
`docker-hexmesh` *environment* image + host source mounted + `compile.sh`. The
goal you described — one Dockerfile that `COPY`s/clones the updated source,
installs all deps, compiles, and yields a ready-to-run image — is a clean Week-2
deliverable, not a Week-1 requirement (the current path already reproduces the
build). It is on the plan with every step to be documented.

### Q2 — Make sure everything is well documented (for the report)

**DONE.** The CLI ships a complete, report-grade doc set, all under `cli/`:

| Doc | Purpose |
|---|---|
| [REPORT.md](REPORT.md) | this report — answers to your questions |
| [BUILD.md](BUILD.md) | from-scratch build, Docker + native + prebuilt-binary paths |
| [USAGE_AND_TESTS.md](USAGE_AND_TESTS.md) | simplest usage, the test case, verify-after-edit |
| [SOURCE_CHANGES.md](SOURCE_CHANGES.md) | exactly what changed in the original CDM source |
| [README.md](README.md) | full reference: subcommands, I/O layout, YAML parameter schema |
| [../PIPELINE_NOTES.md](../PIPELINE_NOTES.md) | the underlying 4-stage CDM pipeline |

Anything from these can be lifted directly into the larger report.

### Q3 — If you compiled it successfully, provide the executable binary

**DONE.** The binary is built (`interactive-hex-meshing/bin/Release/hex`) and
**published as a GitHub Release asset** so you can run it without recompiling:

- **Release:** `cli-runner-v1` on `DavranDev/cli_hexmeshing`
- **Download:** `https://github.com/DavranDev/cli_hexmeshing/releases/download/cli-runner-v1/hex`
  *(verified live on 2026-06-02: asset `hex`, 8.40 MB, URL resolves)*

Drop it into `interactive-hex-meshing/bin/Release/` and drive it with
`cli/run.sh` (see [BUILD.md](BUILD.md) §C).

**Important — it only runs in a matching environment.** Because it's a
dynamically linked CUDA/LibTorch/Vulkan binary, it needs:
- the `docker-hexmesh` image (or a host with the same libraries),
- an NVIDIA driver supporting **CUDA 12.4**, **LibTorch 2.6.0+cu124**, **Vulkan
  SDK 1.3.268.0**,
- an **X11 display** (`DISPLAY` set) — it opens a Vulkan window.

If your environment matches ("same system environment"), you can run it directly.
If it differs at all, build from source (Q1) — that's the robust path.

### Q4 — Simplest usage examples, the test cases to run, and how to verify after the code is modified

**DONE.** Full detail in [USAGE_AND_TESTS.md](USAGE_AND_TESTS.md); the essentials:

**Simplest usage** — one subcommand per stage, file in → run directory out:
```bash
./cli/run.sh deform         <input.mesh|.hdf5>  --exit-after   # Stage 0
./cli/run.sh decompose      <stage_0.hdf5>      --exit-after   # Stage 1
./cli/run.sh discretize     <stage_1.hdf5>      --exit-after   # Stage 2
./cli/run.sh hexahedralize  <stage_2.hdf5>      --exit-after   # Stage 3
```

**Full chain on a tutorial mesh:**
```bash
M=interactive-hex-meshing/assets/tutorial/spot.mesh
./cli/run.sh deform        "$M" --exit-after
./cli/run.sh decompose     output/runs/spot/deformation_*/stage_0_deformation.hdf5     --exit-after
./cli/run.sh discretize    output/runs/spot/decomposition_*/stage_1_decomposition.hdf5 --exit-after
./cli/run.sh hexahedralize output/runs/spot/discretization_*/stage_2_discretization.hdf5 --exit-after
```
Inputs ship in `interactive-hex-meshing/assets/tutorial/` (`bob`, `bunny`,
`horse`, `rockerArm`, `spot`, `kitten.vtk`).

**The test case — pass/fail criteria.** Run everything in one command:
```bash
./cli/smoke_test.sh        # PASS = valid hex mesh, 0 inverted (defaults to spot.mesh)
```

| Check | Expected |
|---|---|
| All four stages exit 0 | yes |
| `result.mesh` produced | yes (vertex/hex counts depend on the model + `hex_size`) |
| `total_hexes` | **> 0** |
| `inverted_count` | **0** — hard requirement; any inversion = FAIL |

The exact hex count and scaled-Jacobian values are model-dependent and the
optimizers are stochastic, so they vary per run/mesh; they're written to
`result_metrics.yaml` and echoed by the smoke test. The pass gate is
**0 inverted hexes**, not specific values — record the numbers for the mesh you
demo.

**How to verify after you modify the code** — the same loop every time:
1. Rebuild: `. /space/compile.sh` (inside the container).
2. Run the smoke test: `./cli/smoke_test.sh`.
3. Confirm it prints `PASS` (`inverted_count == 0`, `total_hexes > 0`).

`smoke_test.sh` also accepts any other Stage-0 tet mesh
(`./cli/smoke_test.sh interactive-hex-meshing/assets/tutorial/bunny.mesh`); the
0-inverted gate still applies.

### Q5 — Did Claude modify the original CDM source? If so, track every change; keep it under Git

**Yes — the original source *was* modified, but the changes are small and
purely additive, and they are all tracked under Git.** Full detail in
[SOURCE_CHANGES.md](SOURCE_CHANGES.md).

**No model, optimizer, or geometry algorithm was changed.** Every stage gained a
thin public `RunFromScript()` that calls the **same** methods the GUI buttons
already call. The whole CLI effort vs. the pre-CLI baseline (`d0a904a`) is
**18 files, +590 / −4 lines** — re-verified today with
`git -C interactive-hex-meshing diff --stat d0a904a..HEAD`.

**Two repos, two kinds of change:**
- **Parent repo (`cli_hexmeshing`)** — *pure addition*: a new `cli/` folder
  (`run.sh`, YAML configs, docs, `smoke_test.sh`). No original host script
  (Docker/build) was rewritten. (`compile.sh` got a 5-line robustness tweak only:
  `mkdir -p build`, export `Torch_DIR` directly, pass `-DTorch_DIR` to cmake —
  same image, same outputs.)
- **CDM submodule (`interactive-hex-meshing`)** — new files + thin shims:

*New files (where the new logic lives):*
| File | Lines | Purpose |
|---|---|---|
| `hex/src/cli/PipelineScriptRunner.cpp` | +200 | parse YAML, load input, dispatch stages, save HDF5s, export mesh/metrics |
| `hex/src/cli/PipelineScriptRunner.h` | +29 | runner declaration |
| `hex/src/cli/MetricsDumper.cpp` | +77 | scaled-Jacobian/Jacobian + inverted count → `result_metrics.yaml` |
| `hex/src/cli/MetricsDumper.h` | +14 | declaration |

*Modified original files (thin additive shims):*
| File | Δ | Change |
|---|---|---|
| `controllers/stages/HexahedralizationStage.{cpp,h}` | +62 | `RunFromScript()` + mesh/metrics export |
| `controllers/stages/DecompositionStage.{cpp,h}` | +76/−4 | `RunFromScript()` **+ the headless fix** (write optimized polycube back) |
| `controllers/stages/DeformationStage.{cpp,h}` | +50 | `RunFromScript()` |
| `controllers/stages/DiscretizationStage.{cpp,h}` | +27 | `RunFromScript()` |
| `main.cpp` | +32 | parse `--script` / `--exit-after` |
| `controllers/GlobalController.{cpp,h}` | +17 | public Open/Save/Export accessors |
| `optim/PolycubeOptimizer.h` | +8/−2 | expose `GetOptimizedPolycube()` (for the fix) |
| `HexMeshingApp.h` | +1 | `GetGlobalController()` accessor |
| `hex/CMakeLists.txt` | +1 | glob `src/cli/*.cpp` |

Only **4 lines were ever deleted** (a visibility move + a no-op revert), so the
existing source is essentially intact — this keeps future upstream merges
low-risk.

**The one behavioral fix:** in headless mode the Stage-1 optimized polycube was
being discarded (the GUI writes it back each frame via `Update()`); we now write
it back after the optimizer thread joins. This makes the headless path match what
the GUI already did — it does **not** change the algorithm.

**Kept under Git — verified.** Both the source changes and the wrapper are
committed on the `cli-runner` branch and **pushed** (the remote `cli-runner` tip
equals local `HEAD`, `e1a8206`, confirmed via `git ls-remote`). A fresh
`git clone --recurse-submodules` checks out the exact reviewed state, submodule
included. So you can always see precisely which files changed as we keep
developing.

---

## 3. What's done vs. scheduled (Weeks 2–3)

**Done now (Week 1):**
- CLI driver, all four stages, validated end-to-end (0 inverted hexes).
- The Stage-1 decomposition fix.
- Full doc set + one-command smoke test.
- Docker build (verified), native build instructions (written), prebuilt binary
  published, all changes tracked + pushed.

**Not done yet — explicitly scheduled (every remaining email item is on the
plan, see `small_plan.txt`):**

| Item from your email | Status | When |
|---|---|---|
| Self-contained one-step Dockerfile (builds updated source) | not started | **Week 2** |
| Native / non-Docker build — *verified* on a clean host | written, unverified | **Week 2** |
| True no-GUI **headless** mode (drop the Vulkan window) | scoped only | **Week 2** scope → **Week 3** impl/design |
| Which steps need NVIDIA / Vulkan / GPU, and which can be **CPU-only** | preliminary analysis only | **Week 2** start → **Week 3** final per-stage map |
| Consolidated final report | this is the Week-1 version | **Week 3** assembly |

Preliminary finding for the GPU question (to be confirmed): **Vulkan + X11 are
only the GUI renderer; the pipeline math uses CUDA/LibTorch + custom `.cu`
kernels.** So "remove NVIDIA/Vulkan" is really two separate questions — (a) drop
Vulkan/X11 → headless (looks tractable), and (b) drop CUDA → CPU-only (larger
effort; Stage 2 discretization is the strongest CPU-only candidate).

---

## 4. Artifacts

- **Branch:** `cli-runner` on both repos (not `main`) — pushed and verified.
- **Prebuilt binary:** Release `cli-runner-v1` →
  `https://github.com/DavranDev/cli_hexmeshing/releases/download/cli-runner-v1/hex`
  (8.40 MB; runs only in the matching CUDA 12.4 / LibTorch 2.6.0+cu124 /
  Vulkan 1.3.268.0 environment — see [BUILD.md](BUILD.md) §C).
- **Docs:** [BUILD.md](BUILD.md) · [USAGE_AND_TESTS.md](USAGE_AND_TESTS.md) ·
  [SOURCE_CHANGES.md](SOURCE_CHANGES.md) · [README.md](README.md).
- **One-command verify:** `./cli/smoke_test.sh` → `PASS`.
- **Forward plan:** `small_plan.txt` (Weeks 1–3, with a coverage check that every
  email item is scheduled).
