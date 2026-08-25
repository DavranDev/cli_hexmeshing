#!/usr/bin/env bash
#
# Smoke test for the command-line hex-meshing pipeline.
#
# Runs all four stages on one input mesh, chaining each stage's HDF5 output into
# the next, then checks the final mesh-quality metrics. This is the single
# command to answer "does the tool still work after I changed the code?".
#
# Usage:
#   ./cli_run/smoke_test.sh                 # uses interactive-hex-meshing/assets/tutorial/spot.mesh
#   ./cli_run/smoke_test.sh <input.mesh>    # use a different tet mesh (Stage-0 input)
#
# The default is true headless, so no X11 display or authorization is needed.
# Set SMOKE_GUI=1 only when intentionally testing the GUI/--exit-after path.
# Set SMOKE_NO_VULKAN=1 to additionally drop every Vulkan call (no ICD needed).
# Exits 0 and prints PASS if the pipeline produces a valid (non-inverted) hex
# mesh; exits 1 and prints FAIL otherwise.
# Stop at the first failed stage. Without `-e`, a failure inside one of the
# command substitutions below was reported, but the script continued and
# emitted misleading follow-on errors for stages whose inputs did not exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

INPUT="${1:-interactive-hex-meshing/assets/tutorial/spot.mesh}"
RUN="./cli_run/run.sh"

# Display mode: default to true headless so the verification command is reliable
# on local workstations, SSH sessions, and servers. GUI smoke is opt-in.
RUN_FLAGS=(--headless)
echo "=== smoke test: HEADLESS mode (no GUI window / no X11) ===" >&2
if [[ "${SMOKE_GUI:-0}" == "1" ]]; then
  RUN_FLAGS=(--exit-after)
  echo "=== smoke test: GUI auto-close mode (X11 required) ===" >&2
fi

# Compute device: default leaves it unset so run.sh/hex use their own default
# (cuda). Set SMOKE_DEVICE=cpu to validate the CPU-only path (slower).
if [[ -n "${SMOKE_DEVICE:-}" ]]; then
  RUN_FLAGS+=(--device "$SMOKE_DEVICE")
  echo "=== smoke test: compute device = $SMOKE_DEVICE ===" >&2
fi

# Renderer: set SMOKE_NO_VULKAN=1 to run with no Vulkan instance/device/view at
# all. Mutually exclusive with SMOKE_GUI, which needs the renderer it disables.
if [[ "${SMOKE_NO_VULKAN:-0}" == "1" ]]; then
  if [[ "${SMOKE_GUI:-0}" == "1" ]]; then
    echo "FAIL: SMOKE_GUI=1 and SMOKE_NO_VULKAN=1 are contradictory (a GUI needs Vulkan)." >&2
    exit 1
  fi
  RUN_FLAGS+=(--no-vulkan)
  echo "=== smoke test: --no-vulkan (no Vulkan instance, device or view) ===" >&2
fi

if [[ ! -f "$INPUT" ]]; then
  echo "FAIL: input not found: $INPUT" >&2
  exit 1
fi

# Derive the example name the way run.sh does (filename stem), so we can locate
# the per-stage run directories it creates under output/runs/<example>/.
EXAMPLE="$(basename "${INPUT%.*}")"

# Run one stage and echo the newest run directory it produced for that stage.
# Args: <subcommand> <stage_dirname> <input_path>
run_stage() {
  local cmd="$1" stage="$2" in="$3"
  echo "==> $cmd  ($in)" >&2
  if ! "$RUN" "$cmd" "$in" "${RUN_FLAGS[@]}" >/dev/null 2>&1; then
    echo "FAIL: '$cmd' returned non-zero" >&2
    exit 1
  fi
  local dir
  dir="$(ls -dt "output/runs/${EXAMPLE}/${stage}_"*/ 2>/dev/null | head -1)"
  if [[ -z "$dir" ]]; then
    echo "FAIL: no run directory produced for $cmd" >&2
    exit 1
  fi
  printf '%s' "$dir"
}

echo "=== smoke test: $INPUT ==="
S0="$(run_stage deform        deformation      "$INPUT")"
S1="$(run_stage decompose     decomposition    "${S0}stage_0_deformation.hdf5")"
S2="$(run_stage discretize    discretization   "${S1}stage_1_decomposition.hdf5")"
S3="$(run_stage hexahedralize hexahedralization "${S2}stage_2_discretization.hdf5")"

MESH="${S3}result.mesh"
METRICS="${S3}result_metrics.yaml"
for f in "$MESH" "$METRICS"; do
  [[ -f "$f" ]] || { echo "FAIL: expected output missing: $f" >&2; exit 1; }
done

# Pull the two numbers we gate on out of the YAML sidecar.
hexes="$(grep -E '^total_hexes:'    "$METRICS" | awk '{print $2}')"
inverted="$(grep -E '^inverted_count:' "$METRICS" | awk '{print $2}')"

echo ""
echo "--- result ---"
echo "  result.mesh:        $MESH"
echo "  total_hexes:        ${hexes:-?}"
echo "  inverted_count:     ${inverted:-?}"
grep -E '^  (min|max|mean):' "$METRICS" | sed 's/^/  scaled_jac /' | head -3
echo ""

if [[ "${inverted:-1}" == "0" && "${hexes:-0}" -gt 0 ]]; then
  echo "PASS: valid hex mesh ($hexes hexes, 0 inverted)"
  exit 0
fi
echo "FAIL: inverted_count=${inverted:-?} total_hexes=${hexes:-?} (expected 0 inverted, >0 hexes)"
exit 1
