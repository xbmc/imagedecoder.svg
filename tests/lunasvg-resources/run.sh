#!/usr/bin/env bash
#
# An SVG must not be able to make the decoder open local files.
#
# lunasvg's SVGImageElement sends any href that is not a data: URI straight to
# stbi_load() -> fopen(), during parse rather than render. In Kodi that is a
# read of arbitrary local paths from inside an add-on that was handed a memory
# buffer, bypassing the VFS entirely - and pointing an href at a FIFO or a
# character device stalls the decode thread.
#
# depends/common/lunasvg/ carries a patch adding LUNASVG_DISABLE_EXTERNAL_RESOURCES
# and flags.txt turns it on. This test proves the shipped configuration blocks:
#
#   1. reading a local image file and rendering its contents
#   2. opening a non-image path at all
#
# while still rendering an ordinary SVG unchanged.
#
# The unguarded build is exercised too, but only as a diagnostic: if upstream
# ever removes file loading by itself, that half stops demonstrating anything
# while the assertions above still hold.
#
# Usage: tests/lunasvg-resources/run.sh [workdir]
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
deps=$root/depends/common/lunasvg
work=${1:-$(mktemp -d)}
mkdir -p "$work"

url=$(awk '{print $2}' "$deps/lunasvg.txt")
sha=$(cat "$deps/lunasvg.sha256")

cd "$work"
[ -f src.tar.gz ] || curl -sSL -o src.tar.gz "$url"
echo "$sha  src.tar.gz" | sha256sum -c - >/dev/null
echo "==> lunasvg pin verified: $url"

rm -rf src && mkdir src && tar xzf src.tar.gz -C src --strip-components=1
shopt -s nullglob
for p in "$deps"/*.patch; do
  echo "==> applying $(basename "$p")"
  ( cd src && patch -p1 -i "$p" >/dev/null )
done

# "guarded" takes the flags the add-on actually ships; "unguarded" is the same
# source with the option off, so any difference is the option and nothing else.
guarded_flags=()
while read -r flag; do
  [ -n "$flag" ] && guarded_flags+=("$flag")
done < "$deps/flags.txt"
cmake -S src -B build-guarded -DCMAKE_BUILD_TYPE=Release "${guarded_flags[@]}" -DLUNASVG_BUILD_EXAMPLES=ON >/dev/null
cmake --build build-guarded -j"$(nproc)" >/dev/null
cmake -S src -B build-unguarded -DCMAKE_BUILD_TYPE=Release -DLUNASVG_DISABLE_EXTERNAL_RESOURCES=OFF -DLUNASVG_BUILD_EXAMPLES=ON >/dev/null
cmake --build build-unguarded -j"$(nproc)" >/dev/null
echo "==> both builds done"

# A private file the SVG has no business seeing, well away from the CWD.
private=$work/private
rm -rf "$private" && mkdir -p "$private"
cat > canary.svg <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="#ff00ff"/></svg>
SVG
( cd "$private" && "$work/build-unguarded/examples/svg2png" "$work/canary.svg" 64x64 >/dev/null && mv canary.svg.png secret.png )

cat > read-file.svg <<SVG
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="64" height="64">
  <image xlink:href="$private/secret.png" width="64" height="64"/>
</svg>
SVG
cat > missing.svg <<SVG
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="64" height="64">
  <image xlink:href="$private/no-such-file.png" width="64" height="64"/>
</svg>
SVG
rm -f "$private/pipe" && mkfifo "$private/pipe"
cat > fifo.svg <<SVG
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="64" height="64">
  <image xlink:href="$private/pipe" width="64" height="64"/>
</svg>
SVG

render() { # render <build> <svg> <outname>; prints the exit status
  rm -rf "run-$1" && mkdir -p "run-$1" && rm -f "$3"
  ( cd "run-$1" && set +e
    ( timeout 30 "$work/build-$1/examples/svg2png" "$work/$2" 64x64 >/dev/null 2>&1 ) 2>/dev/null
    echo $? > status )
  [ -f "run-$1/$2.png" ] && cp "run-$1/$2.png" "$3" 2>/dev/null || true
  cat "run-$1/status"
}

# A guarded build that crashed on every input would satisfy every "no leak, no
# hang" check below by producing nothing at all, so each one is gated on the
# render having actually succeeded.
rendered_ok() { # rendered_ok <status> <outname>
  [ "$1" = "0" ] && [ -f "$2" ]
}

rc=0
echo
echo "==> diagnostic: the unguarded build, to show the vector is real"
render unguarded read-file.svg leak-unguarded.png >/dev/null
if cmp -s leak-unguarded.png "$private/secret.png"; then
  echo "    local file read and rendered (output byte-identical to the private file)"
else
  echo "    no leak - upstream behaviour may have changed; the assertions below still stand"
fi
st=$(render unguarded fifo.svg fifo-unguarded.png)
[ "$st" = "124" ] && echo "    FIFO opened: process blocked (exit 124)" || echo "    FIFO not opened (exit $st)"

# secret.png is the unguarded build's own render of canary.svg, so this also
# shows the option leaves ordinary output untouched.
echo
echo "==> 1. guarded build must still render an ordinary SVG"
st=$(render guarded canary.svg canary-guarded.png)
if ! rendered_ok "$st" canary-guarded.png; then
  echo "    FAIL - no render of a plain SVG (exit $st)"; rc=1
elif cmp -s canary-guarded.png "$private/secret.png"; then
  echo "    ok - byte-identical to the unguarded render"
else
  echo "    FAIL - differs from the unguarded render of the same file"; rc=1
fi

echo
echo "==> 2. guarded build must not render a local file's contents"
st_leak=$(render guarded read-file.svg leak-guarded.png)
st_missing=$(render guarded missing.svg missing-guarded.png)
if ! rendered_ok "$st_leak" leak-guarded.png || ! rendered_ok "$st_missing" missing-guarded.png; then
  echo "    FAIL - no render to compare (exit $st_leak / $st_missing)"; rc=1
elif cmp -s leak-guarded.png "$private/secret.png"; then
  echo "    FAIL - the private file still reaches the output"; rc=1
elif cmp -s leak-guarded.png missing-guarded.png; then
  echo "    ok - identical to the missing-file control"
else
  echo "    ok - private file not in the output (differs from the missing-file control)"
fi

echo
echo "==> 3. guarded build must not open a non-image path at all"
st=$(render guarded fifo.svg fifo-guarded.png)
if [ "$st" = "124" ]; then
  echo "    FAIL - still blocked on the FIFO, so the path was opened"; rc=1
elif ! rendered_ok "$st" fifo-guarded.png; then
  echo "    FAIL - no hang, but no render either (exit $st)"; rc=1
else
  echo "    ok - no hang, render completed (exit $st)"
fi

echo
[ $rc -eq 0 ] && echo "PASS" || echo "FAIL"
exit $rc
