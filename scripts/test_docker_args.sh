#!/usr/bin/env bash
# Unit tests for cli_run/lib/docker_args.sh.
#
# The property that matters: a CPU-variant launch must never carry `nvidia`,
# `--gpus` or `--runtime`. cli_run/run.sh, ./hex and run_docker.sh all build
# their docker command lines from this helper, so asserting it here covers all
# three. Host-side only — no Docker needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cli_run/lib/docker_args.sh
source "$ROOT/cli_run/lib/docker_args.sh"
fail=0
check() { # <desc> <expect-clean:0|1> <text>
  local desc="$1" want_clean="$2" text="$3"
  if grep -Eiq 'nvidia|--gpus|--runtime' <<<"$text"; then found=1; else found=0; fi
  if [[ "$want_clean" == 1 && $found -eq 1 ]]; then
    echo "FAIL: $desc contains GPU options: $text"; fail=1
  elif [[ "$want_clean" == 0 && $found -eq 0 ]]; then
    echo "FAIL: $desc is missing the GPU options it needs"; fail=1
  else
    echo "ok:   $desc"
  fi
}

HEX_IMAGE_VARIANT=cpu; hexmesh_runtime_docker_args
check "cpu docker args"        1 "${HEXMESH_DOCKER_ARGS[*]-}"
check "cpu LD_LIBRARY_PATH"    1 "$(hexmesh_ld_library_path /space)"
[[ "$(hexmesh_ld_library_path /space)" == "/space/lib/libtorch/lib" ]] \
  || { echo "FAIL: cpu LD_LIBRARY_PATH references a Vulkan SDK"; fail=1; }

HEX_IMAGE_VARIANT=cuda; hexmesh_runtime_docker_args
check "cuda docker args"       0 "${HEXMESH_DOCKER_ARGS[*]-}"

HEX_IMAGE_VARIANT=bogus
if hexmesh_variant >/dev/null 2>&1; then echo "FAIL: bogus variant accepted"; fail=1
else echo "ok:   bogus variant rejected"; fi

# The binary-variant guard must catch a cpu/cuda mismatch.
tmp="$(mktemp -d)"; printf 'variant=cuda\n' > "$tmp/.hexmesh-variant"
HEX_IMAGE_VARIANT=cpu
if hexmesh_check_binary_variant "$tmp" >/dev/null 2>&1; then
  echo "FAIL: mismatched binary variant accepted"; fail=1
else echo "ok:   mismatched binary variant rejected"; fi
HEX_IMAGE_VARIANT=cuda
hexmesh_check_binary_variant "$tmp" >/dev/null 2>&1 \
  && echo "ok:   matching binary variant accepted" \
  || { echo "FAIL: matching binary variant rejected"; fail=1; }
rm -rf "$tmp"

[[ $fail -eq 0 ]] && echo "PASS: docker_args helper" || { echo "FAIL"; exit 1; }
