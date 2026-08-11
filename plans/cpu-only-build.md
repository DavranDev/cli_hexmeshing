# Plan: CPU-only build & run (no CUDA packages, no GPU)

Status: **recommended prerequisite** — not yet implemented. Drafted 2026-07-29,
rev. 3 coordinated with [no-vulkan-headless.md](no-vulkan-headless.md).

## Context

We want to move this pipeline to a Linux box with **no NVIDIA GPU at all**, and
install **none of the GPU packages** (CUDA toolkit, cu124 LibTorch, NVIDIA Container
Toolkit).

Two things must not be conflated, and the docs must lead with the distinction:

- **CPU *runtime* mode** — CUDA-enabled binaries operating on CPU tensors. This
  already exists and is validated: [cli_run/CPU_ONLY.md](../cli_run/CPU_ONLY.md) §5
  records `hex --device cpu --headless` running all four stages with no GPU and no
  driver → 18 526 hexes / 0 inverted. Both geomlib kernels already have CPU branches
  dispatching on `points.is_cuda()`.
- **CPU-only *build*** — no CUDA toolkit, no CUDA LibTorch, no CUDA headers, no
  CUDA-linked shared objects anywhere in the shipped image. **This is what this plan
  delivers.** Today CUDA is a hard *compile-time* dependency, so the only way to run
  GPU-free is to install the entire CUDA stack and then not use it.

**Outcome:** a `-DHEX_ENABLE_CUDA=OFF` build linking no CUDA at all, a CPU Docker
image (build + slim runtime) on `ubuntu:22.04`, and `setup.sh --cpu` + `run.sh`
per-stage commands that never touch `--gpus`. The default build stays CUDA-enabled, so
the GPU machine is unaffected.

This plan deliberately delivers the first two entries of the eventual setup matrix:

```bash
./setup.sh         # CUDA + Vulkan renderer
./setup.sh --cpu   # CPU-only + Vulkan renderer (lavapipe on a GPU-less host)
```

The other two entries, `--no-vulkan` and `--cpu --no-vulkan`, require the separate
two-phase renderer separation in [no-vulkan-headless.md](no-vulkan-headless.md). Do not
pretend that a runtime `--no-vulkan` flag alone removes the build/link dependency on the
Vulkan loader.

### Decisions taken
- **Docker** is the build/run vehicle (matches the `/space` layout every script assumes).
- **Vulkan** comes from distro `libvulkan-dev` + `mesa-vulkan-drivers` (lavapipe), not
  the ~1.5 GB LunarG SDK. Vulkan is a *renderer* dep, not a GPU one — `hex` builds a
  Vulkan device even headless. `external/` already bundles glslang, spirv-cross and
  glfw, so the SDK only supplied loader + headers + validation layers, and
  [Instance.cpp:30-35](../interactive-hex-meshing/vkoo/src/core/Instance.cpp#L30-L35)
  already falls back cleanly when validation layers are absent.
- **amd64 only.** The lavapipe ICD manifest path is arch-specific; ARM64 is out of scope
  and will be documented as unsupported rather than silently broken.
- **CPU parallelization is deferred.** Ship the CUDA-free build matching today's
  validated numbers first; `at::parallel_for` is a separate follow-up.
- **LibTorch has two consumers.** The host-mounted developer workflow uses
  `setup.sh::install_libtorch`; the self-contained Docker workflow downloads LibTorch in
  its `libs` stage. Both must read the same version, ABI and variant constants (or Docker
  build arguments) so they cannot silently drift.

---

## The actual CUDA surface

Smaller than it looks — 6 source files plus build/run scripts.

| Where | What |
|---|---|
| [geomlib/geomlib/CMakeLists.txt](../interactive-hex-meshing/geomlib/geomlib/CMakeLists.txt) | `find_package(CUDA/CUDAToolkit REQUIRED)`, `cuda_add_library`, links `CUDA::cudart/cusolver/cupti` |
| `common.cuh` | `#include <cuda.h>`, `<cuda_runtime_api.h>`, `<driver_types.h>`, `CHECK_CUDA`, `CHECK_ON_CUDA` — the main CUDA-header leak |
| `utils.cuh` | unused `#include <thrust/tuple.h>`; `float3`/`double3` in `MakeVec3`; `__device__`-only `WarpReduceMin`/`ReduceMin`/`WarpReduceSum` (~L60-100) |
| `vec_utils.cuh` | only `__host__ __device__` decorations — pure scalar math |
| the two `*_cuda.cu` | `__global__` kernels, `at::cuda::CUDAGuard`, `getCurrentCUDAStream`, `dim3`, launch syntax, `AT_CUDA_CHECK` — plus shared math, CPU loops and the public dispatcher, all in one file |
| [PolycubeOptimizer.cpp](../interactive-hex-meshing/hex/src/optim/PolycubeOptimizer.cpp#L4), [HexComplexDeformer.cpp](../interactive-hex-meshing/hex/src/optim/HexComplexDeformer.cpp#L4) | `#include <c10/cuda/CUDACachingAllocator.h>` + one `emptyCache()` each |

`hausdorff_distance.cpp`, the autograd wrappers, `TriangularProjectionInfo`,
`TriangularMeshSampler` and all of evocube are already CUDA-free.

---

## Step 1 — CMake option with a numeric definition

**This is the highest-risk detail in the whole plan.** `target_compile_definitions(...
HEX_ENABLE_CUDA=OFF)` still satisfies `#ifdef HEX_ENABLE_CUDA` — the name exists
regardless of value, so the CUDA path would silently stay compiled in.

In [interactive-hex-meshing/CMakeLists.txt](../interactive-hex-meshing/CMakeLists.txt),
**before** `add_subdirectory(...)`:

```cmake
option(HEX_ENABLE_CUDA "Build CUDA acceleration" ON)
```

Then define it numerically, `PUBLIC` on geomlib (its public headers carry conditional
declarations):

```cmake
target_compile_definitions(geomlib PUBLIC HEX_ENABLE_CUDA=$<BOOL:${HEX_ENABLE_CUDA}>)
target_compile_definitions(hex     PRIVATE HEX_ENABLE_CUDA=$<BOOL:${HEX_ENABLE_CUDA}>)
```

**Every C++ guard in this plan uses `#if HEX_ENABLE_CUDA`, never `#ifdef`.** Default
ON ⇒ the GPU build is unchanged.

## Step 2 — split CPU and CUDA translation units

Rather than compiling `.cu` as C++ with `-x c++` (works on Linux/GCC, but relies on
compiler-specific behavior and leaves CUDA syntax visible to g++), split the files so
**plain g++ never sees a `.cu` at all**. CMake then adds `.cu` sources only in CUDA
builds — structurally impossible to get wrong.

New layout in `geomlib/geomlib/`, per kernel pair:

| File | Contents | Compiled by |
|---|---|---|
| `generalized_projection_impl.h` *(new)* | the shared `__host__ __device__` per-element math (`ComputeBarycentricGradient`, `GeneralizedTriangleProjection`, `GeneralizedTetrahedronProjection`), moved verbatim out of the `.cu` | both |
| `generalized_projection.cpp` *(new)* | CPU reference loops + the public dispatcher + the explicit instantiations (`<3>`, `<8>` triangle; `<3>` tet) | always |
| `generalized_projection_cuda.h` *(new)* | declares the `...Cuda<dim>()` entry points, whole file behind `#if HEX_ENABLE_CUDA` | CUDA builds |
| `generalized_projection_cuda.cu` *(trimmed)* | only `__global__` kernels + the `...Cuda<dim>()` definitions and their instantiations | CUDA builds |

Identical four-way split for `point_tet_mesh_test`.

The dispatcher in the `.cpp`:
```cpp
if (points.is_cuda()) {
#if HEX_ENABLE_CUDA
  return ComputeGeneralizedTriangleProjectionCuda<dim>(points, info);
#else
  TORCH_CHECK(false, "geomlib was built without CUDA support; use CPU tensors");
#endif
}
return ComputeGeneralizedTriangleProjectionCpu<dim>(...);
```
The message is library-level on purpose — geomlib should not reference the CLI's
`--device` flag.

**`cuda_compat.h`** *(new)* — keyed on the build option, not primarily `__CUDACC__`,
and it must not redefine CUDA's own types inside a CUDA TU:

```cpp
#if HEX_ENABLE_CUDA
#include <vector_types.h>
#include <vector_functions.h>
#else
#ifndef __host__
#define __host__
#endif
#ifndef __device__
#define __device__
#endif
struct float3  { float  x, y, z; };
struct double3 { double x, y, z; };
inline float3  make_float3(float x, float y, float z)      { return {x, y, z}; }
inline double3 make_double3(double x, double y, double z)  { return {x, y, z}; }
#endif
```

**`__global__` is deliberately NOT defined away.** Kernels are excluded from CPU
compilation entirely by the TU split; an empty `__global__` would let an accidentally
exposed kernel compile as ordinary — and silently wrong — host code.

**Header cleanup:**
- `utils.cuh` — delete the unused `<thrust/tuple.h>` include outright (no `thrust::`
  use anywhere); include `cuda_compat.h`; put `WarpReduceMin`/`ReduceMin`/
  `WarpReduceSum` behind `#if HEX_ENABLE_CUDA`. `MakeVec3` and `IsPointInTetrahedron`
  stay available to both.
- `vec_utils.cuh` — include `cuda_compat.h`; otherwise unchanged.
- `common.cuh` — CUDA headers, `CHECK_CUDA` and `CHECK_ON_CUDA` behind
  `#if HEX_ENABLE_CUDA`; **`CHECK_CONTIGUOUS` must remain available in CPU builds** (the
  CPU dispatchers use it).

**`geomlib/geomlib/CMakeLists.txt`** — replace the `*.cu` glob with an explicit
conditional source list; in the OFF branch skip both `find_package` calls, use plain
`add_library`, and drop the `CUDA::*` link libraries. Keep the ON branch byte-identical
to today.

## Step 3 — hex: drop the last hard CUDA links

Guard the `c10::cuda::CUDACachingAllocator` include and `emptyCache()` call in
`PolycubeOptimizer.cpp` and `HexComplexDeformer.cpp` with `#if HEX_ENABLE_CUDA`. These
are cache-release hints; a no-op on CPU is semantically correct.

In [main.cpp](../interactive-hex-meshing/hex/src/main.cpp#L50-L56), expose the build
capability **once** so the default, the validation and the help text cannot drift:

```cpp
#if HEX_ENABLE_CUDA
constexpr bool kCudaBuild = true;
#else
constexpr bool kCudaBuild = false;
#endif
```
Drive all three from it: default device (`cpu` when `!kCudaBuild`), rejection of
`--device cuda` with a clear message, and the `--help` text.

## Step 4 — compile against CPU LibTorch, outside Docker first

Get feedback on the riskiest boundary (source + CMake) before touching any shell
wrapper. Configure and build geomlib + hex against a CPU LibTorch in a plain
`ubuntu:22.04` container with **no CUDA installed** — a clean configure+build here is
the real proof the TU split is complete.

**Separate build directories per variant**, rather than selectively deleting a stale
cache (compile.sh already has stale-cache repair logic for `Vulkan_INCLUDE_DIR`; do not
extend that pattern):

```
interactive-hex-meshing/build/cpu-release
interactive-hex-meshing/build/cuda-release
```

## Step 5 — CPU unit tests

[geomlib/test/main.cpp](../interactive-hex-meshing/geomlib/test/main.cpp) hard-codes
`.cuda()` in ~5 places. **Do not skip the target** — that would drop coverage exactly
where the new build configuration is least proven.

- Parameterize the tests on a `torch::Device`; run them on CPU in every build.
- In CUDA builds, run both CPU and CUDA variants.
- Add small direct CPU tests for `PointTetMeshTest` and both projection variants
  (triangle and tet), including gradients, so a break at the optional-CUDA boundary is
  caught in seconds rather than after a ~6-minute four-stage run.
- In a CUDA-enabled build, run the same CPU cases against CUDA-enabled LibTorch as well as
  the CUDA cases. This proves that the shared CPU implementation works with both LibTorch
  distributions.
- Add negative tests for mixed-device inputs. Every dispatcher must verify that related
  tensors (`points`, `vertices`, indices and cached projection data) are on the same device
  before taking raw pointers; dispatching only on `points.is_cuda()` is insufficient.

## Step 6 — CPU Docker image (build **and** runtime)

**New `Dockerfile.cpu`**, mirroring [Dockerfile.build](../Dockerfile.build)'s
`libs` → `build` → `runtime` stage structure so the `/space` layout is identical.

- **libs stage:** fetch the `+cpu` LibTorch archive
  (`libtorch/cpu/libtorch-cxx11-abi-shared-with-deps-2.6.0%2Bcpu.zip`, ~200 MB vs
  ~2.5 GB). No Vulkan SDK download at all.
- **build stage** — base `ubuntu:22.04`: the existing compiler/dev packages
  (`git cmake build-essential patch python3 python3-pip libblas-dev liblapack-dev
  libgl1-mesa-dev libx{randr,inerama,cursor,i}-dev libhdf5-serial-dev`) plus
  `libvulkan-dev`, and `mesa-vulkan-drivers` + `vulkan-tools` so the build stage can run
  a real Vulkan smoke check. Runs `compile.sh` with `HEX_CPU_ONLY=1`.
- **runtime stage** — slim, base `ubuntu:22.04`, carrying the same runtime deps the GPU
  runtime stage copies: `libblas3 liblapack3 libgomp1 libhdf5-103 libhdf5-cpp-103
  libgl1 libglu1-mesa libgl1-mesa-dri libx{randr2,inerama1,cursor1,i6}` plus
  `libvulkan1` and `mesa-vulkan-drivers`; LibTorch `.so`s, the binaries, assets,
  shaders and `cli_run/`. No compilers, no source, no build trees.
- Install `file` and `vulkan-tools` in the initial diagnostic runtime image because
  Verification B invokes `file` and Verification D invokes `vulkaninfo`. They may be
  removed from a later production-slim target after those checks move to a dedicated test
  image.
- Both stages: `ENV VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json`
  (amd64; documented as such), `ENV LD_LIBRARY_PATH=/space/lib/libtorch/lib`, and **no**
  `VULKAN_SDK*` variables.

## Step 7 — setup.sh `--cpu` and runner integration

**[setup.sh](../setup.sh)** gains `--cpu` (env `HEX_CPU_ONLY=1`). In that mode:
- `install_libtorch` fetches the `+cpu` archive. The current "already installed, skip"
  check would happily reuse a CUDA LibTorch and undermine the entire guarantee, so:
  write a **`lib/libtorch/.hexmesh-variant` marker** carrying
  `variant=cpu|cu124`, `version=2.6.0`, `abi=cxx11`. Download to a temp dir, validate
  the extracted tree (`ldd` / expected `.so` set) and only then replace the install and
  write the marker. **A missing marker on an existing directory is treated as
  incompatible**, not guessed at. Print the selected variant prominently.
- Skip `install_vulkan_sdk`, `install_host_vulkan_tools`, `ensure_nvidia_runtime`,
  `verify_nvidia_runtime`.
- Build `Dockerfile.cpu`, compile in it, then smoke with `SMOKE_DEVICE=cpu` and **no**
  `--gpus` / `--runtime=nvidia` / NVIDIA ICD mounts.
- `run_checks` ([scripts/verify_no_crash_fixes.sh](../scripts/verify_no_crash_fixes.sh))
  needs no change — source/patch inspection only.

**[compile.sh](../compile.sh)** — `source_vulkan_sdk` currently hard-errors when
`setup-env.sh` is missing; skip sourcing under `HEX_CPU_ONLY=1` (system Vulkan is
already on the default paths). Pass the build option from a normalized array rather
than string-splicing:
```bash
hex_cmake_args=(-DCMAKE_BUILD_TYPE=Release -DTorch_DIR="$Torch_DIR")
if [[ "${HEX_CPU_ONLY:-0}" == 1 ]]; then
  hex_cmake_args+=(-DHEX_ENABLE_CUDA=OFF)
else
  hex_cmake_args+=(-DHEX_ENABLE_CUDA=ON)
fi
```
evocube's build is untouched — already CPU/OpenMP only.

**Runner scripts.** Keep two concepts strictly separate:
- **image/build variant** — `HEX_IMAGE_VARIANT=cpu|cuda`
- **requested compute device** — `--device cpu|cuda`

A CUDA-enabled image can legitimately run its CPU path, so **CPU launch mode must never
be inferred from `--device cpu`**. In CPU variant, the `docker run` line must drop *all*
of `--runtime=nvidia`, `--gpus all`, `NVIDIA_DRIVER_CAPABILITIES`, the `nvidia_icd.json`
env, and the `/usr/share/vulkan/icd.d` bind-mount; the image's internal lavapipe config
stands.

[cli_run/run.sh](../cli_run/run.sh#L235-L242), [hex](../hex) and
[run_docker.sh](../run_docker.sh) each assemble their own `docker run` line today, so
updating them independently invites drift. **Extract a shared helper** (e.g.
`cli_run/lib/docker_args.sh`) that builds the common argument list — image, mounts,
Vulkan vars, LibTorch lib paths — per variant. If that refactor proves too broad, the
minimum acceptable fallback is a test that renders/inspects every assembled CPU command
and asserts it contains no `nvidia`, `--gpus`, or `--runtime` option.
The `hex` wrapper also currently hard-errors when `lib/vulkan-sdk` is absent; that
becomes conditional.

## Step 8 — documentation

Update [cli_run/CPU_ONLY.md](../cli_run/CPU_ONLY.md), [README.md](../README.md),
[cli_run/SETUP_FROM_SCRATCH.md](../cli_run/SETUP_FROM_SCRATCH.md) and
[cli_run/DEPENDENCY_MAP.md](../cli_run/DEPENDENCY_MAP.md). Lead the quickstart with the
**CPU runtime mode vs CPU-only build** distinction from the Context section, and state
amd64-only support explicitly.

---

## Verification

Run in this order — cheap and localizing first.

### Meshing-result preservation contract

The correctness baseline for this refactor is the **current CUDA-enabled build run
with `--device cpu`**, not a CUDA run. This compares the same tensor backend and the
same CPU kernels before and after the translation-unit/CMake split, and therefore
isolates effects of the CPU-only build work from expected CPU-versus-GPU floating-point
and reduction-order differences.

Before changing the sources, create a versioned `spot.mesh` baseline with the current
CUDA build, `--device cpu`, the checked-in YAML configurations, and seed 42. Preserve
all four stage HDF5 files, `result.mesh`, `result_metrics.yaml`, stdout/stderr, the Git
commit, LibTorch version, compiler version and configuration-file hashes. Run the
baseline twice first; any field that differs between those two runs is nondeterministic
and must be compared by an explicitly recorded tolerance rather than silently ignored.

The CPU-only build must then satisfy all of the following against that baseline:

- Stage 0 and stage 1 HDF5 datasets have identical shapes, integer/connectivity data
  and metadata; floating-point arrays are equal within a documented absolute/relative
  tolerance.
- Stage 2 has exactly the same vertex, quad, patch and hex connectivity. Compare
  canonicalized topology (stable vertex/cell ordering or sorted connectivity), not a
  raw HDF5 checksum unless ordering is known to be contractual.
- Stage 3 has the same number of vertices and hexes and identical canonicalized hex
  connectivity. Corresponding vertex coordinates and per-element quality values are
  within the tolerance established above; `inverted_count` remains zero.
- The final mesh-quality statistics are checked with tolerances, including scaled-
  Jacobian and Jacobian min/max/mean/std. A matching `18526 / 0` alone is insufficient.

Add a reusable comparison script (for example
`scripts/compare_pipeline_artifacts.py`) and make it emit the first mismatching dataset,
index, maximum absolute/relative error and topology difference. The script should use
`h5py` for stage files and `meshio` (or the repository's MEDIT reader) for `result.mesh`.
Commit only a compact baseline manifest (hashes, shapes, counts, statistics and chosen
tolerances); keep large HDF5 artifacts as CI artifacts or release fixtures rather than
adding them to Git.

**A. CPU unit tests** (Step 5) — the fast gate on the optional-CUDA boundary.

**B. No CUDA in *any* shipped ELF object.** Checking only the `hex` executable would
miss a CUDA dependency on `libgeomlib.so` or another object. Note this exits 0 on
success; a bare `grep` would exit 1 on success and confuse CI:

```bash
docker run --rm hexmesh-cpu:latest bash -c '
  found=0
  while IFS= read -r f; do
    file "$f" | grep -q ELF || continue
    if ldd "$f" 2>/dev/null | grep -Eiq "cuda|nvidia|cudnn|nvrtc|cupti|cusolver"; then
      echo "CUDA dependency found in $f"; found=1
    fi
  done < <(find /space -type f \( -perm -111 -o -name "*.so" -o -name "*.so.*" \))
  exit $found'
```

**C. No CUDA/NVIDIA packages installed:**
```bash
docker run --rm hexmesh-cpu:latest bash -c \
  'dpkg-query -W 2>/dev/null | grep -Ei "cuda|nvidia|cudnn|nccl" && exit 1 || exit 0'
```

**D. Vulkan is a software device:** `vulkaninfo --summary` must report
lavapipe / llvmpipe, `deviceType = CPU`.

**E. Each stage separately, no GPU** — the acceptance test. In the CPU image with
`HEX_LOCAL=1`, chaining each stage's HDF5 into the next:
```bash
./cli_run/run.sh deform        assets/tutorial/spot.mesh                                    --headless --device cpu
./cli_run/run.sh decompose     output/runs/spot/deformation_*/stage_0_deformation.hdf5      --headless --device cpu
./cli_run/run.sh discretize    output/runs/spot/decomposition_*/stage_1_decomposition.hdf5  --headless --device cpu
./cli_run/run.sh hexahedralize output/runs/spot/discretization_*/stage_2_discretization.hdf5 --headless --device cpu
```
Each must exit 0. Expected wall times from CPU_ONLY.md §5: ~5 s / ~76 s / <1 s / ~269 s.

**F. Artifact parity gate:** run the reusable comparator against the pre-change
CUDA-build/CPU-device baseline. All per-stage topology, arrays and final quality
statistics must meet the preservation contract above. Also require stage 3's
`result_metrics.yaml` to read `total_hexes: 18526`, `inverted_count: 0`. These two
numbers are a useful acceptance check, but are not by themselves proof of result
preservation.

**G. Full CPU chain:** `SMOKE_DEVICE=cpu ./cli_run/smoke_test.sh` → PASS.

**H. GPU regression, last:** on the GPU box, the unchanged default build —
`./setup.sh --no-smoke && ./cli_run/smoke_test.sh` → PASS, 18526 / 0.

## Implementation order

1. Capture/repeat the pre-change CUDA-build + `--device cpu` baseline
2. CMake option + numeric `0/1` compile definition (Step 1)
3. Split / conditionally compile the CUDA translation units (Step 2, Step 3)
4. Compile geomlib + hex against CPU LibTorch in a bare `ubuntu:22.04` container (Step 4)
5. CPU unit tests (Step 5)
6. CPU Docker build + runtime images (Step 6)
7. `setup.sh` and runner integration (Step 7)
8. CPU acceptance + artifact parity (Verification E–G)
9. Unchanged default CUDA build + GPU regression (Verification H)
10. Documentation (Step 8)

## Non-goals

- Removing Vulkan from `hex` entirely — not needed to drop CUDA and intentionally sequenced
  afterward. See [no-vulkan-headless.md](no-vulkan-headless.md): Phase A proves a no-ICD
  runtime path; Phase B adds the true `HEX_ENABLE_VULKAN=OFF` build and the remaining two
  setup variants.
- ARM64 support.
- Speeding up the serial CPU kernel loops — deferred by decision.
- Any change to evocube (already CPU-only) or to the GPU code paths.
