#!/usr/bin/env bash
# `make extension-amdgpu` against a registry the test runs: the extension carries the amdgpu
# modules of talos-kernel's own kernel, byte for byte, so they load under its signing key, plus
# the amdgpu firmware. A module from siderolabs' kernel would carry a signature this kernel
# refuses, so the signature marker alone proves nothing.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
# check <description> <want> <got>
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"
  else printf 'FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}

[ -n "${TEST_REGISTRY:-}" ] || { echo "skip: no TEST_REGISTRY"; exit 0; }
kernel=$(make -s print-config TARGET_ARCH=amd64 | sed -n 's/^kernel *: //p')
modules="drivers/gpu/drm/amd/amdgpu/amdgpu.ko drivers/gpu/drm/amd/amdxcp/amdxcp.ko"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# rootfs <image> <dir>: the image's files.
rootfs() {
  local c
  c=$(docker create --platform linux/amd64 "$1" /none) && docker export "$c" | tar -xf - -C "$2"
  docker rm "$c" >/dev/null
}

make -s extension-amdgpu TARGET_ARCH=amd64 TAG=test REGISTRY="$TEST_REGISTRY" >"$work/log" 2>&1
status=$?
[ $status -eq 0 ] || tail -30 "$work/log" >&2
check "builds" "0" "$status"

mkdir "$work/ext" "$work/kernel"
docker pull -q --platform linux/amd64 "$TEST_REGISTRY/amdgpu:test-amd64" >/dev/null 2>&1
rootfs "$TEST_REGISTRY/amdgpu:test-amd64" "$work/ext" 2>/dev/null
docker pull -q --platform linux/amd64 "$kernel" >/dev/null
rootfs "$kernel" "$work/kernel"

release=$(ls "$work/kernel/usr/lib/modules")
for m in $modules; do
  check "$(basename "$m") is the kernel's own" \
    "$(sha256sum < "$work/kernel/usr/lib/modules/$release/kernel/$m")" \
    "$(sha256sum < "$work/ext/rootfs/usr/lib/modules/$release/kernel/$m" 2>/dev/null)"
done
check "carries the amdgpu firmware" "yes" \
  "$([ -n "$(ls "$work/ext/rootfs/usr/lib/firmware/amdgpu" 2>/dev/null)" ] && echo yes || echo no)"
check "names itself amdgpu" "amdgpu" "$(sed -n 's/^  name: //p' "$work/ext/manifest.yaml" 2>/dev/null)"
exit $fail
