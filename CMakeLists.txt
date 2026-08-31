cmake_minimum_required(VERSION 3.5...4.0)
project(imagedecoder.svg)

set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${PROJECT_SOURCE_DIR})

find_package(Kodi REQUIRED)
# plutovg (lunasvg's rasterizer, built as part of it) exports Threads::Threads in
# its link interface, so the target has to exist by the time lunasvg's config is
# pulled in - otherwise generation fails on an unknown target.
find_package(Threads REQUIRED)
find_package(lunasvg CONFIG REQUIRED)

include_directories(${KODI_INCLUDE_DIR}/.. # Hack way with "/..", matches the same approach
                                            # used by other out-of-tree Kodi imagedecoder addons
                    )

set(SVG_SOURCES src/SvgPicture.cpp)
set(SVG_HEADERS src/SvgPicture.h)

set(DEPLIBS lunasvg::lunasvg ${CMAKE_THREAD_LIBS_INIT})

build_addon(imagedecoder.svg SVG DEPLIBS)

include(CPack)
