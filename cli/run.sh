#!/usr/bin/env bash
#
# Subcommand wrapper that runs one or more pipeline stages of the
# interactive-hex-meshing GUI from the command line.
#
# Usage:
#   ./cli/run.sh <subcommand> <input.hdf5> [config.yaml] [--exit-after]
#
# Subcommands:
#   discretize       run Stage 2 only
#   hexahedralize    run Stage 3 only
#   full             run Stages 2 + 3 chained
#
# The <input.hdf5> argument is REQUIRED on every invocation.
# The output run directory under output/runs/ is generated automatically.
# All parameters are read from the YAML config — to tune them, copy a default
# from cli/configs/, edit the values, and pass your file as [config.yaml].
#
# Optional flags:
#   --exit-after     close the GUI window when the script finishes
#   -h | --help      show this message
#
# Outputs land under:
#     output/runs/<example>/<stage>_<YYYY_MM_DD>_<NNN>/
# where <example> is derived from the input file (filename stem, or the
# enclosing example folder if the input is itself a stage_N_*.hdf5).
set -euo pipefail

print_usage() {
  sed -n '2,/^set -euo pipefail/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//; $d'
}

# ---- 1. Resolve repo root (host paths) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ---- 2. Parse arguments ----
if [[ $# -lt 1 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
  print_usage
  exit 0
fi
if [[ $# -lt 2 ]]; then
  echo "ERROR: <input.hdf5> is required." >&2
  echo "" >&2
  print_usage
  exit 1
fi
SUBCOMMAND="$1"; shift
INPUT_HOST="$1"; shift

USER_CONFIG=""
EXIT_AFTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exit-after) EXIT_AFTER="--exit-after"; shift ;;
    -h|--help)    print_usage; exit 0 ;;
    *)
      if [[ -z "$USER_CONFIG" && -f "$1" ]]; then
        USER_CONFIG="$1"; shift
      else
        echo "ERROR: unknown argument '$1'" >&2
        echo "" >&2
        print_usage
        exit 1
      fi
      ;;
  esac
done

case "$SUBCOMMAND" in
  discretize)    DEFAULT_CONFIG="cli/configs/stage_discretization.yaml" ;;
  hexahedralize) DEFAULT_CONFIG="cli/configs/stage_hexahedralization.yaml" ;;
  full)          DEFAULT_CONFIG="cli/configs/full_pipeline.yaml" ;;
  *)
    echo "ERROR: unknown subcommand '$SUBCOMMAND'. Use: discretize | hexahedralize | full" >&2
    exit 1
    ;;
esac

CONFIG_TEMPLATE="${USER_CONFIG:-$DEFAULT_CONFIG}"
if [[ ! -f "$CONFIG_TEMPLATE" ]]; then
  echo "ERROR: config template not found: $CONFIG_TEMPLATE" >&2
  exit 1
fi
if [[ ! -f "$INPUT_HOST" ]]; then
  echo "ERROR: input file not found: $INPUT_HOST" >&2
  exit 1
fi

# ---- 3. Generate run id and create run dir ----
# Output layout: output/runs/<example>/<stage>_<date>_<NNN>/

INPUT_BASE="$(basename "$INPUT_HOST")"
INPUT_STEM="${INPUT_BASE%.*}"
DATE_STAMP="$(date +%Y_%m_%d)"

# Map subcommand to a friendly stage-dir name.
case "$SUBCOMMAND" in
  discretize)    STAGE_DIRNAME="discretization" ;;
  hexahedralize) STAGE_DIRNAME="hexahedralization" ;;
  full)          STAGE_DIRNAME="full" ;;
esac

# Derive the example name from the input path:
#   - if the file is a chained stage output (stage_N_*.hdf5), use the parent
#     dir name (e.g. .../runs/toy_plane/discretization_xxx/stage_2_*.hdf5
#     -> example = "toy_plane")
#   - otherwise use the file stem (e.g. toy_plane.hdf5 -> "toy_plane")
if [[ "$INPUT_STEM" =~ ^stage_[0-9]+_ ]]; then
  PARENT_BASE="$(basename "$(dirname "$INPUT_HOST")")"
  GRANDPARENT_BASE="$(basename "$(dirname "$(dirname "$INPUT_HOST")")")"
  if [[ -n "$GRANDPARENT_BASE" && "$GRANDPARENT_BASE" != "runs" \
        && "$GRANDPARENT_BASE" != "." && "$GRANDPARENT_BASE" != "/" ]]; then
    EXAMPLE_NAME="$GRANDPARENT_BASE"
  else
    # Older flat layout (output/runs/<example>_<date>_<NNN>/...). Strip the
    # _YYYY_MM_DD_NNN suffix from the parent dir if present.
    STRIPPED="$(printf '%s' "$PARENT_BASE" | sed -E 's/_[0-9]{4}_[0-9]{2}_[0-9]{2}_[0-9]+$//')"
    EXAMPLE_NAME="${STRIPPED:-unknown}"
  fi
else
  EXAMPLE_NAME="$INPUT_STEM"
fi

SEQ=1
while [[ -d "output/runs/${EXAMPLE_NAME}/${STAGE_DIRNAME}_${DATE_STAMP}_$(printf '%03d' $SEQ)" ]]; do
  SEQ=$((SEQ + 1))
done
RUN_ID="${STAGE_DIRNAME}_${DATE_STAMP}_$(printf '%03d' $SEQ)"
HOST_RUN_DIR="output/runs/${EXAMPLE_NAME}/${RUN_ID}"
CONTAINER_RUN_DIR="/space/output/runs/${EXAMPLE_NAME}/${RUN_ID}"

mkdir -p "$HOST_RUN_DIR"
cp "$INPUT_HOST" "$HOST_RUN_DIR/input.hdf5"

# ---- 4. Render run_config.yaml from template ----
HOST_CONFIG="$HOST_RUN_DIR/run_config.yaml"
CONTAINER_INPUT="${CONTAINER_RUN_DIR}/input.hdf5"

# Substitute the input/run_dir placeholders. The input path is ALWAYS the one
# provided on the CLI — the YAML must contain __INPUT_PATH__ (the templates do).
sed -e "s|__INPUT_PATH__|${CONTAINER_INPUT}|g" \
    -e "s|__RUN_DIR__|${CONTAINER_RUN_DIR}|g" \
    "$CONFIG_TEMPLATE" > "$HOST_CONFIG"

# ---- 5. Launch docker with the GUI + script ----
echo "[run.sh] subcommand:   $SUBCOMMAND"
echo "[run.sh] input:        $INPUT_HOST"
echo "[run.sh] config:       $CONFIG_TEMPLATE"
echo "[run.sh] run dir:      $HOST_RUN_DIR"
echo "[run.sh] launching docker..."

xhost +local:root >/dev/null 2>&1 || true

CONTAINER_CONFIG="${CONTAINER_RUN_DIR}/run_config.yaml"
LOG_FILE="$HOST_RUN_DIR/log.txt"

docker run \
  --runtime=nvidia \
  --gpus all \
  --rm \
  --name "hexmesh-${RUN_ID}" \
  --env="DISPLAY=$DISPLAY" \
  --env="NVIDIA_DRIVER_CAPABILITIES=all" \
  --env="VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json" \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  -v /usr/share/vulkan:/usr/share/vulkan:ro \
  -v "$REPO_ROOT/lib:/space/lib" \
  -v "$REPO_ROOT/evocube:/space/evocube" \
  -v "$REPO_ROOT/interactive-hex-meshing:/space/interactive-hex-meshing" \
  -v "$REPO_ROOT/compile.sh:/space/compile.sh" \
  -v "$REPO_ROOT/data:/space/data" \
  -v "$REPO_ROOT/output:/space/output" \
  -v "$REPO_ROOT/cli:/space/cli" \
  docker-hexmesh \
  bash -c "source /space/lib/vulkan-sdk-1.3.268.0/setup-env.sh \
           && cd /space/interactive-hex-meshing/bin/Release \
           && ./hex --script ${CONTAINER_CONFIG} ${EXIT_AFTER}" \
  2>&1 | tee "$LOG_FILE"

STATUS=${PIPESTATUS[0]}
echo "[run.sh] done. run dir: $HOST_RUN_DIR  (exit=$STATUS)"
exit "$STATUS"
