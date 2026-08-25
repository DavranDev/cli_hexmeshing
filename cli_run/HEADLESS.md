# Headless mode — design + implementation

> **STATUS (2026-08-13): LEVEL 1, LEVEL 2 and LEVEL 3 are all implemented.**
> §0 records LEVEL 1 (`--headless`, surfaceless Vulkan, Week 3).
> **§0.2 records LEVEL 2 (`--no-vulkan`) and §0.3 records LEVEL 3
> (`-DHEX_ENABLE_VULKAN=OFF`)**, both from
> [plans/no-vulkan-headless.md](../plans/no-vulkan-headless.md).
> Sections 1–7 are the original Week-2 feasibility trace, kept verbatim as
> design rationale. Where §6 estimates the cost of "design A", see §0.2 —
> the measured scope was much larger than that estimate.

**Question the memo answered:** what stands between today's `--exit-after` *GUI
automation* (the window opens, the script runs, the window closes) and a true
`--headless` mode that needs no on-screen window — and how big is that change?

It answers it from a source trace of the startup path and every stage's view call
sites, plus an `xvfb` experiment, and recommended **design B (surfaceless
Vulkan)**. Week 3 promoted that recommendation to code.

---

## 0. Implementation (Week 3, T1)

### What was built — design B / "LEVEL 1" (surfaceless Vulkan)
A real `--headless` flag where **no GLFW window, Vulkan surface, swapchain, render
pipelines or GUI are ever created**. The `VkInstance` + logical `Device` are still
created (surfaceless), so the compute path and the view objects can allocate GPU
buffers exactly as before — nothing is ever presented. The tool takes the input,
runs the scripted pipeline, writes output, and exits. (Contrast `--exit-after`,
which still *opens* a window and then closes it.)

`LEVEL 2` (drop the Vulkan device entirely — the memo's "design A") was **not**
taken *at the time*, and the reason given was right: `GlobalController` held a
`vkoo::Device&` by reference and `GlobalView` eagerly built Vulkan sub-views at
construction, so removing the device meant rewriting the controller/view
classes. **That rewrite has since been done — see §0.2.** The ~1–1.5 wk estimate
was for the device removal alone; the full LEVEL 2 + LEVEL 3 work took
substantially more, because the coupling was through *reads* (a thread join and
a visibility bitmask living inside a view), not just through construction.

### The change is additive and confined to startup (5 files, ~1 stage untouched)
| File | Change |
|---|---|
| `hex/src/main.cpp` | parse `--headless`; pass to `Prepare(headless)`; skip `MainLoop()` (exit after script); usage text. `--headless` requires `--script`. |
| `vkoo/include/vkoo/core/Application.h` | `Prepare(bool headless=false)`; add `headless_`; default-init `window_{nullptr}`, `surface_{VK_NULL_HANDLE}`. |
| `vkoo/src/core/Application.cpp` | guard `PrepareWindow`/glfw surface exts/`CreateSurface`/`VK_KHR_swapchain`/`RenderContext` behind `!headless`; `GetWindowSize` falls back to starter dims when there is no swapchain; guard window/GLFW teardown in the dtor. |
| `hex/src/HexMeshingApp.{h,cpp}` | `Prepare(bool)`: skip `SetupRenderPipelines()` + `gui_` when headless. |
| `cli_run/run.sh` | forward a `--headless` flag to the `hex` invocation. |

**No stage/optimizer/view files were edited.** The memo's §4 listed the class-(a)
view-update call sites as candidates to guard; that turned out **unnecessary under
LEVEL 1** because (verified by grep) **no controller or view references
`render_context_` or `gui_`** — they only touch `device_` (which still exists) and
the scene. So those calls run harmlessly and never dereference the skipped
swapchain/GUI. The two GUI-only touchpoints that *do* use the swapchain —
`SaveScreenshot` (F10 key) and `UpdatePipelines` (an ImGui checkbox) — are reachable
only from `HandleInputEvent`/`DrawGui`, which the script path never enters.
Why this is safe at the Vulkan layer: `PhysicalDevice::IsPresentSupported()`
already no-ops on a `VK_NULL_HANDLE` surface, and the only throw-on-no-present
path (`Device::GetSuitableGraphicsQueue`) is called solely by `RenderContext`,
which headless skips.

### Startup trace — before vs after
| Step (`HexMeshingApp::Prepare` → `vkoo::Application::Prepare`) | GUI (default) | `--headless` |
|---|---|---|
| `glfwInit` + `glfwCreateWindow` + input callbacks | ✔ | **skipped** |
| glfw-required surface instance extensions | ✔ | **skipped** (only `VK_KHR_get_physical_device_properties2`) |
| `VkInstance` | ✔ | ✔ |
| `glfwCreateWindowSurface` → `VkSurfaceKHR` | ✔ | **skipped** (`surface_` stays `VK_NULL_HANDLE`) |
| logical `Device` (+ `VK_KHR_swapchain`) | ✔ (with swapchain ext) | ✔ (**no** swapchain ext) |
| `RenderContext` (swapchain) | ✔ | **skipped** |
| `HexConvention`, `CreateSampler`, `SetupScene` (controller + views) | ✔ | ✔ |
| `SetupRenderPipelines`, `Gui` | ✔ | **skipped** |
| `MainLoop` (per-frame render/present) | ✔ | **never entered** |

### Verification
- **Compile:** clean incremental build in the `docker-hexmesh` env image
  (CUDA 12.4 toolchain, **no GPU needed to build**): `[100%] Built target hex`.
- **`hex --help`** lists `--headless`.
- **`hex --headless --script <cfg>` with `DISPLAY` unset** (this driverless box):
  ```
  [info] workspace path: /space/interactive-hex-meshing/bin/Release
  [info] vkoo: headless mode - skipping window, surface and swapchain (surfaceless Vulkan).
  Validation layer: terminator_CreateInstance: Failed to CreateInstance in ICD 2.  Skipping ICD.
  terminate called after throwing an instance of 'std::runtime_error'  what():  Ugh!   # exit 134
  ```
  The headless log line prints, **no GLFW/X11/window step runs**, and execution
  reaches the `vkCreateInstance` boundary with **no `DISPLAY` and no xvfb** — the
  only remaining failure is the missing GPU **ICD/driver** on this box. That is the
  expected clean stop and proves the window/surface/swapchain path was skipped in
  code — the same Vulkan boundary the Week-2 `xvfb` experiment (§5) hit.

### Definition of done — metric gate PASSED (T1.6, 2026-06-18)
The **metric gate** is the real definition of done: `hex --headless` must produce
**0 inverted hexes and metrics identical to the GUI/`--exit-after` run**. Run on the
RTX 4090 (driver 580.159.03), full chain on `spot.mesh`, **`--headless` with no
`DISPLAY`**, the final `result_metrics.yaml` is:
```
total_hexes: 18526        # identical to the GUI / xvfb smoke run (§5)
inverted_count: 0         # PASS — hard gate met
scaled_jacobian: min 0.0244 / mean 0.862 / max 0.9997
```
So `--headless` is **done**: it runs the whole pipeline with no window and matches
the GUI result. (Per-stage GPU evidence for the same run is in
[DEPENDENCY_MAP.md](DEPENDENCY_MAP.md) §4.)

### Usage
```bash
# direct binary (in-container / native; no DISPLAY, no xvfb):
./hex --headless --script cli_run/configs/stage_deformation.yaml

# via the wrapper (forwards --headless):
HEX_LOCAL=1 ./cli_run/run.sh deform input.mesh --headless
```

---

## 0.2 LEVEL 2 — `hex --no-vulkan` (runtime flag)

**What it is:** the same binary, told at run time to create no Vulkan object at
all. No `Instance`, no physical-device enumeration, no `Device`, no
`RenderContext`, no sampler, and no view.

**What it removes:** the need for a Vulkan ICD, a graphics driver, lavapipe,
validation layers and `VK_ICD_FILENAMES`.

**What it does NOT remove:** the binary still *links* `libvulkan.so.1`, because
`find_package(Vulkan REQUIRED)` and `Vulkan::Vulkan` are still in the build. A
container needs `libvulkan1` present or the process fails before `main()`.
Removing that is LEVEL 3.

```bash
hex --script run.yaml --no-vulkan            # implies --headless
./cli_run/run.sh deform in.mesh --no-vulkan
SMOKE_NO_VULKAN=1 ./cli_run/smoke_test.sh
```

### Why it needed a refactor rather than a flag

Two things had to move before the view could simply be absent:

1. **`DecompositionStage::UnfocusCuboid()` opened with an optimizer-thread
   join**, and four of its nine callers are on the script path. Skipping the
   function to skip its view work would have raced the optimizer. The join is
   now `JoinOptimizerThread()` and always runs.
2. **The visibility bitmask was non-visual state living inside `GlobalView`.**
   It moved to `GlobalController`; `GlobalView` only consumes it now.

All view dereferences were classified before the refactor. The audit criteria
and the load-bearing cases are recorded in
[the main no-Vulkan plan](../plans/no-vulkan-headless.md), Step A3.

### Proof

`Application::HasAnyVulkanObject()` is asserted **and logged** after `Prepare`,
so a release run states it:

```
No-Vulkan mode: skipped sampler, render pipelines, GUI and every view;
vulkan_objects_created=false
```

In a container with the loader installed but no ICD and no driver
(`vulkaninfo` → `ERROR_INCOMPATIBLE_DRIVER`), `--no-vulkan` completes all four
stages while `--headless` on the same config fails. That contrast is the proof.

---

## 0.3 LEVEL 3 — `-DHEX_ENABLE_VULKAN=OFF` (build variant)

**What it is:** the renderer is not compiled or linked. `vkoo` builds 17 source
files (the scene graph plus two Vulkan-free odds and ends) instead of the full
tree, and links **`glm spdlog`** and nothing else.

**What it removes:** everything LEVEL 2 removes, **plus** `libvulkan-dev`,
`libvulkan1`, imgui, glfw, glslang, SPIRV, spirv-cross, stb, and the GL/X11
packages that existed only for glfw.

```bash
./setup.sh --no-vulkan              # CUDA + headless-only
./setup.sh --cpu --no-vulkan        # CPU  + headless-only
docker build -f Dockerfile.novk --target runtime -t hexmesh-novk:latest .
```

`--headless` and `--no-vulkan` are still **accepted** by an OFF binary, as
idempotent no-ops, so existing command lines and scripts keep working.
`--script` becomes mandatory: there is no GUI to open.

### How the split works

`InputEvent.h` turned out to have no includes at all — no GLFW, no Vulkan — so
**no stage header needed conditioning** and every
`HandleInputEvent(const vkoo::InputEvent&)` signature survives verbatim. The
split is therefore `.cpp`-level:

| Kept in every build | Compiled only when ON |
|---|---|
| `<Stage>.cpp` — `RunFromScript` and all non-visual methods | `<Stage>Gui.cpp` — `DrawStageWindow` / `HandleInputEvent` / `Update` |
| `GlobalController.cpp` | `GlobalControllerGui.cpp` |
| `HeadlessSession.{h,cpp}` — the non-rendering owner | `HexMeshingApp.{h,cpp}`, `views/*`, `CuboidEditingController`, `ImGuiEx` |

`PipelineScriptRunner` now takes `GlobalController&` rather than
`HexMeshingApp&`, and `GlobalController` takes `Settings&`, `vkoo::Device*` and
`vkoo::st::Scene&` as constructor data instead of holding the application. The
renderer-free dependency-closure analysis is recorded in
[the main no-Vulkan plan](../plans/no-vulkan-headless.md), Step B1.

### The four variants

| Command | CUDA | Vulkan | GUI |
|---|---|---|---|
| `./setup.sh` | ✔ | ✔ | ✔ |
| `./setup.sh --cpu` | ✘ | ✔ | ✔ |
| `./setup.sh --no-vulkan` | ✔ | ✘ | ✘ |
| `./setup.sh --cpu --no-vulkan` | ✘ | ✘ | ✘ |

All four share `bin/Release/hex`, so `bin/Release/.hexmesh-variant` now records
both `variant=` and `renderer=`, verified against the built binary's `--help`
rather than against what was requested. The runner scripts refuse a mismatched
launch.


---

## 1. TL;DR

- **Two independent dependencies, often conflated.** *(V) Vulkan window + X11
  display* are used **only** to show the GUI. *(C) CUDA / libtorch + geomlib
  kernels* do the actual pipeline math. A headless mode removes (V); it does
  **not** touch (C). (CPU-only — removing (C) — is the separate Week-3 question.)
- **What works on a headless server TODAY (verified):** `xvfb-run ./cli_run/smoke_test.sh`
  ran the full pipeline with no `DISPLAY` at all and printed **PASS — 18 526 hexes,
  0 inverted** on a GPU host (RTX 4090, 2026-06-17; §5). Zero code changes — the
  design-C stopgap is real right now.
- **The compute path does not need the Vulkan device.** The optimizers are
  libtorch/CUDA and are independent of vkoo's Vulkan device. The Vulkan device is
  needed only by the **view objects** (their construction + vertex-buffer
  uploads), and every view call on the script path is **display-only**.
- **Side-effect audit is clean.** Across all four stages, the script path has
  **zero** "view call that secretly does real work" cases beyond the one we
  already fixed (the Stage-1 optimized-polycube writeback). Every state write
  lives in stage logic, *before/independent of* the view call. So `--headless` is
  a **guarding / startup change, not a logic rewrite.**
- **Recommended path:** ship **xvfb-run as the documented stopgap now** (§6-C),
  implement a **surfaceless-Vulkan `--headless`** as the real engineered mode
  (§6-B, ~4-5 startup files, stage code untouched), and treat a **no-Vulkan
  CUDA-only** mode (§6-A) as a larger Week-3 item folded into the CPU-only work.

---

## 2. Where the window / Vulkan / GUI come from (startup trace)

`main()` ([hex/src/main.cpp](../interactive-hex-meshing/hex/src/main.cpp)) builds
the app and calls `app.Prepare()` **before** the `--script` branch — so the window
exists purely because `Prepare()` made it; the script path then *skips*
`MainLoop()` when `--exit-after`/`keep_window_open:false` is set, so per-frame
rendering is already absent.

`HexMeshingApp::Prepare()` (`HexMeshingApp.cpp:38-49`) calls, in order:

| Step | What it creates | Needs a display? | Needs the GPU? |
|---|---|---|---|
| `vkoo::Application::Prepare()` (`vkoo/src/core/Application.cpp:64-94`) | see breakdown below | yes (window+surface) | yes (Vulkan) |
| `HexConvention::Initialize()` | CPU lookup tables | no | no |
| `CreateSampler()` | a `VkSampler` (via `device_`) | no | yes |
| `SetupScene()` | scene, camera, lights, **`GlobalController`** | no | yes (controller holds `device_`) |
| `SetupRenderPipelines()` | gbuffer/ssao/lighting/transparent/postproc graphics pipelines | no | yes |
| `gui_ = vkoo::Gui(...)` | ImGui context | no | yes |

`vkoo::Application::Prepare()` itself (`Application.cpp:64-94`):

1. `PrepareWindow()` → `glfwInit()`, `glfwCreateWindow(...)` **← the only true X11/
   display dependency**, plus input callbacks.
2. `glfwGetRequiredInstanceExtensions()` → the surface extensions GLFW needs.
3. `instance_ = Instance(...)` → `VkInstance` (+ validation layers).
4. `CreateSurface()` → `glfwCreateWindowSurface()` → `VkSurfaceKHR` (needs the window).
5. `instance_->GetSuitableGPU()` → picks the physical device.
6. `device_ = Device(gpu, surface_, {VK_KHR_SWAPCHAIN, ...})` → logical device,
   **created with the surface** for present-queue selection + swapchain extension.
7. `render_context_ = RenderContext(device_, surface_, ...)` → swapchain.

**Key dependency fact.** `GlobalController`
(`controllers/GlobalController.cpp:39-40,65-68,104`) stores `vkoo::Device&` and
`Scene&` *references* and, in its constructor, builds **all four stages** and the
**`GlobalView`** (which eagerly builds Vulkan sub-views — `GlobalView.cpp:111,125,
163,335,355`). So the Vulkan `device_` is threaded through the controller → view →
stage objects by reference. The **compute** never calls `device_`; the **views**
(construction + buffer uploads) do. That is the whole of the headless problem.

---

## 3. Does the compute path need the vkoo Vulkan device? — No.

The optimizers (`CubicVolumetricDeformer`, `PolycubeOptimizer`,
`HexComplexDeformer`) and the SDF / projection / Hausdorff math are **libtorch
CUDA + geomlib `.cu` kernels**. They run on their own CUDA context, with no
reference to vkoo's `device_`. The only consumers of `device_` are the view
classes (`TriSurfaceView`, `QuadSurfaceView`, `PolycubeView`, `HexCollectionView`,
`LandmarksEditingView`) — all of which exist to put geometry on screen. The saved
output (`SaveProject` HDF5, `ExportTargetComplex` `.mesh`, the metrics sidecar) is
read from `GlobalState`, never from a rendered frame.

---

## 4. Call-site classification (the core of the memo)

Class **(a)** = pure display update, safe to skip headless · **(b)** = does real
work as a side effect (must be re-routed) · **(c)** = reachable only via mouse/UI,
never runs in `--script`.

| Stage | Script-path view site (`file:line`) | What it does | State write that matters (separate) | Class |
|---|---|---|---|---|
| 0 deform | `DeformationStage.cpp:208-213` `UpdateDeformationViews()` (called from `Reoptimize:169`) | `UpdateDeformedMeshView` + `SetVisibility` | `SetDeformedVolumeMesh` at `:166`, before the view | **a** |
| 1 decompose | `DecompositionStage.cpp:462-463` `UpdateAnchorsView` (in `CreateSdfAndAnchors:447`) | anchors view + visibility | `CreateAnchors`/`CreateDistanceField` at `:456-460` | **a** |
| 1 decompose | `:300-303` `UpdatePolycubeView` (in `ResetPolycube:295`) | polycube view + visibility | `SetPolycube`/`SetPolycubeInfo` at `:297-299` | **a** |
| 1 decompose | `:263-266` `polycube_view.AddCuboid` + `FocusCuboid` (in `AddNewCuboid`, via `SuggestNewCuboid`) | add/highlight cuboid | `polycube.AddCuboid` `:258`, `PolycubeInfo.Push` `:261` | **a** |
| 1 decompose | `:157` `UnfocusCuboid` (in `Reoptimize`) | clear highlight | — | **a** |
| 1 decompose | `:137-154` `Update()` GUI per-frame writeback | `SetPolycube` + `polycube_view.Update` | **already re-routed**: `RunFromScript:243-244` writes `GetOptimizedPolycube()` once | **b → fixed** |
| 2 discretize | `DiscretizationStage.cpp:109-112` `UpdatePolycubeComplexView` (in `DiscretizePolycube`) | complex view + visibility | `current_graph_`/`quad_complex`/`surface` at `:104-107` | **a** |
| 2 discretize | `:120-123` `UpdatePolycubeComplexView` (in `FinalizePolycube`) | complex view + visibility | `SetPolycubeComplex(GenerateHexComplex())` at `:118` | **a** |
| 2 discretize | `:175-274` `pending_view_` / `HandleQuadClicked` / `ApplyPendingChanges` | interactive dig/extrude hex viz | edits live in `pending_hex_coords_` + `current_graph_` rebuild, not the view | **c** |
| 3 hexahedralize | `HexahedralizationStage.cpp:33-42` **ctor** builds `landmarks_view_` + `pickable_surface_view_` via `GetDevice()` | allocate 2 Vulkan views | — (construction only) | **a (ctor)** |
| 3 hexahedralize | `:62-71` `UpdateCurrentSurface` (in `UpdateOnTargetComplexChange:520`) | surface/landmark view update | `SetResultMesh(ExtractHexMesh())` at `:518` | **a** |
| 3 hexahedralize | `:556-560` `UpdateFilteredMeshView` (in `UpdateOnTargetComplexChange:522`) | filtered hex view | (result already in state) | **a** |
| 3 hexahedralize | `:495-502` `FetchSnapshot`→`AddVisibility` (only via per-frame `Update`) | async snapshot viz | script sets `snapshot_freq=-1` (`:469`) → blocking, never runs | **c** |
| 3 hexahedralize | `:808-913` mouse landmark/pick sites | interactive editing | — | **c** |

**Headline:** every script-path site is **(a)** except the **one (b) we already
fixed**. The construction choke points are `GlobalController` building `GlobalView`
+ the four stages, and `HexahedralizationStage`'s constructor — these allocate
Vulkan view objects whether or not anything is drawn.

---

## 5. `xvfb` experiment (run in the Week-2 image)

```bash
# inside hexmesh-cli:week2
apt-get install -y xvfb
xvfb-run -s "-screen 0 1280x720x24" ./cli_run/run.sh deform \
  interactive-hex-meshing/assets/tutorial/spot.mesh --exit-after   # HEX_LOCAL=1
```

**Result on this (no-GPU) host:**
```
[info] workspace path: ...
Validation layer: vkCreateInstance: Found no drivers!
terminate called after throwing an instance of 'std::runtime_error'  what(): Ugh!
Aborted (core dumped)            # exit 134
```

**Reading it — this is a *positive* data point:**
- `glfwInit()` + `glfwCreateWindow()` **succeeded against the Xvfb virtual
  display** — the X11/window step (the (V) "display" half) is satisfied by Xvfb
  with **zero code changes**. `hex --help` also runs under Xvfb (exit 0).
- The run then stopped at **`vkCreateInstance: Found no drivers!`** — there is no
  Vulkan **ICD** because this box has no NVIDIA driver. That is the **GPU/Vulkan**
  dependency, *not* the display dependency. (The Vulkan loader + SDK validation
  layers are present — hence the `Validation layer:` prefix — only the driver ICD
  is missing.)
- **On a host with an NVIDIA GPU this is now VERIFIED.** With the driver present
  and `NVIDIA_DRIVER_CAPABILITIES=all` (the container toolkit injects the ICD —
  do *not* bind-mount the host `/usr/share/vulkan`), `xvfb-run ./cli_run/smoke_test.sh`
  ran the whole pipeline with **no `DISPLAY` and no X socket** and printed
  **PASS — 18 526 hexes, 0 inverted** (RTX 4090, driver 580.159.03, 2026-06-17).
  So headless-server operation via a virtual display works **today**, zero code
  changes — exactly the design-C stopgap.

So Xvfb cleanly resolves (V-display); the only thing it still requires is
(V-Vulkan/GPU), which is the same GPU the math needs anyway.

---

## 6. Candidate designs + effort

| | Mechanism | Files touched | Removes | Still needs | Effort (incl. validation) |
|---|---|---|---|---|---|
| **C** | **`xvfb-run` stopgap** (no code) | docs only | on-screen window / real X server | GPU + Vulkan ICD | **~0.5 day** — available now |
| **B** | **Surfaceless-Vulkan `--headless`**: skip `PrepareWindow`/`CreateSurface`/swapchain + `SetupRenderPipelines`/`Gui`; create the device without a window surface (or `VK_EXT_headless_surface`) | vkoo `Application::Prepare`, `Device`, `RenderContext`; `HexMeshingApp::Prepare`; a `--headless` flag from `main.cpp` → ctor (**~4-5 startup files; stage + view code untouched**) | window + X11 entirely | GPU + Vulkan device (views still allocate buffers, nothing presents) | **~2-3 days** |
| **A** | **No-Vulkan CUDA-only**: make `GlobalView` a no-op headless, stop `GlobalController` holding a live `vkoo::Device&` (reference → optional/null device), guard the ~10 (a) view calls + `HexahedralizationStage` ctor + `GlobalView` sub-view construction | `GlobalController`, `GlobalView` (whole class), `HexahedralizationStage` ctor, the ~10 `GetGlobalView()` sites across the 4 stages (**~6-8 files incl. core controllers**) | window + X11 **+ Vulkan** | GPU only via CUDA (no Vulkan) | **~1-1.5 weeks** |

> **CORRECTION (2026-08-13), from having built A.** Row **A**'s estimate was
> **wrong, and wrong in both directions.** Measured against the delivered work:
>
> | | §6 estimate | Measured |
> |---|---|---|
> | Files touched | ~6–8 | **42** (33 modified + 9 new), across two phases |
> | View call sites to guard | "~10 `GetGlobalView()` sites" | **44 dereferences** — 31 `GetGlobalView()`/`GetPolycubeView()` calls outside `views/`, plus 4 inside `GlobalController` and 9 stage-owned views |
> | Effort | ~1–1.5 weeks | Phase A + Phase B, and Phase B was the larger half |
>
> The estimate missed the coupling because it counted *writes* to views. The two
> things that actually made this hard were **reads**:
> `DecompositionStage::UnfocusCuboid()` opening with an optimizer-thread join
> that four script-path callers depend on, and the visibility bitmask being
> non-visual state that happened to live inside `GlobalView`. Neither is visible
> in a count of view-update calls.
>
> Row A also conflated two outcomes that turned out to be separate deliverables:
> making no Vulkan *call* (LEVEL 2, §0.2) and linking no Vulkan *at all*
> (LEVEL 3, §0.3). Only the second removes the packages.
>
> Row **B**'s estimate held up: `--headless` landed in ~2–3 days as predicted,
> and its claim that stage/view code needed no changes was correct **for B**.

Notes:
- **B is the smallest real `--headless`.** Because no script-path view call is
  load-bearing (§4), the views can keep running against a window-less Vulkan
  device and simply never be presented; the stage/optimizer code needs **no**
  changes. Risk is contained to Vulkan startup (surfaceless device + skipping the
  swapchain-bound render pipelines and the GUI).
- **A is the "true" headless** (no Vulkan, no X — CUDA only) but it changes core
  controller/view class structure and is really the *front half of the CPU-only
  question* (Week-3): once `GlobalView` is a no-op and the device is gone, the only
  remaining GPU use is CUDA. Recommend doing A **together with** the CPU-only
  analysis rather than as a standalone refactor.

---

## 7. Why memo, not prototype (this week)

Plan T2.5: prototype only if it is `< ~10` sites with zero new (b)-class side
effects **and can be finished *and validated* by Friday**. Two of those hold and
one does not:
- ✅ **Zero new (b)-class** side effects (§4) — the risky part is clear.
- ⚠️ **Site count / structure:** design **B** is contained but is fiddly Vulkan
  startup work; design **A** exceeds ~10 sites and changes core class signatures
  (`vkoo::Device&` is a *reference* member of `GlobalController`).
- ❌ **Cannot validate here.** A headless prototype is only "done" when
  `smoke_test.sh` still yields **0 inverted hexes, identical hex count** vs the GUI
  run. That needs a working Vulkan/GPU, which this host lacks (`Found no drivers!`,
  §5). Shipping an unvalidated startup refactor would risk silent breakage we
  could not catch — exactly what the plan's guardrail forbids.

So the Week-2 deliverable is this memo + estimate. **Week-3 plan:** on a GPU host,
(1) confirm the §5 xvfb PASS, (2) implement design **B** behind `--headless`, (3)
gate it on the smoke-test metric diff (must match the GUI run), (4) fold design
**A** into the CPU-only feasibility work.

## 8. Validation checklist
- [x] `xvfb-run ./cli_run/smoke_test.sh` → `PASS, 0 inverted` (confirms §5 / design C).
      **Done 2026-06-17 (RTX 4090): PASS, 18 526 hexes, 0 inverted.**
- [x] **`--headless` (design B) implemented + compile-verified** (Week 3 T1, §0).
      `hex --help` lists it; `hex --headless --script …` skips window/surface/
      swapchain in code and reaches the Vulkan-ICD boundary with no `DISPLAY`.
- [x] **`--headless` metric gate PASS** (2026-06-18, RTX 4090) → full chain on
      `spot.mesh` headless ⇒ **`total_hexes: 18526`, `inverted_count: 0`** —
      identical to the GUI/`xvfb` run. Definition of done met (§0).
- [x] **runtime: headless run needs the Vulkan ICD but no `DISPLAY`** — the GPU
      chain above ran with `DISPLAY` unset and no `xvfb`.
