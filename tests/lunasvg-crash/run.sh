#!/usr/bin/env bash
#
# Regression test for the lunasvg crash reported against this add-on:
# https://github.com/xbmc/repo-binary-addons/pull/165#issuecomment-5418375450
#
# Three of the public fuzz samples from sammycage/lunasvg#209 segfault the
# renderer, which in Kodi means taking the whole application down - decoding
# happens in-process and a SIGSEGV cannot be caught. The fix lives in
# depends/common/lunasvg/, so this test builds exactly what the add-on ships:
# the pinned lunasvg tarball with this repo's patches applied.
#
# Checks, in order:
#   1. every sample renders without crashing
#   2. valid SVGs render byte-identically with and without the patches, so the
#      guard cannot be hiding a rendering regression
#
# Usage: tests/lunasvg-crash/run.sh [workdir]
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:-$(mktemp -d)}
mkdir -p "$work"

url=$(awk '{print $2}' "$root/depends/common/lunasvg/lunasvg.txt")
sha=$(cat "$root/depends/common/lunasvg/lunasvg.sha256")
echo "==> lunasvg pin: $url"

cd "$work"
[ -f src.tar.gz ] || curl -sSL -o src.tar.gz "$url"
echo "$sha  src.tar.gz" | sha256sum -c - >/dev/null
echo "==> tarball checksum matches the pin"

rm -rf ctrl fix && mkdir ctrl fix
tar xzf src.tar.gz -C ctrl --strip-components=1
tar xzf src.tar.gz -C fix --strip-components=1

shopt -s nullglob
patches=("$root"/depends/common/lunasvg/*.patch)
if [ ${#patches[@]} -eq 0 ]; then
  echo "!! no patches in depends/common/lunasvg - nothing to test"; exit 1
fi
for p in "${patches[@]}"; do
  echo "==> applying $(basename "$p")"
  # -p1, exactly as cmake/scripts/common/HandleDepends.cmake applies it.
  ( cd fix && patch -p1 -i "$p" >/dev/null )
done

for v in ctrl fix; do
  cmake -S "$v" -B "build-$v" -DCMAKE_BUILD_TYPE=Release -DLUNASVG_BUILD_EXAMPLES=ON >/dev/null
  cmake --build "build-$v" -j"$(nproc)" >/dev/null
done
echo "==> both builds done"

rc=0

echo
echo "==> 1. fuzz samples must not crash the patched build"
for f in "$here"/samples/*; do
  printf '    %-48s ' "$(basename "$f")"
  set +e
  # The subshell keeps bash's own "Segmentation fault" job message off the
  # report; the exit status is what this test reads.
  ( timeout 120 "./build-fix/examples/svg2png" "$f" 50x50 >/dev/null 2>&1 ) 2>/dev/null
  status=$?
  set -e
  # 139 = SIGSEGV, 134 = SIGABRT. Anything above 128 is a signal, which is the
  # failure this test exists for. A non-zero exit below that is lunasvg
  # refusing the file, which is a fine outcome for a fuzzed sample.
  if [ $status -gt 128 ]; then
    echo "CRASH (exit $status)"; rc=1
  else
    echo "ok (exit $status)"
  fi
done

echo
echo "==> 2. valid SVGs must render identically with and without the patches"
for v in ctrl fix; do
  rm -rf "out-$v" && mkdir -p "out-$v"
  ( cd "out-$v" && for f in "$here"/valid/*.svg; do
      # svg2png writes <basename>.png into the current directory.
      timeout 120 "../build-$v/examples/svg2png" "$f" 512x512 >/dev/null 2>&1 || true
    done )
done
for f in "$here"/valid/*.svg; do
  n=$(basename "$f")
  printf '    %-48s ' "$n"
  if [ ! -f "out-ctrl/$n.png" ] || [ ! -f "out-fix/$n.png" ]; then
    echo "MISSING OUTPUT"; rc=1
  elif cmp -s "out-ctrl/$n.png" "out-fix/$n.png"; then
    echo "identical"
  else
    echo "DIFFERS"; rc=1
  fi
done

echo
[ $rc -eq 0 ] && echo "PASS" || echo "FAIL"
exit $rc
