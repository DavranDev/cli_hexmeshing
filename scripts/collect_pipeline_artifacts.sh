#!/usr/bin/env bash
# Gather one pipeline run's artifacts into the flat layout
# scripts/compare_pipeline_artifacts.py expects.
#
#   collect_pipeline_artifacts.sh <output_root> <example> <dest> [run_suffix]
#
# <output_root> is the directory holding runs/ (usually ./output), <example> the
# input stem (e.g. spot). Without <run_suffix> the newest run directory per stage
# is used, which is what a freshly chained four-stage run produces. Pass an
# explicit suffix (e.g. 2026_08_03_003) to pin a specific earlier run -- needed
# when several runs share an output tree and "newest" is the wrong one.
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 <output_root> <example> <dest> [run_suffix]" >&2
  exit 2
fi

OUT_ROOT="$1"
EXAMPLE="$2"
DEST="$3"
RUN_SUFFIX="${4:-}"
mkdir -p "$DEST"

newest() {
  if [[ -n "$RUN_SUFFIX" ]]; then
    local d="$OUT_ROOT/runs/$EXAMPLE/$1_$RUN_SUFFIX/"
    [[ -d "$d" ]] && printf '%s' "$d"
    return 0
  fi
  ls -dt "$OUT_ROOT/runs/$EXAMPLE/$1"_*/ 2>/dev/null | head -1
}

copy_from() { # <stage-dir-prefix> <filename...>
  local prefix="$1"; shift
  local dir; dir="$(newest "$prefix")"
  if [[ -z "$dir" ]]; then
    echo "ERROR: no run directory for stage '$prefix' under $OUT_ROOT/runs/$EXAMPLE" >&2
    exit 1
  fi
  local f
  for f in "$@"; do
    if [[ -f "$dir$f" ]]; then
      cp "$dir$f" "$DEST/$f"
    else
      echo "ERROR: expected artifact missing: $dir$f" >&2
      exit 1
    fi
  done
}

copy_from deformation       stage_0_deformation.hdf5
copy_from decomposition     stage_1_decomposition.hdf5
copy_from discretization    stage_2_discretization.hdf5
copy_from hexahedralization stage_3_hexahedralization.hdf5 result.mesh result_metrics.yaml

echo "collected into $DEST:"
ls -1 "$DEST"
