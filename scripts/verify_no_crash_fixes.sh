#!/usr/bin/env bash
# Lightweight regression checks for the crash fixes that do not require a full
# GPU/X11 pipeline run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVOCUBE="$ROOT/evocube"
PATCH_FILE="$ROOT/patches/evocube-polycube_final-segfault.patch"
EVOCUBE_INIT_PATCH_FILE="$ROOT/patches/evocube-init_from_folder-options.patch"
HEX_SRC="$ROOT/interactive-hex-meshing"
HEX_PATCH_FILE="$ROOT/patches/interactive-hex-meshing-validation-layer-fallback.patch"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

if [[ ! -f "$PATCH_FILE" ]]; then
  fail "missing $PATCH_FILE"
fi
if [[ ! -f "$EVOCUBE_INIT_PATCH_FILE" ]]; then
  fail "missing $EVOCUBE_INIT_PATCH_FILE"
fi
if [[ ! -f "$HEX_PATCH_FILE" ]]; then
  fail "missing $HEX_PATCH_FILE"
fi

if grep -q "Skipping final-polycube measurement" "$EVOCUBE/app/init_from_folder.cpp"; then
  pass "Evocube source already has the missing-polycube_final guard"
else
  patch -p1 --dry-run -d "$EVOCUBE" < "$PATCH_FILE" >/dev/null \
    || fail "Evocube patch is neither applied nor cleanly applicable"
  pass "Evocube patch is cleanly applicable to the current source"
fi

if grep -q -- "--input-dir PATH" "$EVOCUBE/app/init_from_folder.cpp"; then
  pass "Evocube init_from_folder has reliable CLI options"
elif grep -q "Skipping final-polycube measurement" "$EVOCUBE/app/init_from_folder.cpp"; then
  patch -p1 --dry-run -d "$EVOCUBE" < "$EVOCUBE_INIT_PATCH_FILE" >/dev/null \
    || fail "Evocube init_from_folder options patch is neither applied nor cleanly applicable"
  pass "Evocube init_from_folder options patch is cleanly applicable to the current source"
else
  pass "Evocube init_from_folder options patch will apply after the polycube_final guard patch"
fi

INSTANCE_CPP="$HEX_SRC/vkoo/src/core/Instance.cpp"
hex_validation_fallback_applied=0
if grep -q "enable_validation_layer_ = false" "$INSTANCE_CPP"; then
  hex_validation_fallback_applied=1
  pass "hex source already has the missing-validation-layer fallback"
else
  patch -p1 --dry-run -d "$HEX_SRC" < "$HEX_PATCH_FILE" >/dev/null \
    || fail "hex validation-layer patch is neither applied nor cleanly applicable"
  pass "hex validation-layer patch is cleanly applicable to the current source"
fi
grep -q "return VK_FALSE" "$INSTANCE_CPP" \
  || fail "Vulkan debug callback does not return VK_FALSE"
if grep -q 'throw std::runtime_error("Ugh!")' "$INSTANCE_CPP"; then
  fail "Vulkan debug callback still throws on validation messages"
fi
pass "Vulkan validation callback no longer throws"
if [[ $hex_validation_fallback_applied -eq 1 ]]; then
  if grep -q 'Validation layers requested but not available' "$INSTANCE_CPP"; then
    fail "Vulkan instance still aborts when validation layers are unavailable"
  fi
  grep -q "Continuing without" "$INSTANCE_CPP" \
    || fail "Vulkan instance does not warn-and-disable missing validation layers"
  grep -q "enable_validation_layer_ = false" "$INSTANCE_CPP" \
    || fail "Vulkan instance does not disable missing validation layers"
  pass "Vulkan instance tolerates missing validation layers"
else
  pass "Vulkan instance will tolerate missing validation layers after compile-time patch"
fi

run_expected_nonzero_without_crash() {
  local name="$1"
  shift
  set +e
  local output
  output=$(timeout 30 "$@" 2>&1)
  local status=$?
  set -e

  if [[ $status -eq 124 ]]; then
    echo "$output"
    fail "$name timed out"
  fi
  if [[ $status -eq 134 || $status -eq 139 ]]; then
    echo "$output"
    fail "$name crashed with status $status"
  fi
  if [[ $status -eq 0 ]]; then
    echo "$output"
    fail "$name unexpectedly succeeded on intentionally missing inputs"
  fi

  pass "$name returns a clean nonzero status on missing inputs"
}

EVOCUBE_LD="$EVOCUBE/build/lib/libHexEx${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if [[ -x "$EVOCUBE/build/measurement" ]]; then
  LD_LIBRARY_PATH="$EVOCUBE_LD" run_expected_nonzero_without_crash \
    "evocube measurement" \
    "$EVOCUBE/build/measurement" /tmp/autohexmesh_missing_boundary.obj /tmp/autohexmesh_missing_polycube.obj
else
  echo "SKIP: evocube/build/measurement is not built"
fi

if [[ -x "$EVOCUBE/build/figure_generator" ]]; then
  LD_LIBRARY_PATH="$EVOCUBE_LD" run_expected_nonzero_without_crash \
    "evocube figure_generator" \
    "$EVOCUBE/build/figure_generator" missing_model 1 /tmp/autohexmesh_missing_data/
else
  echo "SKIP: evocube/build/figure_generator is not built"
fi

if [[ -x "$EVOCUBE/build/init_from_folder" ]]; then
  set +e
  init_help=$(LD_LIBRARY_PATH="$EVOCUBE_LD" timeout 30 "$EVOCUBE/build/init_from_folder" --help 2>&1)
  init_help_status=$?
  set -e
  [[ $init_help_status -eq 0 ]] || { echo "$init_help"; fail "evocube init_from_folder --help failed"; }
  grep -q -- "--input-dir" <<<"$init_help" || fail "evocube init_from_folder --help does not list --input-dir"
  pass "evocube init_from_folder --help exits cleanly"

  LD_LIBRARY_PATH="$EVOCUBE_LD" run_expected_nonzero_without_crash \
    "evocube init_from_folder missing input" \
    "$EVOCUBE/build/init_from_folder" --input-dir /tmp/autohexmesh_missing_examples --no-figures
else
  echo "SKIP: evocube/build/init_from_folder is not built"
fi

HEX="$ROOT/interactive-hex-meshing/bin/Release/hex"
TORCH_LIB="$ROOT/lib/libtorch/lib"
VULKAN_ROOT="$ROOT/lib/vulkan-sdk/x86_64"
if [[ ! -d "$VULKAN_ROOT" ]]; then
  VULKAN_ROOT="$ROOT/lib/vulkan-sdk-1.3.268.0/x86_64"
fi
if [[ -x "$HEX" && -d "$TORCH_LIB" ]]; then
  set +e
  hex_help=$(LD_LIBRARY_PATH="$TORCH_LIB:$VULKAN_ROOT/lib:$VULKAN_ROOT/lib/VulkanLoader/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    timeout 30 "$HEX" --help 2>&1)
  hex_status=$?
  set -e
  [[ $hex_status -eq 0 ]] || { echo "$hex_help"; fail "hex --help failed"; }
  grep -q -- "--headless" <<<"$hex_help" || fail "hex --help does not list --headless"

  # The advertised device list depends on the BUILD variant, so this cannot
  # assert the CUDA-build wording unconditionally: a -DHEX_ENABLE_CUDA=OFF build
  # correctly offers only `--device cpu`. Check against what the binary actually
  # is, taken from the marker compile.sh writes next to it.
  hex_variant="$(sed -n 's/^variant=//p' "$ROOT/interactive-hex-meshing/bin/Release/.hexmesh-variant" 2>/dev/null | head -n 1)"
  if [[ -z "$hex_variant" ]]; then
    # No marker (a binary predating it): infer from the help text itself, and
    # require the CUDA wording only if it claims cuda.
    if grep -q -- "--device cpu|cuda" <<<"$hex_help"; then hex_variant=cuda; else hex_variant=cpu; fi
    echo "NOTE: no bin/Release/.hexmesh-variant marker; inferred '$hex_variant' from --help"
  fi

  grep -q -- "--device cpu" <<<"$hex_help" || fail "hex --help does not list --device cpu"
  if [[ "$hex_variant" == cuda ]]; then
    grep -q -- "--device cpu|cuda" <<<"$hex_help" \
      || fail "CUDA-enabled hex --help does not list --device cpu|cuda"
  else
    # `if !` rather than `grep && fail`: the no-match case returns 1, which
    # under this script's `set -e` would abort instead of passing.
    if grep -q -- "--device cpu|cuda" <<<"$hex_help"; then
      fail "CPU-only hex --help advertises cuda, which this build cannot do"
    fi
    grep -qi "built without CUDA" <<<"$hex_help" \
      || fail "CPU-only hex --help does not state that the build has no CUDA"
  fi
  pass "hex advertises headless and device modes ($hex_variant build)"
else
  echo "SKIP: hex binary or LibTorch runtime is not available"
fi

echo "OK: no-crash fix checks completed."
