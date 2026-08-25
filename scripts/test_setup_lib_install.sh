#!/usr/bin/env bash
# Verifies setup.sh's local-package management for all four build variants:
# every variant must CHECK what is already installed under lib/ (libtorch,
# vulkan-sdk) and automatically download + install whatever is missing, reuse
# what is valid, and replace what is broken — never trust a directory name.
#
# Runs setup.sh inside a throwaway sandbox with stubbed docker/wget/sudo/
# apt-get, so no real image builds or multi-GB downloads happen. The wget stub
# records every requested URL and fabricates a minimal valid archive, which
# exercises setup.sh's real download -> extract -> validate -> activate path.
# Host-side only; finishes in seconds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export STUB_LOG_DIR="$TEST_ROOT/logs"
STUBS_DIR="$TEST_ROOT/stubs"
mkdir -p "$STUB_LOG_DIR" "$STUBS_DIR"

fail=0
ok()  { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# ---- stubs ----------------------------------------------------------------

cat > "$STUBS_DIR/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_LOG_DIR/docker.log"
exit 0
EOF

cat > "$STUBS_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

cat > "$STUBS_DIR/apt-get" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# setup.sh checks for vulkaninfo before apt-installing host vulkan-tools.
cat > "$STUBS_DIR/vulkaninfo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$STUBS_DIR/wget" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -O) out="$2"; shift 2 ;;
    -*) shift ;;
    *)  url="$1"; shift ;;
  esac
done
echo "$url" >> "$STUB_LOG_DIR/wget.log"
python3 "$STUB_LOG_DIR/../make_archive.py" "$url" "$out"
EOF
chmod +x "$STUBS_DIR"/*

cat > "$TEST_ROOT/make_archive.py" <<'EOF'
import io, sys, tarfile, zipfile

url, out = sys.argv[1], sys.argv[2]
if "libtorch" in url:
    variant = "cpu" if ("%2Bcpu" in url or "+cpu" in url) else "cu124"
    with zipfile.ZipFile(out, "w") as z:
        z.writestr("libtorch/build-version", f"2.6.0+{variant}\n")
        z.writestr("libtorch/lib/libtorch_cpu.so", "")
        if variant != "cpu":
            z.writestr("libtorch/lib/libtorch_cuda.so", "")
elif "vulkan" in url:
    with tarfile.open(out, "w:xz") as t:
        for name in (
            "setup-env.sh",
            "x86_64/lib/libVkLayer_khronos_validation.so",
            "x86_64/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json",
        ):
            info = tarfile.TarInfo("1.4.999.0/" + name)
            info.size = 0
            t.addfile(info, io.BytesIO(b""))
else:
    sys.exit(f"unexpected download URL: {url}")
EOF

# ---- sandbox + runner -----------------------------------------------------

make_sandbox() { # <dir>
  mkdir -p "$1/scripts" "$1/cli_run/lib"
  cp "$ROOT/setup.sh" "$1/"
  cp "$ROOT/scripts/test_docker_args.sh" "$1/scripts/"
  cp "$ROOT/cli_run/lib/docker_args.sh" "$1/cli_run/lib/"
}

run_setup() { # <sandbox> [setup args...]
  local sb="$1"; shift
  : > "$STUB_LOG_DIR/wget.log"
  if ! (cd "$sb" && RUN_SMOKE=0 PATH="$STUBS_DIR:$PATH" bash ./setup.sh "$@") \
      > "$STUB_LOG_DIR/last_run.log" 2>&1; then
    echo "---- setup.sh $* failed; output: ----"
    cat "$STUB_LOG_DIR/last_run.log"
    bad "setup.sh $* exited non-zero"
    return 1
  fi
}

wget_hits() { # <pattern> -> count of matching download URLs
  grep -c -- "$1" "$STUB_LOG_DIR/wget.log" 2>/dev/null || true
}

assert_downloads() { # <desc> <libtorch-pattern-or-'-'> <vulkan:0|1>
  local desc="$1" lt="$2" vk="$3"
  if [[ "$lt" == "-" ]]; then
    [[ "$(wget_hits libtorch)" == 0 ]] \
      && ok "$desc: no LibTorch re-download" \
      || bad "$desc: unexpected LibTorch download"
  else
    [[ "$(wget_hits "$lt")" == 1 ]] \
      && ok "$desc: downloaded LibTorch ($lt)" \
      || bad "$desc: expected exactly one LibTorch download matching '$lt'"
  fi
  [[ "$(wget_hits vulkan)" == "$vk" ]] \
    && ok "$desc: Vulkan SDK downloads = $vk" \
    || bad "$desc: expected $vk Vulkan SDK download(s), got $(wget_hits vulkan)"
}

assert_libtorch_variant() { # <desc> <sandbox> <variant>
  local marker="$2/lib/libtorch/.hexmesh-variant"
  if [[ -f "$marker" ]] && grep -qx "variant=$3" "$marker"; then
    ok "$1: active LibTorch is '$3'"
  else
    bad "$1: lib/libtorch is not the '$3' variant"
  fi
}

assert_vulkan_sdk() { # <desc> <sandbox> <present:0|1>
  local have=0
  [[ -f "$2/lib/vulkan-sdk/setup-env.sh" \
     && -f "$2/lib/vulkan-sdk/x86_64/lib/libVkLayer_khronos_validation.so" ]] && have=1
  [[ "$have" == "$3" ]] \
    && ok "$1: lib/vulkan-sdk present=$3" \
    || bad "$1: lib/vulkan-sdk present=$have, expected $3"
}

# ---- 1..4: fresh install per variant --------------------------------------
# Each variant starts from an empty lib/ and must pull in exactly the local
# packages it needs: the right LibTorch always, the LunarG SDK only for the
# default CUDA+Vulkan variant (the other three deliberately link no LunarG SDK).

SB_DEFAULT="$TEST_ROOT/sb-default"
make_sandbox "$SB_DEFAULT"
run_setup "$SB_DEFAULT" && {
  assert_downloads       "default (CUDA+Vulkan) fresh" cu124 1
  assert_libtorch_variant "default (CUDA+Vulkan) fresh" "$SB_DEFAULT" cu124
  assert_vulkan_sdk       "default (CUDA+Vulkan) fresh" "$SB_DEFAULT" 1
}

SB_CPU="$TEST_ROOT/sb-cpu"
make_sandbox "$SB_CPU"
run_setup "$SB_CPU" --cpu && {
  assert_downloads       "--cpu fresh" '%2Bcpu' 0
  assert_libtorch_variant "--cpu fresh" "$SB_CPU" cpu
  assert_vulkan_sdk       "--cpu fresh" "$SB_CPU" 0
}

SB_NOVK="$TEST_ROOT/sb-novk"
make_sandbox "$SB_NOVK"
run_setup "$SB_NOVK" --no-vulkan && {
  assert_downloads       "--no-vulkan fresh" cu124 0
  assert_libtorch_variant "--no-vulkan fresh" "$SB_NOVK" cu124
  assert_vulkan_sdk       "--no-vulkan fresh" "$SB_NOVK" 0
}

SB_CPU_NOVK="$TEST_ROOT/sb-cpu-novk"
make_sandbox "$SB_CPU_NOVK"
run_setup "$SB_CPU_NOVK" --cpu --no-vulkan && {
  assert_downloads       "--cpu --no-vulkan fresh" '%2Bcpu' 0
  assert_libtorch_variant "--cpu --no-vulkan fresh" "$SB_CPU_NOVK" cpu
  assert_vulkan_sdk       "--cpu --no-vulkan fresh" "$SB_CPU_NOVK" 0
}

# ---- 5: rerun reuses valid local installs (no re-download) ----------------

run_setup "$SB_DEFAULT" && \
  assert_downloads "default rerun" - 0

# ---- 6: variant switch parks + reuses instead of re-downloading -----------

run_setup "$SB_DEFAULT" --cpu && {
  assert_downloads       "switch to --cpu" '%2Bcpu' 0
  assert_libtorch_variant "switch to --cpu" "$SB_DEFAULT" cpu
  [[ -d "$SB_DEFAULT/lib/libtorch-cu124" ]] \
    && ok "switch to --cpu: cu124 tree parked, not deleted" \
    || bad "switch to --cpu: cu124 tree was not parked"
}
run_setup "$SB_DEFAULT" && {
  assert_downloads       "switch back to default" - 0
  assert_libtorch_variant "switch back to default" "$SB_DEFAULT" cu124
}

# ---- 7: a broken Vulkan SDK is detected and re-downloaded -----------------

rm -f "$SB_DEFAULT/lib/vulkan-sdk/x86_64/lib/libVkLayer_khronos_validation.so"
run_setup "$SB_DEFAULT" && {
  assert_downloads  "corrupt vulkan-sdk" - 1
  assert_vulkan_sdk "corrupt vulkan-sdk repaired" "$SB_DEFAULT" 1
}

# ---- 8: an unidentifiable LibTorch is parked and replaced, not trusted ----

rm -f "$SB_CPU/lib/libtorch/.hexmesh-variant" "$SB_CPU/lib/libtorch/build-version"
run_setup "$SB_CPU" --cpu && {
  assert_downloads       "corrupt libtorch" '%2Bcpu' 0
  assert_libtorch_variant "corrupt libtorch replaced" "$SB_CPU" cpu
  compgen -G "$SB_CPU/lib/libtorch-unidentified-*" > /dev/null \
    && ok "corrupt libtorch: old tree parked under a timestamped name" \
    || bad "corrupt libtorch: old tree was deleted instead of parked"
}

[[ $fail -eq 0 ]] && echo "PASS: setup.sh local-package install (all 4 variants)" \
  || { echo "FAIL"; exit 1; }
