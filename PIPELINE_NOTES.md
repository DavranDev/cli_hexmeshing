# Interactive Hex-Meshing — Pipeline Walkthrough

A detailed map of how `interactive-hex-meshing` works, with the concept, source files, GUI controls, parameters, and I/O for every stage. End goal: enough understanding to drive each step from the command line given an input mesh and parameters.

---

## 0. Big picture — what the software does

Goal: turn an arbitrary triangle/tet input mesh into an **all-hexahedral mesh** (every element is a cube-like cell with 8 vertices) by going through a **polycube intermediate**. A polycube is a shape made of axis-aligned cuboids glued together — once your model is morphed into a polycube, hexing it is trivial (just a regular grid), and then you morph the hex mesh back to the original shape.

The 4 stages, in order:

| Stage | What it does conceptually | Input | Output |
|---|---|---|---|
| **Deformation** | Bend the input tet mesh so its surface faces become axis-aligned (cubelike) | tet mesh | deformed tet mesh |
| **Decomposition** | Place a small set of axis-aligned cuboids (a "polycube") that approximate the deformed mesh | deformed tet mesh | polycube (list of cuboids) |
| **Discretization** | Lay a regular hex grid over the polycube and extract the boundary quad mesh | polycube | hex complex (grid hexes + surface quads + patches) |
| **Hexahedralization** | Morph that hex complex back so its boundary fits the **original** input surface, optimizing element quality | hex complex + original mesh | final hex mesh (`result_mesh`) |

All pipeline data lives in one struct: `GlobalState` (`hex/src/models/GlobalState.h`). Each stage reads/writes specific fields on it.

The whole app is at `interactive-hex-meshing/hex/src/`. Entry point: `main.cpp` → `HexMeshingApp.cpp` → owns a `GlobalController` + `Settings` + Vulkan render context.

---

## 1. Top-level layout

```
hex/src/
├── main.cpp / HexMeshingApp.*    application + Vulkan loop + ImGui
├── Settings.*                    persistent config (window, camera, lights, FPS)
├── controllers/
│   ├── GlobalController.*        menu bar (File/Options), stage switcher
│   ├── ShortcutController.*      F9/F10/F11/F12, Z, L, ESC, BACKSPACE
│   ├── CuboidEditingController.* drag/resize cuboids in 3D
│   └── stages/
│       ├── PipelineStage.*       base: CanSwitchTo, SwitchTo, DrawStageWindow
│       ├── DeformationStage.*
│       ├── DecompositionStage.*
│       ├── DiscretizationStage.*
│       └── HexahedralizationStage.*
├── models/                       data: GlobalState, TetrahedralMesh, Polycube,
│                                 HexComplex, HexahedralMesh, QuadComplex,
│                                 PolycubeGraph, Cuboid, PolycubeInfo
├── optim/                        PyTorch optimizers (Adam, autograd losses):
│                                 CubicVolumetricDeformer, PolycubeOptimizer,
│                                 HexComplexDeformer, DistortionEnergy
├── views/                        Vulkan rendering of each model type
├── serialization/                HDF5 save/load + MEDIT .mesh export
└── utility/                      ImGuiEx, file browser, paths, stopwatch
```

The optimizers in `optim/` use **LibTorch** (`libtorch.zip` in the repo). They are pure compute — no Vulkan/ImGui — which is why they would survive a port to CLI. The `views/` and the `Update*View()` calls scattered through stage controllers are GUI-only and are what makes a CLI port nontrivial.

---

## 2. Stage 0 — Deformation

**Concept.** Adam optimizer pushes each surface normal toward the nearest axis (±x, ±y, ±z) — "cubeness" — while keeping the interior tets non-degenerate via a distortion energy. Result: a tet mesh that *looks like a polycube* but is still a smooth deformation of the input.

**Files.**
- Controller: `hex/src/controllers/stages/DeformationStage.cpp`
- Optimizer: `hex/src/optim/CubicVolumetricDeformer.cpp`
- Loss: `hex/src/optim/DistortionEnergy.cpp`

**GUI buttons → functions.**

| Button | Function |
|---|---|
| Init/Reset deformed mesh | `DeformationStage::InitDeformedMesh()` at `DeformationStage.cpp:120` |
| Init/Reset optimizer | `DeformationStage::PrepareVolumetricDeformation()` at `:135` |
| Reoptimize | `DeformationStage::Reoptimize(num_steps)` at `:153`, calls `CubicVolumetricDeformer::Optimize()` |

**Parameters (ImGui sliders).**

| Param | Default | Range | Meaning |
|---|---|---|---|
| `cubeness_weight` | 1.0 | [0, 100] | How hard to push normals toward an axis |
| `smoothness_weight` | 1.0 | [0, 1] | Penalize disagreeing normals on adjacent faces |
| `norm_eps` | 1e-6 | [1e-6, 1] | Smoothing for L1-style cubeness loss (expert) |
| `conformal_weight` | 1.0 | [0, ∞] | Distortion penalty (angle-preserving) |
| `authalic_weight` | 1.0 | [0, ∞] | Distortion penalty (area-preserving) |
| `learning_rate` | 1e-3 | — | Adam |
| `adam_betas` | (0.9, 0.9) | — | Adam |

**Reads:** `GlobalState::target_volume_mesh_`. **Writes:** `GlobalState::deformed_volume_mesh_`.
**Precondition:** must `Import` a tet mesh first.

---

## 3. Stage 1 — Decomposition

**Concept.** Define a **signed distance field (SDF)** of the deformed mesh on a uniform anchor grid + surface samples. Then optimize a small set of axis-aligned cuboids so that their union approximates the SDF (positive = outside, negative = inside). You can manually add/subtract/lock cuboids; the optimizer also has a `SuggestNewCuboid` move that picks the next best cuboid greedily.

**Files.**
- Controller: `hex/src/controllers/stages/DecompositionStage.cpp`
- Model: `hex/src/models/Polycube.h`, `Cuboid.h`, `PolycubeInfo.h`
- Optimizer: `hex/src/optim/PolycubeOptimizer.h`
- SDF/anchors live on `TetrahedralMesh`: `hex/src/models/TetrahedralMesh.h:36-38`

**GUI actions → functions.**

| Action | Function |
|---|---|
| Create anchors and SDF | `DecompositionStage::CreateSdfAndAnchors()` at `:381` → `TetrahedralMesh::CreateAnchors()` + `CreateDistanceField()` |
| Init/Reset polycube | `ResetPolycube()` at `:229` |
| Add a new cuboid (distance/volume strategy) | `SuggestNewCuboid(SuggestStrategy)` at `:166` → `PolycubeOptimizer::SuggestNewCuboid()` |
| Subtract a cuboid | `StartSubtractCuboid()` at `:606` → `PolycubeOptimizer::SuggestSubtractCuboid()` |
| Reoptimize | `Reoptimize(steps)` at `:152` → `PolycubeOptimizer::Optimize(deformed, polycube, steps, locked)` |
| Click cuboid / L / ESC / BACKSPACE | `FocusCuboid`, lock/unlock, `DeleteCuboid`/`DuplicateCuboid` (`:203, :213, :320`) |

**Parameters.**

*Anchors panel*

| Param | Default | Range |
|---|---|---|
| `grid_size` | 24 | [4, 64] |
| `inside_only` | false | bool |
| `bbox_padding` | 0.2 | [0, 0.5] |
| `surface_samples` | 20 000 | [1k, 100k] |
| `perturbation` | 0.10 | [0, 0.5] — random jitter on samples |

*Optimizer panel*

| Param | Default | Range |
|---|---|---|
| `positive_l2_weight` | 1.0 | [0, 1] — penalize over-coverage |
| `negative_l2_weight` | 1.0 | [0, 1] — penalize under-coverage |
| `learning_rate` | 5e-3 | — |
| `adam_betas` | (0.9, 0.9) | — |
| `snapshot_freq` | 50 | async snapshot interval |
| `reoptimize_steps` | 1000 | per Reoptimize click |

**Reads:** `deformed_volume_mesh_`. **Writes:** `polycube_`, `polycube_info_`, plus anchors+SDF cached on the deformed mesh.
**Precondition:** Stage 0 done. The Reoptimize/Add buttons require anchors+SDF and an initialized polycube; the controller greys them out otherwise.

---

## 4. Stage 2 — Discretization

**Concept.** The polycube is just a list of cuboids in continuous space. To get a hex mesh, we lay a regular grid of edge length `hex_size` over its bounding box, classify each grid cell as inside-or-outside the polycube union, and extract the boundary quads. The result is a `HexComplex` (volumetric hexes + surface quads grouped into flat **patches**, where one patch = one face of one cuboid). You can also locally edit it: Shift+click to dig (remove) or extrude (add) hexes; `Z` toggles the mode.

**Files.**
- Controller: `hex/src/controllers/stages/DiscretizationStage.cpp`
- Model: `hex/src/models/PolycubeGraph.h`, `HexComplex.h`, `QuadComplex.h`

**GUI actions → functions.**

| Action | Function |
|---|---|
| Discretize | `DiscretizePolycube()` at `DiscretizationStage.cpp:100` → constructs `PolycubeGraph(polycube, hex_size, round_to_nearest)`, then `GenerateQuadComplex()` |
| Finalize polycube | `FinalizePolycube()` at `:114` → `PolycubeGraph::GenerateHexComplex(padding)`, writes `polycube_complex_` |
| Shift+click on quad | `HandleQuadClicked(quad_id)` at `:200` (dig/extrude one hex; Ctrl+Shift = whole patch) |
| Apply pending edits | `ApplyPendingChanges()` at `:233` |

**Parameters.**

| Param | Default | Range | Meaning |
|---|---|---|---|
| `hex_size` | 0.05 | [0.01, ∞] | Grid spacing (edge length of one hex) |
| `round_to_nearest` | false | bool | Snap cuboid bounds to integer grid coords (vs expanding outward) |
| `padding` | true | bool | Add an extra layer of hexes everywhere (helps surface fitting later) |
| `color_by_patch` | true | bool | Color each quad by which polycube face it belongs to |

**Reads:** `polycube_`. **Writes:** `polycube_complex_` (the `HexComplex`).
**Precondition:** Stage 1 has produced a non-empty polycube.

> **Sizing intuition for CLI:** the number of hexes scales as `(volume / hex_size^3)`. A `hex_size` that's too small produces millions of cells that the next stage's PyTorch optimizer can't fit in GPU memory. Too large and the surface looks blocky. Realistic range for normalized [-1,1] inputs is 0.03–0.1.

---

## 5. Stage 3 — Hexahedralization

**Concept.** Now we have a clean hex mesh of the polycube. We need to deform it back so its **boundary surface matches the original input mesh** while every hex stays well-shaped (positive scaled Jacobian = no inversions). PyTorch optimizes vertex positions against three competing energies: distortion (don't squash hexes), projection (boundary verts should sit on the input surface), and Hausdorff (max distance to surface should drop). Optionally you place **landmarks**: Shift+click pins surface vertices to specific surface positions, so the user can correct misalignments.

**Files.**
- Controller: `hex/src/controllers/stages/HexahedralizationStage.cpp`
- Optimizer: `hex/src/optim/HexComplexDeformer.h`
- Model: `hex/src/models/HexComplex.h`, `HexahedralMesh.h`

**GUI actions → functions.**

| Action | Function |
|---|---|
| Init/Reset final hex mesh | `InitTargetComplex(use_pullback, indirect, gradual)` at `:339`. In normal mode the single "inversion-free" checkbox = `indirect && transport`. |
| Init/Reset optimizer | `PrepareHexDeformation()` at `:393` → builds `HexComplexDeformer` |
| Morph / Reoptimize | `OptimizeHexDeformation(steps)` at `:409` → `HexComplexDeformer::Optimize()` |
| Enter/Leave edit mode | `EnterEditMode()` / `LeaveEditMode()` at `:45, :48` |
| Clear landmarks | `ClearLandmarks()` at `:210` |
| Filtering panel (slice / quality) | `DrawFilteringWindow()` at `:217` → `UpdateFilteredMeshView()` |

**Parameters.**

| Param | Default | Meaning |
|---|---|---|
| `use_pullback` | true | Initialize hex positions via generalized projection from polycube to surface |
| `indirect` | true (expert) | Higher-order projection (smoother) |
| `transport` | true (expert) | Smooth deformation transport during gradual morphing |
| `inversion_free` | true (normal mode) | Equivalent to `indirect && transport` |
| `conformal_weight`, `authalic_weight` | 1.0, 1.0 | Distortion energy |
| `projection_weight` | 1.0 | Pull boundary verts toward surface |
| `hausdorff_weight` | 1.0 | Reduce worst-case surface distance |
| `fairness_weight` | 0.0 | Laplacian smoothness on boundary |
| `smoothness_weight` | 1.0 | Normal smoothness |
| `custom_weight` | 1.0 | User-defined extra term |
| `learning_rate` | 1e-4 | Adam |
| `adam_betas` | (0.9, 0.9) | Adam |
| `snapshot_freq` | -1 | -1 = blocking, >0 = async every N steps |
| Filtering: `slice_dist` | 0.5 | Cut plane along camera front |
| Filtering: `quality_metric` | ScaledJacobian | or Jacobian |
| Filtering: `quality_cutoff` | 0.0 | Hide hexes below this quality |

**Reads:** `polycube_complex_`, `target_volume_mesh_`, `deformed_volume_mesh_`, landmarks. **Writes:** `target_complex_`, `result_mesh_` (a `HexahedralMesh`), per-hex quality cache. **Precondition:** Stages 0–2 done. `CanSwitchTo()` enforces this at `HexahedralizationStage.cpp:81-89`.

---

## 6. File menu — what you can load and save

In `hex/src/controllers/GlobalController.cpp`:

| Menu item | Action | Format |
|---|---|---|
| File → New | Clears `GlobalState` | — |
| File → Open | `Serializer::LoadState()` reads a project | `.hdf5` |
| File → Save | `Serializer::SaveState()` writes whole project | `.hdf5` |
| File → Import | `LoadTargetMesh()` at `:316` | `.mesh` (MEDIT) or `.vtk` |
| File → Export | Save final hex mesh (only after Stage 3) | `.mesh` (MEDIT) |
| File → Import Hex Mesh | Expert mode; load a precomputed hex | `.mesh` |
| Options → Load/Save Settings | Window/camera/etc | `.yml` |

The HDF5 schema (see `hex/src/serialization/Serializer.cpp`) is:

```
/target_volume_mesh/   {vertices (3,N), tets (4,T), [anchors], [sdf]}
/deformed_volume_mesh/ {vertices (3,N), tets (4,T), [anchors], [sdf]}
/polycube/             {params (6,M)}                — 6 = halflengths(3)+center(3)
/polycube_info/        {ordering, locked, names}
/polycube_complex/     {vertices, quads, patches, hexes}
/target_complex/       {vertices, quads, patches, hexes}
/result_mesh/          {vertices, hexes}
attrs: input_scale (float), input_center (3,)
```

This matches what `evocube/build_hdf5.py` writes — see §8 — which is why the demo workflow is "evocube → HDF5 → File→Open in hex".

The MEDIT export uses 1-indexed vertices and a specific hex vertex ordering `kHexMeditOrder = {1,5,7,3,0,4,6,2}` (`Serializer.cpp:11, :398`).

---

## 7. Keyboard shortcuts

From `hex/src/controllers/ShortcutController.cpp`:

| Key | Action |
|---|---|
| F9 | Toggle GUI |
| F10 | Save screenshot.png |
| F11 | ImGui demo window |
| F12 | Advanced panel (FPS limit, etc.) |
| Z | Toggle Dig/Extrude in Discretization |
| L | Lock/unlock focused cuboid (Decomposition) |
| ESC | Unfocus cuboid |
| BACKSPACE | Delete focused cuboid |
| Shift+Click | Place landmark / dig-extrude / focus cuboid (context-sensitive) |
| Ctrl+Shift+Click | Operate on entire patch |
| Ctrl+Drag landmark | Slide landmark along surface |

---

## 8. Where the inputs come from — the evocube side

Located at `evocube/`. It's the labeling + initial-polycube generator that **produces the HDF5 the hex GUI consumes**.

| Tool | Role |
|---|---|
| `evocube/build/init_from_folder` | Bulk-process a folder of `.obj` inputs |
| `evocube/build/evolabel <input.obj>` | GUI: genetic-algorithm polycube labeling |
| `evocube/build_hdf5.py --dir <output_dir>` | Convert evocube's results into the HDF5 the hex GUI loads |

`build_hdf5.py` does:

1. Reads `tetra.mesh` and `fast_polycube_surf.obj` from the folder
2. Normalizes both to `[-1, 1]` (records `input_scale`, `input_center`)
3. Voxelizes the polycube surface with Open3D at `voxel_size=0.1` to extract initial cuboid params
4. Writes the HDF5 with the schema in §6

Complete documented chain:

```
evolabel <model.obj>            → folder with tetra.mesh + fast_polycube_surf.obj
build_hdf5.py --dir <folder>    → evocube.hdf5
hex (this app) → File→Open      → loads evocube.hdf5, all 4 stages run interactively
                File→Export     → final .mesh hex output
```

---