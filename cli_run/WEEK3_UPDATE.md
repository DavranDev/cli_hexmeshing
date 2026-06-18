# Week-3 Update — Command-line hex-meshing tool

**Headline (demoable):** `hex --headless` now runs the whole pipeline with **no GUI
window and no display**, and **Stage 2 (discretize) runs CPU-only** (no NVIDIA GPU).
Everything below was validated on hardware — the dev box turned out to *be* a working
GPU host (RTX 4090, driver 580.159.03), so every Week-2 "pending a GPU host" item is
now closed.

Full consolidated report: [REPORT3.md](REPORT3.md). Status date 2026-06-18, branch
`cli-runner`. **Committed locally; not yet pushed** (pushing in one batch later).

---

## 1. Summary

Week 3 turned the Week-2 feasibility layer into delivery: a real `--headless` mode,
runtime-backed GPU evidence, a proven CPU-only Stage 2 + a costed plan for the rest,
GPU run-validation of the build work, a slim image, and the final binary — folded
into one report.

| Task | Result |
|---|---|
| **T1** true headless `--headless` | ✅ implemented + **metric gate PASS** (18 526 hexes, 0 inverted, headless) |
| **T2** dependency map, part 2 | ✅ per-stage runtime `nvidia-smi` evidence; map finalized |
| **T3** CPU-only feasibility | ✅ Stage 2 proven CPU-only; S0/S1/S3 costed |
| **T4** GPU run-validation + slim image | ✅ Docker smoke (xvfb + headless), native run, slim image −42% |
| **T5** final binary | ✅ extracted + fingerprinted; runs in a matching env w/o rebuild |
| **T6** consolidated report | ✅ [REPORT3.md](REPORT3.md) |

---

## 2. The deliverables

### T1 — True headless mode  ✅ implemented + gate PASS
A real `--headless` flag (surfaceless Vulkan, "design B"): no window / surface /
swapchain / render-pipelines / GUI are created; the tool runs the pipeline and
exits. **Additive startup guard, not a logic rewrite** — 5 startup files, no
stage/optimizer/view code changed. Metric gate (definition of done): full chain via
`--headless` with no `DISPLAY` → **`total_hexes 18526, inverted_count 0`**, identical
to the GUI run. Design + trace + verification: [HEADLESS.md](HEADLESS.md) §0.

### T2 — Dependency map, part 2  ✅ runtime evidence
Per-stage `nvidia-smi` on the RTX 4090: peak GPU util **deform 72 % / decompose
55 % / discretize 13 % / hexahedralize 66 %** (idle 3 %). Utilisation is the
discriminator — Stage 2 does no CUDA compute. Map finalized, no "pending" cells:
[DEPENDENCY_MAP.md](DEPENDENCY_MAP.md).

### T3 — CPU-only feasibility  ✅ S2 proven, rest costed
Stage 2 ran end-to-end on a **CUDA-less** box (software Vulkan via lavapipe) →
18 526 hexes, no CUDA. S0 = a mechanical device knob (~39 `.cuda()` calls); S1/S3 =
device knob + a CUDA-kernel port (SDF trivial, projection medium). Recommended path
+ costs: [CPU_ONLY.md](CPU_ONLY.md).

### T4 — GPU run-validation + slim image  ✅
- `Dockerfile.build` smoke **PASS** on the GPU — both xvfb GUI and `--headless`
  (18 526 / 0).
- The binary also runs **natively on the host** (no container): CUDA deform +
  discretize, headless, exit 0.
- New two-stage **slim** image (`runtime` target): **15.2 GB vs 26.1 GB devel
  (−42 %)**, headless smoke PASS out of the box. BUILD.md §A2.6.

### T5 — Final binary  ✅
`hex` (with `--headless`) extracted from the clean self-contained build:
sha256 `dea52a45…3bed3`, `ldd` clean. Provenance + env in `dist/MANIFEST.md`.
Confirmed: the extracted binary runs the full headless smoke in a matching env it
did **not** build (18 526 / 0). Delivery = Docker image (portable) or the bare
binary as a GitHub Release asset (uploaded with the push).

### T6 — Consolidated report  ✅
[REPORT3.md](REPORT3.md): build / usage / test / source-tracking / headless /
dependency-map / CPU-only / known-gaps in one document, mapped to all 13 of your
items, cross-linking the detailed docs.

---

## 3. Original source — change footprint (refreshed)

Still small and **additive — no model / optimizer / geometry algorithm changed**.
Total vs the pre-CLI baseline `d0a904a`: **+682 / −33 across 21 files** (was
+590/−4/18 at Week 1; the additive `--headless` startup guards account for the
growth). Per-file breakdown: [SOURCE_CHANGES.md](SOURCE_CHANGES.md).

---

## 4. What's left after Week 3

- **Push to GitHub** — all Week-1/2/3 work is **committed on `cli-runner`** (both
  repos) but intentionally **not pushed yet**; push later in one batch (submodule
  fork first, then the parent pointer), then a fresh-clone `--recurse-submodules` +
  `docker build` re-verify, and upload the bare binary as a Release asset.
- **Full CPU-only pipeline** — S2 runs CPU-only today; S0 (device knob) + S1/S3
  (kernel ports) are a costed ~3–4.5-day follow-on (CPU_ONLY.md), not a one-week
  item.
- **Slim-image GUI** — the slim image is validated for headless use; on-screen GUI
  needs the devel image (it carries the full NVIDIA GL/Vulkan stack).

---

## 5. Artifacts (all on `cli-runner`)

| Artifact | Where |
|---|---|
| Consolidated report | [REPORT3.md](REPORT3.md) |
| Build guide (Docker one-step + native + slim) | [BUILD.md](BUILD.md) |
| Usage + I/O | [USAGE_AND_TESTS.md](USAGE_AND_TESTS.md) |
| Smoke test | `cli_run/smoke_test.sh` (`SMOKE_HEADLESS=1` for no-display) |
| Headless design + status | [HEADLESS.md](HEADLESS.md) |
| Dependency map (final) | [DEPENDENCY_MAP.md](DEPENDENCY_MAP.md) |
| CPU-only feasibility | [CPU_ONLY.md](CPU_ONLY.md) |
| Source-change tracking | [SOURCE_CHANGES.md](SOURCE_CHANGES.md) |
| Prebuilt binary + manifest | `dist/` (gitignored; ships as image / Release asset) |
| Docker images | `hexmesh-cli:week3` (devel) · `hexmesh-cli:week3-slim` (15.2 GB) |
