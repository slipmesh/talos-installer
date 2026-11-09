#!/usr/bin/env bash
# `make imager` with stand-in kernels: the image is the stock imager with both arches' vmlinuz and
# initramfs replaced, and its labels name the installer and the extensions it belongs with.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
# check <description> <want> <got>
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"
  else printf 'FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/kernels"
for a in amd64 arm64; do
  echo "vmlinuz-$a" > "$work/kernels/vmlinuz-$a"
  echo "initramfs-$a" > "$work/kernels/initramfs-$a.xz"
done

# imager <kernels dir> <oci dir>: exit status of `make imager` exporting an OCI layout.
imager() {
  make -s imager REGISTRY=registry.example/o TAG=sha-abc VERSION=v1.15.0-alpha.2+sm.9 \
    KERNELS_DIR="$1" IMAGER_OUTPUT="type=oci,dest=$2,tar=false" >"$work/log" 2>&1
  local status=$?
  [ $status -eq 0 ] || tail -15 "$work/log" >&2
  echo $status
}

# blob <oci dir> <digest>: the path of a blob.
blob() { echo "$1/blobs/${2/://}"; }

check "builds" "0" "$(imager "$work/kernels" "$work/oci")"
index=$(blob "$work/oci" "$(jq -r '.manifests[0].digest' "$work/oci/index.json" 2>/dev/null)")
for a in amd64 arm64; do
  manifest=$(jq -r --arg a "$a" '.manifests[] | select(.platform.architecture == $a) | .digest' "$index" 2>/dev/null)
  [ -n "$manifest" ] || { check "an $a image" "present" "missing"; continue; }
  manifest=$(blob "$work/oci" "$manifest")
  config=$(blob "$work/oci" "$(jq -r .config.digest "$manifest")")
  check "$a: names the installer it belongs with" "registry.example/o/talos-installer:v1.15.0-alpha.2-sm.9" \
    "$(jq -r '.config.Labels["dev.slipmesh.installer"]' "$config")"
  for b in amd64 arm64; do
    check "$a: names the $b extensions" \
      "registry.example/o/amneziawg:sha-abc-$b registry.example/o/awg:sha-abc-$b registry.example/o/router:sha-abc-$b registry.example/o/nftables:sha-abc-$b" \
      "$(jq -r --arg b "$b" '.config.Labels["dev.slipmesh.extensions." + $b]' "$config")"
  done
  # Later layers win, so the last one holding a path is what the imager reads.
  got=""
  for b in amd64 arm64; do
    for f in vmlinuz initramfs.xz; do
      content=""
      for layer in $(jq -r '.layers[].digest' "$manifest"); do
        c=$(tar -xOf "$(blob "$work/oci" "$layer")" "usr/install/$b/$f" 2>/dev/null) && content=$c
      done
      got+="$b/$f=$content "
    done
  done
  check "$a: carries both arches' kernel and initramfs" \
    "amd64/vmlinuz=vmlinuz-amd64 amd64/initramfs.xz=initramfs-amd64 arm64/vmlinuz=vmlinuz-arm64 arm64/initramfs.xz=initramfs-arm64 " "$got"
done

rm "$work/kernels/initramfs-arm64.xz"
check "a missing kernel file fails" "1" "$( [ "$(imager "$work/kernels" "$work/oci2" 2>/dev/null)" = 0 ] && echo 0 || echo 1)"
exit $fail
