# CPU-only feasibility — per-stage verdict + costed plan

**Question (Ronald #13):** can the pipeline run without an NVIDIA GPU, and how much
work is each stage? This document answers it per stage: what runs CPU-only **now**,
what needs a small **device knob**, and what needs a **CUDA-kernel port** — with
file-level effort estimates and a recommended path.

It builds on the static GPU map ([DEPENDENCY_MAP.md](DEPENDENCY_MAP.md)) and the
headless work ([HEADLESS.md](HEADLESS.md) §0). **No pipeline source was changed for
this document** — §1 is an empirical run, §§2–3 are a costed scope.

---

## 0. TL;DR

| Stage | CPU-only status | What it takes |
|---|---|---|
| **S2 discretize** | ✅ **runs CPU-only NOW** (proven, §1) | nothing — zero CUDA in the stage |
| **S0 deform** | 🟡 after the **device knob** | ~8 mechanical `.cuda()`→`.to(device)`; **no kernel** |
| **S1 decompose** | 🟠 device knob **+ 1 kernel port** | port `point_tet_mesh_test` (SDF sign) — **trivial** |
| **S3 hexahedralize** | 🔴 device knob **+ 1 kernel port** | port `generalized_projection` (nearest-face) — **medium**, perf risk |

**Two independent axes, do not conflate** (same split as HEADLESS.md):
- **(C) CUDA compute** — libtorch `.cuda()` + the two geomlib `.cu` kernels. This is
  what "CPU-only" is about and what §§2–3 cost.
- **(V) Vulkan device** — the view objects still construct against a Vulkan device
  even headless (LEVEL 1). On a box with no NVIDIA GPU this is satisfied by a
  **software Vulkan ICD (Mesa lavapipe / llvmpipe)** — see §1. Removing Vulkan
  *entirely* is LEVEL 2 / "design A" (HEADLESS.md §6), a separate, larger refactor,
  **not** required for CPU compute.

**Recommended path:** S2 (now) → **S0 device knob** (cheapest, unlocks deform on
CPU) → **S1 SDF kernel** (trivial) → **S3 projection kernel** (last, hardest).
- **Minimum useful CPU deliverable:** S2 + S0 ⇒ *deform + discretize with no NVIDIA
  GPU* (device knob only; ~0.5–1 day).
- **Full CPU pipeline:** also needs the S1 and S3 kernel ports.

---

## 1. S2 (discretize) runs CPU-only NOW — proven on this box (3.1)

DiscretizationStage has **zero** `.cuda()`/CUDA references (grep-confirmed), so the
static map already predicted S2 = CPU-only. Week 3 **demonstrated it end-to-end on
this driverless box**:

- **How:** the T1 `--headless` build (no window/surface/swapchain) + Mesa **lavapipe**
  as a software Vulkan ICD (`VK_ICD_FILENAMES=…/lvp_icd.x86_64.json`,
  `deviceName = llvmpipe`, `deviceType = CPU`). Input was a **reused** Stage-1
  artifact from the prior RTX-4090 run (`stage_1_decomposition.hdf5`), so S0/S1 did
  not have to run here.
- **Command** (in the `docker-hexmesh` env image; **no NVIDIA driver, no `DISPLAY`**):
  ```bash
  apt-get install -y mesa-vulkan-drivers          # CPU Vulkan (lavapipe)
  export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json
  HEX_LOCAL=1 ./cli_run/run.sh discretize \
      output/runs/spot/decomposition_*/stage_1_decomposition.hdf5 --headless
  ```
- **Result:** exit 0; log shows
  `=== running stage 2 (discretization) ===` →
  `Generate a hex complex with 16729 vertices, 3792 quads, 40 patches, and 18526 hexes` →
  `saving … stage_2_discretization.hdf5` → `done`.
  **18 526 hexes — identical to the GPU-host smoke run** (HEADLESS.md §5). Wall
  **0.34 s**, peak RSS **~434 MB**.
- **CUDA check:** the box has no NVIDIA driver, so **any** `.cuda()` would throw at
  runtime. The run completed clean ⇒ S2 hits **no** CUDA op and triggers **no** CUDA
  init. (Plan 3.1 asked "if load-time drags in a CUDA init, note where" — it does
  not.)

**Verdict:** S2 is CPU-only today. The only non-compute GPU dependency (the Vulkan
view device) is satisfied in software; **no NVIDIA GPU is required for Stage 2.**

---

## 2. The device knob (S0 path) — cost (3.2)

**Idea:** one setting, e.g. `--device cpu|cuda` → a `torch::Device` on `Settings`,
threaded to the optimizers/models, replacing hard-coded `.cuda()` with
`.to(device_)`. The `.cpu()` result-readbacks stay as-is (CPU→CPU is a no-op).

**Call-site inventory** (the 5 files with `.cuda()`/`kCUDA`; `.cpu()` readbacks
excluded — they need no change):

| File (stage) | hard `.cuda()` to convert | Notes |
|---|---:|---|
| `optim/CubicVolumetricDeformer.cpp` (S0) | 8 | all `MatrixXfToTensor(x).cuda()` — **purely mechanical**; **no kernel** ⇒ S0 is fully CPU-capable after this |
| `models/TetrahedralMesh.cpp` (shared) | 8 | mechanical; some feed the **S1 SDF kernel** (see §3) |
| `optim/PolycubeOptimizer.cpp` (S1) | 1 (+1 default) | **already device-parameterized** — has a `device_` member + uses `.to(device_)`; only `device_{torch::kCUDA}` default (line 23) and one stray `.cuda()` (line 238) to fix |
| `optim/HexComplexDeformer.cpp` (S3) | 15 | mechanical `…cuda()`; add a `device_` member |
| `controllers/stages/HexahedralizationStage.cpp` (S3) | 7 | mechanical; lines 594-596 feed the **S3 projection kernel** (see §3) |
| **Total** | **~39** | every site is **mechanical**; none structural |

**Effort:** ~**0.5–1 day** — add the settings field + `--device` arg, thread it to
5 constructors, do the ~39 `.cuda()`→`.to(device_)` edits, then a CPU smoke of S0
(`deform`) on this box (lavapipe, like §1). **Low risk** (mechanical, additive,
guarded by the default `cuda`).

**What the knob unlocks by itself:** **S0** fully (libtorch-only, no kernel). It also
converts the libtorch halves of S1/S3, but those stages still call CUDA-only kernels
(§3), so the knob is **necessary but not sufficient** for S1/S3.

---

## 3. The two kernel ports (S1, S3) — cost (3.3)

The only project CUDA that is **not** plain libtorch: two `.cu` kernels in `geomlib`
with **no CPU variant**. Both are brute-force "for each query point, loop over all
primitives" designs — a CPU reference is a double loop (serial, or OpenMP over
points).

### 3a. `point_tet_mesh_test_cuda.cu` — SDF sign (S1) — **trivial port**
- **Used by:** `TetrahedralMesh.cpp:158` (distance-field / inside-outside) → Stage 1.
- **Computes:** for each point, count tets containing it (winding) → sign
  `winding>0 ? -1 : 1`. I/O: `points {N,3}`, `vertices {V,3}`, `tets {T,4}` →
  `signs {N}`. O(N·T).
- **CPU reference:** ~15-line double loop over (points × tets) with the existing pure
  predicate `IsPointInTetrahedron`; `#pragma omp parallel for` over points. The
  predicate is plain scalar math (needs a host-callable copy).
- **Effort: ~0.5 day** incl. a parity test vs the CUDA output. Perf: O(N·T) but fine
  for CLI-scale meshes (sub-second to a few seconds with OpenMP).

### 3b. `generalized_projection_cuda.cu` — nearest-face projection (S3) — **medium port**
- **Used by:** `hausdorff_distance.cpp` and the `GeneralizedProjection` autograd
  Function → Stage 3 hex deformation (and the Hausdorff metric).
- **Computes:** for each point, the nearest triangle/tet (min squared distance) with
  **barycentric weights + gradients** (triangle and tet variants, `dim` templated).
  I/O: `points {P,dim}` + precomputed face/tet data → `{dists {P}, idxs {P}, weights}`.
  O(P·F). The host **precompute** (`linalg_det`, `linalg_pinv`, `stack`) is plain
  torch and **already runs on CPU**; only the per-point projection + min-reduction
  kernel is CUDA.
- **CPU reference:** the `__device__` projection routines are portable scalar C++
  (Cramer's rule, edge/face projection); replace the block-per-point + warp-reduction
  with an OpenMP loop over points tracking the min. Must reproduce dists/idxs/weights
  **and gradients** for autograd.
- **Effort: ~1.5–2.5 days** incl. parity + gradient checks. **Perf risk:** O(P·F),
  called **per optimization iteration** in S3 → can be slow on large meshes; the
  honest expectation is "S3-on-CPU works but is markedly slower than GPU."

---

## 4. Recommended path & verdict

1. **S2 — done.** Ships CPU-only today (§1). Document lavapipe as the CPU Vulkan ICD.
2. **S0 device knob (~0.5–1 day).** Cheapest, highest value: unlocks `deform` on CPU
   and lays the `--device` plumbing for everything else. **Do this first.**
3. **S1 SDF kernel (~0.5 day).** Trivial; with the knob, unlocks `decompose` on CPU.
4. **S3 projection kernel (~1.5–2.5 days).** Last and hardest; unlocks the full CPU
   pipeline but with a CPU perf caveat on large meshes.

**Total to a full CPU pipeline:** ~**3–4.5 days** of mechanical + two-kernel work on
top of the headless mode already shipped.

- **Minimum useful CPU deliverable (recommended near-term):** **S2 (now) + S0 (device
  knob)** ⇒ deform + discretize with **no NVIDIA GPU**. Small, low-risk, demoable.
- **Full CPU pipeline** requires both kernel ports (S1, S3); S3 is the real cost and
  carries the only meaningful performance caveat.

> Caveat to set expectations: CPU-only is explicitly **not** a one-week deliverable.
> The free win is S2; the cheap win is S0; S1/S3 are a scoped follow-on project.
