# Report — Command-line hex-meshing tool (consolidated: Weeks 1–3)

**One document to build, run, verify, and understand the GPU/CPU story.** It folds
the Week-1/2/3 work into a single report mapped to your questions, and **cross-links
the detailed source docs rather than duplicating them**. Where a claim needs a GPU,
it is stated as measured (this dev box turned out to *be* a working GPU host — RTX
4090, driver 580.159.03 — so the Week-2 "pending a GPU host" items are now closed).

Status date: 2026-06-18. Branch `cli-runner` (parent `cli_hexmeshing` + submodule
`interactive-hex-meshing`). **Not yet pushed** — committed in one batch at week's
end (your call); see §8.

---

## 0. Coverage of your asks (where each is answered)

| # | Your item | Status | Where |
|---|---|---|---|
| 1 | Simplified from-scratch build guide | ✅ | §1, [BUILD.md](BUILD.md) |
| 2 | Docker **and** non-Docker build | ✅ | §1, BUILD.md §A/§B |
| 3 | End-to-end Dockerfile for the updated source | ✅ | §1, `Dockerfile.build`, BUILD.md §A2 |
| 4 | Well-documented for the report | ✅ | this doc + the doc map (§9) |
| 5 | Provide the compiled binary | ✅ | §1.3, `dist/MANIFEST.md` |
| 6 | Simplest usage + I/O behaviour | ✅ | §2, [USAGE_AND_TESTS.md](USAGE_AND_TESTS.md) |
| 7 | Test cases + verify-after-change | ✅ | §3, `cli_run/smoke_test.sh` |
| 8 | Track original-source changes | ✅ | §4, [SOURCE_CHANGES.md](SOURCE_CHANGES.md) |
| 9 | Keep under Git | ✅ (push at week end) | §8 |
| 10 | Run without GUI / auto-close GUI | ✅ | §5 (`--exit-after`) |
| 11 | **True headless mode** | ✅ implemented + gate PASS | §5, [HEADLESS.md](HEADLESS.md) |
| 12 | Which steps need NVIDIA/Vulkan/GPU | ✅ static + runtime | §6, [DEPENDENCY_MAP.md](DEPENDENCY_MAP.md) |
| 13 | CPU-only feasibility per step | ✅ scoped + S2 proven | §7, [CPU_ONLY.md](CPU_ONLY.md) |

---

## 1. Build

Two supported paths; **the build needs no GPU** (`nvcc` cross-compiles). Full
guide: [BUILD.md](BUILD.md).

### 1.1 Docker — one self-contained command (recommended)
`Dockerfile.build` COPYs the source and compiles `hex` + evocube inside the image.
The build **fails loudly if either binary is missing** (`compile.sh` was hardened —
it previously masked a failed evocube build; `.dockerignore` no longer strips the
`.git` from libigl's eigen cache that broke evocube's configure). A cold build is
~15–25 min. It is **multi-stage** with two selectable targets:

| Target | Base | Size | Use |
|---|---|---|---|
| `build` (devel, self-contained) | `cuda:12.4.1-cudnn-devel` | 26.1 GB | full env incl. GUI |
| `runtime` (slim) | `cuda:12.4.1-cudnn-runtime` | **15.2 GB** | run-only (−42%) |

```bash
docker build -f Dockerfile.build --target build   -t hexmesh-cli:week3 .       # devel
docker build -f Dockerfile.build --target runtime  -t hexmesh-cli:week3-slim .  # slim
```

### 1.2 Native (no Docker)
Compile-verified on a clean Ubuntu 22.04 (CUDA-12.4 toolkit + LibTorch 2.6.0+cu124
+ Vulkan SDK 1.3.268.0); steps in BUILD.md §B. **End-to-end native run validated**
on this host's RTX 4090 (the in-container-built `hex` runs natively — deform + the
other stages — headless, exit 0).

### 1.3 Prebuilt binary
`hex` (Week-3, with `--headless`) — sha256 `dea52a45…3bed3`, 9.1 MB, `ldd` clean.
Delivery: **Docker image (portable, recommended)** or the bare binary as a GitHub
Release asset (uploaded at week-end with the push). Provenance + exact env in
`dist/MANIFEST.md`; running instructions in BUILD.md §C. Runs as-is **only** on a
matching env (CUDA 12.4 + driver ≥550 + LibTorch 2.6.0+cu124 + Vulkan 1.3.268.0).

---

## 2. Usage + I/O behaviour

Each pipeline stage is one subcommand; I/O is file-based. Details + the full
4-stage chain: [USAGE_AND_TESTS.md](USAGE_AND_TESTS.md).

```bash
./cli_run/run.sh deform        <input.mesh|.hdf5>  --headless   # Stage 0
./cli_run/run.sh decompose     <stage_0.hdf5>      --headless   # Stage 1
./cli_run/run.sh discretize    <stage_1.hdf5>      --headless   # Stage 2
./cli_run/run.sh hexahedralize <stage_2.hdf5>      --headless   # Stage 3
```

Each stage writes a run dir under `output/runs/<example>/`; the final stage emits
`result.mesh` (MEDIT) + `result_metrics.yaml` (quality summary). Parameters live in
the per-stage YAML in `cli_run/configs/` (copy + edit to tune).

---

## 3. Test cases + verifying after a change

`cli_run/smoke_test.sh` runs all four stages on a tutorial mesh and gates on the
result. Hard pass criterion: **`inverted_count == 0` and `total_hexes > 0`.**

```bash
./cli_run/smoke_test.sh                       # GUI/--exit-after path (needs X11/xvfb)
SMOKE_HEADLESS=1 ./cli_run/smoke_test.sh      # headless (no display)
```

**Verified 2026-06-18 (RTX 4090):** PASS, **18 526 hexes, 0 inverted** on `spot.mesh`
— identically via GUI(xvfb), `--headless`, the slim image, and the bare extracted
binary in a matching env it did not build. After any code change: rebuild (§1) then
run the smoke; see USAGE_AND_TESTS.md "Verifying after you modify the code".

---

## 4. Did we change the original CDM source?

Yes, but **small and additive — no model / optimizer / geometry algorithm was
changed.** Full per-file breakdown + how to regenerate the diff:
[SOURCE_CHANGES.md](SOURCE_CHANGES.md).

- Footprint vs the pre-CLI baseline (`d0a904a`): **+682 / −33 across 21 files**
  (was +590/−4/18 at Week 1; Week-3's `--headless` guards added the rest — all
  additive `if (!headless)` startup guards, see §5).
- New logic is isolated in `hex/src/cli/` (the script runner + metrics dumper);
  everything else is thin public shims (`RunFromScript()`) that drive the **same**
  code the GUI buttons drive, plus the surfaceless-Vulkan startup guards.
- Keeps future upstream merges low-risk.

---

## 5. Headless mode (design + status)

`--exit-after` (item #10) opens the GUI window, runs the script, closes it — still
needs a display. **`--headless` (item #11) creates no window / surface / swapchain /
render-pipelines / GUI at all** (surfaceless Vulkan, "design B"): it keeps the
Vulkan *device* (the views still allocate buffers) but never presents, runs the
pipeline, and exits. Implementation is a **startup guard, not a logic rewrite** —
confined to 5 startup files; no stage/optimizer/view code changed. Full design,
call-site analysis, and before/after trace: [HEADLESS.md](HEADLESS.md) §0.

**Metric gate (definition of done) — PASS** (2026-06-18, RTX 4090): full chain via
`--headless` with **no `DISPLAY`** → `total_hexes 18526, inverted_count 0`, identical
to the GUI run.

---

## 6. GPU / Vulkan / CUDA per-stage dependency map (final)

Two **independent** dependencies, often conflated:
- **(V) Vulkan + X11** — only the GUI renderer. Removing it = headless (§5).
- **(C) CUDA** — the actual math (libtorch + 2 geomlib `.cu` kernels). Removing it =
  CPU-only (§7).

Static trace + **runtime evidence** (per-stage `nvidia-smi`, RTX 4090). Full table +
call chains: [DEPENDENCY_MAP.md](DEPENDENCY_MAP.md).

| Stage | peak GPU util | CUDA compute? | CPU-only verdict |
|---|---:|---|---|
| 0 deform | 72 % | yes (libtorch only, no kernel) | cheap (device knob) |
| 1 decompose | 55 % | yes (SDF kernel `PointTetMeshTest`) | needs kernel port |
| 2 discretize | **13 %** | **no** | **runs CPU-only now** |
| 3 hexahedralize | 66 % | yes (projection kernel) | needs kernel port |

Stage 2's low utilisation is the runtime confirmation that it does no CUDA compute
(decisively cross-checked in §7).

---

## 7. CPU-only feasibility + recommended path

Full per-stage verdict, file-level costs, and recommended order:
[CPU_ONLY.md](CPU_ONLY.md).

- **S2 discretize — runs CPU-only NOW (proven).** Ran end-to-end on a CUDA-less box
  (software Vulkan via lavapipe) → **18 526 hexes, exit 0, no CUDA op**.
- **S0 deform — after a device knob (~0.5–1 day).** ~39 hard-coded `.cuda()` calls
  across 5 files, **all mechanical** (`.cuda()` → `.to(device)`); S0 has no kernel.
- **S1 / S3 — device knob + a CUDA-kernel port.** `point_tet_mesh_test` (S1 SDF) is a
  trivial O(N·T) port (~0.5 day); `generalized_projection` (S3) is a medium O(P·F)
  port (~1.5–2.5 days, per-iteration perf caveat).

**Recommended:** S2 (now) → S0 device knob → S1 kernel → S3 kernel. Minimum-useful
CPU deliverable = S2 + S0; full CPU pipeline ≈ 3–4.5 days more.

---

## 8. Known gaps + what's left

- **Git push (item #9):** all Week-1/2/3 work is committed/staged locally on
  `cli-runner` but **not pushed yet** — by choice, to commit everything in one batch
  at week's end (submodule fork first, then the parent pointer). The bare-binary
  GitHub Release upload happens with that push.
- **CPU-only is not finished, by design** — S2 runs CPU-only today; S0/S1/S3 are a
  costed follow-on (§7), not a one-week deliverable.
- **Slim image GUI:** the slim runtime base omits the full NVIDIA GL stack, so the
  on-screen GUI needs the *devel* image; the slim image is validated for
  **headless** use (CUDA on the GPU, views on software Vulkan). See BUILD.md §A2.6.
- **No remaining GPU-host blockers** — the items Week 2 marked "pending a GPU host"
  (smoke PASS, xvfb, per-stage GPU evidence, native run, slim validation, the
  headless metric gate) are all now measured on the local RTX 4090.

---

## 9. Doc map (where the detail lives)

| Topic | Doc |
|---|---|
| Build (Docker one-step + native + slim) | [BUILD.md](BUILD.md) |
| Usage + examples + I/O | [USAGE_AND_TESTS.md](USAGE_AND_TESTS.md) |
| Test / verify | `cli_run/smoke_test.sh` |
| Original-source change tracking | [SOURCE_CHANGES.md](SOURCE_CHANGES.md) |
| Headless design + status | [HEADLESS.md](HEADLESS.md) |
| GPU/Vulkan/CUDA per-stage map | [DEPENDENCY_MAP.md](DEPENDENCY_MAP.md) |
| CPU-only feasibility + plan | [CPU_ONLY.md](CPU_ONLY.md) |
| Prebuilt binary provenance | `dist/MANIFEST.md` |
| Week-1 / Week-2 reports (superseded by this) | [REPORT.md](REPORT.md) / [REPORT2.md](REPORT2.md) |

**Bottom line:** a reader can build (Docker or native), run any stage or the full
chain (GUI or fully headless), verify with one smoke command, see exactly what was
changed in the original source, and understand precisely which steps need the GPU
and what a CPU-only port would cost — all validated on real hardware.
