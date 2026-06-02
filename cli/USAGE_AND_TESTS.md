# Usage & test cases

Report-grade quick reference for running the CLI and verifying it works. Full
parameter docs are in [README.md](README.md) and [how_to_run.txt](how_to_run.txt).

## Simplest usage

Each pipeline stage is one subcommand. Input/output is file-based: you pass an
input file, the tool writes a run directory under `output/runs/<example>/` and
prints where. `--exit-after` closes the GUI window when the stage finishes.

```bash
./cli/run.sh deform         <input.mesh|.hdf5>  --exit-after   # Stage 0
./cli/run.sh decompose      <stage_0.hdf5>      --exit-after   # Stage 1
./cli/run.sh discretize     <stage_1.hdf5>      --exit-after   # Stage 2
./cli/run.sh hexahedralize  <stage_2.hdf5>      --exit-after   # Stage 3
```

Input → output per stage:

| Subcommand | Input must contain | Writes |
|---|---|---|
| `deform` | tet mesh (`.mesh`/`.vtk`) or HDF5 w/ `target_volume_mesh` | `stage_0_deformation.hdf5` |
| `decompose` | HDF5 w/ `deformed_volume_mesh` | `stage_1_decomposition.hdf5` |
| `discretize` | HDF5 w/ `polycube` | `stage_2_discretization.hdf5` |
| `hexahedralize` | HDF5 w/ `polycube_complex` | `stage_3_hexahedralization.hdf5`, `result.mesh`, `result_metrics.yaml` |

## Full chain (all four stages)

```bash
M=output/input_examples/stage_0_deformation/toy_plane.mesh
./cli/run.sh deform        "$M" --exit-after
./cli/run.sh decompose     output/runs/toy_plane/deformation_*/stage_0_deformation.hdf5     --exit-after
./cli/run.sh discretize    output/runs/toy_plane/decomposition_*/stage_1_decomposition.hdf5 --exit-after
./cli/run.sh hexahedralize output/runs/toy_plane/discretization_*/stage_2_discretization.hdf5 --exit-after
```

The final hexahedralization run directory holds `result.mesh` (the hex mesh,
MEDIT format) and `result_metrics.yaml` (quality summary).

## Test case: `toy_plane` (the reference)

Input: `output/input_examples/stage_0_deformation/toy_plane.mesh` (8443-vertex
tet mesh). Running the full chain is automated by:

```bash
./cli/smoke_test.sh        # runs all 4 stages and checks the result
```

**Expected result (pass criteria):**

| Check | Expected |
|---|---|
| All four stages exit 0 | yes |
| `result.mesh` produced | 4963 vertices, **5826 hexes** |
| `inverted_count` | **0** (hard requirement — any inversion = fail) |
| scaled-Jacobian | min ≈ 0.059, **mean ≈ 0.80**, max ≈ 0.9995 |

`smoke_test.sh` prints `PASS` and exits 0 when `inverted_count == 0` and
`total_hexes > 0`; otherwise it prints `FAIL` and exits 1.

> Small run-to-run variation in the scaled-Jacobian decimals is normal (the
> optimizers are stochastic). The gate is **0 inverted hexes**, not exact values.

## Verifying after you modify the code

1. Rebuild the binary (see [BUILD.md](BUILD.md) §A.4): `. /space/compile.sh`.
2. Run the smoke test: `./cli/smoke_test.sh`.
3. Confirm it prints `PASS` and the metrics are in the expected range above.

For a single stage, run just that subcommand and inspect its run directory
(`log.txt` has the full stage log; preconditions throw a clear error and exit 1
if the input HDF5 is missing the required field).

## Testing a different model

`smoke_test.sh` accepts any Stage-0 tet mesh:

```bash
./cli/smoke_test.sh path/to/your_model.mesh
```

Outputs land under `output/runs/your_model/`. The same pass criteria apply
(0 inverted hexes), though hex counts and Jacobian values will differ per model.
