# Input Examples — Test Inputs for the CLI

Ready-to-use input files for each pipeline stage, plus instructions to run them. The examples all use the bundled `toy_plane` model so you have something concrete to test against.

```
output/input_examples/
├── stage_0_deformation/
│   └── toy_plane.mesh                   # tet mesh (volumetric)
├── stage_1_decomposition/
│   └── toy_plane.hdf5                   # has a deformed_volume_mesh
├── stage_2_discretization/
│   └── toy_plane.hdf5                   # has a polycube
├── stage_3_hexahedralization/
│   └── toy_plane.hdf5                   # has a polycube_complex
└── full_pipeline/
    └── toy_plane.hdf5                   # has a polycube; runs Stages 2+3
```

## Quick start (CLI is wired for these today)

### Stage 2 — Discretization
```bash
./cli/run.sh discretize output/input_examples/stage_2_discretization/toy_plane.hdf5
```
**What it does:** lays a regular hex grid over the polycube and extracts the surface quads. Produces `stage_2_discretization.hdf5` and shows the hex complex in the GUI.

### Stage 3 — Hexahedralization
```bash
./cli/run.sh hexahedralize output/input_examples/stage_3_hexahedralization/toy_plane.hdf5
```
**What it does:** morphs the discretized hex mesh so its boundary fits the original input surface and runs distortion-vs-projection optimization. Produces `stage_3_hexahedralization.hdf5` and `result.mesh` (the final hex mesh) and shows it in the GUI.

### Full pipeline (Stages 2 + 3 chained)
```bash
./cli/run.sh full output/input_examples/full_pipeline/toy_plane.hdf5
```
**What it does:** runs discretization then hexahedralization in a single run directory, producing both intermediate HDF5s and the final mesh.

Add `--exit-after` to any of the commands above for batch use (closes the window automatically). To customize parameters, see [cli/how_to_run.txt](../../cli/how_to_run.txt).

---

## Stage-by-stage notes

### Stage 0 — Deformation
**File provided:** `stage_0_deformation/toy_plane.mesh`
**Status:** **Not yet supported by the CLI.** Run via the GUI for now:
1. Launch the GUI: `./run_docker.sh`, inside container source vulkan + run `./hex`.
2. `File → Import` → select this `.mesh` file.
3. In the Deformation panel, click "Init/Reset deformed mesh", "Init/Reset optimizer", then "Reoptimize".
4. `File → Save` → produces an HDF5 you can hand to Stage 1.

**What this stage does:** bends the input tet mesh so its surface faces become axis-aligned (cubelike), preparing it for polycube fitting.

### Stage 1 — Decomposition
**File provided:** `stage_1_decomposition/toy_plane.hdf5`
**Status:** **Not yet supported by the CLI.** This file already contains a `deformed_volume_mesh` (and an initial polycube from evocube), so it is a valid Stage-1 input. Run via the GUI for now:
1. Launch the GUI: `./run_docker.sh`, inside container source vulkan + run `./hex`.
2. `File → Open` → select this `.hdf5` file.
3. Switch to the Decomposition panel. The cuboids from evocube load automatically; you can:
   - Click "Reoptimize" to refine them, or
   - Click "Init/Reset polycube" to start from scratch and add cuboids manually.
4. `File → Save` → produces an HDF5 you can hand to Stage 2.

**What this stage does:** approximates the deformed mesh with a small set of axis-aligned cuboids — the polycube.

### Stage 2 — Discretization
**File provided:** `stage_2_discretization/toy_plane.hdf5`
**Status:** **CLI ready.** This file is the output of evocube + Stage 0/1 already done for you, so it has a polycube and is ready to discretize.

**What this stage does:** turns continuous cuboids into a discrete hex mesh on a regular grid.

### Stage 3 — Hexahedralization
**File provided:** `stage_3_hexahedralization/toy_plane.hdf5`
**Status:** **CLI ready.** This file is the output of running discretization on the Stage-2 input.

**What this stage does:** morphs the hex mesh boundary back onto the original surface and optimizes mesh quality. This is where you get the final hex mesh.

### Full pipeline
**File provided:** `full_pipeline/toy_plane.hdf5`
**Status:** **CLI ready.** Same content as Stage 2 input, but used as the entry point when you want to chain Stages 2 + 3 in one go.

---

## Where outputs land

Every command creates a fresh run directory grouped by example name:

```
output/runs/<example>/<stage>_<YYYY_MM_DD>_<NNN>/
    input.hdf5
    stage_2_discretization.hdf5      # if Stage 2 ran
    stage_3_hexahedralization.hdf5   # if Stage 3 ran
    result.mesh                      # if Stage 3 ran
    run_config.yaml
    log.txt
```

`<example>` (e.g. `toy_plane`) is auto-derived from the input file name. `<stage>` is `discretization`, `hexahedralization`, or `full`. Running discretize then hexahedralize on the same model gives you:

```
output/runs/toy_plane/
├── discretization_2026_05_08_001/
└── hexahedralization_2026_05_08_001/
```

The GUI window opens at the end of each run so you can rotate, zoom, and inspect the result. Close the window when done. Use `--exit-after` to skip the window.
