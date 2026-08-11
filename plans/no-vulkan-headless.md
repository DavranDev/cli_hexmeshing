# Plan: Vulkan-free headless build (`./setup.sh --no-vulkan`)

Status: **recommended after the CPU-only prerequisite** — not yet implemented. Drafted
2026-07-29, rev. 3 coordinated with [cpu-only-build.md](cpu-only-build.md).

**Sequenced after [plans/cpu-only-build.md](cpu-only-build.md).** Land that first; this plan
assumes its `HEX_ENABLE_CUDA` option, its CPU Docker images, and its `setup.sh --cpu` flag
already exist. Together the two plans deliver the four-variant setup matrix.

## Context

Two outcomes were conflated in rev. 1 of this plan. They are different, and only the second
delivers the setup matrix:

| | Meaning | Removes | Still needs |
|---|---|---|---|
| **L2** — runtime | `--no-vulkan` flag. No `Instance`, `Device`, `Surface`, `RenderContext`, sampler or GPU buffer is ever created. No Vulkan API call is made. | ICD / graphics driver, lavapipe, validation layers, `VK_ICD_FILENAMES`, NVIDIA graphics capability | **`libvulkan-dev`** to build, **`libvulkan1`** to run — the binary still links the loader |
| **L3** — build | `-DHEX_ENABLE_VULKAN=OFF`. Renderer code is not compiled or linked at all. | all of the above **plus** `libvulkan-dev`, `libvulkan1`, imgui, glfw, glslang, SPIRV | nothing Vulkan |

**Rev. 1 claimed L2 "runs the whole scripted pipeline with no Vulkan of any kind" and that
the CPU-only image could drop `libvulkan-dev`. Both were wrong.** The root
[CMakeLists.txt](../interactive-hex-meshing/CMakeLists.txt) executes
`find_package(Vulkan REQUIRED)` and [vkoo/CMakeLists.txt](../interactive-hex-meshing/vkoo/CMakeLists.txt)
links `Vulkan::Vulkan`, so under L2 the executable retains a dynamic dependency on
`libvulkan.so.1`. A container without `libvulkan1` fails **before `main()` runs**, even with
`--no-vulkan` passed.

The accurate statement of what L2 delivers:

> makes no Vulkan API calls and requires no Vulkan ICD or graphics driver; the binary still
> links the Vulkan loader.

**Outcome of this plan (both phases):**

```bash
./setup.sh                    # CUDA + Vulkan
./setup.sh --cpu              # CPU  + Vulkan
./setup.sh --no-vulkan        # CUDA + headless-only, no Vulkan packages
./setup.sh --cpu --no-vulkan  # CPU  + headless-only, no Vulkan packages
```

`HEX_ENABLE_CUDA` (from `cpu-only-build.md`) and `HEX_ENABLE_VULKAN` (this plan) are
orthogonal CMake options; the four commands are their four combinations. The default build is
unchanged, so the GPU/GUI machine is unaffected.

### Why two phases, in this order

**Phase A (L2, runtime flag) is not optional scaffolding — it is how Phase B gets validated.**
A single binary that can run *both* with and without Vulkan lets you A/B the same compute and
require identical output. Once Phase B removes the renderer at compile time, that comparison
is impossible from one binary. Phase A also forces the view-lifetime refactor that Phase B
then merely deletes code around.

Phase A is independently shippable and delivers the no-ICD/no-driver win on its own.
However, reserve the user-facing setup flag `setup.sh --no-vulkan` for Phase B. During
Phase A, select the behavior with the executable/runtime flag only; otherwise the setup
command would misleadingly suggest that the image contains no Vulkan packages.

### Interlock with [plans/cpu-only-build.md](cpu-only-build.md)

That plan's Non-goals list this work as "a much larger renderer refactor." **That
characterization was right and rev. 1 of this plan was wrong to dispute it** — see "Coupling
found by the audit" below. Once this plan lands, amend that entry to point here.

Package changes to `cpu-only-build.md`'s Docker stages:

| Package | After Phase A | After Phase B |
|---|---|---|
| `mesa-vulkan-drivers` (lavapipe) | **drop** | drop |
| `vulkan-tools` | **drop** | drop |
| `VK_ICD_FILENAMES` env + ICD manifest handling | **drop** | drop |
| its Verification **D** (lavapipe device check) | **drop** | drop |
| its **amd64-only** restriction (arch-specific ICD manifest path) | **lift** | lift |
| `libvulkan-dev` (build) | keep | **drop** |
| `libvulkan1` (runtime) | keep | **drop** |

### Decisions taken

- **`DisplayMode` is the committed design, not an option.** No process-global
  `RenderEnabled()`. Renderer state does not belong in `optim/torch_utils` — that header owns
  the *compute* device and the two must stay independent.
- **`--no-vulkan` implies `--headless`**, one-way. There is no second render backend.
- **`--headless` keeps its current meaning** in Phase A. Not collapsed — see Non-goals.
- **Nullability lives at the orchestration boundary only.** `Application` owns
  `std::unique_ptr<Device>`; `GlobalController` receives `Device*`; **view constructors keep
  `Device&`.** The controller does not construct views without a device. Rev. 1's
  "~15 nullable leaves" approach is withdrawn.
- **Views are not partially initialized.** Skip construction; do not early-return from
  `Update()`. Rev. 1's leaf-guard approach would have left wrapper nodes without children,
  silently changed `IsEmpty()`, and kept `GetWrapperNode()` callable.
- **Each pipeline step keeps its own YAML** in `cli_run/configs/` and its own `hex` process.
  Unchanged.

### Measured cost of the Vulkan being removed

Measured 2026-07-29: RTX 4090, driver 595.71.05, `docker-hexmesh:latest`, Stage 2 on `spot`.

| What | Time |
|---|---|
| `hex --help` (returns before `Prepare()` → zero Vulkan) | **0.24 s** |
| `hex --headless --script discretize` (full stage) | **1.06 s** |
| Vulkan window in the log (`Prepare` entry → "skipped render pipelines and GUI") | **~600 ms** |
| `vulkaninfo --summary` (instance + GPU enumeration only) | 0.21 s |
| The actual discretization work | **10 ms** |
| Peak RSS: no Vulkan → full run | **296 MB → 454 MB** |

~600 ms of Vulkan setup to perform 10 ms of meshing. Validation layers were *not* active in
this container (a warning is printed), so this is pure driver + instance + device + scene
cost; where the SDK layers *are* present it is worse, because `main.cpp:58` hardcodes
`HexMeshingApp app{true}` unconditionally.

Since each step runs as its own process, the ~600 ms is paid four times per chain:
GPU chain (8.5 s per [cli_run/REPORT_LATEST.md](../cli_run/REPORT_LATEST.md) §8.1) → ~2.4 s
saved, **~28 %**. CPU chain (354.6 s) → **0.7 %, noise**. The *speed* win lands on the GPU
path; the *dependency* win lands on the CPU path.

## The actual Vulkan surface

Verified against the working tree 2026-07-29.

**Favourable finding — the scene graph is already Vulkan-free.** Every file under
`vkoo/include/vkoo/st` and `vkoo/src/st` grepped for `Vk`/`vulkan`: only `st/Image.h` and
`st/Image.cpp` hit. `Node`, `Scene`, `Transform`, `Material`, `Camera`, `Light`, the
hittables — plain C++/glm. Vulkan enters at one point: `st::Mesh` holds a
`vkoo::VertexObject`, whose `Update()` allocates a `core::Buffer`
([VertexObject.h:21](../interactive-hex-meshing/vkoo/include/vkoo/core/VertexObject.h#L21)).

**Favourable finding — outputs never read from a view or the scene.** `DumpQualityMetrics`
([MetricsDumper.cpp:44-53](../interactive-hex-meshing/hex/src/cli/MetricsDumper.cpp#L44))
reads `mesh.GetMeshQuality()` off `GlobalState`; `SaveProject` and `ExportTargetComplex`
likewise. No view function writes to `GlobalState`, and the one historical write-back
(`DecompositionStage.cpp:137-154`) is already re-routed in `RunFromScript`.

### Coupling found by the audit — rev. 1 underestimated this

Rev. 1 audited whether views **write** state. The review correctly identified that the real
risk is stage code **reading** views for control flow. Re-auditing on that basis found two
cases rev. 1 got wrong:

**1. `UnfocusCuboid()` joins the optimizer thread.**
[DecompositionStage.cpp:403-407](../interactive-hex-meshing/hex/src/controllers/stages/DecompositionStage.cpp#L403)
opens with `if (opt_thread_.joinable()) opt_thread_.join();` *before* any view work. It is
called from `Reoptimize()` (`:157`) and `ResetPolycube()` (`:296`) — **both on the script
path**. Rev. 1 classified this as "clear highlight — no state write." **Skipping it wholesale
would drop the join and race the optimizer.** The thread join must be split out and always
run; only the `GetCuboidNode` / `CuboidNode::UpdateMode` tail is view work.

**2. The visibility bitmask is non-visual state that lives inside `GlobalView`.**
[PipelineStage.cpp:11-17](../interactive-hex-meshing/hex/src/controllers/stages/PipelineStage.cpp#L11)
— `SwitchTo()` calls `GetGlobalView().SetVisibility(last_visibility_)` and `SwitchFrom()`
reads `GetGlobalView().GetVisibility()`. `SwitchStage` runs on the script path
(`GlobalController.cpp:238-249`). **So `global_view_` cannot simply be absent** until that
state is extracted. This is the architectural coupling the review predicted.

**Dereference inventory.** `GetGlobalView()` / `GetPolycubeView()` are called from **33 sites
outside `views/`**, spread across all four stages plus `PipelineStage` and `GlobalController`.
Each needs classifying as script-path or GUI-only during Step A3; the count is why Phase A is
a week rather than a day.

### What Phase B must remove

`vkoo` links `Vulkan::Vulkan stb spirv-cross-glsl imgui SPIRV glslang
glslang-default-resource-limits glfw glm spdlog`. ImGui/GLFW references in `hex/src`:

| File | refs |
|---|---:|
| `controllers/stages/HexahedralizationStage.cpp` | 127 |
| `controllers/stages/DecompositionStage.cpp` | 103 |
| `utility/ImGuiEx.cpp` | 85 |
| `controllers/GlobalController.cpp` | 50 |
| `controllers/stages/DeformationStage.cpp` | 43 |
| `controllers/stages/DiscretizationStage.cpp` | 38 |
| `controllers/CuboidEditingController.cpp` | 28 |
| `views/GlobalView.cpp`, `HexMeshingApp.cpp`, `ShortcutController.cpp` | 8, 2, 2 |

Note stage code uses GLFW constants directly (e.g. `GLFW_KEY_LEFT_SHIFT` at
`HexahedralizationStage.cpp:509`), so GUI code is interleaved at file level in every stage.
Phase B's real work is separating those translation units.

---

# Phase A — L2: `--no-vulkan` runtime flag

## Step A1 — `DisplayMode` plumbing

```cpp
enum class DisplayMode { Gui, HeadlessVulkan, HeadlessNoVulkan };
```

Threaded `main` → `HexMeshingApp::Prepare` → `Application::Prepare` → `GlobalController`.

| File | Change |
|---|---|
| [hex/src/main.cpp](../interactive-hex-meshing/hex/src/main.cpp) | parse `--no-vulkan`; resolve flags to one `DisplayMode`; imply headless and log it; help text |
| [vkoo/.../Application.h:26](../interactive-hex-meshing/vkoo/include/vkoo/core/Application.h#L26) | `virtual void Prepare(DisplayMode mode)` — **single parameter.** `Prepare(bool headless, bool no_vulkan)` is rejected: it admits the invalid `headless=false, no_vulkan=true` |
| `vkoo/.../Application.h` | expose `bool HasGraphicsDevice() const;` and `vkoo::Device* GetDevice();` |

No new process-global. `hex::ComputeDevice()` is untouched and stays independent.

## Step A2 — Extract non-visual state out of `GlobalView`

**Prerequisite for making `global_view_` absent.** Move the visibility bitmask
(`SetVisibility` / `GetVisibility` / `AddVisibility` / `RemoveVisibility`) out of `GlobalView`
into state owned by `GlobalController` (or `GlobalState`). `GlobalView` becomes a consumer of
that state rather than its owner.

Then `PipelineStage::SwitchTo/SwitchFrom` work with no view present, and the ~10 `SetVisibility`
call sites across the stages become pure state writes.

## Step A3 — Classify and rework the 33 view-dereference sites

For each of the 33 `GetGlobalView()` / `GetPolycubeView()` sites outside `views/`, classify:

- **script-path, purely visual** → guard behind `if (HasGraphicsDevice())` at the *call site*,
  or route through a controller method that no-ops without a view
- **script-path, load-bearing** → split the load-bearing part out (see `UnfocusCuboid` below)
- **GUI-only** (reachable only from `HandleInputEvent` / `DrawGui` / `Update`) → no change;
  unreachable when headless

Known must-fix items:

1. **`UnfocusCuboid()`** — split into `JoinOptimizerThread()` (always runs) and the view tail
   (guarded). Verify all 9 call sites still join.
2. **`GlobalView::UpdateMeshViewByInfo`** dereferences `view->` with no null check.
3. **`HexahedralizationStage`'s ctor** builds `landmarks_view_` + `pickable_surface_view_`
   unconditionally
   ([:33-42](../interactive-hex-meshing/hex/src/controllers/stages/HexahedralizationStage.cpp#L33));
   `UpdateCurrentSurface()` (`:70`) calls into them on the script path.
4. **`DecompositionStage::FocusCuboid`** (`:388`) reads `GetCuboidNode(id)` on the script path
   via `AddNewCuboid`.

Deliverable of this step is a table of all 33 sites with dispositions — produce it before
editing.

## Step A4 — Do not construct what needs a device

```cpp
if (device_ != nullptr) {
  global_view_ = std::make_unique<GlobalView>(*device_, scene_);
}
```

- `GlobalController::device_` becomes `vkoo::Device*`; **view constructors keep `Device&`.**
- `GetGlobalView()` returns `GlobalView*`, or callers route through no-op controller methods.
- **`CuboidEditingController` is not constructed** in no-Vulkan mode — change
  `DecompositionStage`'s member to `std::unique_ptr` rather than guarding its constructor
  body. A half-constructed controller whose later methods expect ctor-created nodes and
  materials is worse than an absent one. Its Vulkan allocations are at
  [:422](../interactive-hex-meshing/hex/src/controllers/CuboidEditingController.cpp#L422) and
  `:500`; `DecompositionStage` holds it as a plain member today, so it runs on every scripted
  decompose.
- On every remaining Vulkan-only method, `assert(device_ != nullptr)` — this distinguishes
  *intentionally skipped* view creation from *accidental* null use.

## Step A5 — Close the tap

| File | Change |
|---|---|
| [vkoo/src/core/Application.cpp](../interactive-hex-meshing/vkoo/src/core/Application.cpp) `Prepare` | skip `Instance`, `GetSuitableGPU()`, `Device`, `RenderContext` when `mode == HeadlessNoVulkan` |
| [hex/src/HexMeshingApp.cpp:45](../interactive-hex-meshing/hex/src/HexMeshingApp.cpp#L45) | skip `CreateSampler()` — it currently sits **outside** the `!headless` guard |

**Destructor invariant.** `Application::~Application` already guards `if (device_)` and
`if (surface_ != VK_NULL_HANDLE)`. Add an explicit invariant — *a surface cannot exist without
an instance* — and assert it, rather than relying on the two independent null checks lining up.

Already safe, no action needed: `PrepareSupportedSampleCountList` /
`PrepareDepthResolveModeList` are called only from `SetupRenderPipelines`
(`HexMeshingApp.cpp:607,610`), which headless already skips; `SaveScreenshot` and
`UpdatePipelines` are reachable only from `HandleInputEvent` / `DrawGui`.

## Step A6 — Runner integration

- [cli_run/run.sh:72](../cli_run/run.sh#L72) — forward `--no-vulkan`.
- [cli_run/smoke_test.sh:31-42](../cli_run/smoke_test.sh#L31) — add `SMOKE_NO_VULKAN`,
  mirroring `SMOKE_DEVICE`.

---

# Phase B — L3: `-DHEX_ENABLE_VULKAN=OFF` build variant

## Step B1 — Determine the no-Vulkan `vkoo` surface

**Do this as an investigation before committing to B2's structure.** `hex` needs from `vkoo`:
scene graph (`Node`, `Scene`, `Transform`, `Material`, `Camera`, `Light`), `hittables::Ray`,
`scripts::ArcBallCameraScript`, and `InputEvent` (appears in `HandleInputEvent` signatures in
every stage header). Confirm for each whether it is Vulkan-free, and specifically whether
`core/InputEvent.h` pulls in GLFW — if it does, stage *headers* need conditioning too, not
just their `.cpp` files.

`st::Mesh` is Vulkan-coupled (includes `VertexObject.h` + `ShaderModule.h`) and is used only
by views, so it can be excluded.

Output: the exact source list for a `vkoo-core` (scene graph, no Vulkan) versus `vkoo-render`
split.

## Step B2 — Split GUI translation units

Following the TU-splitting approach `cpu-only-build.md` Step 2 uses for CUDA. Per the table
above, GUI code is interleaved at file level in all four stages, `GlobalController`, and
`HexMeshingApp`. For each: move `DrawStageWindow` / `DrawGui` / `HandleInputEvent` / `Update`
into a `<Name>Gui.cpp`, keep `RunFromScript` and the non-visual methods in the base file, and
condition the GUI-only *members* in the header with `#if HEX_ENABLE_VULKAN`.

Excluded wholesale from the target when OFF: `hex/src/views/*.cpp`,
`controllers/CuboidEditingController.cpp`, `utility/ImGuiEx.cpp`, and the new `*Gui.cpp` files.

Phase A is what makes this safe: it has already proved every excluded path is unreachable on
the script path.

**Define the headless application boundary before doing the split.** The current
`PipelineScriptRunner` accepts `HexMeshingApp&` only to call `GetGlobalController()`, while
`GlobalController` itself stores `HexMeshingApp&`. A Vulkan-OFF target cannot simply retain
that arrangement: `HexMeshingApp.h` contains Vulkan types and inherits the Vulkan-heavy
`vkoo::Application`.

The preferred Phase-B shape is:

- change `PipelineScriptRunner` to accept `GlobalController&` directly;
- introduce a small non-rendering application/session owner that owns `Settings`, the
  Vulkan-free scene/state required by the stages, and `GlobalController`;
- remove `GlobalController`'s dependency on concrete `HexMeshingApp`. Move its genuinely
  non-visual settings needs behind a small interface or constructor data; move GUI-only
  calls (`SaveScreenshot`, input polling, pipeline updates) into the GUI translation unit;
- compile `HexMeshingApp` and `vkoo::Application` only when `HEX_ENABLE_VULKAN=ON`.

Do not solve this by surrounding the many Vulkan members of `HexMeshingApp.h` with scattered
preprocessor guards. A separate headless owner gives the OFF build a compile-time boundary
and prevents renderer dependencies from leaking back in.

## Step B3 — CMake option

- Root [CMakeLists.txt](../interactive-hex-meshing/CMakeLists.txt): make
  `find_package(Vulkan REQUIRED)` conditional on `HEX_ENABLE_VULKAN`; define it numerically
  (`0`/`1`), matching `cpu-only-build.md` Step 1's convention.
- [vkoo/CMakeLists.txt](../interactive-hex-meshing/vkoo/CMakeLists.txt): source list and
  `target_link_libraries` per variant. OFF drops `Vulkan::Vulkan imgui glfw glslang SPIRV
  spirv-cross-glsl glslang-default-resource-limits stb`, keeping `glm spdlog`.
- [external/CMakeLists.txt](../interactive-hex-meshing/external/CMakeLists.txt): skip
  `add_subdirectory(glfw)`, glslang, spirv-cross when OFF.
- `hex/CMakeLists.txt`: variant source globs.
- With OFF, `DisplayMode` collapses to headless-only; `--headless` becomes a no-op accepted
  for compatibility and the GUI path does not exist. `--no-vulkan` is also accepted as an
  idempotent compatibility flag. `main.cpp` must reject invocation without `--script` with a
  clear headless-only-build message.

## Step B4 — setup.sh and Docker

- `setup.sh`: add `--no-vulkan`, composable with `--cpu`. Skip `install_vulkan_sdk` and
  `install_host_vulkan_tools`; do not install `libvulkan-dev` / `libvulkan1` /
  `mesa-vulkan-drivers` / `vulkan-tools`; unset `VULKAN_SDK*`.
- `compile.sh`: skip `source_vulkan_sdk` under the no-Vulkan variant (it currently hard-errors
  when `setup-env.sh` is missing — same shape as the fix `cpu-only-build.md` Step 7 makes for
  `HEX_CPU_ONLY`).
- The `hex` wrapper also hard-errors when `lib/vulkan-sdk` is absent; condition that.
- Docker: a no-Vulkan build stage and slim runtime stage per variant.

## Step B5 — Documentation

- New `LEVEL 2` and `LEVEL 3` sections in [cli_run/HEADLESS.md](../cli_run/HEADLESS.md) §0;
  correct §6's design-A estimate with measured scope.
- Update [cli_run/SOURCE_CHANGES.md](../cli_run/SOURCE_CHANGES.md) footprint.
- Update `cpu-only-build.md`'s Non-goals entry and its Vulkan package lines per the interlock
  table.
- Document the four-variant matrix in [cli_run/BUILD.md](../cli_run/BUILD.md).

---

## Verification

**Capture the golden baseline before touching code.** Full chain at both devices on `spot`
plus one larger model; archive `result.mesh` + `result_metrics.yaml` + sha256. Artifacts for
`spot`, `bunny`, `horse` exist under `output/runs/`.

Run in this order — cheap and localizing first.

**A. Compile + behavior-unchanged after each of A1, A2, A4.** Each must leave output
identical; re-run `./cli_run/smoke_test.sh` between steps so a regression is attributable.

**B. Equivalence gate — the load-bearing test.** Same binary, same compute device, Vulkan on
vs off, so *any* difference is a bug introduced here.

Two tiers, because raw byte equality can fail for reasons unrelated to Vulkan (HDF5 embeds
creation timestamps; use `h5diff` for those, not `cmp`):

1. **Byte equality where serialization is deterministic** — `result.mesh` (MEDIT text) and
   `result_metrics.yaml`:
   ```bash
   sha256sum <run_a>/result.mesh <run_b>/result.mesh          # must match
   diff <run_a>/result_metrics.yaml <run_b>/result_metrics.yaml   # must be empty
   ```
2. **Structural comparison if tier 1 fails** — parse both and compare vertex/cell counts,
   connectivity, and coordinates exactly, or to an explicitly justified tolerance.
   **Do not silently fall back to the `18526 / 0` smoke criterion** — that gate is too weak to
   catch a subtle regression in a change of this shape.

Repeat on `spot`, `bunny`, `horse`, at both `--device cuda` and `--device cpu`.

**C. Instance-never-created assertion (code-level seam).** Expose or log whether Vulkan
objects were created and assert, in no-Vulkan mode:
```text
instance_ == nullptr, device_ == nullptr,
surface_ == VK_NULL_HANDLE, render_context_ == nullptr
```
Cheaper and more precise than inferring it from the environment.

**D. No-ICD proof (Phase A).** Container with:
- `libvulkan1` loader **installed**
- **no** Mesa Vulkan drivers
- **no** NVIDIA Vulkan driver mounts (`NVIDIA_DRIVER_CAPABILITIES` not `all`)
- **no** ICD manifests under `/usr/share/vulkan/icd.d`
- **no** `VK_ICD_FILENAMES`

The full chain must succeed. This is exactly what L2 claims and no more.

**E. No-package proof (Phase B).** `dpkg-query` shows no `libvulkan*`, `mesa-vulkan-drivers`,
`vulkan-tools`; `ldd` on every shipped ELF shows no `libvulkan`:
```bash
docker run --rm hexmesh-novk:latest bash -c '
  dpkg-query -W 2>/dev/null | grep -Ei "vulkan" && exit 1
  found=0
  while IFS= read -r f; do
    file "$f" | grep -q ELF || continue
    ldd "$f" 2>/dev/null | grep -qi vulkan && { echo "vulkan dep in $f"; found=1; }
  done < <(find /space -type f \( -perm -111 -o -name "*.so*" \))
  exit $found'
```

**F. Each stage separately, own YAML** — the acceptance test, with `HEX_LOCAL=1`:
```bash
./cli_run/run.sh deform        assets/tutorial/spot.mesh                                     --headless --no-vulkan
./cli_run/run.sh decompose     output/runs/spot/deformation_*/stage_0_deformation.hdf5       --headless --no-vulkan
./cli_run/run.sh discretize    output/runs/spot/decomposition_*/stage_1_decomposition.hdf5   --headless --no-vulkan
./cli_run/run.sh hexahedralize output/runs/spot/discretization_*/stage_2_discretization.hdf5 --headless --no-vulkan
```
Each exits 0; stage 3 reads `total_hexes: 18526`, `inverted_count: 0`. **All four stages must
run** — stage constructors are the likely source of missed dereferences, and Stage 1
(`FocusCuboid`, `UnfocusCuboid`) and Stage 3 (view-heavy ctor) are the ones to push hardest.

**G. CLI contract:**
- `hex --no-vulkan` with no `--script` → clear error, non-zero exit
- `hex --no-vulkan --device cuda` and `--device cpu` both work in their respective builds
- GUI-only operations are unreachable in no-Vulkan mode

**H. Matrix regression, last.** All four `setup.sh` variants build and pass their smoke test;
the default CUDA+Vulkan GUI build is bit-unchanged.

**I. Link-interface closure (Phase B).** In addition to checking `libvulkan`, inspect the
no-Vulkan target's direct and transitive link interface for renderer libraries (`glfw`,
`imgui`, `glslang`, `SPIRV`, `spirv-cross`, GL/X11 where no remaining dependency requires
them). This catches a nominally disabled dependency that happens not to appear in one
particular `ldd` output because it was statically linked or removed by `--as-needed`.

## Implementation order

**Prerequisite:** [plans/cpu-only-build.md](cpu-only-build.md) landed and green.

1. Golden baseline capture
2. `DisplayMode` plumbing (A1) → Verification A
3. Extract visibility state from `GlobalView` (A2) → Verification A
4. Produce the 33-site disposition table (A3)
5. Rework the load-bearing sites — `UnfocusCuboid` thread join first (A3)
6. Skip construction of view-owning objects (A4) → Verification A
7. Skip `Instance`/`Device`/sampler + destructor invariant (A5)
8. **Equivalence gate on GPU (Verification B)** — validate here first: 8.5 s per chain vs
   ~6 min on CPU, ~40× faster iteration
9. Instance-never-created assertion + no-ICD proof (C, D)
10. Per-stage acceptance + CLI contract (F, G)
11. Runner integration (A6) — **Phase A shippable here**
12. `vkoo` no-Vulkan surface investigation (B1)
13. Decouple `PipelineScriptRunner`/`GlobalController` from concrete `HexMeshingApp` and add
    the headless application/session owner (B2)
14. GUI translation-unit split (B2)
15. CMake option (B3)
16. `setup.sh` / `compile.sh` / Docker (B4)
17. No-package proof (E), link-interface closure (I), matrix regression (H)
18. Documentation (B5)

## Effort and risk

**Phase A ≈ 1.5 weeks. Phase B ≈ 2 weeks. Total ≈ 3–4 weeks.**

Rev. 1 estimated 2.5 days. That was based on an audit that asked only whether views *write*
state; re-auditing for *reads* found the `UnfocusCuboid` thread join and the visibility-state
coupling, and the four-variant build matrix is a different and larger goal than the runtime
flag. This is a project, not a task.

**Phase A main risk** — 33 dereference sites to classify; a misclassification is either a
crash (guarded too little) or a silent behavior change (guarded too much, as would have
happened with `UnfocusCuboid`). The equivalence gate catches wrong results; only running all
four stages catches an unguarded path. Mitigation: produce the disposition table before
editing, and assert on Vulkan-only methods.

**Phase B main risk** — TU splitting touches every stage file. Mitigation: Phase A has already
proved the excluded paths unreachable, so B2 is deletion guided by evidence rather than
judgement.

**Shared risk** — this deepens divergence from upstream CDM, raising merge cost.
`SOURCE_CHANGES.md` exists to track it; keep changes additive and behind the options, as was
done for `--headless` and `--device`.

## Non-goals

- **Combining pipeline steps into one YAML or one process.** Each step keeps its own config
  and its own `hex` invocation.
- **Making `--headless` imply `--no-vulkan` in Phase A.** The right end state, but collapsing
  it during Phase A destroys the equivalence gate. Revisit after Phase B, when the build
  variant makes the distinction structural.
- **Compute performance.** No optimizer, kernel, or `--device` behavior is touched. The CPU
  kernel parallelization in [cli_run/CPU_ONLY.md](../cli_run/CPU_ONLY.md) §5 is separate.
- **The GUI in the default build.** Unchanged; covered by Verification H.
- **A GUI that works without Vulkan.** There is no second render backend and none is proposed.
- **Any change to evocube.**
