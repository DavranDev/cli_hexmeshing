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
    └── toy_plane.hdf5                   # has a polycube (legacy; = Stage-2 input)
```

## Quick start (CLI is wired for these today)

### Stage 0 — Deformation
```bash
./cli/run.sh deform output/input_examples/stage_0_deformation/toy_plane.mesh
```
**What it does:** bends the input tet mesh so its surface faces become axis-aligned (cube-like). Produces `stage_0_deformation.hdf5`.

### Stage 1 — Decomposition
```bash
./cli/run.sh decompose output/input_examples/stage_1_decomposition/toy_plane.hdf5
```
**What it does:** approximates the deformed mesh with a small set of axis-aligned cuboids and refines them. Produces `stage_1_decomposition.hdf5` (the optimized polycube).

### Stage 2 — Discretization
```bash
./cli/run.sh discretize output/input_examples/stage_2_discretization/toy_plane.hdf5
```
**What it does:** lays a regular hex grid over the polycube and extracts the surface quads. Produces `stage_2_discretization.hdf5`.

### Stage 3 — Hexahedralization
```bash
./cli/run.sh hexahedralize output/input_examples/stage_3_hexahedralization/toy_plane.hdf5
```
**What it does:** morphs the discretized hex mesh so its boundary fits the original input surface and optimizes quality. Produces `stage_3_hexahedralization.hdf5`, `result.mesh` (the final hex mesh), and `result_metrics.yaml`.

### Full chain (all four stages)
There is no single `full` subcommand — run the four stages in order, feeding each `stage_N_*.hdf5` into the next:
```bash
M=output/input_examples/stage_0_deformation/toy_plane.mesh
./cli/run.sh deform        "$M" --exit-after
./cli/run.sh decompose     output/runs/toy_plane/deformation_*/stage_0_deformation.hdf5   --exit-after
./cli/run.sh discretize    output/runs/toy_plane/decomposition_*/stage_1_decomposition.hdf5 --exit-after
./cli/run.sh hexahedralize output/runs/toy_plane/discretization_*/stage_2_discretization.hdf5 --exit-after
```

Add `--exit-after` to any command for batch use (closes the window automatically). To customize parameters, see [cli/how_to_run.txt](../../cli/how_to_run.txt).

---

## Stage-by-stage notes

### Stage 0 — Deformation
**File provided:** `stage_0_deformation/toy_plane.mesh`
**Status:** **CLI ready.** `./cli/run.sh deform <this .mesh>` produces `stage_0_deformation.hdf5`. (Can also be done in the GUI: Import the `.mesh`, then Init/Reset deformed mesh → Init/Reset optimizer → Reoptimize → Save.)

**What this stage does:** bends the input tet mesh so its surface faces become axis-aligned (cubelike), preparing it for polycube fitting.

### Stage 1 — Decomposition
**File provided:** `stage_1_decomposition/toy_plane.hdf5`
**Status:** **CLI ready.** This file contains a `deformed_volume_mesh`, so `./cli/run.sh decompose <this .hdf5>` produces `stage_1_decomposition.hdf5` (the optimized polycube). (Can also be done in the GUI: Open the `.hdf5`, switch to the Decomposition panel, Reoptimize or build the polycube manually, then Save.)

**What this stage does:** approximates the deformed mesh with a small set of axis-aligned cuboids — the polycube.

### Stage 2 — Discretization
**File provided:** `stage_2_discretization/toy_plane.hdf5`
**Status:** **CLI ready.** This file is the output of evocube + Stage 0/1 already done for you, so it has a polycube and is ready to discretize.

**What this stage does:** turns continuous cuboids into a discrete hex mesh on a regular grid.

### Stage 3 — Hexahedralization
**File provided:** `stage_3_hexahedralization/toy_plane.hdf5`
**Status:** **CLI ready.** This file is the output of running discretization on the Stage-2 input.

**What this stage does:** morphs the hex mesh boundary back onto the original surface and optimizes mesh quality. This is where you get the final hex mesh.

### Full pipeline (legacy input)
**File provided:** `full_pipeline/toy_plane.hdf5`
**Status:** Same content as the Stage-2 input (a polycube HDF5). Kept as a convenient entry point for a `discretize` → `hexahedralize` chain. There is no longer a `full` subcommand — run the two stages in sequence.

---

## Where outputs land

Every command creates a fresh run directory grouped by example name:

```
output/runs/<example>/<stage>_<YYYY_MM_DD>_<NNN>/
    input.hdf5  (or input.mesh)
    stage_0_deformation.hdf5         # if Stage 0 ran
    stage_1_decomposition.hdf5       # if Stage 1 ran
    stage_2_discretization.hdf5      # if Stage 2 ran
    stage_3_hexahedralization.hdf5   # if Stage 3 ran
    result.mesh                      # if Stage 3 ran
    result_metrics.yaml              # if Stage 3 ran + export_metrics set
    run_config.yaml
    log.txt
```

`<example>` (e.g. `toy_plane`) is auto-derived from the input file name. `<stage>` is `deformation`, `decomposition`, `discretization`, or `hexahedralization`. Running the four stages in sequence on the same model gives you:

```
output/runs/toy_plane/
├── deformation_2026_06_01_001/
├── decomposition_2026_06_01_001/
├── discretization_2026_06_01_001/
└── hexahedralization_2026_06_01_001/
```

The GUI window opens at the end of each run so you can rotate, zoom, and inspect the result. Close the window when done. Use `--exit-after` to skip the window.
