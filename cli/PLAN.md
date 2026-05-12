# CLI Automation Plan — Interactive Hex-Meshing

Plan for adding scripted, command-line driven execution of the hex meshing pipeline with minimal code change.

---

## 1. Framing — what this is, honestly

This is **scripted GUI automation via CLI arguments** — not a fully headless CLI. The existing `hex` binary still launches Vulkan + the window; we just teach it to read a YAML script on startup, run pipeline stages automatically, and leave the window open for inspection (or exit immediately with `--exit-after`). A real headless `hex_cli` is a future step, not part of this plan.

**README: What was done in short?**

> *I added a command-line script mode to the existing GUI application. It runs each pipeline stage automatically from a YAML config, saves intermediate HDF5 files, exports the final hex mesh, and optionally keeps the GUI window open for inspection. This avoids changing the model and optimizer logic while making the workflow reproducible from CLI. Requires a working Vulkan + display setup (the same one the GUI already needs).*

---

## 2. CLI surface — different subcommands per stage

```bash
./cli/run.sh discretize     <input.hdf5>  [config.yaml]
./cli/run.sh hexahedralize  <input.hdf5>  [config.yaml]
./cli/run.sh full           <input.hdf5>  [config.yaml]   # discretize + hexahedralize
./cli/run.sh <cmd> ... --exit-after                       # close GUI on completion
```

If `[config.yaml]` is omitted, defaults are read from `cli/configs/stage_<cmd>.yaml`.

**Requirements per subcommand:**

| Subcommand | Input must contain | Outputs in run dir |
|---|---|---|
| `discretize` | `/polycube` (post-decomposition) | `stage_2_discretization.hdf5` |
| `hexahedralize` | `/polycube_complex` (post-discretization) | `stage_3_hexahedralization.hdf5`, `result.mesh` |
| `full` | `/polycube` | both above |

---

## 3. Run-directory layout

Every invocation produces a self-contained run directory under `output/runs/`:

```
output/runs/<example>/<stage>_<YYYY_MM_DD>_<NNN>/
├── input.hdf5                          # copy of the user's input
├── stage_0_deformation.hdf5            # if Stage 0 ran
├── stage_1_decomposition.hdf5          # if Stage 1 ran
├── stage_2_discretization.hdf5         # if Stage 2 ran
├── stage_3_hexahedralization.hdf5      # if Stage 3 ran
├── result.mesh                         # if Stage 3 ran (MEDIT format)
├── run_config.yaml                     # the actual config used
└── log.txt                             # combined stdout+stderr
```

**Naming rule:**
- `<example>` is auto-derived from the input file path: filename stem (e.g. `toy_plane.hdf5` → `toy_plane`), or the enclosing example folder when the input is itself a chained `stage_N_*.hdf5` from a previous run.
- `<stage>` is `discretization`, `hexahedralization`, or `full` depending on the subcommand.
- `<NNN>` is a 3-digit zero-padded auto-increment per (example, stage, day).

So a typical session looks like:
```
output/runs/toy_plane/
├── discretization_2026_05_08_001/
└── hexahedralization_2026_05_08_001/
```

---

## 4. Implementation order — safest path first

| Step | Stages covered | Why first |
|------|----------------|-----------|
| **1** *(this commit)* | Discretization + Hexahedralization (Stages 2 + 3) | Deterministic given a saved HDF5 — lowest risk, fastest payoff |
| **2** | Deformation (Stage 0) | Pure optimizer, no interactive bits |
| **3** | Decomposition (Stage 1) with `auto_cuboids` | Hardest, marked experimental |

---

## 5. Source changes — `interactive-hex-meshing/hex/`

**Class name:** `PipelineScriptRunner`, in `hex/src/cli/`. Signals *scripted GUI automation*, not headless CLI.

### 5.1 New files

| File | Purpose |
|------|---------|
| `hex/src/cli/PipelineScriptRunner.h` | Class declaration (~30 lines) |
| `hex/src/cli/PipelineScriptRunner.cpp` | YAML parser + per-stage dispatch + intermediate HDF5 saves (~200 lines for Step 1; ~280 when complete) |

### 5.2 Modified files

| File | Change |
|------|--------|
| `hex/src/main.cpp` | Add ~15 lines for argv parsing (`--script`, `--exit-after`) |
| `hex/CMakeLists.txt` | Add glob entry for `src/cli/*.cpp` (1 line) |
| `hex/src/HexMeshingApp.h/.cpp` | Add public `GetGlobalController()` accessor (~3 lines) |
| `hex/src/controllers/GlobalController.h/.cpp` | Add public `OpenProject(path)` / `SaveProject(path)` (~10 lines) |
| `hex/src/controllers/stages/DiscretizationStage.h/.cpp` | Add public `RunFromScript(YAML::Node)` (~15 lines) |
| `hex/src/controllers/stages/HexahedralizationStage.h/.cpp` | Add public `RunFromScript(YAML::Node)` (~25 lines) |

**Why public wrapper methods, not `friend class`:** keeps existing private methods private. Each wrapper is a thin shim that calls the same private methods the GUI buttons call.

### 5.3 Safety baked into PipelineScriptRunner

Per stage:
1. **Explicit precondition check** — throws `std::runtime_error` with a clear message if required `GlobalState` fields are missing (e.g., "discretization requires a polycube; load an HDF5 that has one").
2. **Force blocking optimizer mode** — `snapshot_freq = -1` regardless of YAML.
3. **Save intermediate HDF5** — after each stage finishes, call `GlobalState::SaveToFile(<run_dir>/stage_N_<name>.hdf5)`.
4. **Export final `.mesh`** — if hexahedralization ran and `output.export_mesh` is set in YAML, call `Serializer::SaveHexMesh()`.

### 5.4 `main.cpp` diff (~15 lines)

```cpp
int main(int argc, char** argv) {
  std::string script_path;
  bool exit_after = false;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    if (a == "--script" && i + 1 < argc) script_path = argv[++i];
    else if (a == "--exit-after") exit_after = true;
  }

  HexMeshingApp app{true};
  app.Prepare();

  if (!script_path.empty()) {
    PipelineScriptRunner runner(app);
    bool ok = runner.LoadAndRun(script_path);
    if (!ok) return 1;
    if (exit_after || runner.RequestedExit()) return 0;
  }

  app.MainLoop();
}
```

---

## 6. `cli/` folder layout (no source code, repo root)

```
cli/
├── PLAN.md                            ← this file
├── README.md                          ← user-facing docs
├── run.sh                             ← subcommand wrapper (host)
├── configs/
│   ├── stage_discretization.yaml      ← Step 1
│   ├── stage_hexahedralization.yaml   ← Step 1
│   ├── stage_deformation.yaml         ← Step 2 (future)
│   ├── stage_decomposition.yaml       ← Step 3 (future)
│   └── full_pipeline.yaml             ← Step 1: stages 2+3
└── examples/
    └── toy_plane.yaml                 ← worked example
```

### 6.1 YAML schema (Step 1 surface)

```yaml
input:
  type: hdf5
  path: /space/output/runs/toy_plane/discretization_2026_05_07_001/input.hdf5

stages:
  - discretization:
      hex_size: 0.05
      round_to_nearest: false
      padding: true

  - hexahedralization:
      inversion_free: true
      projection_weight: 1.0
      hausdorff_weight: 1.0
      fairness_weight: 0.0
      smoothness_weight: 1.0
      learning_rate: 1.0e-4
      steps: 100

output:
  run_dir: /space/output/runs/toy_plane/discretization_2026_05_07_001
  export_mesh: result.mesh   # filename relative to run_dir; only if Stage 3 ran

keep_window_open: true   # ignored if --exit-after is passed
```

### 6.2 Parser rules

- Missing parameter → use the in-code default (matches GUI default).
- All optimizer `snapshot_freq` fields forced to `-1` regardless of YAML.
- Stages run in YAML order; precondition errors halt with a clear message.
- Per-stage HDF5 is auto-saved to `run_dir` after each stage completes.
- `cli/run.sh` (host side) substitutes the run_dir and input path before launching.

---

## 7. Validation per step

### After Step 1 (this commit)

- Recompile in Docker (`. ./compile.sh` inside the container).
- Take an existing `evocube.hdf5` (post-Stage 1):
  - `./cli/run.sh discretize <hdf5>` — expect `stage_2_discretization.hdf5` in run dir, GUI shows hex complex.
  - `./cli/run.sh hexahedralize <stage_2_hdf5>` — expect `stage_3_hexahedralization.hdf5` + `result.mesh`, GUI shows final hex mesh.
  - `./cli/run.sh full <evocube.hdf5>` — expect both stage outputs in one run dir.

### Future steps
Stage 0 (Deformation) and Stage 1 (Decomposition) follow the same template.

---

## 8. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Vulkan/display not working on host | Documented as hard requirement; same constraint as GUI |
| Stages run out of order | Precondition checks throw with clear error |
| Async optimizer races the script | Force `snapshot_freq: -1` in parser, ignore YAML override |
| YAML drift from GUI defaults | Param names mirror GUI labels; defaults pulled from same place |
| Source code regression | All changes additive: one new dir, ~5 modified files for thin wrappers, ~15 lines in main.cpp. Existing GUI behavior unchanged. |
| Run-dir collisions | `run.sh` auto-increments the `NNN` suffix per basename per day |

---

## 9. Total code footprint (Step 1)

- **New:** 2 files in `hex/src/cli/` (~230 lines)
- **Modified:** 5 files (HexMeshingApp, GlobalController, 2 stages, main.cpp), ~10–25 lines each
- **Build:** 1-line CMakeLists update
- **No deletions, no refactors, no behavior changes to existing GUI.**

---

## 10. Naming and design decisions (locked in)

| Decision | Choice | Reason |
|----------|--------|--------|
| Class name | `PipelineScriptRunner` | Reflects "scripted GUI automation", not "headless CLI" |
| Folder location | `cli/` at repo root; outputs at `output/runs/` | Discoverable; outputs alongside existing `output/examples/` |
| CLI surface | `run.sh <subcommand> <input> [config]` | Different commands per stage as requested; YAML for tunables |
| Window behavior | Stay open by default; `--exit-after` flag for batch | Matches "result pops up" intent without locking out batch use |
| Method visibility | Public `RunFromScript()` wrapper per stage | Cleaner than `friend class` while keeping existing methods private |
| Optimizer mode | Forced blocking (`snapshot_freq: -1`) | Prevents script proceeding before convergence |
| Run-dir naming | `<example>/<stage>_<YYYY_MM_DD>_<NNN>` | Groups all runs of the same model under one folder; one subfolder per stage run |
| Logging | `log.txt` via `tee` in `run.sh` | Captures both Docker and `hex` stdout/stderr |
