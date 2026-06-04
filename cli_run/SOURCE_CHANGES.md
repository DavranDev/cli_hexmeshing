# What changed in the original CDM source

This documents exactly what the CLI work touched in the upstream
*interactive-hex-meshing* ("CDM") source, so the team can track modifications as
we keep developing.

**Short answer:** the original source *was* modified, but the changes are small
and **additive** — new files plus thin wrappers that expose existing
functionality to a script runner. **No model, optimizer, or geometry algorithm
was changed.** The whole CLI effort is **+590 / −4 lines across 18 files**.

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
git diff --stat d0a904a..HEAD     # the table below
git diff        d0a904a..HEAD     # full line-by-line diff
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
