/*
 *  Copyright (C) 2026 cinemaONE
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSE.md for more information.
 */

#include "SvgPicture.h"

#include <kodi/Filesystem.h>

#include <algorithm>
#include <cstring>

SvgPicture::SvgPicture(const kodi::addon::IInstanceInfo& instance)
  : CInstanceImageDecoder(instance)
{
}

bool SvgPicture::SupportsFile(const std::string& file)
{
  // Cheap sniff only - lunasvg's parser does the real validation later.
  kodi::vfs::CFile fileData;
  if (!fileData.OpenFile(file))
    return false;

  char header[512] = {};
  const ssize_t read = fileData.Read(header, sizeof(header) - 1);
  if (read <= 0)
    return false;

  return std::strstr(header, "<svg") != nullptr || std::strstr(header, "<?xml") != nullptr;
}

namespace
{
// Kodi passes its GPU maxTextureSize as an upper bound, not a real per-control
// request, and an SVG's own viewBox is usually far too small to serve as a
// native size. Report a fixed one instead. See README for the full reasoning.
constexpr unsigned int kNativeSize = 512;
constexpr unsigned int kMaxPlausibleHint = 4096; // no UI icon control asks for more than this
} // namespace

bool SvgPicture::LoadImageFromMemory(const std::string& mimetype,
                                     const uint8_t* buffer,
                                     size_t bufSize,
                                     unsigned int& width,
                                     unsigned int& height)
{
  m_document =
      lunasvg::Document::loadFromData(reinterpret_cast<const char*>(buffer), bufSize);
  if (!m_document)
  {
    kodi::Log(ADDON_LOG_ERROR, "%s: Failed to parse SVG data", __func__);
    return false;
  }

  if (width == 0 || height == 0 || width > kMaxPlausibleHint || height > kMaxPlausibleHint)
  {
    double docWidth = m_document->width();
    double docHeight = m_document->height();
    if (docWidth <= 0 || docHeight <= 0)
    {
      docWidth = kNativeSize;
      docHeight = kNativeSize;
    }

    // The size the SVG declares is the size it gets decoded at. Neither the
    // skin control's size nor the output resolution ever reaches an image
    // decoder, so the file itself is the only place the intended resolution
    // can be expressed - an asset meant to be drawn at 200px on a 4K screen
    // says so, and gets rasterized at exactly that. kNativeSize is only the
    // fallback for a file that declares no usable size at all.
    //
    // Only an upper bound is enforced, to keep a malformed or hostile file
    // from asking for an allocation that is never a plausible UI texture.
    const double longSide = std::max(docWidth, docHeight);
    if (longSide > kMaxPlausibleHint)
    {
      const double shrink = kMaxPlausibleHint / longSide;
      docWidth *= shrink;
      docHeight *= shrink;
    }

    width = static_cast<unsigned int>(docWidth + 0.5);
    height = static_cast<unsigned int>(docHeight + 0.5);
  }

  if (width == 0 || height == 0)
  {
    kodi::Log(ADDON_LOG_ERROR, "%s: SVG has no usable intrinsic size and none was requested",
              __func__);
    return false;
  }

  return true;
}

bool SvgPicture::Decode(uint8_t* pixels,
                        size_t pixelBufferSize,
                        unsigned int width,
                        unsigned int height,
                        unsigned int pitch,
                        ADDON_IMG_FMT format)
{
  if (!m_document)
    return false;

  if (format != ADDON_IMG_FMT_RGBA8 && format != ADDON_IMG_FMT_A8R8G8B8)
  {
    // Deliberately narrow: only the two byte orders Kodi actually asks for.
    kodi::Log(ADDON_LOG_ERROR,
              "%s: Unsupported target format (%d), only ADDON_IMG_FMT_RGBA8/A8R8G8B8 are "
              "implemented",
              __func__, static_cast<int>(format));
    return false;
  }

  kodi::Log(ADDON_LOG_DEBUG, "%s: Kodi requested decode at %ux%u", __func__, width, height);

  // Decode() gets its size from Kodi independently of LoadImageFromMemory(),
  // so re-check rather than risk a runaway allocation.
  if (width == 0 || height == 0 || width > kMaxPlausibleHint || height > kMaxPlausibleHint)
  {
    kodi::Log(ADDON_LOG_ERROR, "%s: Refusing implausible decode size %ux%u", __func__, width,
              height);
    return false;
  }

  // What the copy loop below actually reaches: every row starts at y * pitch,
  // and the last one writes width * 4 bytes into it. Kodi passes pitch * height,
  // which is never smaller, but the point of the argument is not to trust that.
  const size_t reach = static_cast<size_t>(height - 1) * pitch + static_cast<size_t>(width) * 4;
  if (reach > pixelBufferSize)
  {
    kodi::Log(ADDON_LOG_ERROR,
              "%s: Output buffer too small: %ux%u at pitch %u reaches %zu bytes, was given %zu",
              __func__, width, height, pitch, reach, pixelBufferSize);
    return false;
  }

  // plutovg computes analytic coverage antialiasing at whatever size it is
  // given, so rendering straight at the target size is both cheaper and no
  // worse than supersampling and averaging back down.
  lunasvg::Bitmap bitmap =
      m_document->renderToBitmap(static_cast<int>(width), static_cast<int>(height));
  if (bitmap.isNull())
  {
    kodi::Log(ADDON_LOG_ERROR, "%s: Rendering SVG to %ux%u failed", __func__, width, height);
    return false;
  }

  const uint8_t* src = bitmap.data();
  const unsigned int srcStride = static_cast<unsigned int>(bitmap.stride());

  for (unsigned int y = 0; y < height; ++y)
  {
    const uint8_t* srcRow = src + y * srcStride;
    uint8_t* dstRow = pixels + y * pitch;
    for (unsigned int x = 0; x < width; ++x)
    {
      // lunasvg's native premultiplied ARGB32 is already B,G,R,A in memory on
      // a little-endian target.
      const uint8_t b = srcRow[x * 4 + 0];
      const uint8_t g = srcRow[x * 4 + 1];
      const uint8_t r = srcRow[x * 4 + 2];
      const uint8_t a = srcRow[x * 4 + 3];

      uint8_t* dst = dstRow + x * 4;
      if (format == ADDON_IMG_FMT_A8R8G8B8)
      {
        dst[0] = b;
        dst[1] = g;
        dst[2] = r;
        dst[3] = a;
      }
      else // ADDON_IMG_FMT_RGBA8: plain (non-premultiplied) byte order
      {
        if (a == 0)
        {
          dst[0] = dst[1] = dst[2] = dst[3] = 0;
        }
        else
        {
          dst[0] = static_cast<uint8_t>(std::min(255u, (r * 255u + a / 2) / a));
          dst[1] = static_cast<uint8_t>(std::min(255u, (g * 255u + a / 2) / a));
          dst[2] = static_cast<uint8_t>(std::min(255u, (b * 255u + a / 2) / a));
          dst[3] = a;
        }
      }
    }
  }
  return true;
}

class ATTR_DLL_LOCAL CSvgAddon : public kodi::addon::CAddonBase
{
public:
  CSvgAddon() = default;
  ADDON_STATUS CreateInstance(const kodi::addon::IInstanceInfo& instance,
                              KODI_ADDON_INSTANCE_HDL& hdl) override
  {
    if (instance.IsType(ADDON_INSTANCE_IMAGEDECODER))
    {
      hdl = new SvgPicture(instance);
      return ADDON_STATUS_OK;
    }

    return ADDON_STATUS_NOT_IMPLEMENTED;
  }
};

ADDONCREATOR(CSvgAddon)
