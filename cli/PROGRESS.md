# Progress Report — Hex Meshing CLI Automation

## Goal

Make the interactive-hex-meshing pipeline runnable from the command line, so the same operations that previously required clicking through the GUI (discretization, hexahedralization, etc.) can be triggered with a single command, given an input file and parameters.

## What was done

### 1. Got the GUI running and understood the pipeline
- Set up the Docker environment, fixed a Vulkan driver conflict that was crashing the GUI on startup, and confirmed the application launches end-to-end.
- Studied the full pipeline in detail and produced an internal reference document mapping each of the four stages — Deformation, Decomposition, Discretization, Hexahedralization — to its purpose, parameters, inputs, outputs, and the underlying code.

### 2. Designed the CLI approach
- Compared two paths: building a fully headless command-line tool from scratch vs. adding a script-driven mode to the existing GUI.
- Chose the second path because it is much safer: it reuses the same code the GUI already uses, requires very few changes, and naturally lets the user see the result in the window after the script finishes.
- Documented the design decision and risks in `cli/PLAN.md`.

### 3. Implemented Step 1: Discretization and Hexahedralization
- Added a small "script runner" component to the application so it can read a YAML config on startup and run the requested stages automatically.
- Exposed Discretization and Hexahedralization as **two separate command-line subcommands**, plus a third command that runs them back-to-back:
  - `./cli/run.sh discretize <input>`
  - `./cli/run.sh hexahedralize <input>`
  - `./cli/run.sh full <input>`
- Each run produces a clean, self-contained output directory grouped by example (model name) and stage:
  ```
  output/runs/<example>/<stage>_<date>_<NNN>/
      input.hdf5
      stage_2_discretization.hdf5
      stage_3_hexahedralization.hdf5
      result.mesh
      run_config.yaml
      log.txt
  ```
  All runs of the same model land under one folder, with one subfolder per stage run. The example and stage names are derived automatically from the input file path — no extra flags needed.
- Parameters are tunable through YAML config files — defaults are provided, and a user can copy a default and override any value.

### 4. Validated end-to-end
- Recompiled the application; build succeeded with no errors introduced by the new code.
- Ran all three CLI commands on a real input model (toy_plane). All three completed successfully:
  - Discretization produced a valid hex complex (~5,400 hexes).
  - Hexahedralization improved mesh quality measurably (distortion error dropped ~55%, surface-projection error dropped ~91% during optimization).
  - Final mesh exported in standard MEDIT format.
- The GUI window correctly opens after each run for visual inspection (or can be skipped with `--exit-after` for batch jobs).

### 5. Documentation
- Authored a usage guide (`cli/how_to_run.txt`) showing minimal and fully parameterized examples for each command.
- Authored a README (`cli/README.md`) with prerequisites, parameter reference, and troubleshooting.
- Authored a plan document (`cli/PLAN.md`) capturing design choices and the implementation roadmap.

## What works today

- Discretization can be run from the command line with custom parameters.
- Hexahedralization can be run from the command line with custom parameters.
- Both stages can be chained in a single command.
- All input, intermediate, and final outputs are saved to a timestamped run directory, alongside the exact configuration that was used and a log of the run.
- The GUI still works exactly as before — none of the existing functionality was changed or broken.

## What is next

- **Stage 0 (Deformation)** and **Stage 1 (Decomposition)** are not yet wired into the CLI. The current workflow assumes those have been done in the GUI and saved as an HDF5 file. Adding them follows the same template used for Stages 2 and 3.
- **Structured metrics output** (final hex mesh quality statistics, Hausdorff distance) is currently only visible in the GUI. Optional follow-up: write a `metrics.json` per run for easy comparison across runs.
- **True headless mode** (no display required) is a longer-term goal; the current design already separates the compute from the GUI cleanly enough that this would be a natural follow-up.

## Why this approach is safe

- All code changes are additive — no existing files were rewritten.
- The CLI runner uses the same internal functions the GUI buttons call, so behavior is consistent with what users already see in the GUI.
- Each stage validates its preconditions and fails with a clear error message rather than silently producing bad output.
- Optimizer is forced into blocking mode for scripted runs so the script never proceeds before the previous step has finished.
