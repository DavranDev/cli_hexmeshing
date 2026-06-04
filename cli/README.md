# CLI Automation for interactive-hex-meshing

Run the hex-meshing pipeline from the command line. This is **scripted GUI automation**, not a fully headless CLI: the existing `hex` binary still launches the Vulkan window, but it now reads a YAML script on startup and runs the requested stage automatically. The window stays open for inspection unless `--exit-after` is passed.

For the underlying pipeline, see [../PIPELINE_NOTES.md](../PIPELINE_NOTES.md).

**Docs index:** [REPORT.md](REPORT.md) (Week-1 summary report) · [BUILD.md](BUILD.md) (build from scratch) · [USAGE_AND_TESTS.md](USAGE_AND_TESTS.md) (usage + test cases) · [SOURCE_CHANGES.md](SOURCE_CHANGES.md) (what changed in the CDM source) · [smoke_test.sh](smoke_test.sh) (one-command verify).

---

## Status

**All four pipeline stages are wired into the script runner** and validated end-to-end (raw `.mesh` → final hex mesh):

| Stage | Subcommand | Input must contain | Produces |
|---|---|---|---|
| 0 Deformation | `deform` | a tet mesh (`.mesh`/`.vtk`) or an HDF5 with `target_volume_mesh` | `stage_0_deformation.hdf5` |
| 1 Decomposition | `decompose` | HDF5 with a `deformed_volume_mesh` | `stage_1_decomposition.hdf5` |
| 2 Discretization | `discretize` | HDF5 with a `polycube` | `stage_2_discretization.hdf5` |
| 3 Hexahedralization | `hexahedralize` | HDF5 with a `polycube_complex` | `stage_3_hexahedralization.hdf5`, `result.mesh`, `result_metrics.yaml` |

There is no single `full` subcommand: run the stages in sequence, feeding each `stage_N_*.hdf5` into the next.

---

## Prerequisites

1. A working Docker + NVIDIA + X11 + Vulkan setup. The same one the GUI already needs — `./run_docker.sh` must work first.
2. The `hex` binary must be **rebuilt** after pulling these CLI changes. Inside the container:
   ```bash
   . /space/compile.sh
   ```

---

## Usage

```bash
./cli/run.sh deform         <input.mesh|input.hdf5>  [config.yaml]  [--exit-after]
./cli/run.sh decompose      <input.hdf5>             [config.yaml]  [--exit-after]
./cli/run.sh discretize     <input.hdf5>             [config.yaml]  [--exit-after]
./cli/run.sh hexahedralize  <input.hdf5>             [config.yaml]  [--exit-after]
```

`deform` is the only subcommand that accepts a raw `.mesh`/`.vtk` tet mesh (detected by extension); Stages 1–3 require an HDF5 carrying the field listed in the table above.

If `[config.yaml]` is omitted, the default at `cli/configs/stage_<subcommand>.yaml` is used. To customize parameters, copy a default YAML, edit it, and pass it as the third argument — `cli/run.sh` substitutes the input path and run-directory placeholders for you.

### Worked example — full chain on `spot`

```bash
M=interactive-hex-meshing/assets/tutorial/spot.mesh

./cli/run.sh deform        "$M" --exit-after
./cli/run.sh decompose     output/runs/spot/deformation_*/stage_0_deformation.hdf5   --exit-after
./cli/run.sh discretize    output/runs/spot/decomposition_*/stage_1_decomposition.hdf5 --exit-after
./cli/run.sh hexahedralize output/runs/spot/discretization_*/stage_2_discretization.hdf5 --exit-after
```

Other ready-to-use Stage-0 tet meshes ship alongside it in
`interactive-hex-meshing/assets/tutorial/` (`bob`, `bunny`, `horse`,
`rockerArm`, `spot`, plus `kitten.vtk`).

The final run directory holds `result.mesh` plus a `result_metrics.yaml` quality sidecar.

---

## What gets produced

Every invocation creates a fresh run directory grouped by example (model name):

```
output/runs/<example>/<stage>_<YYYY_MM_DD>_<NNN>/
├── input.hdf5 (or input.mesh)          # copy of the user-provided input
├── stage_0_deformation.hdf5            # if deform ran
├── stage_1_decomposition.hdf5          # if decompose ran
├── stage_2_discretization.hdf5         # if discretize ran
├── stage_3_hexahedralization.hdf5      # if hexahedralize ran
├── result.mesh                         # if hexahedralize ran (MEDIT format)
├── result_metrics.yaml                 # if hexahedralize ran + export_metrics set
├── run_config.yaml                     # exact config that was used
└── log.txt                             # combined stdout + stderr
```

- `<example>` is auto-derived from the input path — usually the input filename stem (e.g. `spot.mesh` → `spot`). When the input is itself a chained `stage_N_*.hdf5` from a previous run, the example name is taken from the enclosing folder so the new run lands next to its predecessor.
- `<stage>` is one of `deformation`, `decomposition`, `discretization`, `hexahedralization`.
- `<NNN>` is a 3-digit zero-padded counter that auto-increments to avoid collisions for the same example + stage + day.

---

## YAML schema

Default templates live in `cli/configs/` (`stage_deformation.yaml`, `stage_decomposition.yaml`, `stage_discretization.yaml`, `stage_hexahedralization.yaml`). Each uses `__INPUT_PATH__`, `__RUN_DIR__`, and (deform only) `__INPUT_TYPE__` placeholders that `run.sh` substitutes before launching. Any parameter you omit falls back to the in-code GUI default.

### Deformation (`deform`)

| Param | Default | Meaning |
|---|---|---|
| `cubeness_weight` | 1.0 | Push surface normals toward axis-aligned |
| `smoothness_weight` | 1.0 | Penalize disagreeing adjacent normals |
| `conformal_weight` | 1.0 | Distortion: angle preserving |
| `authalic_weight` | 1.0 | Distortion: area preserving |
| `learning_rate` | 1e-3 | Adam learning rate |
| `steps` | 100 | Optimization steps |

### Decomposition (`decompose`)

| Param | Default | Meaning |
|---|---|---|
| `num_cuboids` | 8 | How many cuboids to greedily add |
| `suggest_strategy` | largest | `largest` or `simple` |
| `reopt_steps` | 1000 | Optimizer steps refining the cuboids |
| `grid_size`, `inside_only`, `bbox_padding`, `surface_samples`, `perturbation` | — | Anchor sampling for the SDF |
| `positive_l2_weight`, `negative_l2_weight`, `learning_rate` | — | Polycube optimizer |

### Discretization (`discretize`)

| Param | Default | Meaning |
|---|---|---|
| `hex_size` | 0.05 | Edge length of one hex element (smaller = more hexes, more memory) |
| `round_to_nearest` | false | Snap cuboid bounds to integer grid (vs expand cuboids outward) |
| `padding` | true | Add an extra layer of hexes globally (helps surface fitting) |

### Hexahedralization (`hexahedralize`)

| Param | Default | Meaning |
|---|---|---|
| `inversion_free` | true | Use the smooth-deformation init (200 internal opt steps) |
| `projection_weight` | 1.0 | Pull boundary verts toward the input surface |
| `hausdorff_weight` | 1.0 | Reduce worst-case surface distance |
| `fairness_weight` | 0.0 | Laplacian smoothness on boundary |
| `smoothness_weight` | 1.0 | Normal smoothness |
| `learning_rate` | 1e-4 | Adam optimizer learning rate |
| `steps` | 100 | Additional optimization steps after init |

The `output:` block of the hexahedralization config also supports:
- `export_mesh: result.mesh` — write the final hex mesh (MEDIT) to the run dir.
- `export_metrics: result_metrics.yaml` — write a quality sidecar (scaled-Jacobian / Jacobian min·max·mean·std and inverted-hex count).

All parameter names mirror the GUI labels documented in [PIPELINE_NOTES.md](../PIPELINE_NOTES.md). The optimizer always runs in blocking mode (`snapshot_freq = -1` is forced internally regardless of YAML).

---

## Caveats

- **Display required.** This launches the Vulkan + X11 GUI inside Docker. On a server without a display, the binary will fail before any stage runs. There is no headless mode yet.
- **Preconditions.** Each subcommand checks its required input field and throws a clear `std::runtime_error` (exit 1, no partial output) if it's missing — e.g. calling `hexahedralize` on an HDF5 without a `polycube_complex`.
- **Logs.** Both Docker startup output and the `hex` binary's own logs are captured in `log.txt` via `tee`. Look there first when debugging.
- **Run-dir persistence.** Run directories are not auto-cleaned. They live under `output/runs/` until you remove them.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Cannot open display` / `Vulkan ICD error` | X11 not forwarded, or wrong ICD. The wrapper already sets `VK_ICD_FILENAMES` to NVIDIA-only and runs `xhost +local:root` — confirm `./run_docker.sh` works first. |
| `[script] decomposition requires a deformed volume mesh` | Input HDF5 has no `deformed_volume_mesh`. Run `deform` first and feed its `stage_0` output. |
| `[script] discretization requires a polycube` | Input HDF5 has no `/polycube`. Run `decompose` first. |
| `[script] hexahedralization requires polycube_complex + ...` | Input HDF5 is missing one of `polycube_complex`, `deformed_volume_mesh`, `target_volume_mesh`. Use a Stage-2 (or later) HDF5. |
| Build failure after pulling these CLI changes | You must rebuild the `hex` binary inside the container: `. /space/compile.sh`. |
| Window does not appear | `keep_window_open: false` in your YAML, or `--exit-after` was passed. |
