# GPU / Vulkan / CUDA dependency map (final — static + runtime)

Replaces the old §4B *hypothesis* (in `small_plan.txt`) with an **evidence-backed**
map of what each pipeline stage actually depends on. Paths are relative to the CDM
submodule (`interactive-hex-meshing/`); line numbers are from the `cli-runner`
branch. **Both passes are now done:** part 1 = static source trace (§§2–5); part 2 =
per-stage **runtime** `nvidia-smi` evidence on the RTX 4090 (§4). No "pending" cells
remain. The CPU-only cost (device knob + kernel ports) is scoped in
[CPU_ONLY.md](CPU_ONLY.md).

> **Update (2026-08-03): CUDA is no longer a compile-time dependency.** Everything
> below describes what the code *uses* at runtime, and that is unchanged. What
> changed is that all of it is now behind a build option: `-DHEX_ENABLE_CUDA=OFF`
> (via `./setup.sh --cpu`) compiles the two `.cu` kernels out of the build
> entirely, so the shipped image contains no CUDA toolkit, no CUDA headers and no
> CUDA-linked object. Read the table below as "the CUDA surface that the option
> switches off", not as "things you must install". See
> [CPU_ONLY.md](CPU_ONLY.md) §6.
>
> Note that **Vulkan is not part of this**: it is a *renderer* dependency that
> survives in the CPU-only build, satisfied in software by Mesa lavapipe.
> Removing Vulkan from the build is a separate piece of work.

---

## 1. The two questions (keep them separate)

"Does this need NVIDIA?" is really **two** independent questions:

- **(V) Vulkan + X11 / display** — used **only** to render the GUI window. The
  pipeline math never calls the Vulkan device. Removing it = *headless* (see
  [HEADLESS.md](HEADLESS.md)). Verdict from the T2 trace: **display-only for every
  stage.**
- **(C) CUDA** — used for the actual math: **libtorch** CUDA tensors (the
  optimizers) + **2 custom geomlib `.cu` kernels**. Removing it = *CPU-only*, and
  it splits cleanly per stage. This document is about (C).

These are orthogonal: a stage can be headless-ready but still CUDA-bound.

---

## 2. Method + fact-check of the prior claims

For each stage I followed `RunFromScript()` (the only code the CLI runs — the GUI
buttons call the same private methods) into `optim/`, `models/`, and `geomlib/`,
and recorded every GPU touch. While doing so I re-checked the plan's "what we
already know" list:

| Prior claim | Verdict |
|---|---|
| Only 2 project CUDA kernels (`generalized_projection_cuda.cu`, `point_tet_mesh_test_cuda.cu`) | ✅ confirmed (the other `.cu` files are vendored Eigen tests) |
| `kCUDA`/`.cuda()` in 6 `hex/src` files | ⚠️ **5, not 6** — `optim/torch_utils.cpp` has **no** CUDA (it's CPU-side `Matrix*ToTensor` helpers; callers append `.cuda()`). The real five: `optim/CubicVolumetricDeformer.cpp`, `optim/PolycubeOptimizer.cpp`, `optim/HexComplexDeformer.cpp`, `models/TetrahedralMesh.cpp`, `controllers/stages/HexahedralizationStage.cpp` |
| Stage 2 (discretize) has no direct CUDA | ✅ confirmed — and **no transitive CUDA either** (see §5) |

---

## 3. The crux: 2 CUDA-only kernels vs. ~40 libtorch `.cuda()` calls

There are two *qualitatively different* CUDA dependencies, and the CPU-port cost
is completely different for each:

**(A) libtorch CUDA tensors — *cheap* to move to CPU.** ~40 hard-coded `.cuda()`
calls across the 5 files. They are plain tensor placements; CPU mode is mechanical
(`.cuda()` → `.to(device)` behind one device knob). **There is no device knob
today** — every `.cuda()` is hard-coded, and the only `torch::Device` member
(`PolycubeOptimizer.h:84`, set `device_{torch::kCUDA}` at `PolycubeOptimizer.cpp:23`)
is itself hard-wired to CUDA. So step 1 of any CPU effort is "introduce a device
setting and route the `.cuda()` calls through it" — tedious but no algorithm change.

**(B) 2 geomlib `.cu` kernels — *kernel port needed*.** Each is declared as a
single CUDA-backed function with **no CPU overload**:
- `geomlib::PointTetMeshTest(points, vertices, tets)` — `point_tet_mesh_test.h:7`,
  impl `point_tet_mesh_test_cuda.cu`. Inside/outside test driving the **SDF /
  distance field**.
- `geomlib::ComputeGeneralizedTriangleProjection` / `...TetrahedronProjection` —
  `generalized_projection.h:9,13`, impl `generalized_projection_cuda.cu`. The
  surface/volume **projection** used as the deformation loss + Hausdorff metric.
- `geomlib::ComputeHausdorffDistance` (`hausdorff_distance.cpp`) is built on the
  projection kernel and `assert`s `is_cuda()` (`hausdorff_distance.cpp:10-11`) — so
  it is CUDA-only by construction.

A CPU pipeline must port (B) (or route around it); (A) is comparatively easy.

---

## 4. Per-stage table

| Stage | CUDA touches (`file:line`) | Vulkan (V) | Runtime GPU evidence (peak util) | CPU-only verdict |
|---|---|---|---|---|
| **0 deform** | libtorch only: `CubicVolumetricDeformer.cpp:19-56` (8× `.cuda()`). **No geomlib kernel, no SDF.** | display-only (views) | **72% — CUDA-active** | **cheap** — libtorch device knob; no kernel |
| **1 decompose** | `TetrahedralMesh.cpp:156-158` `PointTetMeshTest` **(kernel B)** via `CreateDistanceField`→`ComputeDistanceFieldGPU`; re-called in opt loop `PolycubeOptimizer.cpp:285,342`. + libtorch `CreateAnchors` `TetrahedralMesh.cpp:92,106,108`, `PolycubeOptimizer.cpp:23,106,238` | display-only (views) | **55% — CUDA-active** | **kernel-port-needed** — SDF kernel is CUDA-only & on the hot path |
| **2 discretize** | **none** (direct or transitive — §5) | display-only (views) | **13% — no CUDA compute** (≈ launch transient) | **now** — combinatorial; **proven CPU-only** (see below) |
| **3 hexahedralize** | `HexComplexDeformer.cpp:101` `GeneralizedTriangleProjection` **(kernel B)** + 15× `.cuda()`; `HexahedralizationStage.cpp:592` `GeneralizedTetrahedronProjection` (pullback); `:544` `ComputeHausdorffDistance` (CUDA-only metric), `:534-542,594-596` `.cuda()` | display-only (views) | **66% — CUDA-active** (883 MiB CUDA) | **kernel-port-needed** — projection kernel is CUDA-only |
| *shared* | `models/TetrahedralMesh.cpp` (anchors + SDF, used by stage 1); `optim/torch_utils.cpp` = **CPU** tensor helpers (not CUDA) | — | — | — |

Vulkan column is identical for all stages by design — the renderer is display-only
(full call-site classification in [HEADLESS.md](HEADLESS.md) §4).

**Runtime evidence (re-measured 2026-06-18, RTX 4090 + driver 580.159.03, full chain
on `spot.mesh`, `--headless`).** Each stage ran in its own `hex` process while
polling `nvidia-smi` every 100 ms for both `utilization.gpu,memory.used` and
per-process `--query-compute-apps`. Idle baseline 3 % / 323 MiB.

| Stage | peak util | peak GPU mem (global) | per-proc CUDA mem | wall | CUDA compute? |
|---|---:|---:|---:|---:|---|
| 0 deform | **72 %** | 1070 MiB | 69 MiB | 4.2 s | yes |
| 1 decompose | **55 %** | 1035 MiB | 81 MiB | 1.9 s | yes |
| 2 discretize | **13 %** | 531 MiB | 69 MiB | 1.1 s | **no** |
| 3 hexahedralize | **66 %** | 1342 MiB | 883 MiB | 3.4 s | yes |

**Reading it.** Utilization is the discriminator: deform/decompose/hexahedralize sit
at **55–72 %** (CUDA-active), while **discretize peaks at 13 %** — barely above idle,
and its actual discretization is ~11 ms of CPU work (log timestamps). The honest
caveats: (a) a small (~69 MiB) CUDA *context* shows up even for discretize — that is
`torch::manual_seed(42)` at startup seeding the CUDA RNG **when a GPU is visible**,
**not** stage compute (on a driverless box no context is created and S2 still runs —
next paragraph); (b) the Vulkan renderer here runs on the **same** NVIDIA GPU, so
some of every stage's util/mem is display, not CUDA; (c) optimizers are stochastic,
so values are indicative.

**Decisive S2 proof (cross-check).** Discretize was also run on a **CUDA-less box**
(no NVIDIA driver; software-Vulkan via lavapipe) and completed identically —
**18 526 hexes, exit 0, no CUDA op** ([CPU_ONLY.md](CPU_ONLY.md) §1). Any `.cuda()`
would have thrown there, so S2 is conclusively **CPU-only**. The full chain also
passes end-to-end on the GPU headless (**18 526 hexes, 0 inverted** —
[HEADLESS.md](HEADLESS.md) §0 / T1.6).

---

## 5. Per-stage call chains (evidence)

**Stage 0 — Deformation.** `DeformationStage::RunFromScript`
→ `PrepareVolumetricDeformation` + `Reoptimize` → `CubicVolumetricDeformer::Optimize`.
All GPU use is libtorch tensor placement (`CubicVolumetricDeformer.cpp:19-56`).
It does **not** call any geomlib kernel and does **not** touch the SDF/anchors
(confirmed: no `CreateDistanceField`/`CreateAnchors` in `DeformationStage.cpp`).
→ *libtorch-only ⇒ CPU is a device-knob change.*

**Stage 1 — Decomposition.** `DecompositionStage::RunFromScript`
→ `CreateSdfAndAnchors` → `TetrahedralMesh::CreateAnchors` (libtorch, `:92,106,108`)
+ `CreateDistanceField` → `ComputeDistanceFieldGPU` → `geomlib::PointTetMeshTest`
(`TetrahedralMesh.cpp:156-158`, **kernel B**); then `SuggestNewCuboid`×N +
`Reoptimize` → `PolycubeOptimizer` which keeps the SDF on device
(`PolycubeOptimizer.cpp:106`) and **re-evaluates the kernel every iteration**
(`:285,342` `ComputeDistanceFieldGPU`). → *blocked on the PointTetMeshTest kernel.*

**Stage 2 — Discretization.** `DiscretizationStage::RunFromScript`
→ `DiscretizePolycube` (`PolycubeGraph`, `GenerateQuadComplex`, `ExtractQuadMesh`)
+ `FinalizePolycube` (`GenerateHexComplex`). Grep over `PolycubeGraph`,
`QuadComplex`, `HexComplex`, `QuadrilateralMesh`, `HexahedralMesh`, `Polycube`:
**no `.cuda()`, no `kCUDA`, no geomlib kernel.** → *CPU-only today.*

**Stage 3 — Hexahedralization.** `HexahedralizationStage::RunFromScript`
→ `InitTargetComplex` (→ `PullPolycubeVolumeBack`, `geomlib::GeneralizedTetrahedronProjection`
at `:592`) + `PrepareHexDeformation`/`OptimizeHexDeformation` → `HexComplexDeformer`
(`geomlib::GeneralizedTriangleProjection` at `HexComplexDeformer.cpp:101`, 15×
`.cuda()`). `UpdateOnTargetComplexChange` also runs `ComputeHausdorffDistance`
(`:544`, CUDA-only metric). → *blocked on the generalized-projection kernel.*

---

## 6. Summary + what rolls to Week 3

**V-vs-C in one line:** Vulkan/X11 is display-only for all four stages (drop it →
headless); CUDA splits as **Stage 2 = CPU-now, Stages 0 = CPU-cheap (libtorch
knob), Stages 1 & 3 = need a CUDA-kernel port** (SDF `PointTetMeshTest` for stage
1; `GeneralizedProjection` for stage 3). So a CPU pipeline is *Stage 2 immediately,
Stage 0 with a device knob, and a costed kernel-port for 1 & 3* — exactly the order
to tackle it.

**Week-3 follow-ups — all now resolved:**
- ✅ **Runtime evidence (part 2)** — per-stage `nvidia-smi` measured on the RTX 4090
  (§4 table); corroborates the static map (stage 2 clearly the lowest, 13 %).
- ✅ **libtorch device-knob scope** — the ~39 `.cuda()` calls are counted + classified
  (all mechanical) in [CPU_ONLY.md](CPU_ONLY.md) §2.
- ✅ **CPU port of the two geomlib kernels** — scoped (CPU_ONLY.md §3) and now
  **IMPLEMENTED + validated** (CPU_ONLY.md §5): `--device cpu` runs the whole
  pipeline with no NVIDIA GPU (18 526 hexes, 0 inverted). Ties into
  [HEADLESS.md](HEADLESS.md) design A (no-Vulkan) since both remove GPU dependence.
