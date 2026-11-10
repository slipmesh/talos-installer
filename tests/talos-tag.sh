#!/usr/bin/env bash
# The Talos build takes the release as its tag, so a node reports v<talos>+sm.<n>; without a
# VERSION it takes the Talos release itself, and a VERSION Talos could not parse is refused.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
# check <description> <want> <got>
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"
  else printf 'FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}

talos=$(make -s print-config TARGET_ARCH=amd64 | sed -n 's/^talos *: \(v[^ ]*\).*/\1/p')
[ -n "$talos" ] || { echo "FAIL no Talos version from print-config"; exit 1; }

# tag [VERSION]: the TAG the Talos build gets, as check-talos-build reports it, or "refused".
tag() {
  out=$(make -s check-talos-build ${1:+VERSION=$1} 2>&1) || { echo refused; return; }
  sed -n 's/^the Talos build gets TAG=\([^,]*\),.*/\1/p' <<<"$out"
}

check "a release tags the Talos build with itself" "$talos+sm.9" "$(tag "$talos+sm.9")"
check "without a VERSION the Talos build gets the Talos release" "$talos" "$(tag)"
check "a VERSION of another Talos release is refused" "refused" "$(tag v1.0.0+sm.1)"
check "a VERSION with the revision as a pre-release is refused" "refused" "$(tag "$talos-sm.9")"
exit $fail
