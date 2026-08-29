# imagedecoder.svg addon for Kodi

This is a [Kodi](https://kodi.tv) image decoder addon for SVG (Scalable Vector Graphics)
images, rasterizing via [lunasvg](https://github.com/sammycage/lunasvg) (MIT licensed).

Kodi has no built-in SVG support — a skin `<texture>` tag can only reference raster formats.
This addon plugs into Kodi's existing, generic `kodi.imagedecoder` extension point (the same
one `imagedecoder.heif`, `imagedecoder.raw` and `imagedecoder.mpo` use), so once it is
installed and enabled, any `<texture>` reference to a `.svg` file renders through it
automatically — no core Kodi change and no skin-side registration required. Image decoders are
looked up globally by add-on type and MIME type, independent of which skin is active.

Because SVG is vector data, each texture is rasterized at the size Kodi actually asks for
rather than being scaled up from a fixed-size bitmap, so a single `.svg` stays sharp at any
resolution instead of needing a per-resolution PNG ladder.

## Status

Built, cross-compiled for aarch64, and confirmed working end-to-end on real hardware
(Ugoos SK1 running CoreELEC), rendering SVG textures through the normal Kodi skin texture path
with correct transparency.

> [!NOTE]
> Correct **transparency** additionally requires a core Kodi fix: `CImageDecoder` never set
> `IImage::m_hasAlpha`, so every `kodi.imagedecoder` addon's output was treated as fully
> opaque. Without that fix SVG textures render with a black background. The fix is generic
> (it benefits `imagedecoder.heif`/`.raw`/`.mpo` equally) and reached `xbmc/xbmc` as
> [PR #29068](https://github.com/xbmc/xbmc/pull/29068), which also raises the ImageDecoder
> instance API to 3.1.0 — the version this add-on now builds against.

## Known limitations

lunasvg is a **static** renderer, and three SVG features it does not implement are worth knowing
about before reaching for this add-on. All three are silent: the file loads, decoding succeeds,
and the result is simply missing something.

| Feature | Supported | What you get instead |
|---|---|---|
| `<animate>`, `<animateTransform>` | no | the first frame, frozen at its start value |
| `<filter>` (`feGaussianBlur`, `feBlend`, `feImage`, ...) | no | the unfiltered source graphic |
| `transform` inside a CSS `style=` attribute | no | the element at the untransformed origin |

The first two are lunasvg's own documented exceptions - it calls out "animation, filters, and
scripts", and says animation is *unlikely to be supported in the future* because static rendering
is the design. Filters it describes as something that may be added later. The third is not
documented anywhere; it was found by testing, and it is the one most likely to be mistaken for a
bug in this add-on, because the `transform` **attribute** works perfectly and only the CSS
property form is dropped.

`docs/lunasvg-limitations.svg` exercises all three. Rendered through lunasvg:

![lunasvg limitations](docs/lunasvg-limitations.png)

The green box uses the `transform` attribute and lands correctly. The blue box asks for
`filter="url(#soft)"` and comes out hard-edged. The red box is positioned with
`style="transform:translate(300px,40px)"` and has collapsed onto the green one at the origin
instead of sitting on the right. The small circle carries an `<animate>` and sits at its start
value.

Practically: this is fine for what the add-on was built for - flat, single-colour icons and
symbols, which is the overwhelming majority of SVG in a Kodi skin. It is not suitable for
complex illustrative artwork that leans on filters, and it cannot do animation at all.

Animation would need more than a different renderer, incidentally. The `kodi.imagedecoder`
extension point has no frame, delay or loop concept anywhere in its C API - `Decode()` fills one
buffer, once. Kodi's animated textures take an entirely different route
(`CTextureBundleXBT::LoadAnim`, via the `.gif` branch of `CGUITextureManager::Load`). Supporting
animated SVG would mean extending `kodi.binary.instance.imagedecoder` with multi-frame output,
which is an add-on API version bump rather than anything an add-on can do on its own.

## Implementation notes

Details that were established by reading Kodi's actual source and confirming on hardware, and
that are easy to get wrong if this addon is ever extended:

- **Two MIME types are declared, not one.** For a bare `<texture>foo.svg</texture>` skin
  reference, Kodi's texture loader builds the MIME type as `"image/" + <file extension>` —
  literally `image/svg` — rather than consulting its own `CMime` table, which would correctly
  give `image/svg+xml`. Both are declared in `addon.xml.in` so real skin texture loading
  actually matches.
- **The requested pixel format is `ADDON_IMG_FMT_A8R8G8B8`,** not `RGBA8` as might be assumed.
  lunasvg's native premultiplied ARGB32 bitmap is already byte-identical to this, so that path
  is a direct copy with no conversion.
- **Kodi's width/height argument is an upper bound, not a request.** The skin texture path
  passes the GPU's `maxTextureSize` (16383 observed) when the control has no explicit ideal
  size. Echoing that back as the image's "native" size causes a runaway allocation; using the
  SVG's own export-time `viewBox` (often 24x24) instead causes a blurry GPU upscale. This
  addon reports a fixed 512px long side and hard-caps implausible hints.
- **The size an SVG declares is the size it is decoded at.** Neither the skin control's size
  nor the output resolution reaches an image decoder (see below), so the file itself is the only
  place the intended resolution can be expressed. An icon meant to be drawn at 100 units on
  Kodi's 1080 skin grid - 200px on a 4K screen - declares `width="200"` and is rasterized at
  exactly that, rendering natively there and downscaling 2x at 1080p.

  Only an upper bound is enforced (4096px), to stop a malformed file requesting an allocation
  that is never a plausible UI texture. Below that the file is trusted: a file declaring
  `width="24"` really is decoded at 24 and will look poor if drawn larger, which is the
  caller's responsibility. The 512px default applies only to a file declaring no usable size at
  all - rare, since lunasvg falls back to the viewBox when `width`/`height` are absent.
- **No supersampling.** plutovg computes analytic coverage antialiasing at whatever size it is
  handed, so rendering straight at the target size is both cheaper and no worse than rendering
  4x and averaging down.

### Why an SVG can look softer than a font glyph

An earlier version of these notes blamed plutovg's "linear coverage-to-alpha mapping, unlike
FreeType's gamma-tuned text path". That is wrong: Kodi rasterizes glyphs with plain
`FT_RENDER_MODE_NORMAL` and applies no gamma correction anywhere in `GUIFontTTF.cpp`. The real
differences are elsewhere.

- **Hinting.** `GUIFontTTF.cpp` loads glyphs with `FT_LOAD_TARGET_LIGHT`, so FreeType grid-fits
  stems onto pixel boundaries. lunasvg/plutovg do no grid-fitting at all, so an unhinted edge
  straddles pixels where a hinted one lands cleanly. This is not an antialiasing-quality
  difference.
- **Decode size.** A font glyph is always rasterized into the atlas at its final pixel size. A
  skin `<texture>` is not: `CGUITextureManager::Load()` calls `CTexture::LoadFromFile(strPath)`
  with no ideal width/height, so `CTexture::LoadIImage` falls back to whatever size this addon
  reports, and the GPU rescales from there to the control size. Measured on a real Kodi: three
  controls declared at 100, 400 and 800 skin px all produced a decode request of `512x512`, and
  the same was true at both 1920x1080 and 3840x2160 output. Neither the control size nor the
  output resolution reaches the decoder - which is why an SVG's own declared size is the only
  way to opt an asset into rendering natively on a 4K screen.
- **No mipmaps.** `SetMipmapping()` is called only by the slideshow and RetroPlayer shader
  code, never by the skin texture path, so that GPU rescale is plain bilinear. Note this
  applies to the *normal* texture path only - see below.

### Smoother downscaling via `background="true"`

The bilinear-minification softness above can be avoided from the skin side. A
`<texture background="true">` sets `CTextureInfo::useLarge`, which routes the texture through
`CGUILargeTextureManager` instead of `CGUITextureManager::Load()`. That path passes the
control's size down to `CTexture::LoadFromFile()`, so the image is resampled on the CPU to the
size it is drawn at rather than handed to the GPU oversized and minified bilinearly.

Measured on a 4K output with a 1080 skin grid, drawing this addon's output against the same
outline rendered as a font glyph (mid-tone fraction along the edges; higher means a smoother
antialiased ramp):

| control size | font glyph | plain `<texture>` | `background="true"` |
|---|---|---|---|
| 18 skin px | 46.7% | 14.2% | 45.5% |
| 36 skin px | 26.1% | 14.8% | 25.7% |
| 72 skin px | 13.6% | 13.9% | 14.6% |

Two caveats, both consequences of `CTextureCache` being keyed on URL alone:

- **The first use of a file is not resampled.** It runs before the cache holds a raster, takes
  the `CacheImage()` fallthrough in `CImageLoader::DoWork()`, and comes back looking like the
  plain path. Only later requests load the cached copy through
  `LoadFromFile(cached, targetW, targetH, ...)`.
- **It is still one raster per file, at the size this addon decoded it.** `background="true"`
  buys resampling, not per-use re-rasterization, so it does not change the "decode resolution is
  per-file" rule below - an SVG drawn *larger* than its declared size gains nothing from it.

### Decode resolution is per-file, not per-use

The size an SVG is decoded at comes from the file, and one file gets one decode resolution no
matter how many controls draw it. A consuming add-on cannot ask for a different size per use:
`ImageFactory::CreateLoader()` uses the filename only to derive `"image/" + extension` and then
discards it, and the decoder is constructed with the mimetype alone. `SupportsFile()` - the one
interface method that takes a filename - is called for audio decoders and the file-extension
provider, never for image decoders. So the addon does not know which file it is decoding, nor
at what size it will be drawn.

For one piece of artwork used at two sizes, ship two files declaring different `width`/`height`.
Kodi's texture manager caches by path and would treat them as separate textures regardless, so
nothing is lost by not sharing the file. Generating the variants from one master fits naturally
into whatever already produces the artwork.

This is the same shape as the rest of Kodi rather than an anomaly: a skin declares a separate
`<font>` entry per point size of the same typeface, and raster assets ship per intended size.

Wiring the control's size through would need `CGUITextureManager::Load()` to key its cache on
(path, size) rather than path alone, since one texture is currently shared by every control
referencing it. That is a design change to the texture cache, not a small patch.

## Build instructions

When building the addon you have to use the correct branch depending on which version of Kodi
you are building against. For example, if you are building the `master` branch of Kodi you
should checkout the `master` branch of this repository.

### Linux

The following instructions assume you will have built Kodi already in the `kodi-build`
directory suggested by the Kodi README.

1. `git clone https://github.com/xbmc/xbmc.git`
2. `git clone https://github.com/cinema-ONE/imagedecoder.svg.git`
3. `cd imagedecoder.svg && mkdir build && cd build`
4. `cmake -DADDONS_TO_BUILD=imagedecoder.svg -DADDON_SRC_PREFIX=../.. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=../../xbmc/kodi-build/addons -DPACKAGE_ZIP=1 ../../xbmc/cmake/addons`
5. `make`

The addon files will be placed in `../../xbmc/kodi-build/addons`, so if you build Kodi from
source and run it directly the addon will be available as a system addon.

`lunasvg` is pulled and built automatically by Kodi's addon dependency system from
`depends/common/lunasvg/`, and is linked statically, so the built addon has no external
lunasvg/plutovg runtime dependency.

## License

GPL-2.0-or-later, matching Kodi's own `imagedecoder.*` addons. `lunasvg` and `plutovg` are MIT
licensed.

`imagedecoder.svg/resources/icon.png` is the [W3C SVG logo](https://www.w3.org/Graphics/SVG/), designed by
Harvey Rayner for the 2006 SVG Logo Contest and adopted by W3C in 2009. Taken from
[Wikimedia Commons](https://commons.wikimedia.org/wiki/File:SVG_Logo.svg), where it is tagged
both public domain (below the threshold of originality) and
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/); the only change made was
rasterizing it to a 256x256 PNG. W3C's own
[SVG logo terms](https://www.w3.org/2009/08/svg-logos.html) explicitly encourage its use by
software that renders SVG natively without plug-ins, which is what this addon does.

This project is written with AI assistance, and says so rather than leaving it to be inferred.
