# What changed in the original CDM source

This documents exactly what the CLI work touched in the upstream
*interactive-hex-meshing* ("CDM") source, so the team can track modifications as
we keep developing.

**Short answer:** the original source *was* modified, but the changes are
**additive** — new files plus thin wrappers/guards that expose existing
functionality. **No model, optimizer, or geometry algorithm was changed.**

**Current total vs the pre-CLI baseline `d0a904a`: +1003 / −133 across 34 files**
(`git -C interactive-hex-meshing diff --stat d0a904a`). It grew additively across
the weeks:

| Stage | Footprint | What was added |
|---|---|---|
| W1 — CLI runner | +590 / −4 / 18 files | new `hex/src/cli/` + thin `RunFromScript()` shims (table below) |
| W3 — `--headless` | +682 / −33 / 21 files | surfaceless-Vulkan `if (!headless)` startup guards in `main.cpp`, `HexMeshingApp`, `vkoo/Application` |
| W3 — CPU-only | **+967 / −121 / 32 files** | the `--device cpu\|cuda` knob (`.cuda()`→`.to(ComputeDevice())` across 5 files + `torch_utils`), and CPU branches in the two geomlib `.cu` kernels (`point_tet_mesh_test`, `generalized_projection`) that **reuse the identical per-element math** — see [CPU_ONLY.md](CPU_ONLY.md) §5 |
| Phase A — `--no-vulkan` | **+375 / −214 / 16 files** | `DisplayMode` replaces `Prepare(bool)`; visibility bitmask moved out of `GlobalView` into `GlobalController`; `UnfocusCuboid`'s optimizer-thread join split out; views/`CuboidEditingController` no longer constructed without a device — see [the main no-Vulkan plan](../plans/no-vulkan-headless.md), Step A3 |
| Phase B — `HEX_ENABLE_VULKAN=OFF` | **+2723 / −1933 / 42 files** | GUI translation-unit split (`<Stage>Gui.cpp`, `GlobalControllerGui.cpp`); new `HeadlessSession` owner; `PipelineScriptRunner` takes `GlobalController&`; `vkoo/common.h` Vulkan block guarded; per-variant source lists in `vkoo`/`hex`/`external` CMake. Most deletions are code *moved* into the 9 new files, not removed. |
| W4 — GUI synchronization | **+1003 / −133 / 34 files** | replace unsafe acquire-semaphore recycling with a host-waited Vulkan acquire fence in `vkoo/RenderContext`; fixes the indefinite GUI render loop under current validation layers |

The additions remain focused on CLI/device selection and Vulkan lifecycle code.
The W1 per-file table below is the original CLI runner; the W3 files are listed in
HEADLESS.md §0 and CPU_ONLY.md §5.

## Two repositories, two kinds of change

| Repo | Role | Nature of change |
|---|---|---|
| `cli_hexmeshing` (parent) | host wrapper | **Pure addition** — the `cli_run/` folder (`run.sh`, YAML configs, docs, `smoke_test.sh`). No upstream source here. |
| `interactive-hex-meshing` (submodule) | the CDM source | New `hex/src/cli/` files + thin shims on existing files (below). |

## Regenerate the exact diff

In the submodule, compare against the pre-CLI baseline commit (`d0a904a`,
"Update README.md", the last commit before any CLI work):

```bash
cd interactive-hex-meshing
git diff --stat d0a904a           # includes current working-tree fixes
git diff        d0a904a           # full line-by-line diff
```

## New files (where the new logic lives)

| File | Purpose |
|---|---|
| `hex/src/cli/PipelineScriptRunner.{h,cpp}` | Parse the YAML script, load the input, dispatch each stage, save `stage_N_*.hdf5`, export mesh + metrics. |
| `hex/src/cli/MetricsDumper.{h,cpp}` | Compute scaled-Jacobian / Jacobian summary + inverted-hex count; write `result_metrics.yaml`. |

## Modified original files (thin, additive shims)

| File | +/− | What changed |
|---|---|---|
| `hex/src/main.cpp` | +32 | Parse `--script <yaml>` / `--exit-after`; run the script then exit or fall through to the GUI. |
| `hex/CMakeLists.txt` | +1 | Glob `src/cli/*.cpp` into the build. |
| `hex/src/HexMeshingApp.h` | +1 | Public `GetGlobalController()` accessor. |
| `hex/src/controllers/GlobalController.{h,cpp}` | +17 | Public `OpenProject` / `SaveProject` / export accessors (wrap existing private calls). |
| `hex/src/controllers/stages/DeformationStage.{h,cpp}` | +50 | `RunFromScript()` — calls the same methods the GUI's Deformation panel does. |
| `hex/src/controllers/stages/DecompositionStage.{h,cpp}` | +76 | `RunFromScript()` **+ the headless fix**: write the optimized polycube back to `GlobalState` after the optimizer thread joins (the GUI did this each frame via `Update()`). |
| `hex/src/controllers/stages/DiscretizationStage.{h,cpp}` | +27 | `RunFromScript()`. |
| `hex/src/controllers/stages/HexahedralizationStage.{h,cpp}` | +62 | `RunFromScript()` + optional mesh/metrics export. |
| `hex/src/optim/PolycubeOptimizer.h` | +8 | Move `GetOptimizedPolycube()` from private to public (needed by the decomposition fix above). |
| `vkoo/core/RenderContext.{h,cpp}` | +36/−12 | Use a host-waited acquire fence so the GUI does not recycle a pending Vulkan binary semaphore. |

## The only deletions (−4 lines total)

- `PolycubeOptimizer.h`: the visibility move (the line removed from the private
  section).
- `TetrahedralMesh.cpp`: reverted a no-op `.to(torch::kInt64)` that a previous
  debugging pass had added — `geomlib::TriangularProjectionInfo` already converts
  internally, so the net effect on that file is **zero** (it matches upstream).

## Bottom line

Every stage gained a small public `RunFromScript(YAML::Node)` that drives the
**same** code the GUI buttons drive. The compute kernels, optimizers, and data
structures are untouched. The one behavioral fix (decomposition writeback) makes
the headless path match what the GUI already did — it does not change the
algorithm. This keeps future merges with upstream low-risk.
