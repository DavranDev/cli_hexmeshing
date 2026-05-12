# CLI Automation for interactive-hex-meshing

Run pipeline stages of the hex-meshing GUI from the command line. This is **scripted GUI automation**, not a fully headless CLI: the existing `hex` binary still launches the Vulkan window, but it now reads a YAML script on startup and runs the requested stages automatically. The window stays open for inspection unless `--exit-after` is passed.

For the architectural rationale, see [PLAN.md](PLAN.md). For the underlying pipeline, see [../PIPELINE_NOTES.md](../PIPELINE_NOTES.md).

---

## Status

This is **Step 1** of the rollout — only Stages 2 + 3 (Discretization and Hexahedralization) are wired into the script runner. Deformation (Stage 0) and Decomposition (Stage 1) are planned for future steps; for now, prepare those in the GUI and save an HDF5 to feed into the CLI.

---

## Prerequisites

1. A working Docker + NVIDIA + X11 + Vulkan setup. The same one the GUI already needs — `./run_docker.sh` must work first.
2. The `hex` binary must be **rebuilt** after this CLI patch is applied. Inside the container:
   ```bash
   . /space/compile.sh
   ```
3. An HDF5 input file for the stage you want to run:
   - `discretize` needs a polycube (post-decomposition).
   - `hexahedralize` needs a polycube_complex (post-discretization).
   - `full` runs both starting from a polycube.

---

## Usage

```bash
./cli/run.sh discretize     <input.hdf5>  [config.yaml]  [--exit-after]
./cli/run.sh hexahedralize  <input.hdf5>  [config.yaml]  [--exit-after]
./cli/run.sh full           <input.hdf5>  [config.yaml]  [--exit-after]
```

If `[config.yaml]` is omitted, the default at `cli/configs/stage_<subcommand>.yaml` is used. To customize parameters, copy a default YAML, edit it, and pass it as the third argument — `cli/run.sh` will substitute the input path and run-directory placeholders for you.

### Examples

```bash
# Discretize an existing polycube HDF5; window stays open for inspection.
./cli/run.sh discretize output/examples/toy_plane/evocube.hdf5

# Run hexahedralization on a Stage-2 result; close window when done.
./cli/run.sh hexahedralize output/runs/toy_plane/discretization_2026_05_07_001/stage_2_discretization.hdf5 --exit-after

# Run the full Stage 2+3 chain with custom parameters.
./cli/run.sh full output/examples/toy_plane/evocube.hdf5 my_custom_config.yaml
```

---

## What gets produced

Every invocation creates a fresh run directory grouped by example (model name):

```
output/runs/<example>/<stage>_<YYYY_MM_DD>_<NNN>/
├── input.hdf5                          # copy of the user-provided input
├── stage_2_discretization.hdf5         # if discretize or full ran
├── stage_3_hexahedralization.hdf5      # if hexahedralize or full ran
├── result.mesh                         # if hexahedralization ran (MEDIT format)
├── run_config.yaml                     # exact config that was used
└── log.txt                             # combined stdout + stderr
```

- `<example>` is auto-derived from the input path — usually the input filename stem (e.g. `toy_plane.hdf5` → `toy_plane`). When the input is itself a chained `stage_N_*.hdf5` from a previous run, the example name is taken from the enclosing folder so the new run lands next to its predecessor.
- `<stage>` is one of `discretization`, `hexahedralization`, or `full`.
- `<NNN>` is a 3-digit zero-padded counter that auto-increments to avoid collisions for the same example + stage + day.

Example session — running discretize then hexahedralize on `toy_plane`:
```
output/runs/toy_plane/
├── discretization_2026_05_08_001/
└── hexahedralization_2026_05_08_001/
```

---

## YAML schema

Default templates live in `cli/configs/`. Each one uses `__INPUT_PATH__` and `__RUN_DIR__` placeholders that `run.sh` substitutes before launching.

### Discretization parameters

| Param | Default | Meaning |
|---|---|---|
| `hex_size` | 0.05 | Edge length of one hex element (smaller = more hexes, more memory) |
| `round_to_nearest` | false | Snap cuboid bounds to integer grid (vs expand cuboids outward) |
| `padding` | true | Add an extra layer of hexes globally (helps surface fitting) |

### Hexahedralization parameters

| Param | Default | Meaning |
|---|---|---|
| `inversion_free` | true | Use the smooth-deformation init (200 internal opt steps) |
| `projection_weight` | 1.0 | Pull boundary verts toward the input surface |
| `hausdorff_weight` | 1.0 | Reduce worst-case surface distance |
| `fairness_weight` | 0.0 | Laplacian smoothness on boundary |
| `smoothness_weight` | 1.0 | Normal smoothness |
| `learning_rate` | 1e-4 | Adam optimizer learning rate |
| `steps` | 100 | Additional optimization steps after init |

All parameter names mirror the GUI labels documented in [PIPELINE_NOTES.md](../PIPELINE_NOTES.md). The optimizer always runs in blocking mode (`snapshot_freq = -1` is forced internally regardless of YAML).

---

## Caveats

- **Display required.** This launches the Vulkan + X11 GUI inside Docker. On a server without a display, the binary will fail before any stage runs. There is no headless mode yet.
- **Preconditions.** If you call `hexahedralize` on an HDF5 that doesn't contain a polycube_complex, the runner throws a `std::runtime_error` with a clear message, exits 1, and does not produce a partial output.
- **Logs.** Both Docker startup output and the `hex` binary's own logs are captured in `log.txt` via `tee`. Look there first when debugging.
- **Run-dir persistence.** Run directories are not auto-cleaned. They live under `output/runs/` until you remove them.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Cannot open display` / `Vulkan ICD error` | X11 not forwarded, or wrong ICD. The wrapper already sets `VK_ICD_FILENAMES` to NVIDIA-only and runs `xhost +local:root` — confirm `./run_docker.sh` works first. |
| `[script] discretization requires a polycube` | Input HDF5 doesn't have `/polycube`. Run decomposition in the GUI first and save. |
| `[script] hexahedralization requires polycube_complex + ...` | Input HDF5 is missing one of `polycube_complex`, `deformed_volume_mesh`, `target_volume_mesh`. Use a Stage-2 (or later) HDF5. |
| Build failure after pulling these CLI changes | You must rebuild the `hex` binary inside the container: `. /space/compile.sh`. |
| Window does not appear | `keep_window_open: false` in your YAML, or `--exit-after` was passed. |
