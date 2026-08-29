/*
 *  Copyright (C) 2026 cinemaONE
 *
 *  SPDX-License-Identifier: GPL-2.0-or-later
 *  See LICENSE.md for more information.
 */

#pragma once

#include <kodi/addon-instance/ImageDecoder.h>

#include <lunasvg.h>

#include <cstddef>
#include <cstdint>
#include <memory>

class ATTR_DLL_LOCAL SvgPicture : public kodi::addon::CInstanceImageDecoder
{
public:
  SvgPicture(const kodi::addon::IInstanceInfo& instance);
  ~SvgPicture() override = default;

  bool SupportsFile(const std::string& file) override;
  bool LoadImageFromMemory(const std::string& mimetype,
                           const uint8_t* buffer,
                           size_t bufSize,
                           unsigned int& width,
                           unsigned int& height) override;
  bool Decode(uint8_t* pixels,
              size_t pixelBufferSize,
              unsigned int width,
              unsigned int height,
              unsigned int pitch,
              ADDON_IMG_FMT format) override;

private:
  // Parsed once in LoadImageFromMemory() and re-rendered (at whatever size
  // Kodi asks for) in Decode() - SVG is vector data, so unlike raster
  // decoders there is no fixed "native" pixel size to decode at; every
  // Decode() call can rasterize at a different requested resolution without
  // any quality loss.
  std::unique_ptr<lunasvg::Document> m_document;
};
