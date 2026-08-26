# External resource access

An SVG handed to this add-on arrives as a memory buffer. Everything else the decoder needs should
come through Kodi's VFS, which is what enforces source restrictions and credentials.

lunasvg does not work that way. `SVGImageElement::parseAttribute()` passes any `href` that is not a
`data:` URI to `stbi_load()` -> `fopen()`, with no scheme check and no base directory, and it does
so **during parse** — before `Decode()` is reached. Two consequences, both demonstrated by
`run.sh`:

- an SVG can read a local image file and render its contents (verified byte-identical to the
  source file)
- an SVG can make the decoder open *any* path, not only images: pointed at a FIFO, the process
  blocks, which in Kodi stalls the decode thread

`depends/common/lunasvg/` carries a patch adding `LUNASVG_DISABLE_EXTERNAL_RESOURCES`, mirroring
the `LUNASVG_DISABLE_LOAD_SYSTEM_FONTS` option upstream already has, and `flags.txt` turns it on.
A blocked reference then degrades exactly like a broken one.

`run.sh` builds the pinned tarball twice from one patched source — once with the flags the add-on
ships, once with the option off — so any difference is the option and nothing else. The unguarded
half is diagnostic: it shows the vector is real in the same run, and if upstream ever removes file
loading on its own it simply stops demonstrating anything while the assertions still hold.

Each assertion is gated on the guarded render having succeeded and written a PNG, and the first one
renders an ordinary SVG and requires it to come out byte-identical to the unguarded build's. A build
that rejected or crashed on everything would otherwise pass "no leak" and "no hang" by producing
nothing.

Not addressed: `plutovg` also reads fonts from system directories. That path is reachable only from
the directory scan, its filenames are not attacker-controlled, and lunasvg already gates it behind
`LUNASVG_DISABLE_LOAD_SYSTEM_FONTS` — which would disable `<text>` rendering entirely, so it is a
trade-off rather than a free win.
