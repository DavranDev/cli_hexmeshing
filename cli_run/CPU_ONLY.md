# CPU-only — implemented + per-stage verdict

## Read this first: two different things are called "CPU-only"

They are **not** interchangeable, and most confusion about this project comes from
conflating them.

| | **CPU runtime mode** | **CPU-only build** |
|---|---|---|
| Command | `hex --device cpu` | `./setup.sh --cpu` (`-DHEX_ENABLE_CUDA=OFF`) |
| The binary | CUDA-enabled, operating on CPU tensors | Links **no CUDA at all** |
| CUDA toolkit installed? | **Yes** — it is a hard compile-time dependency | No |
| LibTorch | cu124 (~2.5 GB) | `+cpu` (~200 MB) |
| NVIDIA Container Toolkit | Yes | No |
| LunarG Vulkan SDK | Yes (~1.5 GB) | No — distro `libvulkan1` + lavapipe |
| Since | 2026-06-18 (§5) | 2026-08-03 (§6) |

Both produce the same numbers (18 526 hexes / 0 inverted). The difference is what
has to be **installed** to get there. If the target machine has no NVIDIA GPU and
you do not want the CUDA stack on it at all, you want the **CPU-only build** (§6).

**amd64 only** — the lavapipe ICD manifest path is architecture-specific; ARM64 is
documented as unsupported rather than silently broken.

---

> **STATUS: IMPLEMENTED & VALIDATED (2026-06-18).** The full pipeline now runs with
> **no NVIDIA GPU**: `hex --device cpu --headless` ran all four stages on a box with
> **no `--gpus` at all** (software Vulkan via lavapipe for the view device, CPU for
> all compute) → **18 526 hexes, 0 inverted** — identical to the GPU run. The default
> `--device cuda` path is unchanged (regression-checked: 18 526 / 0). §§2–4 below are
> the original costing; **§5 records what was actually built**, and **§6 the
> CUDA-free build that removes the toolkit dependency entirely.**

**Question (Ronald #13):** can the pipeline run without an NVIDIA GPU, and how much
work is each stage? Answer: **yes, all of it now** — via a `--device cpu` knob plus
CPU ports of the two geomlib kernels (§5).

Builds on the static + runtime GPU map ([DEPENDENCY_MAP.md](DEPENDENCY_MAP.md)) and
the headless work ([HEADLESS.md](HEADLESS.md) §0).

---

## 0. TL;DR

| Stage | CPU-only status | How |
|---|---|---|
| **S2 discretize** | ✅ **runs CPU-only** (was always; proven §1) | zero CUDA in the stage |
| **S0 deform** | ✅ **runs CPU-only** (device knob) | `--device cpu`; libtorch-only, no kernel |
| **S1 decompose** | ✅ **runs CPU-only** (knob + SDF kernels) | `--device cpu`; CPU ports of `point_tet_mesh_test` **and** `generalized_projection` (the SDF uses both) |
| **S3 hexahedralize** | ✅ **runs CPU-only** (knob + projection kernels) | `--device cpu`; CPU ports of `generalized_projection` (tri + tet) + Hausdorff |

Run it: `./cli_run/run.sh <stage> <input> --headless --device cpu` (or
`hex --headless --device cpu --script …`). **Perf caveat:** the CPU kernel loops are
serial → the full `spot.mesh` chain takes ~6 min on CPU vs ~12 s on GPU (deform 5 s,
decompose 76 s, discretize <1 s, hexahedralize 269 s). Correct, not fast.

**Two independent axes, do not conflate** (same split as HEADLESS.md):
- **(C) CUDA compute** — libtorch `.cuda()` + the two geomlib `.cu` kernels. This is
  what "CPU-only" is about and what §§2–3 cost.
- **(V) Vulkan device** — the view objects still construct against a Vulkan device
  even headless (LEVEL 1). On a box with no NVIDIA GPU this is satisfied by a
  **software Vulkan ICD (Mesa lavapipe / llvmpipe)** — see §1. Removing Vulkan
  *entirely* is LEVEL 2 / "design A" (HEADLESS.md §6), a separate, larger refactor,
  **not** required for CPU compute.

**Original plan (now all done — see §5):** S2 (free) → S0 device knob → S1 SDF
kernel → S3 projection kernel. The full CPU pipeline is implemented and validated.

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

---

## 5. Implementation + validation (2026-06-18) — DONE

The §4 plan was implemented. **Additive, behind a default-`cuda` knob, so the GPU
path is unchanged.**

### Device knob (S0 + all libtorch tensors)
- New `hex::ComputeDevice()` / `SetComputeDevice()` in `optim/torch_utils.{h,cpp}`
  (function-local static, default `torch::kCUDA`).
- `main.cpp` parses `--device cpu|cuda` and sets it before the pipeline; `run.sh`
  forwards `--device`.
- The ~39 hard-coded `.cuda()` across the 5 files + the one `device_{torch::kCUDA}`
  → `.to(hex::ComputeDevice())`. `.cpu()` readbacks unchanged. No GPU-only `assert`
  left on the compute path (`TetrahedralMesh::ComputeDistanceFieldGPU`,
  `ComputeHausdorffDistance`).

### Kernel CPU ports (S1 + S3) — same math, host loop
The two geomlib `.cu` kernels got a CPU branch that **reuses the exact per-element
device functions** (now marked `__host__ __device__` in `utils.cuh` / `vec_utils.cuh`
/ the projection `.cu`), so CPU results match CUDA by construction. Each public
function dispatches on `points.is_cuda()`:
- `point_tet_mesh_test_cuda.cu` — point-in-tet sign (S1 SDF sign).
- `generalized_projection_cuda.cu` — **triangle and tet** nearest-face projection.
  *Correction to the earlier scoping:* S1's signed distance field uses **both** the
  triangle projection (unsigned distance) and the point-in-tet test (sign), so S1
  needed the projection port too — not just the SDF-sign kernel.
- `TriangularProjectionInfo` + `TriangularMeshSampler` were already pure torch ops →
  CPU-ready with no change.

### Validation (no NVIDIA GPU at all — `docker run` **without** `--gpus`, lavapipe views)
`hex --device cpu --headless`, full chain on `spot.mesh`:

| Stage | rc | CPU time |
|---|---|---|
| deform (S0) | 0 | 5 s |
| decompose (S1) | 0 | 76 s |
| discretize (S2) | 0 | <1 s |
| hexahedralize (S3) | 0 | 269 s |

**Result: `total_hexes 18526, inverted_count 0`** (scaled-Jac mean 0.862) — identical
to the GPU run. **GPU regression check:** default `--device cuda` headless smoke still
PASSes (18 526 / 0).

### Known follow-up (optional)
The CPU kernel loops are **serial**. They are embarrassingly parallel over query
points; switching to `at::parallel_for` (libtorch's thread pool, no `-fopenmp`/nvcc
issue) would cut the ~6-min chain substantially. Deferred — correctness first.

---

## 6. CPU-only **build** (2026-08-03) — CUDA is no longer a compile-time dependency

§5 removed CUDA from the *run*. It did not remove it from the *build*: CUDA was
still required to compile, so the only way to run GPU-free was to install the
entire CUDA stack and then not use it. §6 removes that.

### What changed

| Piece | Before | After |
|---|---|---|
| Build option | none — CUDA always compiled in | `-DHEX_ENABLE_CUDA=ON` (default) / `OFF` |
| geomlib `.cu` files | always compiled | added to the target **only** when the option is ON |
| `hex` CUDA includes | `c10/cuda/CUDACachingAllocator.h`, unconditional | behind `#if HEX_ENABLE_CUDA` |
| Setup | `./setup.sh` | `./setup.sh` **or** `./setup.sh --cpu` |
| Image | `docker-hexmesh` (16.1 GB) | `hexmesh-cpu:latest` (**1.84 GB**) |

The option is exported to C++ as a **numeric** `HEX_ENABLE_CUDA=0/1`, and every
guard is `#if HEX_ENABLE_CUDA` — never `#ifdef`, which would be true even when the
option is OFF.

Rather than compiling `.cu` files as C++, the kernels were split so that plain
g++ never sees a `.cu` at all. Per kernel pair, in `geomlib/geomlib/`:

| File | Contents | Compiled in |
|---|---|---|
| `*_impl.h` | the shared `__host__ __device__` per-element math | every build |
| `*.cpp` | CPU reference loops, the public dispatcher, explicit instantiations | every build |
| `*_cuda.h` | the `…Cuda()` entry points, whole file behind `#if HEX_ENABLE_CUDA` | CUDA builds |
| `*_cuda.cu` | `__global__` kernels + those entry points | CUDA builds |

`__global__` is deliberately **not** defined away in `cuda_compat.h`: kernels are
excluded by the file split, and an empty `__global__` would let a kernel that
leaked into a host TU compile as ordinary — and silently wrong — host code.

Dispatchers also now verify that related tensors share a device before taking raw
pointers. Branching on `points.is_cuda()` alone was not enough: CPU `points` with
CUDA `vertices` handed a device pointer to the host loop and **segfaulted** rather
than raising.

### Using it

```bash
./setup.sh --cpu          # no CUDA toolkit, no cu124 LibTorch, no Container
                          # Toolkit, no LunarG SDK -- none are downloaded

HEX_IMAGE_VARIANT=cpu ./cli_run/run.sh deform \
    interactive-hex-meshing/assets/tutorial/spot.mesh --headless --device cpu
```

`HEX_IMAGE_VARIANT` picks the **image/build**; `--device` picks the **compute
device**. A CUDA-enabled image can legitimately run its CPU path, so CPU launch
mode is never inferred from `--device cpu`. All three launchers
(`cli_run/run.sh`, `./hex`, `run_docker.sh`) assemble their docker command line
from `cli_run/lib/docker_args.sh`, so the CPU variant cannot pick up a stray
`--gpus` / `--runtime=nvidia` / NVIDIA ICD mount;
`scripts/test_docker_args.sh` asserts exactly that.

Both variants still build into the same `bin/Release/hex`, so a CPU build
overwrites a CUDA one. `compile.sh` records which produced it in
`bin/Release/.hexmesh-variant`, and the launchers refuse a mismatched run.
`lib/libtorch/.hexmesh-variant` does the same for the LibTorch install, so a
cu124 tree can never silently satisfy a `--cpu` setup.

### Switching a machine between the two variants

There is one **active** LibTorch at `lib/libtorch`; any other variant is
**parked** next to it as `lib/libtorch-<variant>`:

```
lib/
  libtorch/          <- active   (.hexmesh-variant says which)
  libtorch-cu124/    <- parked, reused on the way back
```

`install_libtorch` parks the outgoing tree instead of deleting it, and activates
a parked tree of the wanted variant instead of downloading one. Switching is
then a rename:

```bash
./setup.sh --cpu     # parks cu124, activates cpu    -- seconds, no download
./setup.sh           # parks cpu,   activates cu124  -- seconds, no download
```

A parked tree is never trusted on the strength of its directory name: it is
re-validated (`build-version` matches the expected `<version>+<variant>`, and
the CUDA `.so` set agrees with the claim) before being activated. An
unidentifiable tree is parked under a timestamped name rather than deleted —
this script should never be the reason a multi-GB download is lost.

Note this only affects the **host-mounted developer workflow**. The shipped
`hexmesh-cpu:latest` bakes its own `+cpu` LibTorch in the `libs` stage and never
reads the host `lib/`, so the parked cu124 tree cannot leak into it.

Why it matters on a dual-use box: the CUDA-built `hex` links `libtorch_cuda.so`
and `libc10_cuda.so`. Point it at a `+cpu` tree and 6 libraries go unresolved —
so the variants genuinely cannot share one directory, and without parking a
switch back costs a ~2.5 GB re-download.

### Validation (2026-08-03, no NVIDIA driver, no `--gpus`, no CUDA installed)

| Check | Result |
|---|---|
| **A** geomlib unit tests, CPU-only build | **PASS — 70 checks** |
| A′ same tests, CUDA build on an RTX 4090 | **PASS — 146 checks** (70 CPU + 70 CUDA + 6 mixed-device) |
| **B** no CUDA dependency in any shipped ELF under `/space` | **PASS** |
| **C** no CUDA/NVIDIA/cuDNN/NCCL package installed | **PASS** |
| **D** Vulkan is a software device | **PASS** — `llvmpipe`, `PHYSICAL_DEVICE_TYPE_CPU` |
| **E** four stages run separately, chained | **PASS** — 5 s / 74 s / <1 s / 266 s (345 s total) |
| **F** artifact parity vs pre-change baseline | **PASS** — see §6.1 |
| **G** `SMOKE_DEVICE=cpu ./cli_run/smoke_test.sh` | **PASS** — 18 526 / 0 |
| **H** GPU regression: `./setup.sh --no-smoke && ./cli_run/smoke_test.sh` | **PASS** — 18 526 / 0 on an RTX 4090 |

### 6.1 Verification F — artifact parity

`18526 / 0` is an acceptance check, not proof that the meshing result was
preserved. F compares the artifacts themselves.

**Baseline.** The correctness reference is the **pre-change source tree built
with CUDA and run with `--device cpu`** — not a GPU run. That holds the tensor
backend and the CPU kernels fixed, so the comparison isolates the effect of the
translation-unit/CMake split from ordinary CPU-versus-GPU floating-point and
reduction-order differences. The pipeline already fixes its seeds
(`torch::manual_seed(42)`, `std::default_random_engine(42)`).

**This pipeline is not run-to-run deterministic.** Two runs of the *same* build
differ, so a zero tolerance is unattainable and had to be measured rather than
assumed:

| Field | baseline-vs-baseline spread (same build, two runs) |
|---|---|
| `deformed_volume_mesh/vertices` | max 3.9e-4 |
| `deformed_volume_mesh/sdf` | max 5.1e-4 |
| `polycube/params` | max 6.6e-3 |
| `result.mesh` vertices | max 6.8e-2, **p99 3.4e-3, median 3.0e-4** (9 of 16 729 vertices exceed 1e-2) |
| `polycube_info/names` | 32–47 of 256 bytes differ (a name table, not geometry) |

Those measured spreads (×4 margin) become the recorded tolerances. Topology is
deliberately **excluded** from tolerance eligibility: if connectivity were
unstable that is a bug to fix, not to tolerate.

**Result: PASS.** CPU-only build vs pre-change baseline:

- **Every topology field bit-identical** — `tets`, `quads`, `hexes`, `patches`,
  `ordering`, `locked`, across all four stages, plus `result.mesh` canonical hex
  connectivity (18 526 hexes) and `polycube_complex/vertices` (exactly 0.0
  difference).
- **Every float field within the measured run-to-run tolerance**, and at
  comparable magnitude to it — e.g. deformed vertices max 4.2e-4 against a
  baseline self-spread of 3.9e-4. The CPU-only build differs from the baseline
  about as much as the baseline differs from itself.
- **Quality statistics within tolerance**: scaled-Jacobian and Jacobian
  min/max/mean/std all pass; `inverted_count` is 0.
- 3 notes, all `polycube_info/names` — recorded as nondeterministic, never
  silently skipped.

**The gate is not vacuous.** A negative control that flips a *single* quad
connectivity index out of 15 168 fails it, naming the dataset and flat index.

Reproduce:

```bash
scripts/collect_pipeline_artifacts.sh output spot /tmp/candidate
scripts/compare_pipeline_artifacts.py compare BASELINE /tmp/candidate \
    -t cli_run/baselines/tolerances.json
```

`scripts/compare_pipeline_artifacts.py` needs `h5py` + `numpy`, both already in
`docker-hexmesh`. It does **not** use meshio for `result.mesh`: meshio's MEDIT
reader requires the element count on the line after the section keyword, while
`hex` writes `Vertices 16729` on one line, so a small built-in MEDIT parser is
used instead (validated against the file's declared counts).

The committed baseline is
[baselines/spot_cpu_device_baseline.json](baselines/spot_cpu_device_baseline.json)
— a compact manifest of hashes, shapes, counts, statistics and the chosen
tolerances. The large HDF5 artifacts are deliberately not committed.

F is an *acceptance* gate, not a proof of numerical identity: matching final
metrics does not establish that intermediate results are bitwise or
field-by-field identical to the GPU run.

Timings match §5's CPU-runtime-mode numbers, as expected — this work changed what
gets **linked**, not the arithmetic. The serial-loop caveat from §5 stands
unchanged.

### Still out of scope

- **Vulkan is still a build dependency.** `hex` constructs a Vulkan device even
  headless; the CPU image satisfies it in software with Mesa lavapipe. A real
  `HEX_ENABLE_VULKAN=OFF` build is separate work — see
  [../plans/no-vulkan-headless.md](../plans/no-vulkan-headless.md).
- **ARM64.** The lavapipe ICD manifest path is architecture-specific; amd64 only.
- **CPU parallelisation.** Still deferred; `at::parallel_for` is a follow-up.
